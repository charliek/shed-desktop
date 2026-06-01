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

    /// The same action/gate as `rule`, but scoped to one namespace (for the
    /// per-namespace overrides in preferences).
    public func rule(forNamespace ns: String) -> PolicyRule {
        PolicyRule(scope: .namespace, namespace: ns, action: rule.action, gate: rule.gate)
    }

    /// Recover the mode from a rule's action+gate (nil if it's not one of the
    /// four canonical modes).
    public init?(action: PolicyAction, gate: PolicyGate) {
        switch (action, gate) {
        case (.prompt, .touchid): self = .touchID
        case (.prompt, .none): self = .prompt
        case (.approve, .none): self = .approve
        case (.deny, .none): self = .deny
        default: return nil
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
