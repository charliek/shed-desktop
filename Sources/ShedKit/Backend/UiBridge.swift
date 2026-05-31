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
}
