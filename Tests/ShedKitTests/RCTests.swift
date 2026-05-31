// RC classifier tests — ported from shed-remote-agent's rc.test.ts so the
// Swift port stays behavior-compatible with upstream.

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

    func testBootstrapArgvShape() {
        let argv = RemoteControl.bootstrapArgv(slug: "abc234", kind: .repl, displayName: "demo", workdir: "/workspace")
        XCTAssertEqual(argv[0...6], ["tmux", "new-session", "-d", "-s", "rc-abc234", "-c", "/workspace"])
        XCTAssertTrue(argv.contains("SRA_KIND=repl"))
        XCTAssertTrue(argv.contains("SRA_WORKDIR=/workspace"))
        XCTAssertEqual(argv.last, "claude --name demo /rc")
    }

    func testCaptureArgv() {
        XCTAssertEqual(RemoteControl.captureArgv(slug: "abc234"),
                       ["tmux", "capture-pane", "-t", "rc-abc234", "-p", "-S", "-200"])
    }

    func testParseSessionList() {
        let sep = "@@RC@@"
        let output = """
        \(sep)SESSION rc-abc234
        \(sep)NAME demo
        \(sep)KIND repl
        \(sep)WORKDIR /workspace
        \(sep)PANE
          /remote-control is active · Code at https://claude.ai/code/session_01XYZ
          Remote Control active
        \(sep)SESSION rc-mno567
        \(sep)NAME fix
        \(sep)KIND agent
        \(sep)WORKDIR /workspace
        \(sep)PANE
        ·|· Reconnecting · retrying
        """
        let sessions = RemoteControl.parseSessionList(output, sep: sep, serverName: "mini3", shed: "hello-world")
        XCTAssertEqual(sessions.count, 2)
        let repl = sessions.first { $0.slug == "abc234" }!
        XCTAssertEqual(repl.displayName, "demo")
        XCTAssertEqual(repl.kind, .repl)
        XCTAssertEqual(repl.state, .ready)
        XCTAssertEqual(repl.url, "https://claude.ai/code/session_01XYZ")
        XCTAssertEqual(repl.tmuxSession, "rc-abc234")
        XCTAssertEqual(repl.host, "mini3")
        let agent = sessions.first { $0.slug == "mno567" }!
        XCTAssertEqual(agent.kind, .agent)
        XCTAssertEqual(agent.state, .reconnecting)
    }
}
