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

public enum RemoteControl {
    public static let tmuxPrefix = "rc-"
    public static let defaultWorkdir = "/workspace"

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

    /// The `tmux new-session` argv that bootstraps an RC session.
    public static func bootstrapArgv(slug: String, kind: RcKind, displayName: String, workdir: String) -> [String] {
        [
            "tmux", "new-session", "-d",
            "-s", tmuxName(slug: slug),
            "-c", workdir,
            "-e", "SRA_DISPLAY_NAME=\(displayName)",
            "-e", "SRA_KIND=\(kind.rawValue)",
            "-e", "SRA_WORKDIR=\(workdir)",
            innerCommand(kind: kind, displayName: displayName),
        ]
    }

    /// `tmux capture-pane` argv for probing a session's state.
    public static func captureArgv(slug: String) -> [String] {
        ["tmux", "capture-pane", "-t", tmuxName(slug: slug), "-p", "-S", "-200"]
    }

    /// `tmux kill-session` argv.
    public static func killArgv(slug: String) -> [String] {
        ["tmux", "kill-session", "-t", tmuxName(slug: slug)]
    }

    /// A bash script (run over SSH) that lists rc-* sessions and emits, for
    /// each, its SRA_* env + a 200-line pane capture, framed with `sep`.
    public static func listScript(sep: String) -> String {
        """
        names=$(tmux ls -F '#{session_name}' 2>/dev/null | grep '^\(tmuxPrefix)' || true)
        for n in $names; do
          echo "\(sep)SESSION $n"
          echo "\(sep)NAME $(tmux show-environment -t "$n" SRA_DISPLAY_NAME 2>/dev/null | sed -n 's/^SRA_DISPLAY_NAME=//p')"
          echo "\(sep)KIND $(tmux show-environment -t "$n" SRA_KIND 2>/dev/null | sed -n 's/^SRA_KIND=//p')"
          echo "\(sep)WORKDIR $(tmux show-environment -t "$n" SRA_WORKDIR 2>/dev/null | sed -n 's/^SRA_WORKDIR=//p')"
          echo "\(sep)PANE"
          tmux capture-pane -t "$n" -p -S -200 2>/dev/null || true
        done
        """
    }

    /// Parse the output of `listScript` into classified sessions. Pure, so
    /// it's unit-tested against a captured fixture even though the SSH half
    /// can't run under CI.
    public static func parseSessionList(_ output: String, sep: String, serverName: String, shed: String) -> [RcSession] {
        var sessions: [RcSession] = []
        var cur: (slug: String, name: String, kind: RcKind, workdir: String, pane: [String])?
        func flush() {
            guard let c = cur else { return }
            let cls = classifyPane(kind: c.kind, pane: c.pane.joined(separator: "\n"))
            sessions.append(RcSession(
                host: serverName, shed: shed, slug: c.slug,
                tmuxSession: tmuxName(slug: c.slug),
                displayName: c.name.isEmpty ? c.slug : c.name,
                workdir: c.workdir.isEmpty ? defaultWorkdir : c.workdir,
                kind: c.kind, state: cls.state, url: cls.url))
        }
        var inPane = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("\(sep)SESSION ") {
                flush()
                let name = String(line.dropFirst("\(sep)SESSION ".count))
                let slug = name.hasPrefix(tmuxPrefix) ? String(name.dropFirst(tmuxPrefix.count)) : name
                cur = (slug, "", .repl, "", [])
                inPane = false
            } else if line.hasPrefix("\(sep)NAME ") {
                cur?.name = String(line.dropFirst("\(sep)NAME ".count))
            } else if line.hasPrefix("\(sep)KIND ") {
                cur?.kind = RcKind(rawValue: String(line.dropFirst("\(sep)KIND ".count))) ?? .repl
            } else if line.hasPrefix("\(sep)WORKDIR ") {
                cur?.workdir = String(line.dropFirst("\(sep)WORKDIR ".count))
            } else if line == "\(sep)PANE" {
                inPane = true
            } else if inPane {
                cur?.pane.append(line)
            }
        }
        flush()
        return sessions
    }

    /// Build the ssh argv that runs `remoteArgv` on the target. Mirrors
    /// shed-remote-agent's ssh options.
    public static func sshArgv(user: String, host: String, port: Int, remoteArgv: [String], connectTimeout: Int = 10) -> [String] {
        let remote = remoteArgv.map(shellQuote).joined(separator: " ")
        return [
            "ssh",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-p", String(port),
            "\(user)@\(host)",
            "--", remote,
        ]
    }
}
