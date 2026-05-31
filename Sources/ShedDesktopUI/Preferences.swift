// Preferences.swift — the observable backing the preferences window (M4).
// The app wires the on* closures to persist + apply each change.

import ShedKit
import SwiftUI

@MainActor public final class Preferences: ObservableObject {
    @Published public var launchAtLogin: Bool
    @Published public var terminalTemplate: String
    @Published public var defaultApprovalMode: ApprovalMode

    public var onLaunchAtLogin: ((Bool) -> Void)?
    public var onTerminalTemplate: ((String) -> Void)?
    public var onDefaultMode: ((ApprovalMode) -> Void)?

    public init(launchAtLogin: Bool = false, terminalTemplate: String = "", defaultApprovalMode: ApprovalMode = .touchID) {
        self.launchAtLogin = launchAtLogin
        self.terminalTemplate = terminalTemplate
        self.defaultApprovalMode = defaultApprovalMode
    }
}
