// RemoteControl.swift
//
// Guest-binary client for the RC Session Convention v2. The SSH+tmux choreography
// (bootstrap, classification, SHED_RC_* metadata, trust pre-seed, prompt delivery)
// now lives in the `shed-ext-rc` guest binary; shed-desktop invokes it over SSH and
// decodes the neutral JSON DTO. The normative spec lives in shed-remote-agent's
// docs/reference/rc-session-convention.md.

import Foundation

/// RC session kind (Convention v2). `<tool>-<mode>` so the model can grow to other
/// agents later; `shell` is tool-agnostic. v1's `agent`/`repl` were renamed.
public enum RcKind: String, Codable, Sendable, CaseIterable {
    case claudeRc = "claude-rc"
    case claudeBroker = "claude-broker"
    case shell

    public static let `default`: RcKind = .claudeRc
}

public enum RcState: String, Codable, Sendable, Equatable {
    case starting
    case ready
    case reconnecting
    case needsTrust = "needs-trust"
    case needsAuth = "needs-auth"
    case dead
}

/// A pane-derived (state, url). The live RC path takes state/url from the binary's
/// DTO; this type backs the pure `rc.classify` IPC utility.
public struct RcClassification: Sendable, Equatable {
    public let state: RcState
    public let url: String?
    public init(state: RcState, url: String? = nil) {
        self.state = state
        self.url = url
    }
}

/// The neutral, target-agnostic session shape printed by `shed-ext-rc` (it runs
/// inside the shed and can't know the host alias / shed name — the app injects those
/// and maps `id`→`rcID`). Optional fields are absent (not null) when unknown.
public struct RcSessionDTO: Codable, Sendable, Equatable {
    public let slug: String
    public let tmuxSession: String
    public let kind: RcKind
    public let state: RcState
    public let managed: Bool
    public let displayName: String?
    public let workdir: String?
    public let url: String?
    public let id: String?
    public let createdBy: String?
    public let createdAt: String?
    public let targetLabel: String?

    enum CodingKeys: String, CodingKey {
        case slug
        case tmuxSession = "tmux_session"
        case kind, state, managed
        case displayName = "display_name"
        case workdir, url, id
        case createdBy = "created_by"
        case createdAt = "created_at"
        case targetLabel = "target_label"
    }
}

/// The `shed-ext-rc list` response shape.
public struct RcSessionListDTO: Codable, Sendable {
    public let rcSessions: [RcSessionDTO]
    enum CodingKeys: String, CodingKey { case rcSessions = "rc_sessions" }
}

/// A binary-domain outcome distinguished from an SSH transport failure by the
/// exit code (the orchestrator maps SSH auth/unreachable; these are the binary's).
public enum RcError: Error, CustomStringConvertible, Equatable {
    case slugTaken(String)
    case notFound(String)
    case badRequest(String)
    case missingBinary
    case failed(String)

    public var description: String {
        switch self {
        case .slugTaken(let s): return "rc session already exists: \(s)"
        case .notFound(let s): return "rc session not found: \(s)"
        case .badRequest(let s): return "invalid rc request: \(s)"
        case .missingBinary: return "shed-ext-rc is not installed on this shed — update the shed image"
        case .failed(let s): return "rc operation failed: \(s)"
        }
    }
}

public enum RemoteControl {
    public static let tmuxPrefix = "rc-"
    /// Fallback workdir for a legacy/unmanaged session whose DTO omits one (the
    /// binary resolves $SHED_WORKSPACE for managed sessions).
    public static let defaultWorkdir = "/workspace"
    /// Stable tool id for SHED_RC_CREATED_BY (`<tool>/<version>`; no `/`).
    public static let toolName = "shed-desktop"
    /// Convention schema version the binary writes.
    public static let schemaVersion = 2

    // Confusable-free alphabet (no i, l, o, 0, 1) — matches the convention.
    static let slugAlphabet = "abcdefghjkmnpqrstuvwxyz23456789"

    public static func tmuxName(slug: String) -> String { "\(tmuxPrefix)\(slug)" }

    /// Generate a 6-char confusable-free slug (the app picks the slug so it can
    /// build its `<shed>/<slug>` display name; the binary accepts a caller slug).
    public static func generateSlug(length: Int = 6) -> String {
        let alpha = Array(slugAlphabet)
        return String((0..<length).map { _ in alpha.randomElement()! })
    }

    // MARK: - shed-ext-rc invocation

    /// Binary name (or path). Defaults to `shed-ext-rc` (on PATH in the shed `full`
    /// image); overridable via SHED_EXT_RC_BIN for dev/proof (scp'd to e.g. /tmp).
    public static func binaryName() -> String {
        ProcessInfo.processInfo.environment["SHED_EXT_RC_BIN"] ?? "shed-ext-rc"
    }

    /// argv for `shed-ext-rc create --wait` (the binary resolves the workdir,
    /// pre-seeds trust, polls to ready, accepts trust, and delivers a stdin prompt).
    public static func createArgv(
        kind: RcKind, name: String, slug: String, workdir: String?,
        createdBy: String, target: String, hasPrompt: Bool
    ) -> [String] {
        var a = [
            binaryName(), "create",
            "--kind", kind.rawValue,
            "--name", name,
            "--slug", slug,
            "--created-by", createdBy,
            "--target", target,
            "--wait",
        ]
        if let w = workdir, !w.isEmpty { a += ["--workdir", w] }
        if hasPrompt { a += ["--prompt-stdin"] }
        return a
    }

    public static func listArgv() -> [String] { [binaryName(), "list"] }
    public static func killArgv(slug: String) -> [String] { [binaryName(), "kill", "--slug", slug] }

