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
import Sparkle
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
    // In-memory approval grants keyed by (server, namespace, shed) → expiry. A
    // Date.distantFuture value is the sentinel for a *sticky* (Per Shed) grant
    // that never time-expires — it lives until the app restarts or an SSH setting
    // changes; validGrants() (value > now) treats it as always valid by design.
    private var sessionGrants: [SessionGrantKey: Date] = [:]
    /// A queued prompt: the request plus the gate to apply when the user acts.
    private struct PendingApproval { let request: ApprovalRequest; let gate: PolicyGate }
    private var pending: [String: PendingApproval] = [:]
    private var hostAgentTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    /// Actionable Approve/Deny notifications (Fake under the harness).
    private var notifier: (any NotificationPresenter)?

    /// Fallback grant duration (seconds) — used only if even the default TTL
    /// string can't be parsed. Mirrors defaultApprovalTTL ("2h").
    private let grantTTL: TimeInterval = 2 * 3600

    // M4: preferences
    private let prefsStore = PreferencesStore()
    private let prefs = Preferences()
    private var prefsWindow: NSWindow?

    private(set) var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var menuPanel: MenuPanel?
    private var menuPanelHost: NSHostingView<MenuBarContentView>?
    private var menuDismissMonitors: [Any] = []
    private var updater: SPUStandardUpdaterController?

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
        setupUpdater()
    }

    // MARK: - M8: Sparkle auto-update

    /// Retained for the app's lifetime; owns the background scheduler and backs
    /// the menu's "Check for Updates…". Skipped under the test harness so the
    /// hermetic E2E never instantiates Sparkle (no network, no update UI). Feed
    /// URL + EdDSA key come from Info.plist (SUFeedURL / SUPublicEDKey).
    private func setupUpdater() {
        guard !ShedBackend.shared.testMode else { return }
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        updater?.checkForUpdates(nil)
    }

    private func loadPreferences() {
        let testMode = ShedBackend.shared.testMode
        prefs.launchAtLogin = testMode ? false : LoginItem.isEnabled
        prefs.terminalTemplate = prefsStore.terminalTemplate
        prefs.sshMethod = prefsStore.sshMethod
        prefs.sshPolicy = prefsStore.sshPolicy
        prefs.sshTTL = prefsStore.sshTTL
        prefs.awsMode = prefsStore.providerMode(CredentialNamespace.aws)
        prefs.dockerMode = prefsStore.providerMode(CredentialNamespace.docker)
        // Apply the per-provider settings + persisted per-shed rules. Only
        // per-shed rules are persisted now; drop any legacy namespace-scope rules
        // from the old model (clean break, no migration).
        extraRules = prefsStore.policyRules.filter { $0.scope == .shed }
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
        // Changing any SSH approval setting clears live in-memory SSH grants, so
        // the new policy takes effect on the very next request (a grant from an
        // earlier per-session/per-shed approval no longer auto-approves past the
        // change). Explicit per-shed always-allow/deny rules are left untouched.
        prefs.onSSHMethod = { [weak self] m in self?.setSshApproval(method: m, policy: nil, ttl: nil) }
        prefs.onSSHPolicy = { [weak self] p in self?.setSshApproval(method: nil, policy: p, ttl: nil) }
        prefs.onSSHTTL = { [weak self] t in self?.setSshApproval(method: nil, policy: nil, ttl: t) }
        prefs.onProviderMode = { [weak self] ns, mode in self?.setProviderMode(ns, mode) }
        prefs.onRemoveShedRule = { [weak self] server, shed in self?.removeShedRule(server: server, shed: shed) }
    }

    // MARK: - policy rules (per-provider namespace rules + per-shed overrides)

    private func rebuildPolicy() {
        // One namespace rule per provider, derived from the per-provider prefs.
        // SSH's action comes from its policy (Always Allow/Deny decide outright;
        // the rest prompt with the chosen method); AWS/Docker apply their live mode.
        let sshPolicy = prefsStore.sshPolicy
        let rules: [PolicyRule] = [
            PolicyRule(scope: .namespace, namespace: CredentialNamespace.ssh, action: sshPolicy.namespaceAction, gate: sshPolicy.prompts ? prefsStore.sshMethod.gate : .none),
            PolicyRule(scope: .namespace, namespace: CredentialNamespace.aws, action: prefsStore.providerMode(CredentialNamespace.aws).policyAction, gate: .none),
            PolicyRule(scope: .namespace, namespace: CredentialNamespace.docker, action: prefsStore.providerMode(CredentialNamespace.docker).policyAction, gate: .none),
        ]
        policyEngine = PolicyEngine(rules: rules + extraRules)
    }

    private func setProviderMode(_ ns: String, _ mode: ApprovalDecision) {
        prefsStore.setProviderMode(ns, mode)
        rebuildPolicy()
    }

    /// Drop the in-memory SSH session grants (the always-allow/deny per-shed
    /// rules in `extraRules` are persistent and left untouched).
    private func resetSshGrants() {
        sessionGrants = sessionGrants.filter { $0.key.namespace != CredentialNamespace.ssh }
    }

    /// Re-decide queued prompts against the current policy. After an SSH policy
    /// change to Always Allow/Deny, a card queued under the old prompting policy
    /// must resolve now rather than linger (and stay actionable) under a
    /// non-prompting policy. Requests the policy still decides to prompt stay put.
    private func reevaluatePending() {
        let grants = validGrants()
        for (id, item) in Array(pending) {
            let decision = policyEngine.decide(for: item.request, sessionGrants: grants)
            guard decision.action != .prompt else { continue }
            respondAndAudit(item.request, decision.action == .approve ? .approve : .deny,
                            decidedBy: .policy, policy: decision.appliedScope.rawValue)
            pending[id] = nil
            notifier?.withdraw(id: id)
        }
        publishApprovals()
    }

    /// Apply SSH approval preferences (any subset) and reset live SSH grants so
    /// the change takes effect immediately. Drives the same path as the UI.
    func setSshApproval(method: ApprovalMethod?, policy: SSHApprovalPolicy?, ttl: String?) {
        if let method { prefsStore.sshMethod = method; prefs.sshMethod = method }
        if let policy { prefsStore.sshPolicy = policy; prefs.sshPolicy = policy }
        if let ttl { prefsStore.sshTTL = ttl; prefs.sshTTL = ttl }
        rebuildPolicy()
        resetSshGrants()
        reevaluatePending()
    }

    private func persistAndRebuild() {
        prefsStore.policyRules = extraRules
        rebuildPolicy()
        publishPolicyPrefs()
    }

    /// Mirror the per-shed rules into the preferences view-model.
    private func publishPolicyPrefs() {
        prefs.shedRules = extraRules
            .filter { $0.scope == .shed }
            .map { ShedRuleRow(server: $0.server ?? "", shed: $0.shed ?? "", action: $0.action == .deny ? .deny : .approve) }
    }

    private func addShedRule(server: String, shed: String, action: ApprovalDecision) {
        // Store the server verbatim ("" = the single/unnamed server) rather than
        // collapsing "" → nil: nil is reserved for an explicit any-server rule,
        // so a single-server grant never silently widens to other servers.
        extraRules.removeAll { $0.scope == .shed && $0.shed == shed && ($0.server ?? "") == server }
        extraRules.append(PolicyRule(scope: .shed, server: server, shed: shed, action: action.policyAction, gate: .none))
        persistAndRebuild()
    }

    private func removeShedRule(server: String, shed: String) {
        extraRules.removeAll { $0.scope == .shed && $0.shed == shed && ($0.server ?? "") == server }
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
        state.onSystemRefresh = { [weak self] in
            Task { [weak self] in _ = await self?.refreshSystemUsage() }
        }
        state.onImagesRefresh = { [weak self] in
            Task { [weak self] in _ = await self?.refreshImages() }
        }
        state.onOpenURL = { url in
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
        state.onApprovalDecide = { [weak self] req, choice in
            Task { [weak self] in
                guard let self else { return }
                do { try await self.decideApproval(id: req.id, choice: choice) }
                catch { self.state.lastError = "approval \(req.id): \(error)" }
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
        // Seed image data for the Sheds pane's repo:tag labels, concurrently so a
        // slow image endpoint never delays the first shed render. Images change
        // rarely and are also refreshed when the New-Shed sheet opens; until this
        // lands, the badge falls back to the short digest.
        Task { [weak self] in await self?.refreshImages() }
    }

    // MARK: - polling (UiBridge.refreshSheds)

    private var inflightRefresh: Task<Void, Never>?
    private var inflightSystemRefresh: Task<Void, Never>?
    private var inflightImageRefresh: Task<Void, Never>?

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

    /// M7: fan out `GET /api/system/df` to every host, publish + return the
    /// per-host disk usage. Serialized like `refreshSheds` so overlapping
    /// UI/IPC refreshes can't complete out of order and clobber newer state.
    func refreshSystemUsage() async -> [HostDiskUsage] {
        let previous = inflightSystemRefresh
        let task = Task { [weak self] in
            await previous?.value
            await self?.doSystemRefresh()
        }
        inflightSystemRefresh = task
        await task.value
        return state.systemUsage
    }

    private func doSystemRefresh() async {
        let clients = Array(self.clients.values)
        var result: [HostDiskUsage] = []
        await withTaskGroup(of: HostDiskUsage.self) { group in
            for client in clients {
                group.addTask {
                    // Unreachable host → a row with an error, never a hard failure.
                    do { return HostDiskUsage(host: client.serverName, usage: try await client.systemDF()) }
                    catch { return HostDiskUsage(host: client.serverName, error: "\(error)") }
                }
            }
            for await item in group { result.append(item) }
        }
        if Task.isCancelled { return }
        result.sort { $0.host < $1.host }
        state.systemUsage = result
    }

    /// Fan out `GET /api/images` to every host, publish + return the per-host
    /// image lists. Serialized like `refreshSystemUsage` so overlapping
    /// refreshes can't land out of order.
    func refreshImages() async -> [HostImageList] {
        let previous = inflightImageRefresh
        let task = Task { [weak self] in
            await previous?.value
            await self?.doImageRefresh()
        }
        inflightImageRefresh = task
        await task.value
        return state.imagesByHost
    }

    private func doImageRefresh() async {
        let clients = Array(self.clients.values)
        var result: [HostImageList] = []
        await withTaskGroup(of: HostImageList.self) { group in
            for client in clients {
                group.addTask {
                    // Unreachable host → a row with an error, never a hard failure.
                    do { return HostImageList(host: client.serverName, images: try await client.listImages()) }
                    catch { return HostImageList(host: client.serverName, error: "\(error)") }
                }
            }
            for await item in group { result.append(item) }
        }
        if Task.isCancelled { return }
        result.sort { $0.host < $1.host }
        state.imagesByHost = result
    }

    // MARK: - windows

    private func buildMainWindow() {
        let hosting = NSHostingController(rootView: DashboardView(state: state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "shed desktop"
        window.setContentSize(NSSize(width: 860, height: 660))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // Keep the standard system titlebar with the "shed desktop" title (the
        // content view starts below it). backgroundColor matches the linen canvas
        // so resize / behind-sheet flashes aren't gray; window.appearance stays
        // nil so system light/dark drives it.
        window.titlebarAppearsTransparent = false
        window.backgroundColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? 0x100F0C : 0xF1EFE9)
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.mainWindow = window
        // Build the window but DON'T show it: the app launches to the menu bar
        // only (stays an accessory), and becomes a regular app — Dock icon +
        // ⌘-Tab — the first time the user opens the dashboard. The harness opens
        // it explicitly via `ui.show_window` before any window screenshot.
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Persist the icon's menu-bar position across launches and ⌘-drag
        // reordering, so a user who drags it clear of the notch keeps it there
        // (issue #4 — mitigates the icon landing under the notch unclickable).
        item.autosaveName = "ShedDesktopStatusItem"
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "shed desktop")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(toggleMenu)
        }
        self.statusItem = item

        // A borderless panel (not an NSPopover) so the dropdown is fully opaque
        // with no arrow — the standard menu-bar look. It sizes to the SwiftUI
        // content on each open and dismisses on an outside click.
        let host = NSHostingView(rootView: MenuBarContentView(
            state: state,
            onOpenDashboard: { [weak self] in
                self?.setMenuOpen(false)
                self?.showWindow()
            },
            onOpenPreferences: { [weak self] in
                self?.setMenuOpen(false)
                self?.openPreferences()
            },
            onCheckForUpdates: { [weak self] in
                self?.setMenuOpen(false)
                self?.checkForUpdates()
            },
            onQuit: { NSApp.terminate(nil) }
        ))
        host.wantsLayer = true
        host.layer?.cornerRadius = 12
        host.layer?.masksToBounds = true

        let panel = MenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        self.menuPanel = panel
        self.menuPanelHost = host

        updateStatusItemTitle()
    }

    func updateStatusItemTitle() {
        guard let button = statusItem?.button else { return }
        let running = state.runningCount
        button.title = running > 0 ? " \(running)" : ""
    }

    @objc private func toggleMenu() {
        setMenuOpen(!(menuPanel?.isVisible ?? false))
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
            guard let menuPanel, menuPanel.isVisible else { return nil }
            return menuPanel
        case .preferences:
            return prefsWindow
        }
    }

    func hideWindow() {
        // close() (not orderOut) so the existing windowWillClose handler runs
        // and reverts to a menu-bar-only accessory — the same path as the user
        // closing the window. isReleasedWhenClosed is false, so it can reopen.
        mainWindow?.close()
    }

    func showWindow() {
        guard let window = mainWindow else { return }
        // Becoming a regular app (Dock icon + ⌘-Tab + the top-left app menu)
        // while a window is open; windowWillClose reverts to accessory. Skipped
        // under the harness so its activation policy stays put.
        if !ShedBackend.shared.testMode { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showCreateSheet() {
        showWindow()
        state.pane = .sheds
        state.showCreateSheet = true
    }

    func showLaunchSheet() {
        showWindow()
        state.pane = .agents
        state.showLaunchSheet = true
    }

    func setMenuOpen(_ open: Bool) {
        guard let panel = menuPanel, let host = menuPanelHost,
              let button = statusItem?.button, let buttonWindow = button.window else { return }
        if open {
            guard !panel.isVisible else { return }
            // Size to the SwiftUI content (height varies with the approvals
            // section) and drop the panel just below the status item, clamped
            // to the screen.
            host.layoutSubtreeIfNeeded()
            var size = host.fittingSize
            if size.width < 1 { size.width = 300 }
            if size.height < 1 { size.height = 200 }
            let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            var x = buttonRect.maxX - size.width
            var y = buttonRect.minY - size.height - 4
            if let screen = buttonWindow.screen ?? NSScreen.main {
                let vf = screen.visibleFrame
                x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
                y = max(y, vf.minY + 8)
            }
            panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
            panel.orderFrontRegardless()
            installMenuDismissMonitors()
        } else {
            removeMenuDismissMonitors()
            panel.orderOut(nil)
        }
    }

    /// Dismiss the menu panel on a mouse-down outside it (skipping the status
    /// item, whose own action toggles). Off under the harness so the
    /// open_menu → screenshot sequence stays deterministic.
    private func installMenuDismissMonitors() {
        guard menuDismissMonitors.isEmpty, !ShedBackend.shared.testMode else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.setMenuOpen(false)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if event.window === self.menuPanel { return event }
            if event.window === self.statusItem?.button?.window { return event }
            self.setMenuOpen(false)
            return event
        }
        menuDismissMonitors = [global, local].compactMap { $0 }
    }

    private func removeMenuDismissMonitors() {
        for monitor in menuDismissMonitors { NSEvent.removeMonitor(monitor) }
        menuDismissMonitors.removeAll()
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

    func windowState() -> WindowState {
        WindowState(
            visible: mainWindow?.isVisible ?? false,
            activationPolicy: NSApp.activationPolicy() == .regular ? "regular" : "accessory")
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
            window.delegate = self
            window.center()
            prefsWindow = window
        }
        if !ShedBackend.shared.testMode { NSApp.setActivationPolicy(.regular) }
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
            Task { [weak self] in try? await self?.decideApproval(id: id, choice: ApprovalChoice(decision: decision)) }
        }
        // Tapping the banner body opens the dashboard on the Approvals pane.
        notifier.onOpen = { [weak self] in
            self?.showWindow()
            _ = self?.navigate(toPane: DashboardPane.approvals.rawValue)
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
        case .connected(let ack):
            state.hostAgentConnected = true
            // Show the approval prefs only for the providers the agent delegates.
            prefs.gatedNamespaces = ack.gateNamespaces
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

    func decideApproval(id: String, choice: ApprovalChoice) async throws {
        guard let item = pending[id] else { throw IPCHandlerError.notFound("no pending approval \(id)") }
        let req = item.request
        // Don't act on an already-expired request — the 1s expiry task may not have
        // fired yet, but acting now would persist a rule / create a (possibly sticky)
        // grant and send a late decision for a request the agent has already denied.
        guard (req.expiresAtDate ?? .distantPast) > Date() else { return }
        let decision = choice.decision
        var decidedBy: DecidedBy = .user
        if decision == .approve, item.gate.isBiometric, !ShedBackend.shared.testMode {
            let ok = await TouchID.authenticate(
                reason: "Approve \(req.namespace) \(req.op) for shed \(req.shed)",
                biometricsOnly: item.gate == .biometrics)
            guard ok else {
                state.lastError = "Touch ID not confirmed for \(req.shed)"
                return  // stay pending; user can retry or it expires
            }
            // The request may have expired (and been denied) while the biometric
            // prompt was up — don't send a late, contradictory decision or grant
            // a session for a dead request. Check both presence AND expiry (the
            // 1s expiry task may not have fired yet).
            guard pending[id] != nil,
                  (req.expiresAtDate ?? .distantPast) > Date() else { return }
            decidedBy = .touchid
        }

        // Persistence / grant + the scope/ttl we report to the host for its audit.
        let grantKey = SessionGrantKey(server: req.server, namespace: req.namespace, shed: req.shed)
        // Any deny supersedes a live "approve for this session" grant — otherwise
        // the grant (highest precedence) would keep auto-approving past the deny.
        if decision == .deny { sessionGrants.removeValue(forKey: grantKey) }

        var sentScope = choice.scope?.rawValue ?? "per-request"
        var sentTTL = ""
        var policyLabel = "manual"
        if choice.persist {
            // Always-allow (approve) or always-deny (deny) — a per-shed rule.
            addShedRule(server: req.server, shed: req.shed, action: decision)
            sentScope = "always"
            policyLabel = decision == .approve ? "shed-rule" : "deny-rule"
        } else if decision == .approve, let scope = choice.scope, scope != .perRequest {
            if scope == .perShed {
                // Per Shed: a sticky grant — asks once per shed, then auto-approves
                // until the app restarts (in-memory) or an SSH setting changes. TTL
                // is irrelevant here.
                sessionGrants[grantKey] = .distantFuture
            } else {  // per-session: time-bounded by the duration
                // Resolve one validated TTL — empty/invalid input falls back to the
                // default — and use it for BOTH the grant expiry and the value we
                // report to the host (never the raw, possibly-invalid, input).
                let ttlText = choice.ttl.flatMap { TTLShorthand.seconds($0) != nil ? $0 : nil } ?? defaultApprovalTTL
                let secs = TTLShorthand.seconds(ttlText) ?? Int(grantTTL)
                sessionGrants[grantKey] = Date().addingTimeInterval(TimeInterval(secs))
                sentTTL = ttlText
            }
            policyLabel = "session-grant"
        }

        respondAndAudit(req, decision, decidedBy: decidedBy, policy: policyLabel, scope: sentScope, ttl: sentTTL)
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

    private func respondAndAudit(_ req: ApprovalRequest, _ decision: ApprovalDecision, decidedBy: DecidedBy, policy: String, scope: String = "", ttl: String = "") {
        // Record the decision before transmitting it, so there's always an
        // app-side trail for an approve we sent.
        auditStore?.append(AuditEntry(
            id: req.id, ts: DateFormatting.nowISO8601(), source: .app, server: req.server.isEmpty ? nil : req.server,
            shed: req.shed, ns: req.namespace, op: req.op,
            result: decision == .approve ? "ok" : "denied", detail: req.detail, approval: "shed-desktop", policy: policy))
        publishActivity()
        // Report scope/ttl to the host so its durable audit records how we decided.
        hostAgent?.respond(requestID: req.id, decision: decision, decidedBy: decidedBy,
                           scope: scope.isEmpty ? nil : scope, ttl: ttl.isEmpty ? nil : ttl)
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

    /// Pending requests as UI items: each carries its decided gate (for the
    /// fingerprint icon) + the SSH scope/TTL defaults to pre-fill the card.
    private var sortedItems: [PendingApprovalItem] {
        // The SSH defaults are identical for every item in a pass — read once.
        let scope = prefsStore.sshPolicy.defaultScope ?? .perRequest
        let ttl = prefsStore.sshTTL
        return pending.values.sorted { $0.request.expiresAt < $1.request.expiresAt }
            .map { PendingApprovalItem(request: $0.request, gate: $0.gate, defaultScope: scope, defaultTTL: ttl) }
    }

    private func publishApprovals() {
        state.approvals = sortedItems
    }

    private func publishActivity() {
        state.activity = auditStore?.recent() ?? []
    }

    // MARK: - UiBridge (M3)

    func approvalsList() -> [PendingApprovalItem] { sortedItems }

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

    func invokeNotificationOpen() throws {
        guard let fake = notifier as? FakeNotificationPresenter else {
            throw IPCHandlerError.notEnabled("notification.open requires the test presenter")
        }
        fake.triggerOpen()
    }
}

extension AppModel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard !ShedBackend.shared.testMode else { return }
        // When the last managed window closes, drop back to a menu-bar-only
        // accessory (Dock icon + ⌘-Tab entry go; the status item stays). The
        // closing window is still `isVisible` here, so exclude it explicitly.
        let closing = notification.object as? NSWindow
        // A miniaturized window is still "open" (it has a restorable Dock tile),
        // so keep .regular for it; only a genuinely-closed last window reverts.
        let stillOpen = [mainWindow, prefsWindow]
            .compactMap { $0 }
            .contains { $0 !== closing && ($0.isVisible || $0.isMiniaturized) }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}
