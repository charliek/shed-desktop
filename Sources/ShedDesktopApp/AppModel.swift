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
}
