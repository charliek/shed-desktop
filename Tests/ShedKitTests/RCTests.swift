// RC classifier tests — ported from shed-remote-agent's rc.test.ts so the
// Swift port stays behavior-compatible with upstream.

import Foundation
import XCTest
@testable import ShedKit

final class RCClassifierTests: XCTestCase {
    func testAgentReadyWithURL() {
        let pane = """
        ·✔︎· Connected · my-shed · main
            Capacity: 0/32 · New sessions will be created in the current directory

        Continue coding in the Claude app or https://claude.ai/code?environment=env_01ABC
        space to show QR code · w to toggle spawn mode
        """
        let c = RemoteControl.classifyPane(kind: .agent, pane: pane)
        XCTAssertEqual(c.state, .ready)
        XCTAssertEqual(c.url, "https://claude.ai/code?environment=env_01ABC")
    }

    func testAgentReconnecting() {
        let c = RemoteControl.classifyPane(kind: .agent, pane: "·|· Reconnecting · retrying in 2.5s · disconnected 0s")
        XCTAssertEqual(c.state, .reconnecting)
    }

    func testAgentNeedsTrust() {
        let c = RemoteControl.classifyPane(kind: .agent, pane: "Error: Workspace not trusted. Please run `claude` ...")
        XCTAssertEqual(c.state, .needsTrust)
    }

    func testAgentNeedsAuthSubscription() {
        let c = RemoteControl.classifyPane(kind: .agent, pane: "Remote Control requires a claude.ai subscription.")
        XCTAssertEqual(c.state, .needsAuth)
    }

    func testAgentNeedsAuthLogin() {
        let c = RemoteControl.classifyPane(kind: .agent, pane: "You are not logged in. Run claude auth login.")
        XCTAssertEqual(c.state, .needsAuth)
    }

    func testReplReadyWithURL() {
        let pane = """
        ❯ /remote-control
          ⎿  Remote Control connecting…

          /remote-control is active · Code in CLI or at https://claude.ai/code/session_01RCkTDrdZ2Rr12sD5dfMjgr

        ────────────────────────────────────── spike1 ──
        ❯
          ? for shortcuts                                                  Remote Control active
        """
        let c = RemoteControl.classifyPane(kind: .repl, pane: pane)
        XCTAssertEqual(c.state, .ready)
        XCTAssertEqual(c.url, "https://claude.ai/code/session_01RCkTDrdZ2Rr12sD5dfMjgr")
    }

    func testReplStartingConnecting() {
        let c = RemoteControl.classifyPane(kind: .repl, pane: "❯ /remote-control\n  ⎿  Remote Control connecting…")
        XCTAssertEqual(c.state, .starting)
        XCTAssertNil(c.url)
    }

    func testReplFirstTimeTrustPrompt() {
        let pane = """
        Accessing workspace:

         /home/charliek/projects

         Quick safety check: Is this a project you created or one you trust?

         ❯ 1. Yes, I trust this folder
           2. No, exit
        """
        let c = RemoteControl.classifyPane(kind: .repl, pane: pane)
        XCTAssertEqual(c.state, .needsTrust)
    }

    func testShellReadyAndStarting() {
        XCTAssertEqual(RemoteControl.classifyPane(kind: .shell, pane: "charliek@shed:/workspace$ ").state, .ready)
        XCTAssertEqual(RemoteControl.classifyPane(kind: .shell, pane: "   \n  \n").state, .starting)
    }
}

final class RCBootstrapTests: XCTestCase {
    func testSlugIsConfusableFreeAndCorrectLength() {
        let slug = RemoteControl.generateSlug()
        XCTAssertEqual(slug.count, 6)
        let forbidden = Set("ilo01")
        XCTAssertTrue(slug.allSatisfy { !forbidden.contains($0) })
        XCTAssertTrue(slug.allSatisfy { "abcdefghjkmnpqrstuvwxyz23456789".contains($0) })
    }

