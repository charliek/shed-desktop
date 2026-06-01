// AppModel.swift
//
// The app's coordinator: owns the AppState view-model, one
// ShedServerClient per configured host, the host poller, the dashboard
// NSWindow + the menu-bar NSStatusItem/NSPopover, and the IPC server. It
// is the sole UiBridge conformer, so the IPC handler reaches all
// main-thread UI/state through it.
//
// Windows are AppKit-managed (NSHostingView around SwiftUI) rather than a
// SwiftUI WindowGroup, so screenshots have a stable NSWindow ref and
// show/hide is deterministic for the test harness — see the build plan's
// screenshot section.

import AppKit
import Foundation
import ShedKit
import ShedDesktopUI
import SwiftUI

@MainActor
final class AppModel: NSObject, UiBridge {
    let state = AppState()

    private var clients: [String: ShedServerClient] = [:]
    private var defaultServerName: String?
    private var creates: [String: CreateProgress] = [:]
    /// In-memory RC session table for test mode (no SSH); keyed by slug.
    private var rcTable: [String: RcSession] = [:]
    private var pollTask: Task<Void, Never>?
    private var ipcServer: IPCServer?

    // M3: approvals
    private var hostAgent: HostAgentClient?
    // Replaced from preferences in loadPreferences(); empty rules fail-safe
    // to a Touch ID prompt via PolicyEngine.decide.
    private var policyEngine = PolicyEngine(rules: [])
    /// Per-namespace + per-shed rules (the default rule comes from prefs);
    /// persisted via PreferencesStore.policyRules.
    private var extraRules: [PolicyRule] = []
    private var auditStore: AuditStore?
    private var sessionGrants: [SessionGrantKey: Date] = [:]
    /// A queued prompt: the request plus the gate to apply when the user acts.
    private struct PendingApproval { let request: ApprovalRequest; let gate: PolicyGate }
    private var pending: [String: PendingApproval] = [:]
    private var hostAgentTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    /// Actionable Approve/Deny notifications (Fake under the harness).
    private var notifier: (any NotificationPresenter)?

    private let grantTTL: TimeInterval = 4 * 3600

    // M4: preferences
    private let prefsStore = PreferencesStore()
    private let prefs = Preferences()
    private var prefsWindow: NSWindow?

    private(set) var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    private let pollInterval: Duration = .seconds(5)

    // MARK: - lifecycle

    func start(profile: BundleProfile) {
        ShedBackend.shared.start(profile: profile)
        ShedBackend.shared.registerUI(self)
        loadConfigAndClients()
        loadPreferences()
        wireActions()
        buildMainWindow()
        buildStatusItem()
        bindIPC(profile: profile)
        startPolling()
        startApprovals(profile: profile)
    }

    private func loadPreferences() {
        let testMode = ShedBackend.shared.testMode
        prefs.launchAtLogin = testMode ? false : LoginItem.isEnabled
        prefs.terminalTemplate = prefsStore.terminalTemplate
        prefs.defaultApprovalMode = prefsStore.defaultApprovalMode
        // Apply the stored default mode + persisted per-namespace/per-shed rules.
        extraRules = prefsStore.policyRules
        rebuildPolicy()
        publishPolicyPrefs()

        prefs.onLaunchAtLogin = { [weak self] on in
            guard let self else { return }
            // Never register a real login item under the test harness. The
            // SMAppService status is the source of truth (no separate
            // persisted flag), re-read on next launch.
            guard !ShedBackend.shared.testMode else { return }
            do {
                try LoginItem.setEnabled(on)
                if on && !LoginItem.isEnabled {
                    // register() succeeded but the item is .requiresApproval.
                    self.state.lastError = "Approve “shed desktop” in System Settings › Login Items to finish enabling launch at login."
                }
            } catch {
                self.state.lastError = "launch at login: \(error)"
                self.prefs.launchAtLogin = LoginItem.isEnabled
            }
        }
        prefs.onTerminalTemplate = { [weak self] template in
            self?.prefsStore.terminalTemplate = template
        }
        prefs.onDefaultMode = { [weak self] mode in
            guard let self else { return }
            self.prefsStore.defaultApprovalMode = mode
            self.rebuildPolicy()
        }
        prefs.onNamespaceMode = { [weak self] ns, mode in self?.setNamespaceMode(ns, mode: mode) }
        prefs.onRemoveShedRule = { [weak self] server, shed in self?.removeShedRule(server: server, shed: shed) }
    }