    /// Map a non-zero exit code + stderr to an RcError. SSH-transport failures
    /// (the binary never ran) surface as `.failed` with the ssh stderr.
    public static func error(exitCode: Int32, stderr: String, stdout: String) -> RcError {
        let detail = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        switch exitCode {
        case 3: return .slugTaken(detail)
        case 4: return .notFound(detail)
        case 2: return .badRequest(detail)
        case 127: return .missingBinary
        default:
            if stderr.localizedCaseInsensitiveContains("command not found") { return .missingBinary }
            return .failed(detail.isEmpty ? "shed-ext-rc exited \(exitCode)" : detail)
        }
    }

    // MARK: - DTO → wire RcSession

    /// Adapt a binary DTO into the app's `RcSession`, injecting the host/shed the
    /// binary can't know and applying the `<shed>/<slug>` display fallback. `id`
    /// becomes `rcID` (the app's `id` is the computed `host/shed/slug`).
    public static func rcSession(fromDTO dto: RcSessionDTO, serverName: String, shed: String) -> RcSession {
        RcSession(
            host: serverName, shed: shed, slug: dto.slug,
            tmuxSession: dto.tmuxSession,
            displayName: dto.displayName ?? "\(shed)/\(dto.slug)",
            workdir: dto.workdir ?? defaultWorkdir,
            kind: dto.kind, state: dto.state, url: dto.url,
            rcID: dto.id, createdBy: dto.createdBy, createdAt: dto.createdAt,
            targetLabel: dto.targetLabel, managed: dto.managed)
    }

    /// Decode a single-session DTO from the binary's stdout.
    public static func decodeSession(_ stdout: String) throws -> RcSessionDTO {
        guard let data = stdout.data(using: .utf8) else {
            throw RcError.failed("shed-ext-rc returned no output")
        }
        do { return try JSONDecoder().decode(RcSessionDTO.self, from: data) }
        catch { throw RcError.failed("shed-ext-rc returned an invalid session DTO") }
    }

    /// Decode the `list` response from the binary's stdout.
    public static func decodeList(_ stdout: String) throws -> [RcSessionDTO] {
        guard let data = stdout.data(using: .utf8) else { return [] }
        do { return try JSONDecoder().decode(RcSessionListDTO.self, from: data).rcSessions }
        catch { throw RcError.failed("shed-ext-rc returned an invalid session list") }
    }

    // MARK: - Pure pane classifier (backs the `rc.classify` IPC utility)

    public static func classifyPane(kind: RcKind, pane: String) -> RcClassification {
        // Trust + auth heuristics apply to both kinds that run claude.
        if kind != .shell {
            if pane.contains(/Workspace not trusted/.ignoresCase()) {
                return RcClassification(state: .needsTrust, url: extractURL(kind: kind, pane: pane))
            }
            if pane.contains(/Quick safety check/.ignoresCase())
                || pane.contains(/Yes,\s*I trust this folder/.ignoresCase()) {
                return RcClassification(state: .needsTrust, url: extractURL(kind: kind, pane: pane))
            }
            if pane.contains(/requires a claude\.ai subscription/.ignoresCase())
                || pane.contains(/not logged in/.ignoresCase())
                || pane.contains(/claude auth login/.ignoresCase()) {
                return RcClassification(state: .needsAuth, url: extractURL(kind: kind, pane: pane))
            }
        }

        switch kind {
        case .claudeBroker:
            let url = extractURL(kind: .claudeBroker, pane: pane)
            if pane.contains(/\bReconnecting\b/) { return RcClassification(state: .reconnecting, url: url) }
            if pane.contains(/\bConnected\b/), url != nil { return RcClassification(state: .ready, url: url) }
            if url != nil { return RcClassification(state: .ready, url: url) }
            return RcClassification(state: .starting)
        case .claudeRc:
            let url = extractURL(kind: .claudeRc, pane: pane)
            if pane.contains(/Remote Control connecting/.ignoresCase()), url == nil {
                return RcClassification(state: .starting)
            }
            if pane.contains(/Remote Control active/.ignoresCase()), url != nil {
                return RcClassification(state: .ready, url: url)
            }
            if url != nil { return RcClassification(state: .ready, url: url) }
            return RcClassification(state: .starting)
        case .shell:
            return pane.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? RcClassification(state: .starting)
                : RcClassification(state: .ready)
        }
    }

    /// Extract the claude.ai URL for the given kind (claude-broker uses
    /// `?environment=env_…`, claude-rc uses `/session_…`).
    public static func extractURL(kind: RcKind, pane: String) -> String? {
        switch kind {
        case .claudeBroker:
            if let m = pane.firstMatch(of: /https?:\/\/claude\.ai\/code\?environment=env_[A-Za-z0-9_-]+/) {
                return String(m.0)
            }
        case .claudeRc:
            if let m = pane.firstMatch(of: /https?:\/\/claude\.ai\/code\/session_[A-Za-z0-9_-]+/) {
                return String(m.0)
            }
        case .shell:
            return nil
        }
        return nil
    }

    // MARK: - SSH

    /// Build the ssh argv that runs `remoteArgv` on the target. Mirrors
    /// shed-remote-agent's ssh options.
    public static func sshArgv(user: String, host: String, port: Int, remoteArgv: [String], connectTimeout: Int = 10) -> [String] {
        let remote = remoteArgv.map(shellQuote).joined(separator: " ")
        return [
            "ssh",
            "-o", "BatchMode=yes",
        ] + ShedSSH.hostKeyOptions + [
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-p", String(port),
            "\(user)@\(host)",
            "--", remote,
        ]
    }
}