    func testInnerCommands() {
        XCTAssertEqual(RemoteControl.innerCommand(kind: .agent, displayName: "demo"),
                       "claude remote-control --name demo --spawn same-dir")
        XCTAssertEqual(RemoteControl.innerCommand(kind: .repl, displayName: "demo"),
                       "claude --name demo /rc")
        XCTAssertEqual(RemoteControl.innerCommand(kind: .shell, displayName: "demo"), "bash -l")
    }

    func testBootstrapArgvSHEDRC() {
        let meta = RcMetadata(
            id: "11111111-2222-3333-4444-555555555555",
            displayName: "my agent", kind: .agent, workdir: "/workspace",
            createdBy: "shed-desktop/0.0.8", createdAt: "2026-06-13T18:53:00Z",
            targetLabel: "shed:demo@mini3")
        let argv = RemoteControl.bootstrapArgv(slug: "abc234", meta: meta)
        XCTAssertEqual(argv[0...6], ["tmux", "new-session", "-d", "-s", "rc-abc234", "-c", "/workspace"])
        XCTAssertTrue(argv.contains("SHED_RC_V=1"))
        XCTAssertTrue(argv.contains("SHED_RC_ID=11111111-2222-3333-4444-555555555555"))
        // A multi-word display name is a single raw argv token (verbatim, no
        // tmux/backslash escaping) — sshArgv shell-quotes it as a whole.
        XCTAssertTrue(argv.contains("SHED_RC_DISPLAY_NAME=my agent"))
        XCTAssertTrue(argv.contains("SHED_RC_KIND=agent"))
        XCTAssertTrue(argv.contains("SHED_RC_WORKDIR=/workspace"))
        XCTAssertTrue(argv.contains("SHED_RC_CREATED_BY=shed-desktop/0.0.8"))
        XCTAssertTrue(argv.contains("SHED_RC_CREATED_AT=2026-06-13T18:53:00Z"))
        XCTAssertTrue(argv.contains("SHED_RC_TARGET=shed:demo@mini3"))
        XCTAssertFalse(argv.contains { $0.hasPrefix("SRA_") })
        XCTAssertEqual(argv.last, "claude remote-control --name 'my agent' --spawn same-dir")
    }

    func testBootstrapArgvOmitsTargetWhenNil() {
        let meta = RcMetadata(
            id: "id", displayName: "demo", kind: .repl, workdir: "/workspace",
            createdBy: "shed-desktop/0.0.8", createdAt: "2026-06-13T18:53:00Z")
        let argv = RemoteControl.bootstrapArgv(slug: "abc234", meta: meta)
        XCTAssertFalse(argv.contains { $0.hasPrefix("SHED_RC_TARGET=") })
        XCTAssertEqual(argv.last, "claude --name demo /rc")
    }

    func testCaptureArgv() {
        XCTAssertEqual(RemoteControl.captureArgv(slug: "abc234"),
                       ["tmux", "capture-pane", "-t", "rc-abc234", "-p", "-S", "-200"])
    }

}

// MARK: - SHED_RC_* metadata: version grammar, timestamp validation, helpers

final class RCMetadataTests: XCTestCase {
    func testIsManagedVersion() {
        for ok in ["1", "01", "2", "10", "999999999999999999999999999999"] {
            XCTAssertTrue(RemoteControl.isManagedVersion(ok), "\(ok) should be managed")
        }
        XCTAssertTrue(RemoteControl.isManagedVersion(" 1 "), "trimmed value is managed")
        for bad: String? in [nil, "", "0", "00", "+1", "1.0", "1e3", "0x1", "v1", "-1", "1 2", " "] {
            XCTAssertFalse(RemoteControl.isManagedVersion(bad), "\(bad ?? "nil") should be legacy")
        }
    }