    // MARK: - policy rules (default + per-namespace + per-shed)

    private func rebuildPolicy() {
        policyEngine = PolicyEngine(rules: [prefsStore.defaultApprovalMode.rule] + extraRules)
    }

    private func persistAndRebuild() {
        prefsStore.policyRules = extraRules
        rebuildPolicy()
        publishPolicyPrefs()
    }

    /// Mirror the current extra rules into the preferences view-model.
    private func publishPolicyPrefs() {
        var modes: [String: ApprovalMode] = [:]
        for r in extraRules where r.scope == .namespace {
            if let ns = r.namespace, let m = ApprovalMode(action: r.action, gate: r.gate) { modes[ns] = m }
        }
        prefs.namespaceModes = modes
        prefs.shedRules = extraRules
            .filter { $0.scope == .shed }
            .map { ShedRuleRow(server: $0.server ?? "", shed: $0.shed ?? "") }
    }

    private func addShedRule(server: String, shed: String) {
        // Store the server verbatim ("" = the single/unnamed server) rather than
        // collapsing "" → nil: nil is reserved for an explicit any-server rule,
        // so a single-server grant never silently widens to other servers.
        extraRules.removeAll { $0.scope == .shed && $0.shed == shed && ($0.server ?? "") == server }
        extraRules.append(PolicyRule(scope: .shed, server: server, shed: shed, action: .approve, gate: .none))
        persistAndRebuild()
    }

    private func removeShedRule(server: String, shed: String) {
        extraRules.removeAll { $0.scope == .shed && $0.shed == shed && ($0.server ?? "") == server }
        persistAndRebuild()
    }

    private func setNamespaceMode(_ ns: String, mode: ApprovalMode?) {
        extraRules.removeAll { $0.scope == .namespace && $0.namespace == ns }
        if let mode { extraRules.append(mode.rule(forNamespace: ns)) }
        persistAndRebuild()
    }

    /// Wire the UI's action seams to the bridge methods (the UI module
    /// can't reach AppModel directly).
    private func wireActions() {
        state.onShedAction = { [weak self] action, shed in
            Task { [weak self] in
                guard let self else { return }
                do { try await self.shedAction(action, host: shed.host, name: shed.name) }
                catch { self.state.lastError = "\(action.rawValue) \(shed.name): \(error)" }
            }
        }
        state.onOpenTerminal = { [weak self] shed in
            guard let self else { return }
            do { _ = try self.openTerminal(shed: shed.name, host: shed.host, session: nil) }
            catch { self.state.lastError = "terminal \(shed.name): \(error)" }
        }
        state.onCreate = { [weak self] host, request in
            guard let self else { return }
            do { _ = try self.startCreate(host: host, request: request) }
            catch { self.state.lastError = "create \(request.name): \(error)" }
        }
        state.onRcLaunch = { [weak self] host, shed, kind, name in
            Task { [weak self] in
                guard let self else { return }
                do { _ = try await self.rcLaunch(host: host, shed: shed, kind: kind, displayName: name, workdir: nil) }
                catch { self.state.lastError = "launch \(shed): \(error)" }
            }
        }
        state.onRcKill = { [weak self] session in
            Task { [weak self] in
                guard let self else { return }
                do { try await self.rcKill(host: session.host, shed: session.shed, slug: session.slug) }
                catch { self.state.lastError = "kill \(session.slug): \(error)" }
            }
        }
        state.onRcRefresh = { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                do { _ = try await self.rcList(host: nil, shed: nil) }
                catch { self.state.lastError = "rc list: \(error)" }
            }
        }
        state.onOpenURL = { url in
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
        state.onApprovalDecide = { [weak self] req, decision, grant in
            Task { [weak self] in
                guard let self else { return }
                do { try await self.decideApproval(id: req.id, decision: decision, grantSession: grant, always: false) }
                catch { self.state.lastError = "approval \(req.id): \(error)" }
            }
        }
        state.onApprovalAlwaysAllow = { [weak self] req in
            Task { [weak self] in
                guard let self else { return }
                do { try await self.decideApproval(id: req.id, decision: .approve, grantSession: false, always: true) }
                catch { self.state.lastError = "always-allow \(req.id): \(error)" }
            }
        }
        state.onRevealAuditLog = { [weak self] in
            guard let self, let store = self.auditStore, !ShedBackend.shared.testMode else { return }
            NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
        }
    }

