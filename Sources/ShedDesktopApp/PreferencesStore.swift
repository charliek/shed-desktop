// PreferencesStore.swift — persisted user settings (M4).
//
// UserDefaults-backed, honoring SHED_DESKTOP_DEFAULTS_SUITE so the test
// harness writes to a throwaway suite instead of the dev's real defaults.

import Foundation
import ShedKit

struct PreferencesStore {
    private let defaults: UserDefaults

    init() {
        if let suite = ProcessInfo.processInfo.environment["SHED_DESKTOP_DEFAULTS_SUITE"],
           let scoped = UserDefaults(suiteName: suite) {
            defaults = scoped
        } else {
            defaults = .standard
        }
    }

    /// Terminal launch template with a `{cmd}` placeholder; empty = default
    /// to Terminal.app.
    var terminalTemplate: String {
        get { defaults.string(forKey: "terminalTemplate") ?? "" }
        nonmutating set { defaults.set(newValue, forKey: "terminalTemplate") }
    }

    /// The default approval mode (ApprovalMode lives in ShedKit), mapped to
    /// the default-scope policy rule.
    var defaultApprovalMode: ApprovalMode {
        get { ApprovalMode(rawValue: defaults.string(forKey: "defaultApprovalMode") ?? "") ?? .touchID }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "defaultApprovalMode") }
    }

    /// Per-namespace + per-shed policy rules (the default-scope rule is
    /// `defaultApprovalMode`). JSON-encoded in the defaults suite so per-shed
    /// "always allow" grants and per-namespace overrides survive relaunch.
    var policyRules: [PolicyRule] {
        get {
            guard let data = defaults.data(forKey: "policyRules"),
                  let rules = try? JSONDecoder().decode([PolicyRule].self, from: data) else { return [] }
            return rules
        }
        nonmutating set {
            // Only write on a successful encode — never set(nil), which would
            // silently wipe every per-namespace/per-shed rule.
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: "policyRules")
        }
    }
}
