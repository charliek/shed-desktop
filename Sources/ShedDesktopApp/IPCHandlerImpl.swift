// IPCHandlerImpl.swift
//
// Bridges IPCServer's IPCHandler protocol to the running app. handle()
// runs on the handler's own actor; each op is a @MainActor method that
// reaches AppModel/AppState via the UiBridge and returns only Sendable
// results (the non-Sendable bridge never crosses the actor boundary).
// Mirrors roost's handler: strict params decoding (deny unknown fields)
// and an in-process screenshot.

import AppKit
import Foundation
import ShedKit

actor IPCHandlerImpl: IPCHandler {
    private let socketPath: String
    private let appLabel: String
    private let appID: String

    init(socketPath: String, appLabel: String, appID: String) {
        self.socketPath = socketPath
        self.appLabel = appLabel
        self.appID = appID
    }

    func handle(op: String, params: AnyCodable?) async throws -> AnyCodable? {
        switch op {
        case "identify":
            _ = try decodeParams(params, as: EmptyParams.self, expected: ["client_name", "client_version"])
            return try await encodeResult(identify())
        case "app.screenshot":
            return try await screenshot(params: params)
        case "app.window_metrics":
            _ = try decodeParams(params, as: EmptyParams.self, expected: [])
            return try await encodeResult(windowMetricsOp())
        case "ui.state":
            _ = try decodeParams(params, as: EmptyParams.self, expected: [])
            return try await encodeResult(uiStateOp())
        case "ui.navigate":
            let p = try decodeParams(params, as: PaneParams.self, expected: ["pane"])
            return try await uiNavigate(pane: p.pane)
        case "ui.show_window":
            _ = try decodeParams(params, as: EmptyParams.self, expected: [])
            try await showWindowOp()
            return emptyResult
        case "ui.open_preferences":
            _ = try decodeParams(params, as: EmptyParams.self, expected: [])
            try await openPreferencesOp()
            return emptyResult
        case "ui.open_menu":
            let p = try decodeParams(params, as: OpenMenuParams.self, expected: ["open"])
            try await openMenuOp(p.open)
            return AnyCodable(["open": p.open])
        case "host.list":
            _ = try decodeParams(params, as: EmptyParams.self, expected: [])
            return try await encodeResult(hostListOp())
        case "sheds.list":
            let p = try decodeParams(params, as: HostFilterParams.self, expected: ["host"])
            return try await encodeResult(shedsList(host: p.host))
        case "sheds.refresh":
            _ = try decodeParams(params, as: EmptyParams.self, expected: [])
            try await shedsRefreshOp()
            return emptyResult
        case "shed.start", "shed.stop", "shed.reset", "shed.delete":
            guard let action = ShedAction(rawValue: String(op.dropFirst("shed.".count))) else {
                throw IPCHandlerError.unknownOp(op)
            }
            let p = try decodeParams(params, as: ShedActionParams.self, expected: ["host", "name"])
            try await shedActionOp(action, host: p.host, name: p.name)
            return emptyResult
        case "create.start":
            let p = try decodeParams(params, as: CreateStartParams.self,
                expected: ["host", "name", "repo", "local_dir", "image", "backend", "cpus", "memory_mb", "no_provision"])
            return try await createStartOp(p)
        case "create.status":
            let p = try decodeParams(params, as: CreateStatusParams.self, expected: ["create_id"])
            return try await encodeResult(createStatusOp(id: p.createID))
        case "terminal.preview":
            let p = try decodeParams(params, as: TerminalParams.self, expected: ["host", "shed", "session"])
            return try await encodeResult(terminalPreviewOp(p))
        case "terminal.open":
            let p = try decodeParams(params, as: TerminalParams.self, expected: ["host", "shed", "session"])
            return try await encodeResult(terminalOpenOp(p))
        case "rc.classify":
            let p = try decodeParams(params, as: RcClassifyParams.self, expected: ["kind", "pane"])
            let cls = RemoteControl.classifyPane(kind: p.kind, pane: p.pane)
            return try encodeResult(RcClassifyResult(state: cls.state, url: cls.url))
        case "rc.list":
            let p = try decodeParams(params, as: RcListParams.self, expected: ["host", "shed"])
            return try await encodeResult(rcListOp(p))
        case "rc.launch":
            let p = try decodeParams(params, as: RcLaunchParams.self,
                expected: ["host", "shed", "kind", "display_name", "workdir"])
            return try await encodeResult(rcLaunchOp(p))
        case "rc.kill":
            let p = try decodeParams(params, as: RcKillParams.self, expected: ["host", "shed", "slug"])
            try await rcKillOp(p)
            return emptyResult
        case "approvals.list":
            _ = try decodeParams(params, as: EmptyParams.self, expected: [])
            return try await encodeResult(approvalsListOp())
        case "approval.decide":
            let p = try decodeParams(params, as: ApprovalDecideParams.self, expected: ["id", "decision", "grant_session"])
            try await approvalDecideOp(p)
            return emptyResult
        case "activity.list":
            let p = try decodeParams(params, as: ActivityListParams.self, expected: ["limit"])
            return try await encodeResult(activityListOp(limit: p.limit))
        case "policy.set":
            let p = try decodeParams(params, as: PolicySetParams.self, expected: ["rules"])
            try await policySetOp(p)
            return emptyResult
        default:
            throw IPCHandlerError.unknownOp(op)
        }
    }

    // MARK: - @MainActor ops (the bridge is fetched + used here, never returned)

    @MainActor
    private func uiBridge() throws -> any UiBridge {
        guard let ui = ShedBackend.shared.ui else {
            throw IPCHandlerError.internalError("UI not registered")
        }
        return ui
    }

    @MainActor
    private func identify() -> IdentifyResult {
        IdentifyResult(
            socketPath: socketPath,
            pid: Int32(ProcessInfo.processInfo.processIdentifier),
            appLabel: appLabel,
            appID: appID,
            uiVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            protocolVersion: ipcProtocolVersion,
            testMode: ShedBackend.shared.testMode,
            mockBaseURL: ShedBackend.shared.mockBaseURL)
    }

    @MainActor private func windowMetricsOp() throws -> WindowMetrics { try uiBridge().windowMetrics() }
    @MainActor private func uiStateOp() throws -> UIState { try uiBridge().uiState() }
    @MainActor private func showWindowOp() throws { try uiBridge().showWindow() }
    @MainActor private func openPreferencesOp() throws { try uiBridge().openPreferences() }
    @MainActor private func openMenuOp(_ open: Bool) throws { try uiBridge().setMenuOpen(open) }
    @MainActor private func hostListOp() throws -> HostListResult { HostListResult(hosts: try uiBridge().uiState().hosts) }

    @MainActor private func shedsRefreshOp() async throws {
        try await uiBridge().refreshSheds()
    }

    @MainActor private func shedActionOp(_ action: ShedAction, host: String?, name: String) async throws {
        try await uiBridge().shedAction(action, host: host, name: name)
    }

    @MainActor private func createStartOp(_ p: CreateStartParams) throws -> AnyCodable? {
        let id = try uiBridge().startCreate(host: p.host, request: p.request)
        return AnyCodable(["create_id": id])
    }

    @MainActor private func createStatusOp(id: String) throws -> CreateProgress {
        guard let status = try uiBridge().createStatus(id: id) else {
            throw IPCHandlerError.notFound("no create with id \(id)")
        }
        return status
    }

    @MainActor private func terminalPreviewOp(_ p: TerminalParams) throws -> TerminalCommand {
        try uiBridge().terminalCommand(shed: p.shed, host: p.host, session: p.session)
    }

    @MainActor private func rcListOp(_ p: RcListParams) async throws -> RcListResult {
        RcListResult(sessions: try await uiBridge().rcList(host: p.host, shed: p.shed))
    }

    @MainActor private func rcLaunchOp(_ p: RcLaunchParams) async throws -> RcSession {
        try await uiBridge().rcLaunch(host: p.host, shed: p.shed, kind: p.kind, displayName: p.displayName, workdir: p.workdir)
    }

    @MainActor private func rcKillOp(_ p: RcKillParams) async throws {
        try await uiBridge().rcKill(host: p.host, shed: p.shed, slug: p.slug)
    }

    @MainActor private func approvalsListOp() throws -> ApprovalListResult {
        ApprovalListResult(approvals: try uiBridge().approvalsList())
    }

    @MainActor private func approvalDecideOp(_ p: ApprovalDecideParams) async throws {
        try await uiBridge().decideApproval(id: p.id, decision: p.decision, grantSession: p.grantSession)
    }

    @MainActor private func activityListOp(limit: Int) throws -> ActivityListResult {
        ActivityListResult(entries: try uiBridge().activityList(limit: limit))
    }

    @MainActor private func policySetOp(_ p: PolicySetParams) throws {
        guard ShedBackend.shared.testMode else {
            throw IPCHandlerError.notEnabled("policy.set requires SHED_DESKTOP_TEST_MODE=1")
        }
        try uiBridge().setPolicyRules(p.rules)
    }

    @MainActor private func terminalOpenOp(_ p: TerminalParams) throws -> TerminalCommand {
        // Never spawn a terminal under the test harness.
        guard !ShedBackend.shared.testMode else {
            throw IPCHandlerError.notEnabled("terminal.open is disabled in test mode (use terminal.preview)")
        }
        return try uiBridge().openTerminal(shed: p.shed, host: p.host, session: p.session)
    }

    @MainActor
    private func uiNavigate(pane: String) throws -> AnyCodable? {
        guard try uiBridge().navigate(toPane: pane) else {
            throw IPCHandlerError.invalidParam("unknown pane: \(pane) (want sheds|approvals|agents|activity)")
        }
        return AnyCodable(["pane": pane])
    }

    @MainActor
    private func shedsList(host: String?) throws -> ShedListResult {
        let sheds = try uiBridge().uiState().sheds
        let filtered = host.map { h in sheds.filter { $0.host == h } } ?? sheds
        return ShedListResult(sheds: filtered)
    }

    @MainActor
    private func screenshot(params: AnyCodable?) throws -> AnyCodable? {
        let p = try decodeParams(params, as: ScreenshotParams.self, expected: ["scale", "surface"])
        guard (1...2).contains(p.scale) else {
            throw IPCHandlerError.invalidParam("scale must be 1 or 2, got \(p.scale)")
        }
        guard let window = try uiBridge().window(for: p.surface) else {
            let hint = p.surface == .menu ? "menu is not open; call ui.open_menu {open:true} first" : "no window to capture"
            throw IPCHandlerError.internalError(hint)
        }
        do {
            let img = try captureWindowPNG(window, scale: p.scale)
            return AnyCodable([
                "png": img.png.base64EncodedString(),
                "width": img.width,
                "height": img.height,
                "scale": p.scale,
                "surface": p.surface.rawValue,
            ])
        } catch let e as ScreenshotError {
            throw IPCHandlerError.internalError("\(e)")
        }
    }

    private var emptyResult: AnyCodable? { AnyCodable([:] as [String: Any]) }
}