    private func loadConfigAndClients() {
        let config = ShedConfig.load(path: ShedBackend.shared.shedConfigPath)
        let mockBase = ShedBackend.shared.testMode ? ShedBackend.shared.mockBaseURL : nil

        var hosts: [ShedHost] = []
        var clients: [String: ShedServerClient] = [:]
        for entry in config.servers {
            hosts.append(ShedHost(
                name: entry.name, host: entry.host,
                httpPort: entry.httpPort, sshPort: entry.sshPort))
            let baseURL: URL
            if let mockBase, let url = URL(string: mockBase) {
                baseURL = url
            } else {
                baseURL = URL(string: "http://\(entry.host):\(entry.httpPort)")!
            }
            clients[entry.name] = ShedServerClient(baseURL: baseURL, serverName: entry.name)
        }
        self.clients = clients
        self.defaultServerName = config.defaultServer ?? config.servers.first?.name
        state.hosts = hosts
    }

    /// Resolve a host argument (or the default) to a configured server
    /// name, or throw. The single point both the client and host-metadata
    /// lookups go through.
    private func resolveName(_ host: String?) throws -> String {
        guard let name = host ?? defaultServerName, clients[name] != nil else {
            throw IPCHandlerError.notFound("no configured host\(host.map { " named \($0)" } ?? "")")
        }
        return name
    }

