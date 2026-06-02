// ShedDesktopApp.swift — entry point.
//
// A manual AppKit bootstrap (rather than the SwiftUI App lifecycle) so the
// app fully owns its windows: the dashboard and the menu popover are
// AppKit NSWindows hosting SwiftUI views, which gives the IPC screenshot
// op a stable window handle and deterministic show/hide. The app launches as
// an accessory (menu-bar item, no Dock icon — also `LSUIElement` in the
// bundle's Info.plist); `AppModel` raises it to a regular app (Dock icon +
// ⌘-Tab + the app menu) while a window is open and reverts on close.

import AppKit
import ShedKit

@main
@MainActor
enum ShedDesktopMain {
    // NSApplication.delegate is weak; keep a strong ref so the delegate
    // (and the AppModel it owns) lives for the whole process.
    static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appModel = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appModel.start(profile: .mac())
    }
}