// MARK: - params + results

private struct EmptyParams: Decodable {}

private struct PaneParams: Decodable { let pane: String }

private struct OpenMenuParams: Decodable { let open: Bool }

private struct HostFilterParams: Decodable { let host: String? }

private struct ShedActionParams: Decodable {
    let host: String?
    let name: String
}

/// The create body fields (decoded straight into `CreateShedRequest`, the
/// single owner of that field list) plus the flat `host` selector.
private struct CreateStartParams: Decodable {
    let host: String?
    let request: CreateShedRequest

    init(from decoder: Decoder) throws {
        self.request = try CreateShedRequest(from: decoder)
        self.host = try decoder.container(keyedBy: HostKey.self).decodeIfPresent(String.self, forKey: .host)
    }
    private enum HostKey: String, CodingKey { case host }
}

private struct CreateStatusParams: Decodable {
    let createID: String
    enum CodingKeys: String, CodingKey { case createID = "create_id" }
}

private struct TerminalParams: Decodable {
    let host: String?
    let shed: String
    let session: String?
}

private struct RcClassifyParams: Decodable { let kind: RcKind; let pane: String }
private struct RcListParams: Decodable { let host: String?; let shed: String? }
private struct RcKillParams: Decodable { let host: String?; let shed: String; let slug: String }