    private func client(for host: String?) throws -> ShedServerClient {
        clients[try resolveName(host)]!
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Stop entirely (don't spin on a default interval) if the
                // model has gone away.
                guard let interval = self?.pollInterval else { break }
                await self?.refreshSheds()
                try? await Task.sleep(for: interval)
            }
        }
    }

    // MARK: - polling (UiBridge.refreshSheds)

    private var inflightRefresh: Task<Void, Never>?

    /// Serialize refreshes: chain each after any in-flight one so a slow
    /// older poll can't resolve late and overwrite a newer refresh's state.
    /// Returns once this refresh has applied (the contract action ops rely
    /// on — the result is visible by the time the call returns).
    func refreshSheds() async {
        let previous = inflightRefresh
        let task = Task { [weak self] in
            await previous?.value
            await self?.doRefresh()
        }
        inflightRefresh = task
        await task.value
    }

    private func doRefresh() async {
        // Probe every host concurrently; an unreachable host degrades to a
        // dot, never a hard failure of the whole list.
        let clients = Array(self.clients.values)
        var newHosts = state.hosts
        var allSheds: [Shed] = []
        var errors: [String] = []

        await withTaskGroup(of: (String, ServerInfo?, [Shed], String?).self) { group in
            for client in clients {
                group.addTask {
                    // info + sheds are independent GETs — fetch them
                    // concurrently so each host pays one round-trip, not two.
                    async let info = client.info()
                    async let sheds = client.listSheds()
                    do {
                        return (client.serverName, try await info, try await sheds, nil)
                    } catch {
                        return (client.serverName, nil, [], "\(client.serverName): \(error)")
                    }
                }
            }
            for await (name, info, sheds, err) in group {
                if let idx = newHosts.firstIndex(where: { $0.name == name }) {
                    newHosts[idx].reachable = info != nil
                    newHosts[idx].backend = info?.backend
                    newHosts[idx].version = info?.version
                }
                allSheds.append(contentsOf: sheds)
                if let err { errors.append(err) }
            }
        }

        // A cancelled poll (app shutting down) shouldn't clobber state with
        // the partial/errored results of an interrupted fetch.
        if Task.isCancelled { return }
        allSheds.sort { ($0.host, $0.name) < ($1.host, $1.name) }
        state.hosts = newHosts
        state.sheds = allSheds
        state.lastError = errors.isEmpty ? nil
            : (errors.count == 1 ? errors[0] : "\(errors.count) hosts unreachable")
        updateStatusItemTitle()
    }

    // MARK: - windows

    private func buildMainWindow() {
        let hosting = NSHostingController(rootView: DashboardView(state: state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "shed desktop"
        window.setContentSize(NSSize(width: 820, height: 520))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.center()
        self.mainWindow = window
        showWindow()
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "shed desktop")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(toggleMenu)
        }
        self.statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        // No animation: open/close take effect synchronously so the IPC
        // ui.open_menu → app.screenshot {surface:menu} sequence is
        // deterministic for the test harness (no lingering isShown).
        popover.animates = false
        popover.contentSize = NSSize(width: 300, height: 360)
        popover.contentViewController = NSHostingController(rootView: MenuBarContentView(
            state: state,
            onOpenDashboard: { [weak self] in
                self?.setMenuOpen(false)
                self?.showWindow()
            },
            onOpenPreferences: { [weak self] in
                self?.setMenuOpen(false)
                self?.openPreferences()
            },
            onQuit: { NSApp.terminate(nil) }
        ))
        self.popover = popover

        updateStatusItemTitle()
    }

    func updateStatusItemTitle() {
        guard let button = statusItem?.button else { return }
        let running = state.runningCount
        button.title = running > 0 ? " \(running)" : ""
    }

    @objc private func toggleMenu() {
        setMenuOpen(!(popover?.isShown ?? false))
    }

    // MARK: - IPC

    private func bindIPC(profile: BundleProfile) {
        do {
            let handler = IPCHandlerImpl(
                socketPath: profile.socketPath,
                appLabel: profile.appLabel,
                appID: profile.appID)
            let server = try IPCServer(socketPath: profile.socketPath, handler: handler, recoverStaleSocket: true)
            server.start()
            self.ipcServer = server
            NSLog("shed-desktop ipc: bound at \(profile.socketPath)")
        } catch {
            NSLog("shed-desktop ipc: failed to bind at \(profile.socketPath): \(error)")
        }
    }

    // MARK: - UiBridge

    func window(for surface: ScreenshotSurface) -> NSWindow? {
        switch surface {
        case .window:
            return mainWindow
        case .menu:
            guard let popover, popover.isShown else { return nil }
            return popover.contentViewController?.view.window
        case .preferences:
            return prefsWindow
        }
    }

    func showWindow() {
        guard let window = mainWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func setMenuOpen(_ open: Bool) {
        guard let popover, let button = statusItem?.button else { return }
        if open {
            if !popover.isShown {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        } else {
            popover.close()  // immediate (vs animated performClose) — isShown clears at once
        }
    }

    func navigate(toPane pane: String) -> Bool {
        guard let p = DashboardPane(rawValue: pane) else { return false }
        state.pane = p
        return true
    }

    func uiState() -> UIState {
        state.snapshot()
    }

    func windowMetrics() -> WindowMetrics {
        let content = mainWindow.map { $0.contentRect(forFrameRect: $0.frame) } ?? .zero
        return WindowMetrics(
            windowWidth: Double(content.width),
            windowHeight: Double(content.height),
            sidebarWidth: Double(Theme.sidebarWidth),
            visiblePane: state.pane.rawValue)
    }

    // MARK: - UiBridge (M1)

    func shedAction(_ action: ShedAction, host: String?, name: String) async throws {
        let client = try client(for: host)
        switch action {
        case .start: try await client.start(name: name)
        case .stop: try await client.stop(name: name)
        case .reset: try await client.reset(name: name)
        case .delete: try await client.delete(name: name)
        }
        await refreshSheds()
    }

    func startCreate(host: String?, request: CreateShedRequest) throws -> String {
        let client = try client(for: host)
        let id = UUID().uuidString
        var progress = CreateProgress(id: id, state: .progress, messages: [])
        creates[id] = progress
        state.activeCreate = progress

        Task { [weak self] in
            do {
                for try await event in client.createShed(request) {
                    guard let self else { return }
                    switch event {
                    case .progress(let msg): progress.messages.append(msg)
                    case .complete(let shed):
                        progress.state = .complete
                        progress.shed = shed
                    }
                    self.updateCreate(progress)
                }
                // createShed guarantees a complete event or a throw, so by
                // here progress is already .complete.
                await self?.refreshSheds()
            } catch {
                progress.state = .error
                progress.error = "\(error)"
                self?.updateCreate(progress)
            }
        }
        return id
    }

    private func updateCreate(_ progress: CreateProgress) {
        creates[progress.id] = progress
        if state.activeCreate?.id == progress.id { state.activeCreate = progress }
    }

    func createStatus(id: String) -> CreateProgress? {
        creates[id]
    }

    func terminalCommand(shed: String, host: String?, session: String?) throws -> TerminalCommand {
        let h = try resolveHost(host)
        return TerminalLauncher.sshCommand(shed: shed, host: h.host, sshPort: h.sshPort, session: session)
    }

    func openTerminal(shed: String, host: String?, session: String?) throws -> TerminalCommand {
        let cmd = try terminalCommand(shed: shed, host: host, session: session)
        try TerminalLauncher.launchInTerminal(cmd, template: terminalTemplate)
        return cmd
    }

    private func resolveHost(_ host: String?) throws -> ShedHost {
        let name = try resolveName(host)
        guard let h = state.hosts.first(where: { $0.name == name }) else {
            throw IPCHandlerError.notFound("no host metadata for \(name)")
        }
        return h
    }

    /// User-configurable terminal command template (`{cmd}` placeholder);
    /// nil = default to Terminal.app.
    private var terminalTemplate: String? {
        let t = prefs.terminalTemplate.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    // MARK: - preferences window (M4)

    func openPreferences() {
        if prefsWindow == nil {
            let hosting = NSHostingController(rootView: PreferencesView(prefs: prefs, state: state))
            let window = NSWindow(contentViewController: hosting)
            window.title = "shed desktop — Preferences"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // Pin the content size so the window has a concrete frame immediately
            // (SwiftUI's fitting size is otherwise async — a screenshot taken
            // right after open could see a zero-size window). Matches the
            // PreferencesView .frame.
            window.setContentSize(NSSize(width: 460, height: 560))
            window.center()
            prefsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        prefsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - UiBridge (M2: remote control)

    func rcLaunch(host: String?, shed: String, kind: RcKind, displayName: String?, workdir: String?) async throws -> RcSession {
        let serverName = try resolveName(host)
        let slug = RemoteControl.generateSlug()
        let name = displayName ?? slug
        let dir = workdir ?? RemoteControl.defaultWorkdir
        // Reject control chars: a newline would break the tmux `-e` env
        // injection and could forge a sentinel line in the list output.
        guard isSafeRCValue(name), isSafeRCValue(dir) else {
            throw IPCHandlerError.invalidParam("display name and workdir must not contain newlines or control characters")
        }
        var session = RcSession(
            host: serverName, shed: shed, slug: slug,
            tmuxSession: RemoteControl.tmuxName(slug: slug),
            displayName: name, workdir: dir, kind: kind, state: .starting)

        if ShedBackend.shared.testMode {
            // No SSH under the harness — synthesize a ready session.
            session.state = .ready
            session.url = syntheticURL(kind: kind, slug: slug)
        } else {
            let h = try resolveHost(host)
            let bootstrap = RemoteControl.bootstrapArgv(slug: slug, kind: kind, displayName: name, workdir: dir)
            let res = try await ProcessRunner.run(
                RemoteControl.sshArgv(user: shed, host: h.host, port: h.sshPort, remoteArgv: bootstrap))
            guard res.ok else {
                throw IPCHandlerError.internalError("rc launch failed: \(res.stderr.isEmpty ? res.stdout : res.stderr)")
            }
            let cls = try await probeReal(h: h, shed: shed, slug: slug, kind: kind)
            session.state = cls.state
            session.url = cls.url
        }
        rcTable[slug] = session
        publishRcSessions()
        return session
    }

    func rcKill(host: String?, shed: String, slug: String) async throws {
        if !ShedBackend.shared.testMode {
            let h = try resolveHost(host)
            let res = try await ProcessRunner.run(
                RemoteControl.sshArgv(user: shed, host: h.host, port: h.sshPort, remoteArgv: RemoteControl.killArgv(slug: slug)))
            // Don't drop the session from the table (and report success) if
            // the remote kill actually failed; a refresh reconciles.
            guard res.ok else {
                throw IPCHandlerError.internalError("rc kill failed: \(res.stderr.isEmpty ? res.stdout : res.stderr)")
            }
        }
        rcTable[slug] = nil
        publishRcSessions()
    }

    func rcList(host: String?, shed: String?) async throws -> [RcSession] {
        if !ShedBackend.shared.testMode {
            // Best-effort: probe the running sheds (or the named one)
            // concurrently and rebuild the table from what's actually live.
            // SSH latency is high-variance, so a serial loop would stall on
            // a slow/dead host's 10s timeout.
            let targets: [(ShedHost, Shed)] = state.sheds.compactMap { shedItem in
                guard shedItem.status == .running,
                      host == nil || shedItem.host == host,
                      shed == nil || shedItem.name == shed,
                      let h = state.hosts.first(where: { $0.name == shedItem.host })
                else { return nil }
                return (h, shedItem)
            }
            let lists = await withTaskGroup(of: [RcSession].self) { group in
                for (h, shedItem) in targets {
                    group.addTask { (try? await self.listReal(h: h, serverName: shedItem.host, shed: shedItem.name)) ?? [] }
                }
                var all: [RcSession] = []
                for await s in group { all.append(contentsOf: s) }
                return all
            }
            rcTable = Dictionary(lists.map { ($0.slug, $0) }, uniquingKeysWith: { _, b in b })
        }
        publishRcSessions()
        return rcTable.values
            .filter { (host == nil || $0.host == host) && (shed == nil || $0.shed == shed) }
            .sorted { $0.slug < $1.slug }
    }

    private func publishRcSessions() {
        state.rcSessions = rcTable.values.sorted { $0.slug < $1.slug }
    }

    private func isSafeRCValue(_ s: String) -> Bool {
        !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private func syntheticURL(kind: RcKind, slug: String) -> String? {
        switch kind {
        case .agent: return "https://claude.ai/code?environment=env_\(slug)"
        case .repl: return "https://claude.ai/code/session_\(slug)"
        case .shell: return nil
        }
    }

    // MARK: - real RC (SSH; never runs under the test harness)

    private func probeReal(h: ShedHost, shed: String, slug: String, kind: RcKind) async throws -> RcClassification {
        let res = try await ProcessRunner.run(
            RemoteControl.sshArgv(user: shed, host: h.host, port: h.sshPort, remoteArgv: RemoteControl.captureArgv(slug: slug)))
        guard res.ok else { return RcClassification(state: .dead) }
        return RemoteControl.classifyPane(kind: kind, pane: res.stdout)
    }

    /// List + classify rc-* sessions on one shed via a single bash script
    /// over SSH (the script + parser live in RemoteControl).
    private func listReal(h: ShedHost, serverName: String, shed: String) async throws -> [RcSession] {
        let sep = "@@RC@@"
        let res = try await ProcessRunner.run(
            RemoteControl.sshArgv(user: shed, host: h.host, port: h.sshPort, remoteArgv: ["bash", "-c", RemoteControl.listScript(sep: sep)]))
        guard res.ok else { return [] }
        return RemoteControl.parseSessionList(res.stdout, sep: sep, serverName: serverName, shed: shed)
    }

    // MARK: - M3: approvals + activity

    private var uiVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }
    private var pid: Int32 { Int32(ProcessInfo.processInfo.processIdentifier) }

    private func startApprovals(profile: BundleProfile) {
        let store = AuditStore(path: (profile.stateDir as NSString).appendingPathComponent("audit.jsonl"))
        self.auditStore = store
        publishActivity()

        let notifier: any NotificationPresenter = ShedBackend.shared.testMode
            ? FakeNotificationPresenter() : SystemNotificationPresenter()
        notifier.onAction = { [weak self] id, decision in
            // Already on the main actor (the presenter is @MainActor).
            Task { [weak self] in try? await self?.decideApproval(id: id, decision: decision, grantSession: false) }
        }
        if !ShedBackend.shared.testMode { notifier.requestAuthorization() }
        self.notifier = notifier

        let client = HostAgentClient(socketPath: ShedBackend.shared.hostAgentSocketPath)
        self.hostAgent = client
        let info = HelloClientInfo(
            name: "shed-desktop", version: uiVersion, pid: pid,
            capabilities: ["approval.ssh", "event.stream"], replayEvents: 50)
        let stream = client.start(client: info)
        hostAgentTask = Task { [weak self] in
            for await event in stream { await self?.handleHostAgentEvent(event) }
        }
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.expirePending()
            }
        }
    }

    private func handleHostAgentEvent(_ event: HostAgentEvent) {
        switch event {
        case .connected:
            state.hostAgentConnected = true
        case .disconnected:
            state.hostAgentConnected = false
            // In-flight requests are dead: the agent fails closed on its side
            // (our response would be dropped anyway), so drop them rather than
            // let the user act on — or persist a rule from — a stale prompt.
            for id in pending.keys { notifier?.withdraw(id: id) }
            pending.removeAll()
            publishApprovals()
        case .frame(let frame):
            switch frame {
            case .approvalRequest(let req): handleApprovalRequest(req)
            case .event(let evt): ingestEvent(evt)
            default: break
            }
        }
    }

    private func handleApprovalRequest(_ req: ApprovalRequest) {
        let decision = policyEngine.decide(for: req, sessionGrants: validGrants())
        switch decision.action {
        case .approve:
            respondAndAudit(req, .approve, decidedBy: .policy, policy: decision.appliedScope.rawValue)
        case .deny:
            respondAndAudit(req, .deny, decidedBy: .policy, policy: decision.appliedScope.rawValue)
        case .prompt:
            pending[req.id] = PendingApproval(request: req, gate: decision.gate)
            notifier?.post(req)
            publishApprovals()
        }
    }

    func decideApproval(id: String, decision: ApprovalDecision, grantSession: Bool, always: Bool = false) async throws {
        guard let item = pending[id] else { throw IPCHandlerError.notFound("no pending approval \(id)") }
        let req = item.request
        var decidedBy: DecidedBy = .user
        if decision == .approve, item.gate == .touchid, !ShedBackend.shared.testMode {
            let ok = await TouchID.authenticate(reason: "Approve \(req.namespace) \(req.op) for shed \(req.shed)")
            guard ok else {
                state.lastError = "Touch ID not confirmed for \(req.shed)"
                return  // stay pending; user can retry or it expires
            }
            // The request may have expired (and been denied) while the
            // biometric prompt was up — don't send a late, contradictory
            // approve or grant a session for a dead request.
            guard pending[id] != nil else { return }
            decidedBy = .touchid
        }
        if decision == .approve, always {
            // "Always allow" — persist a per-(server,shed) approve rule.
            addShedRule(server: req.server, shed: req.shed)
        } else if grantSession, decision == .approve {
            sessionGrants[SessionGrantKey(server: req.server, namespace: req.namespace, shed: req.shed)] = Date().addingTimeInterval(grantTTL)
        }
        respondAndAudit(req, decision, decidedBy: decidedBy, policy: always ? "shed-rule" : (grantSession ? "session-grant" : "manual"))
        pending[id] = nil
        notifier?.withdraw(id: id)
        publishApprovals()
    }

    private func expirePending() {
        let now = Date()
        let expired = pending.values.map(\.request).filter { ($0.expiresAtDate ?? now) < now }
        for req in expired {
            respondAndAudit(req, .deny, decidedBy: .timeout, policy: "expired")
            pending[req.id] = nil
            notifier?.withdraw(id: req.id)
        }
        if !expired.isEmpty { publishApprovals() }
    }

    private func respondAndAudit(_ req: ApprovalRequest, _ decision: ApprovalDecision, decidedBy: DecidedBy, policy: String) {
        // Record the decision before transmitting it, so there's always an
        // app-side trail for an approve we sent.
        auditStore?.append(AuditEntry(
            id: req.id, ts: DateFormatting.nowISO8601(), source: .app, server: req.server.isEmpty ? nil : req.server,
            shed: req.shed, ns: req.namespace, op: req.op,
            result: decision == .approve ? "ok" : "denied", detail: req.detail, approval: "shed-desktop", policy: policy))
        publishActivity()
        hostAgent?.respond(requestID: req.id, decision: decision, decidedBy: decidedBy)
    }

    private func ingestEvent(_ evt: AuditEventFrame) {
        auditStore?.append(AuditEntry(frame: evt))
        publishActivity()
    }

    private func validGrants() -> Set<SessionGrantKey> {
        let now = Date()
        return Set(sessionGrants.filter { $0.value > now }.keys)
    }

    /// Pending requests, soonest-to-expire first — the single ordering used
    /// by both the published queue and the IPC list.
    private var sortedPending: [ApprovalRequest] {
        pending.values.map(\.request).sorted { $0.expiresAt < $1.expiresAt }
    }

    private func publishApprovals() {
        state.approvals = sortedPending
    }

    private func publishActivity() {
        state.activity = auditStore?.recent() ?? []
    }

    // MARK: - UiBridge (M3)

    func approvalsList() -> [ApprovalRequest] { sortedPending }

    func activityList(limit: Int) -> [AuditEntry] {
        auditStore?.recent(limit: limit) ?? []
    }

    func auditLogPath() -> String { auditStore?.fileURL.path ?? "" }

    func setPolicyRules(_ rules: [PolicyRule]) {
        policyEngine = PolicyEngine(rules: rules)
    }

    func policyRules() -> [PolicyRule] { policyEngine.rules }

    // M5: notifications (driveable over IPC via the fake presenter).

    func postedNotifications() -> [PostedNotification] {
        (notifier as? FakeNotificationPresenter)?.posted ?? []
    }

    func invokeNotification(id: String, decision: ApprovalDecision) throws {
        guard let fake = notifier as? FakeNotificationPresenter else {
            throw IPCHandlerError.notEnabled("notification.invoke requires the test presenter")
        }
        guard fake.invoke(id: id, decision: decision) else {
            throw IPCHandlerError.notFound("no posted notification \(id)")
        }
    }
}