    func testIsValidCreatedAt() {
        XCTAssertTrue(RemoteControl.isValidCreatedAt("2026-06-13T18:53:00Z"))
        XCTAssertTrue(RemoteControl.isValidCreatedAt("2026-06-13T18:53:00.884935839Z"))
        for bad in ["2026-06-13T18:53:00-05:00", "2026-06-13 18:53:00Z",
                    "2026-06-13T18:53:00", "not-a-date", "2026-06-13T18:53:00Z (UTC)"] {
            XCTAssertFalse(RemoteControl.isValidCreatedAt(bad), bad)
        }
    }

    func testNowISO8601PassesStrictValidation() {
        XCTAssertTrue(RemoteControl.isValidCreatedAt(DateFormatting.nowISO8601()))
    }

    func testKillAndDuplicateErrorClassification() {
        XCTAssertTrue(RemoteControl.isMissingSessionError("can't find session: rc-x"))
        XCTAssertTrue(RemoteControl.isMissingSessionError("no server running on /tmp/tmux-501/default"))
        XCTAssertTrue(RemoteControl.isMissingSessionError("no session: rc-x"))
        XCTAssertFalse(RemoteControl.isMissingSessionError("permission denied"))
        XCTAssertTrue(RemoteControl.isDuplicateSessionError("duplicate session: rc-x"))
        XCTAssertTrue(RemoteControl.isDuplicateSessionError("session rc-x already exists"))
    }

    func testListScriptShape() {
        let script = RemoteControl.listScript(markers: ListMarkers(nonce: "abc"))
        XCTAssertTrue(script.contains("tmux ls -F '#{session_name}'"))
        XCTAssertTrue(script.contains("grep '^rc-'"))
        XCTAssertTrue(script.contains("grep '^SHED_RC_'"))
        XCTAssertFalse(script.contains("SRA_"))
        XCTAssertFalse(script.contains("sed -n"))  // no per-key probes
        // Exactly one show-environment dump per session (not one call per key).
        XCTAssertEqual(script.components(separatedBy: "show-environment").count - 1, 1)
    }
}

// MARK: - SHED_RC_* list parsing: managed / legacy / forward-compat / robustness

final class RCParseTests: XCTestCase {
    /// Build one session block framed by `markers` (env lines, then pane).
    private func block(_ tmux: String, env: [String], pane: String, _ m: ListMarkers) -> String {
        var s = "\(m.session) \(tmux)\n\(m.env)\n"
        if !env.isEmpty { s += env.joined(separator: "\n") + "\n" }
        s += "\(m.pane)\n\(pane)"
        return s
    }

    private func parseOne(_ block: String, _ m: ListMarkers) -> RcSession {
        RemoteControl.parseListOutput(block, markers: m, serverName: "mini3", shed: "demo")[0]
    }

    private let managedEnv = [
        "SHED_RC_V=1",
        "SHED_RC_ID=11111111-2222-3333-4444-555555555555",
        "SHED_RC_DISPLAY_NAME=my agent",
        "SHED_RC_KIND=agent",
        "SHED_RC_WORKDIR=/work",
        "SHED_RC_CREATED_BY=shed-remote-agent/0.1.0",
        "SHED_RC_CREATED_AT=2026-06-13T18:53:00Z",
        "SHED_RC_TARGET=shed:demo@mini3",
    ]