private struct RcLaunchParams: Decodable {
    let host: String?
    let shed: String
    let kind: RcKind
    let displayName: String?
    let workdir: String?

    enum CodingKeys: String, CodingKey {
        case host, shed, kind, workdir
        case displayName = "display_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.host = try c.decodeIfPresent(String.self, forKey: .host)
        self.shed = try c.decode(String.self, forKey: .shed)
        self.kind = try c.decodeIfPresent(RcKind.self, forKey: .kind) ?? .default
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        self.workdir = try c.decodeIfPresent(String.self, forKey: .workdir)
    }
}

private struct RcListResult: Encodable, Sendable { let sessions: [RcSession] }
private struct RcClassifyResult: Encodable, Sendable { let state: RcState; let url: String? }

private struct ApprovalDecideParams: Decodable {
    let id: String
    let decision: ApprovalDecision
    let grantSession: Bool
    enum CodingKeys: String, CodingKey {
        case id, decision
        case grantSession = "grant_session"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.decision = try c.decode(ApprovalDecision.self, forKey: .decision)
        self.grantSession = try c.decodeIfPresent(Bool.self, forKey: .grantSession) ?? false
    }
}

private struct ActivityListParams: Decodable {
    let limit: Int
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 200
    }
    enum CodingKeys: String, CodingKey { case limit }
}

