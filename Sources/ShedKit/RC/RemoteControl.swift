// RemoteControl.swift
//
// Swift port of shed-remote-agent's RC logic (apps/api/src/lib/rc.ts): the
// pane-state classifier, the confusable-free slug, and the SSH+tmux
// bootstrap command shapes. The classifier is pure (a tmux capture-pane
// string in, a state out) so it ports verbatim and is unit-tested against
// the same vectors as upstream.

import Foundation

public enum RcKind: String, Codable, Sendable, CaseIterable {
    case agent
    case repl
    case shell

    public static let `default`: RcKind = .repl
}

public enum RcState: String, Codable, Sendable, Equatable {
    case starting
    case ready
    case reconnecting
    case needsTrust = "needs-trust"
    case needsAuth = "needs-auth"
    case dead
}

public struct RcClassification: Sendable, Equatable {
    public let state: RcState
    public let url: String?
    public init(state: RcState, url: String? = nil) {
        self.state = state
        self.url = url
    }
}

/// The write-once metadata stamped into a managed RC session's tmux env at
/// create, per the cross-tool RC Session Convention v1 (`SHED_RC_*`).
public struct RcMetadata: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let kind: RcKind
    public let workdir: String
    public let createdBy: String
    public let createdAt: String
    public let targetLabel: String?
    public init(id: String, displayName: String, kind: RcKind, workdir: String,
                createdBy: String, createdAt: String, targetLabel: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.workdir = workdir
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.targetLabel = targetLabel
    }
}

/// Per-invocation section markers for the batched list-and-probe script.
/// Built from a random nonce so neither pane text nor a metadata value can
/// collide with a delimiter and corrupt block parsing.
public struct ListMarkers: Sendable, Equatable {
    public let session: String
    public let env: String
    public let pane: String
    public init(nonce: String) {
        let base = "@@RC:\(nonce)"
        session = "\(base):S"
        env = "\(base):E"
        pane = "\(base):P"
    }
}

public enum RemoteControl {
    public static let tmuxPrefix = "rc-"
    public static let defaultWorkdir = "/workspace"

    // MARK: - RC Session Convention v1 (SHED_RC_*)

    /// Schema version stamped into SHED_RC_V. Bumped only for breaking changes.
    public static let schemaVersion = 1
    /// Stable tool id for SHED_RC_CREATED_BY (`<tool>/<version>`; no `/`).
    public static let toolName = "shed-desktop"

    static let envPrefix = "SHED_RC_"
    static let envV = "SHED_RC_V"
    static let envID = "SHED_RC_ID"
    static let envDisplayName = "SHED_RC_DISPLAY_NAME"
    static let envKind = "SHED_RC_KIND"
    static let envWorkdir = "SHED_RC_WORKDIR"
    static let envCreatedBy = "SHED_RC_CREATED_BY"
    static let envCreatedAt = "SHED_RC_CREATED_AT"
    static let envTarget = "SHED_RC_TARGET"

    /// A session is *managed* iff SHED_RC_V is a positive integer. Compared as
    /// decimal text (not `Int(raw)`) so a huge version string stays managed
    /// (forward-compat) rather than overflowing to legacy. Rejects `0`/`00`,
    /// `+1`, `1.0`, `1e3`, `0x1`, blank.
    public static func isManagedVersion(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let v = raw.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, v.allSatisfy({ ("0"..."9").contains($0) }) else { return false }
        return v.contains { $0 != "0" }  // >= 1
    }

