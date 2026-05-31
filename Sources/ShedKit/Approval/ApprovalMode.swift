// ApprovalMode.swift — the user-facing default approval modes (M4). Each
// maps to a default-scope PolicyRule. Lives in ShedKit (next to PolicyRule)
// so the preferences UI can iterate it directly without stringly-typed tags.

import Foundation

public enum ApprovalMode: String, Codable, Sendable, CaseIterable {
    case touchID = "touchid"   // prompt, Touch ID each time
    case prompt = "prompt"     // prompt, no biometric
    case approve = "approve"   // auto-approve (audited)
    case deny = "deny"         // auto-deny

    public var rule: PolicyRule {
        switch self {
        case .touchID: return PolicyRule(scope: .default, action: .prompt, gate: .touchid)
        case .prompt: return PolicyRule(scope: .default, action: .prompt, gate: .none)
        case .approve: return PolicyRule(scope: .default, action: .approve, gate: .none)
        case .deny: return PolicyRule(scope: .default, action: .deny, gate: .none)
        }
    }

    public var label: String {
        switch self {
        case .touchID: return "Touch ID each time"
        case .prompt: return "Prompt (no Touch ID)"
        case .approve: return "Auto-approve"
        case .deny: return "Auto-deny"
        }
    }
}
