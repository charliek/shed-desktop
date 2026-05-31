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

    private(set) var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    private let pollInterval: Duration = .seconds(5)

    // MARK: - lifecycle

    func start(profile: BundleProfile) {
        ShedBackend.shared.start(profile: profile)
        ShedBackend.shared.registerUI(self)
        loadConfigAndClients()
        wireActions()
        buildMainWindow()
        buildStatusItem()
        bindIPC(profile: profile)
        startPolling()
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
    /// nil = default to Terminal.app. Wired to preferences in M4.
    private var terminalTemplate: String? { nil }

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
}
