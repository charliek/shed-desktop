// Preferences.swift — the observable backing the preferences window (M4).
// The app wires the on* closures to persist + apply each change.

import ShedKit
import SwiftUI

/// One per-shed override row shown (and removable) in preferences.
public struct ShedRuleRow: Identifiable, Equatable, Sendable {
    public let server: String
    public let shed: String
    public var id: String { "\(server)/\(shed)" }
    public init(server: String, shed: String) {
        self.server = server
        self.shed = shed
    }
}

@MainActor public final class Preferences: ObservableObject {
    @Published public var launchAtLogin: Bool
    @Published public var terminalTemplate: String
    @Published public var defaultApprovalMode: ApprovalMode
    /// Per-namespace overrides (absent = inherit the default mode).
    @Published public var namespaceModes: [String: ApprovalMode] = [:]
    /// Per-shed "always allow" overrides, for display + removal.
    @Published public var shedRules: [ShedRuleRow] = []

    public var onLaunchAtLogin: ((Bool) -> Void)?
    public var onTerminalTemplate: ((String) -> Void)?
    public var onDefaultMode: ((ApprovalMode) -> Void)?
    /// nil mode → clear the namespace override (inherit the default).
    public var onNamespaceMode: ((String, ApprovalMode?) -> Void)?
    public var onRemoveShedRule: ((String, String) -> Void)?

    public init(launchAtLogin: Bool = false, terminalTemplate: String = "", defaultApprovalMode: ApprovalMode = .touchID) {
        self.launchAtLogin = launchAtLogin
        self.terminalTemplate = terminalTemplate
        self.defaultApprovalMode = defaultApprovalMode
    }
}