private struct PolicySetParams: Decodable { let rules: [PolicyRule] }

private struct ApprovalListResult: Encodable, Sendable { let approvals: [ApprovalRequest] }
private struct ActivityListResult: Encodable, Sendable { let entries: [AuditEntry] }

private struct ScreenshotParams: Decodable {
    let scale: Int
    let surface: ScreenshotSurface
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.scale = try c.decodeIfPresent(Int.self, forKey: .scale) ?? 1
        self.surface = try c.decodeIfPresent(ScreenshotSurface.self, forKey: .surface) ?? .window
    }
    enum CodingKeys: String, CodingKey { case scale, surface }
}

private struct IdentifyResult: Encodable, Sendable {
    let socketPath: String
    let pid: Int32
    let appLabel: String
    let appID: String
    let uiVersion: String
    let protocolVersion: UInt32
    let testMode: Bool
    let mockBaseURL: String?
    enum CodingKeys: String, CodingKey {
        case socketPath = "socket_path"
        case pid
        case appLabel = "app_label"
        case appID = "app_id"
        case uiVersion = "ui_version"
        case protocolVersion = "protocol_version"
        case testMode = "test_mode"
        case mockBaseURL = "mock_base_url"
    }
}

private struct HostListResult: Encodable, Sendable { let hosts: [ShedHost] }
private struct ShedListResult: Encodable, Sendable { let sheds: [Shed] }

// MARK: - decode/encode helpers (ported from roost)

private func decodeParams<T: Decodable>(
    _ params: AnyCodable?, as: T.Type, expected: Set<String>
) throws -> T {
    let raw = params?.value ?? [String: Any]()
    if let dict = raw as? [String: Any] {
        let extras = Set(dict.keys).subtracting(expected)
        if !extras.isEmpty {
            throw IPCHandlerError(code: "unknown-field",
                message: "unknown params: \(extras.sorted().joined(separator: ", "))")
        }
    }
    do {
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        throw IPCHandlerError.invalidParam("\(error)")
    }
}

private func encodeResult<T: Encodable>(_ value: T) throws -> AnyCodable? {
    let data = try JSONEncoder().encode(value)
    let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return AnyCodable(any)
}
