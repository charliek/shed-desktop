// UiBridge.swift
//
// The one seam the IPC handler uses to reach the running SwiftUI app.
// The handler never touches AppKit or NSApp directly — every main-thread
// op goes through this protocol, whose sole conformer is the app's
// AppModel. Mirrors roost's UiBridge.

import AppKit
import Foundation

@MainActor
public protocol UiBridge: AnyObject {
    /// The NSWindow backing a capturable `surface`, for `app.screenshot`.
    /// Returns nil when that surface isn't currently available (e.g. the
    /// menu popover is closed), which the handler maps to an error.
    func window(for surface: ScreenshotSurface) -> NSWindow?

    /// Order the dashboard window front (the accessory app may launch with
    /// it closed). Used by `ui.showWindow` before a window screenshot.
    func showWindow()

    /// Close the dashboard window (reverting to a menu-bar-only accessory via
    /// `windowWillClose`). The inverse of `showWindow`; lets a driver model a
    /// user closing the window so the reopen escape hatch can be exercised.
    func hideWindow()

    /// Open (and front) the preferences window.
    func openPreferences()

    /// Force the menu-bar popover open or closed (`ui.openMenu`).
    func setMenuOpen(_ open: Bool)

    /// Switch the dashboard's selected sidebar pane (`ui.navigate`).
    /// Returns false for an unknown pane name.
    func navigate(toPane pane: String) -> Bool

    /// Apply SSH approval preferences (any subset) and reset live SSH grants so
    /// the change takes effect on the next request (`ui.set_ssh_approval`).
    func setSshApproval(method: ApprovalMethod?, policy: SSHApprovalPolicy?, ttl: String?)

    /// Snapshot of the view-model for `ui.state`.
    func uiState() -> UIState

    /// Logical window measurements for `app.window_metrics`.
    func windowMetrics() -> WindowMetrics

    /// Dashboard visibility + activation policy for `ui.window_state` — the
    /// observable surface of the launch/reopen behavior (issue #4).
    func windowState() -> WindowState

    /// Force an immediate poll of all hosts (`sheds.refresh`); returns once
    /// the refresh has completed so tests can assert without waiting for the
    /// poll interval.
    func refreshSheds() async

    /// Fan out `GET /api/system/df` to every host and publish + return the
    /// per-host disk usage (`system.df`, M7).
    func refreshSystemUsage() async -> [HostDiskUsage]

    /// Fan out `GET /api/images` to every host and publish + return the
    /// per-host image lists (`images.list`), feeding the New-Shed picker.
    func refreshImages() async -> [HostImageList]

    /// Open the dashboard and present the New-Shed sheet (`ui.show_create`),
    /// so the harness can screenshot the image picker.
    func showCreateSheet()

    // MARK: - M1: lifecycle, create, terminal

    /// Run a lifecycle mutation on a shed, then refresh so the result is
    /// reflected by the time this returns.
    func shedAction(_ action: ShedAction, host: String?, name: String) async throws

    /// Kick off a create; returns a create id whose progress is polled via
    /// `createStatus`.
    func startCreate(host: String?, request: CreateShedRequest) throws -> String
    func createStatus(id: String) -> CreateProgress?

    /// Build the ssh command to reach a shed (pure; spawns nothing).
    func terminalCommand(shed: String, host: String?, session: String?) throws -> TerminalCommand
    /// Build AND launch the terminal (side-effecting; gated to test mode off).
    func openTerminal(shed: String, host: String?, session: String?) throws -> TerminalCommand

    // MARK: - M2: remote-control sessions

    func rcList(host: String?, shed: String?) async throws -> [RcSession]
    func rcLaunch(host: String?, shed: String, kind: RcKind, displayName: String?, workdir: String?) async throws -> RcSession
    func rcKill(host: String?, shed: String, slug: String) async throws

    // MARK: - M3: credential approvals + activity

    func approvalsList() -> [PendingApprovalItem]
    /// Resolve a pending approval. `choice` carries the SSH scope/TTL and whether
    /// to persist a per-shed rule (always-allow / always-deny).
    func decideApproval(id: String, choice: ApprovalChoice) async throws
    func activityList(limit: Int) -> [AuditEntry]
    /// Filesystem path of the append-only audit log (FR-6 export).
    func auditLogPath() -> String
    /// Replace the policy rules (test-mode only, to exercise the matrix E2E).
    func setPolicyRules(_ rules: [PolicyRule])
    /// The current effective rule set (default + per-namespace + per-shed).
    func policyRules() -> [PolicyRule]

    // MARK: - M5: notifications (driveable over IPC)

    /// Notifications the app has posted (only the test presenter records these).
    func postedNotifications() -> [PostedNotification]
    /// Drive a posted notification's Approve/Deny action (test presenter only).
    func invokeNotification(id: String, decision: ApprovalDecision) throws
}
