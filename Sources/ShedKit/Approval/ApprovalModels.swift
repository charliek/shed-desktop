// ApprovalModels.swift — the credential-approval domain (M3).
//
// These double as IPC wire shapes (snake_case CodingKeys), like the rest of
// the models, so the approval queue + activity feed need no separate DTOs.

import Foundation

/// A credential-approval request delegated from shed-host-agent. The app
/// only ever sees metadata — never key material.
public struct ApprovalRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var ts: String
    public var server: String          // shed server this came from ("" in single-server mode)
    public var namespace: String       // ssh-agent | aws-credentials | docker-credentials
    public var op: String              // sign | get_credentials | …
    public var shed: String
    public var detail: String          // human-readable (key type, role, registry)
    public var expiresAt: String

    enum CodingKeys: String, CodingKey {
        case id, ts, server, namespace, op, shed, detail
        case expiresAt = "expires_at"
    }

    public init(id: String, ts: String, server: String = "", namespace: String, op: String, shed: String, detail: String, expiresAt: String) {
        self.id = id
        self.ts = ts
        self.server = server
        self.namespace = namespace
        self.op = op
        self.shed = shed
        self.detail = detail
        self.expiresAt = expiresAt
    }

    // `server` is omitted by the host agent in single-server mode (shed-extensions
    // #21), so decode it defensively; the rest are always present on the wire.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ts = try c.decode(String.self, forKey: .ts)
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? ""
        namespace = try c.decode(String.self, forKey: .namespace)
        op = try c.decode(String.self, forKey: .op)
        shed = try c.decode(String.self, forKey: .shed)
        detail = try c.decode(String.self, forKey: .detail)
        expiresAt = try c.decode(String.self, forKey: .expiresAt)
    }

    public var expiresAtDate: Date? { DateFormatting.parseFlexibleTimestamp(expiresAt) }

    /// "server/shed" when multi-server, else just the shed name.
    public var qualifiedShed: String { server.isEmpty ? shed : "\(server)/\(shed)" }
}

public enum ApprovalDecision: String, Codable, Sendable {
    case approve, deny
}

/// The credential namespaces the host agent brokers. Only `ssh-agent` is
/// gated today; the rest are audit-only (visible in the activity feed).
public enum CredentialNamespace {
    public static let all = ["ssh-agent", "aws-credentials", "docker-credentials"]
}

public enum DecidedBy: String, Codable, Sendable {
    case policy, user, touchid, timeout
}

/// An entry in the app's own audit store — a superset of the host agent's
/// JSON log (adds `id`, `source`, `policy`).
public struct AuditEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var ts: String
    public var source: AuditSource
    public var server: String?
    public var shed: String?
    public var ns: String?
    public var op: String?
    public var result: String          // ok | denied | error | …
    public var detail: String?
    public var approval: String?
    public var policy: String?

    public init(
        id: String, ts: String, source: AuditSource, server: String? = nil, shed: String? = nil, ns: String? = nil,
        op: String? = nil, result: String, detail: String? = nil, approval: String? = nil, policy: String? = nil
    ) {
        self.id = id
        self.ts = ts
        self.source = source
        self.server = server
        self.shed = shed
        self.ns = ns
        self.op = op
        self.result = result
        self.detail = detail
        self.approval = approval
        self.policy = policy
    }

    /// Map a host-agent `event` frame into a stored entry (source = host-agent).
    public init(frame: AuditEventFrame) {
        self.init(
            id: frame.requestID ?? UUID().uuidString,
            ts: frame.ts ?? DateFormatting.nowISO8601(),
            source: .hostAgent, server: frame.server, shed: frame.shed, ns: frame.ns, op: frame.op,
            result: frame.result, detail: frame.detail, approval: frame.approval)
    }
}

public enum AuditSource: String, Codable, Sendable {
    case hostAgent = "host-agent"
    case app
    case lifecycle
    case rc
}

// MARK: - Policy

public enum PolicyAction: String, Codable, Sendable {
    case approve, deny, prompt
}

public enum PolicyGate: String, Codable, Sendable {
    case touchid, none
}

public enum PolicyScope: String, Codable, Sendable {
    case `default`, namespace, shed, session
}

/// A single policy rule. The engine resolves the most specific match.
/// `server` scopes a per-shed rule to one shed server ("" = the single/unnamed
/// server); nil means any server (also how a rule predating the multi-server
/// `server` dimension decodes).
public struct PolicyRule: Codable, Sendable, Equatable {
    public var scope: PolicyScope
    public var server: String?
    public var namespace: String?
    public var shed: String?
    public var action: PolicyAction
    public var gate: PolicyGate

    public init(scope: PolicyScope, server: String? = nil, namespace: String? = nil, shed: String? = nil, action: PolicyAction, gate: PolicyGate = .touchid) {
        self.scope = scope
        self.server = server
        self.namespace = namespace
        self.shed = shed
        self.action = action
        self.gate = gate
    }
}

/// A session-scoped "approve for this session" grant key (server+namespace+shed).
public struct SessionGrantKey: Hashable, Sendable {
    public let server: String
    public let namespace: String
    public let shed: String
    public init(server: String, namespace: String, shed: String) {
        self.server = server
        self.namespace = namespace
        self.shed = shed
    }
}

public struct PolicyDecision: Sendable, Equatable {
    public let action: PolicyAction
    public let gate: PolicyGate
    /// The scope of the rule that decided this, for the audit trail.
    public let appliedScope: PolicyScope

    public init(action: PolicyAction, gate: PolicyGate, appliedScope: PolicyScope) {
        self.action = action
        self.gate = gate
        self.appliedScope = appliedScope
    }
}
