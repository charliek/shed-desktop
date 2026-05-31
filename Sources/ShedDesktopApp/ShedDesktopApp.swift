// ShedDesktopApp.swift — entry point.
//
// A manual AppKit bootstrap (rather than the SwiftUI App lifecycle) so the
// app fully owns its windows: the dashboard and the menu popover are
// AppKit NSWindows hosting SwiftUI views, which gives the IPC screenshot
// op a stable window handle and deterministic show/hide. Accessory
// activation policy = menu-bar app, no Dock icon (also set via
// LSUIElement in the bundle's Info.plist).

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
