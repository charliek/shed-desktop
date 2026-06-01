// AppState.swift
//
// The observable view-model the SwiftUI views render. Lives in the UI
// module (ShedKit stays SwiftUI-free); the app target's AppModel owns one
// instance, drives it from the host poller, and exposes a snapshot of it
// over the `ui.state` IPC op. Keeping the rendered state here (not in
// AppModel, which the UI module can't see) is the seam that lets the app
// depend on the UI rather than the reverse.

import Foundation
import ShedKit
import SwiftUI

@MainActor
public final class AppState: ObservableObject {
    @Published public var pane: DashboardPane = .sheds
    @Published public var hosts: [ShedHost] = []
    @Published public var sheds: [Shed] = []
    @Published public var lastError: String?
    /// The most recent in-flight/finished create, for the create sheet.
    @Published public var activeCreate: CreateProgress?
    /// Header indicator; wired to the real host-agent connection in M3.
    @Published public var hostAgentConnected: Bool = false
    /// Whether the create-shed sheet is presented.
    @Published public var showCreateSheet: Bool = false
    /// Whether the launch-agent sheet is presented.
    @Published public var showLaunchSheet: Bool = false
    /// Remote-control sessions across sheds (the Agents pane).
    @Published public var rcSessions: [RcSession] = []
    /// Pending credential-approval requests (the Approvals pane + menu bar).
    @Published public var approvals: [ApprovalRequest] = []
    /// Merged activity feed (host-agent audit + lifecycle + RC).
    @Published public var activity: [AuditEntry] = []
    /// Per-host disk usage (the System pane).
    @Published public var systemUsage: [HostDiskUsage] = []

    // Action seams the app wires up (the UI module can't reach AppModel
    // directly, so it calls these). All run on the main actor. Contract:
    // these are fire-and-forget — results surface back through the
    // @Published state above (sheds/activeCreate refresh; failures land in
    // lastError), not via return values.
    //
    // STOP RULE: this bag is at its practical limit (~8). The NEXT new
    // action seam should promote this to a `weak var actions: AppActions?`
    // delegate protocol (named methods, one wiring point, missing wiring =
    // compile error) rather than adding a ninth closure.
    public var onShedAction: ((ShedAction, Shed) -> Void)?
    public var onOpenTerminal: ((Shed) -> Void)?
    public var onCreate: ((String?, CreateShedRequest) -> Void)?
    public var onRcLaunch: ((String?, String, RcKind, String?) -> Void)?
    public var onRcKill: ((RcSession) -> Void)?
    public var onRcRefresh: (() -> Void)?
    /// Refresh per-host disk usage (the System pane).
    public var onSystemRefresh: (() -> Void)?
    public var onOpenURL: ((String) -> Void)?
    /// Decide a pending approval: (request, decision, grantSession).
    public var onApprovalDecide: ((ApprovalRequest, ApprovalDecision, Bool) -> Void)?
    /// "Always allow" — approve now and persist a per-(server,shed) rule.
    public var onApprovalAlwaysAllow: ((ApprovalRequest) -> Void)?
    /// Reveal the audit log file in Finder (FR-6).
    public var onRevealAuditLog: (() -> Void)?

    public init() {}

    /// Sheds grouped by host config name, in host order, for the dashboard.
    public func shedsByHost() -> [(host: ShedHost, sheds: [Shed])] {
        hosts.map { host in
            (host, sheds.filter { $0.host == host.name })
        }
    }

    public var runningCount: Int {
        sheds.filter { $0.status == .running }.count
    }

    /// Snapshot for the `ui.state` IPC op.
    public func snapshot() -> UIState {
        UIState(pane: pane.rawValue, hosts: hosts, sheds: sheds, hostAgentConnected: hostAgentConnected, lastError: lastError)
    }
}
