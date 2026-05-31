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

    private var clients: [ShedServerClient] = []
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
        buildMainWindow()
        buildStatusItem()
        bindIPC(profile: profile)
        startPolling()
    }

    private func loadConfigAndClients() {
        let config = ShedConfig.load(path: ShedBackend.shared.shedConfigPath)
        let mockBase = ShedBackend.shared.testMode ? ShedBackend.shared.mockBaseURL : nil

        var hosts: [ShedHost] = []
        var clients: [ShedServerClient] = []
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
            clients.append(ShedServerClient(baseURL: baseURL, serverName: entry.name))
        }
        self.clients = clients
        state.hosts = hosts
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

    func refreshSheds() async {
        // Probe every host concurrently; an unreachable host degrades to a
        // dot, never a hard failure of the whole list.
        let clients = self.clients
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
}
