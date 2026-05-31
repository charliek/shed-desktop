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
}
