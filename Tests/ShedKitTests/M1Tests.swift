// M1 unit tests: the terminal command builder and the SSE parser.

import XCTest
@testable import ShedKit

final class TerminalLauncherTests: XCTestCase {
    func testSSHCommandWithoutSession() {
        let cmd = TerminalLauncher.sshCommand(shed: "stbot", host: "mini3", sshPort: 2222)
        XCTAssertEqual(cmd.argv, ["ssh", "-t", "stbot@mini3", "-p", "2222"])
        XCTAssertEqual(cmd.command, "ssh -t stbot@mini3 -p 2222")
    }

    func testSSHCommandWithSession() {
        let cmd = TerminalLauncher.sshCommand(shed: "stbot", host: "mini3", sshPort: 2222, session: "rc-demo")
        XCTAssertEqual(cmd.argv, ["ssh", "-t", "stbot@mini3", "-p", "2222", "tmux", "attach", "-t", "rc-demo"])
        XCTAssertEqual(cmd.command, "ssh -t stbot@mini3 -p 2222 tmux attach -t rc-demo")
    }

    func testShellQuoteEscapesSpacesAndQuotes() {
        XCTAssertEqual(TerminalLauncher.shellQuote("plain"), "plain")
        XCTAssertEqual(TerminalLauncher.shellQuote("a b"), "'a b'")
        XCTAssertEqual(TerminalLauncher.shellQuote("it's"), "'it'\\''s'")
    }
}

final class SSEParserTests: XCTestCase {
    func testParsesProgressThenComplete() {
        let lines = [
            "event: progress", "data: {\"message\":\"resolving\"}", "",
            "event: progress", "data: {\"message\":\"starting\"}", "",
            "event: complete", "data: {\"name\":\"folio\"}", "",
        ]
        let events = SSEParser.parse(lines: lines)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].event, "progress")
        XCTAssertEqual(events[0].data, "{\"message\":\"resolving\"}")
        XCTAssertEqual(events[2].event, "complete")
    }

    func testFlushesFinalRecordWithoutTrailingBlank() {
        var parser = SSEParser()
        XCTAssertNil(parser.push(line: "event: complete"))
        XCTAssertNil(parser.push(line: "data: {}"))
        // No trailing blank line — finish() must flush it.
        let ev = parser.finish()
        XCTAssertEqual(ev?.event, "complete")
        XCTAssertEqual(ev?.data, "{}")
    }

    func testIgnoresCommentAndStripsCR() {
        var parser = SSEParser()
        XCTAssertNil(parser.push(line: ": keep-alive"))
        XCTAssertNil(parser.push(line: "event: progress\r"))
        XCTAssertNil(parser.push(line: "data: hi\r"))
        let ev = parser.push(line: "")
        XCTAssertEqual(ev, SSEEvent(event: "progress", data: "hi"))
    }
}
