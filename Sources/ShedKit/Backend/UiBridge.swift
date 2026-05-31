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

    /// Open (and front) the preferences window.
    func openPreferences()

    /// Force the menu-bar popover open or closed (`ui.openMenu`).
    func setMenuOpen(_ open: Bool)

    /// Switch the dashboard's selected sidebar pane (`ui.navigate`).
    /// Returns false for an unknown pane name.
    func navigate(toPane pane: String) -> Bool

    /// Snapshot of the view-model for `ui.state`.
    func uiState() -> UIState

    /// Logical window measurements for `app.window_metrics`.
    func windowMetrics() -> WindowMetrics

    /// Force an immediate poll of all hosts (`sheds.refresh`); returns once
    /// the refresh has completed so tests can assert without waiting for the
    /// poll interval.
    func refreshSheds() async

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

    func approvalsList() -> [ApprovalRequest]
    func decideApproval(id: String, decision: ApprovalDecision, grantSession: Bool) async throws
    func activityList(limit: Int) -> [AuditEntry]
    /// Replace the policy rules (test-mode only, to exercise the matrix E2E).
    func setPolicyRules(_ rules: [PolicyRule])
}
