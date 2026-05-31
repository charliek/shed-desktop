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
    @MainActor private func openMenuOp(_ open: Bool) throws { try uiBridge().setMenuOpen(open) }
    @MainActor private func hostListOp() throws -> HostListResult { HostListResult(hosts: try uiBridge().uiState().hosts) }

    @MainActor private func shedsRefreshOp() async throws {
        try await uiBridge().refreshSheds()
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