    /// Strict RFC3339 UTC with trailing `Z` (the shape `nowISO8601()` emits).
    /// Used to validate a session's stored SHED_RC_CREATED_AT before trusting
    /// it; the lenient `DateFormatting.parseFlexibleTimestamp` is for display.
    public static func isValidCreatedAt(_ s: String) -> Bool {
        s.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z/) != nil
    }

    /// Parse a `tmux show-environment` dump into SHED_RC_* key→value. Keeps
    /// only `SHED_RC_`-prefixed lines (so tmux's `-KEY` unset markers, which
    /// start with `-`, are skipped) and lines containing `=`; splits on the
    /// first `=`.
    static func parseRcEnv(_ dump: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard line.hasPrefix(envPrefix), let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return out
    }

    /// The raw SHED_RC_* key/value pairs (v1) in deterministic order — the
    /// single source of truth for a managed session's metadata.
    static func metaEnvPairs(_ meta: RcMetadata) -> [(String, String)] {
        var pairs: [(String, String)] = [
            (envV, String(schemaVersion)),
            (envID, meta.id),
            (envDisplayName, meta.displayName),
            (envKind, meta.kind.rawValue),
            (envWorkdir, meta.workdir),
            (envCreatedBy, meta.createdBy),
            (envCreatedAt, meta.createdAt),
        ]
        if let t = meta.targetLabel, !t.isEmpty { pairs.append((envTarget, t)) }
        return pairs
    }

    // Confusable-free alphabet (no i, l, o, 0, 1) — matches upstream.
    static let slugAlphabet = "abcdefghjkmnpqrstuvwxyz23456789"

    public static func tmuxName(slug: String) -> String { "\(tmuxPrefix)\(slug)" }

    /// Generate a 6-char confusable-free slug.
    public static func generateSlug(length: Int = 6) -> String {
        let alpha = Array(slugAlphabet)
        return String((0..<length).map { _ in alpha.randomElement()! })
    }

    // MARK: - Classifier (ported verbatim from rc.ts classifyPane)

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
        case .agent:
            let url = extractURL(kind: .agent, pane: pane)
            if pane.contains(/\bReconnecting\b/) { return RcClassification(state: .reconnecting, url: url) }
            if pane.contains(/\bConnected\b/), url != nil { return RcClassification(state: .ready, url: url) }
            if url != nil { return RcClassification(state: .ready, url: url) }
            return RcClassification(state: .starting)
        case .repl:
            let url = extractURL(kind: .repl, pane: pane)
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

    /// Extract the claude.ai URL for the given kind (agent uses
    /// `?environment=env_…`, repl uses `/session_…`).
    public static func extractURL(kind: RcKind, pane: String) -> String? {
        switch kind {
        case .agent:
            if let m = pane.firstMatch(of: /https?:\/\/claude\.ai\/code\?environment=env_[A-Za-z0-9_-]+/) {
                return String(m.0)
            }
        case .repl:
            if let m = pane.firstMatch(of: /https?:\/\/claude\.ai\/code\/session_[A-Za-z0-9_-]+/) {
                return String(m.0)
            }
        case .shell:
            return nil
        }
        return nil
    }

    // MARK: - Bootstrap command shapes

    /// The inner command run inside the tmux session.
    public static func innerCommand(kind: RcKind, displayName: String) -> String {
        switch kind {
        case .agent: return "claude remote-control --name \(shellQuote(displayName)) --spawn same-dir"
        case .repl: return "claude --name \(shellQuote(displayName)) /rc"
        case .shell: return "bash -l"
        }
    }

    /// The `tmux new-session` argv that bootstraps a managed RC session.
    /// Values are passed raw — `sshArgv` shell-quotes each token, so tmux
    /// stores each `KEY=value` verbatim (no tmux escaping; multi-word display
    /// names round-trip). Callers must reject control chars first.
    public static func bootstrapArgv(slug: String, meta: RcMetadata) -> [String] {
        var argv = [
            "tmux", "new-session", "-d",
            "-s", tmuxName(slug: slug),
            "-c", meta.workdir,
        ]
        for (k, v) in metaEnvPairs(meta) { argv += ["-e", "\(k)=\(v)"] }
        argv.append(innerCommand(kind: meta.kind, displayName: meta.displayName))
        return argv
    }

    /// `tmux capture-pane` argv for probing a session's state.
    public static func captureArgv(slug: String) -> [String] {
        ["tmux", "capture-pane", "-t", tmuxName(slug: slug), "-p", "-S", "-200"]
    }

    /// `tmux kill-session` argv.
    public static func killArgv(slug: String) -> [String] {
        ["tmux", "kill-session", "-t", tmuxName(slug: slug)]
    }

    /// tmux kill-session is non-zero when the session is already gone — either
    /// the name is unknown, or killing the last session stopped the server
    /// ("no server running"). Both mean "already gone", so kill stays idempotent.
    public static func isMissingSessionError(_ stderr: String) -> Bool {
        stderr.contains(/can't find session|no session|no server running/.ignoresCase())
    }

    /// tmux refuses a duplicate session name — a colliding slug surfaces here.
    public static func isDuplicateSessionError(_ stderr: String) -> Bool {
        stderr.contains(/duplicate session|already exists/.ignoresCase())
    }

    /// A bash script that lists rc-* sessions and emits, for each, its full
    /// SHED_RC_* env dump (one `show-environment`, not one call per key) + a
    /// 200-line pane capture, framed by `markers`. Fed to a remote `bash` over
    /// **stdin** (not `bash -c`): on shed images where the user has no
    /// controlling terminal, tmux invoked as a child of `bash -c` fails with
    /// "open terminal failed: not a terminal", but works when bash reads from
    /// stdin. Matches the reference (shed-remote-agent rc.ts listRcSessions).
    public static func listScript(markers: ListMarkers) -> String {
        """
        names=$(tmux ls -F '#{session_name}' 2>/dev/null | grep '^\(tmuxPrefix)' || true)
        for n in $names; do
          echo "\(markers.session) $n"
          echo "\(markers.env)"
          tmux show-environment -t "$n" 2>/dev/null | grep '^\(envPrefix)' || true
          echo "\(markers.pane)"
          tmux capture-pane -t "$n" -p -S -200 2>/dev/null || true
        done
        """
    }

    /// Split the batched list script's stdout into per-session blocks and
    /// parse each. Markers are matched as whole lines (an env value ending in
    /// `:E` can't be mistaken for the env marker; the random nonce keeps pane
    /// text from forging a boundary). Pure, so it's unit-tested directly.
    public static func parseListOutput(_ output: String, markers: ListMarkers, serverName: String, shed: String) -> [RcSession] {
        var sessions: [RcSession] = []
        var cur: (tmux: String, env: [String], pane: [String])?
        enum Section { case none, env, pane }
        var section: Section = .none
        func flush() {
            guard let c = cur else { return }
            sessions.append(parseRcSession(
                tmuxSession: c.tmux, envDump: c.env.joined(separator: "\n"),
                pane: c.pane.joined(separator: "\n"), serverName: serverName, shed: shed))
        }
        let sessionPrefix = markers.session + " "
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix(sessionPrefix) {
                flush()
                cur = (String(line.dropFirst(sessionPrefix.count)).trimmingCharacters(in: .whitespaces), [], [])
                section = .none
            } else if line == markers.env {
                section = .env
            } else if line == markers.pane {
                section = .pane
            } else if section == .env {
                cur?.env.append(line)
            } else if section == .pane {
                cur?.pane.append(line)
            }
        }
        flush()
        return sessions
    }

    /// Reconstruct one session's wire-shape from its SHED_RC_* env dump + pane.
    /// `state`/`url` stay derived from the pane (never stored). A session with
    /// no valid SHED_RC_V is legacy/unmanaged: kind defaults to `.agent` (pre-
    /// convention sessions were all agents — intentionally different from the
    /// create-time `RcKind.default`), with a `<shed>/<slug>` fallback name and
    /// the default workdir, and any stray SHED_RC_*/SRA_* values are ignored.
    /// A SHED_RC_V greater than 1 is still managed (forward-compat): known v1
    /// fields are rendered, unknown keys ignored, and the session never dropped.
    public static func parseRcSession(tmuxSession: String, envDump: String, pane: String, serverName: String, shed: String) -> RcSession {
        let env = parseRcEnv(envDump)
        let slug = tmuxSession.hasPrefix(tmuxPrefix) ? String(tmuxSession.dropFirst(tmuxPrefix.count)) : tmuxSession
        func val(_ k: String) -> String? {
            guard let v = env[k]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
            return v
        }
        guard isManagedVersion(env[envV]) else {
            let kind: RcKind = .agent
            let cls = classifyPane(kind: kind, pane: pane)
            return RcSession(
                host: serverName, shed: shed, slug: slug, tmuxSession: tmuxSession,
                displayName: "\(shed)/\(slug)", workdir: defaultWorkdir,
                kind: kind, state: cls.state, url: cls.url, managed: false)
        }
        let kind = RcKind(rawValue: val(envKind) ?? "") ?? .agent
        let cls = classifyPane(kind: kind, pane: pane)
        return RcSession(
            host: serverName, shed: shed, slug: slug, tmuxSession: tmuxSession,
            displayName: val(envDisplayName) ?? "\(shed)/\(slug)",
            workdir: val(envWorkdir) ?? defaultWorkdir,
            kind: kind, state: cls.state, url: cls.url,
            rcID: val(envID), createdBy: val(envCreatedBy),
            createdAt: val(envCreatedAt).flatMap { isValidCreatedAt($0) ? $0 : nil },
            targetLabel: val(envTarget), managed: true)
    }

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