    func testManagedRoundTrip() {
        let m = ListMarkers(nonce: "n1")
        let pane = "·✔︎· Connected · demo\nhttps://claude.ai/code?environment=env_01ABC"
        let s = parseOne(block("rc-abc234", env: managedEnv, pane: pane, m), m)
        XCTAssertTrue(s.managed)
        XCTAssertEqual(s.slug, "abc234")
        XCTAssertEqual(s.tmuxSession, "rc-abc234")
        XCTAssertEqual(s.host, "mini3")
        XCTAssertEqual(s.displayName, "my agent")
        XCTAssertEqual(s.kind, .agent)
        XCTAssertEqual(s.workdir, "/work")
        XCTAssertEqual(s.rcID, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(s.createdBy, "shed-remote-agent/0.1.0")
        XCTAssertEqual(s.createdAt, "2026-06-13T18:53:00Z")
        XCTAssertEqual(s.targetLabel, "shed:demo@mini3")
        XCTAssertEqual(s.state, .ready)
        XCTAssertEqual(s.url, "https://claude.ai/code?environment=env_01ABC")
    }

    func testLegacyUnmanagedIgnoresStrayValues() {
        let m = ListMarkers(nonce: "n2")
        // No SHED_RC_V → unmanaged; a stray SHED_RC_DISPLAY_NAME and any SRA_*
        // must be ignored, defaults applied (kind=agent, <shed>/<slug> name).
        let env = ["SHED_RC_DISPLAY_NAME=should-be-ignored", "SHED_RC_KIND=repl", "SRA_KIND=repl"]
        let s = parseOne(block("rc-leg001", env: env, pane: "·✔︎· Connected\nhttps://claude.ai/code?environment=env_LEG", m), m)
        XCTAssertFalse(s.managed)
        XCTAssertEqual(s.kind, .agent)
        XCTAssertEqual(s.displayName, "demo/leg001")
        XCTAssertEqual(s.workdir, RemoteControl.defaultWorkdir)
        XCTAssertNil(s.rcID)
        XCTAssertNil(s.createdBy)
        XCTAssertEqual(s.state, .ready)
    }

    func testForwardCompatHigherVersionStillManaged() {
        let m = ListMarkers(nonce: "n3")
        let env = [
            "SHED_RC_V=2", "SHED_RC_ID=id2", "SHED_RC_DISPLAY_NAME=future",
            "SHED_RC_KIND=shell", "SHED_RC_WORKDIR=/w", "SHED_RC_CREATED_BY=tool/9.9",
            "SHED_RC_CREATED_AT=2026-06-13T00:00:00Z", "SHED_RC_FUTURE_THING=whatever",
        ]
        let s = parseOne(block("rc-fut999", env: env, pane: "$ ", m), m)
        XCTAssertTrue(s.managed)            // V=2 retained, not dropped
        XCTAssertEqual(s.kind, .shell)
        XCTAssertEqual(s.displayName, "future")
    }

    func testInvalidCreatedAtStillManaged() {
        let m = ListMarkers(nonce: "n4")
        let env = ["SHED_RC_V=1", "SHED_RC_ID=x", "SHED_RC_DISPLAY_NAME=d", "SHED_RC_KIND=repl",
                   "SHED_RC_WORKDIR=/w", "SHED_RC_CREATED_BY=t/1", "SHED_RC_CREATED_AT=2026-06-13T00:00:00-05:00"]
        let s = parseOne(block("rc-x", env: env, pane: "Remote Control active https://claude.ai/code/session_01X", m), m)
        XCTAssertTrue(s.managed)            // offset timestamp fails strict grammar...
        XCTAssertNil(s.createdAt)           // ...so it's dropped, but the session stays managed
    }

    func testIgnoresUnsetMarkersAndNonEqualsLines() {
        let m = ListMarkers(nonce: "n5")
        // tmux `-KEY` unset markers (start with `-`) and lines without `=` must
        // not corrupt parsing.
        let env = ["-SHED_RC_OLD", "SHED_RC_NOEQUALS", "garbage", "SHED_RC_V=1",
                   "SHED_RC_ID=keep", "SHED_RC_DISPLAY_NAME=d", "SHED_RC_KIND=shell",
                   "SHED_RC_WORKDIR=/w", "SHED_RC_CREATED_BY=t/1", "SHED_RC_CREATED_AT=2026-01-01T00:00:00Z"]
        let s = parseOne(block("rc-u", env: env, pane: "$ ", m), m)
        XCTAssertTrue(s.managed)
        XCTAssertEqual(s.rcID, "keep")
    }

    func testNonceForgeryInPaneIsInert() {
        let m = ListMarkers(nonce: "realnonce")
        // Pane text containing a plausible-but-wrong marker AND the old static
        // `@@RC@@` separator must be treated as content, not a frame boundary.
        // (managedEnv is agent-kind, so the URL extracted is the agent shape.)
        let pane = "@@RC:deadbeef:S rc-evil\n@@RC@@SESSION rc-evil2\nout https://claude.ai/code?environment=env_01OK"
        let sessions = RemoteControl.parseListOutput(
            block("rc-good1", env: managedEnv, pane: pane, m), markers: m, serverName: "mini3", shed: "demo")
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].slug, "good1")
        XCTAssertEqual(sessions[0].url, "https://claude.ai/code?environment=env_01OK")
    }

    func testEnvValueEndingInMarkerSuffixNotMistakenForMarker() {
        let m = ListMarkers(nonce: "n6")
        // A display name whose value ends with the env-marker string must not be
        // read as the (whole-line) env marker.
        let env = ["SHED_RC_V=1", "SHED_RC_ID=i", "SHED_RC_DISPLAY_NAME=weird\(m.env)",
                   "SHED_RC_KIND=shell", "SHED_RC_WORKDIR=/w", "SHED_RC_CREATED_BY=t/1",
                   "SHED_RC_CREATED_AT=2026-01-01T00:00:00Z"]
        let s = parseOne(block("rc-w", env: env, pane: "$ ", m), m)
        XCTAssertTrue(s.managed)
        XCTAssertEqual(s.displayName, "weird\(m.env)")
    }

    func testTwoSessionsAcrossBlocks() {
        let m = ListMarkers(nonce: "n7")
        let out = block("rc-abc234", env: managedEnv, pane: "Connected https://claude.ai/code?environment=env_A", m)
            + "\n" + block("rc-mno567", env: [], pane: "·|· Reconnecting · retrying", m)
        let sessions = RemoteControl.parseListOutput(out, markers: m, serverName: "mini3", shed: "demo")
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.first { $0.slug == "abc234" }!.managed)
        let legacy = sessions.first { $0.slug == "mno567" }!
        XCTAssertFalse(legacy.managed)
        XCTAssertEqual(legacy.kind, .agent)
        XCTAssertEqual(legacy.state, .reconnecting)
    }
}

// MARK: - RcSession wire shape (rc_id vs Identifiable id, defensive decode)

final class RCWireTests: XCTestCase {
    func testRcIDEncodesUnderRcIdNotId() throws {
        let s = RcSession(
            host: "mini3", shed: "demo", slug: "abc234", tmuxSession: "rc-abc234",
            displayName: "d", workdir: "/w", kind: .agent, state: .ready, url: nil,
            rcID: "uuid-123", createdBy: "shed-desktop/0.0.8",
            createdAt: "2026-06-13T00:00:00Z", targetLabel: "shed:demo@mini3", managed: true)
        let data = try JSONEncoder().encode(s)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["rc_id"] as? String, "uuid-123")
        XCTAssertNil(json["id"])  // the computed Identifiable id is never encoded
        XCTAssertEqual(json["created_by"] as? String, "shed-desktop/0.0.8")
        XCTAssertEqual(json["managed"] as? Bool, true)

        let back = try JSONDecoder().decode(RcSession.self, from: data)
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.id, "mini3/demo/abc234")  // Identifiable stays composite
        XCTAssertEqual(back.rcID, "uuid-123")
    }

    func testDecodeDefaultsManagedFalseWhenAbsent() throws {
        let json = Data("""
        {"host":"h","shed":"d","slug":"s","tmux_session":"rc-s","display_name":"n","workdir":"/w","kind":"agent","state":"ready"}
        """.utf8)
        let s = try JSONDecoder().decode(RcSession.self, from: json)
        XCTAssertFalse(s.managed)
        XCTAssertNil(s.rcID)
        XCTAssertNil(s.createdBy)
    }
}
