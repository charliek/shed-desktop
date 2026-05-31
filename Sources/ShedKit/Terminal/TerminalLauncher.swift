// TerminalLauncher.swift
//
// Builds the SSH command that drops the user into a shed (and optionally
// attaches a tmux session), and launches it in the user's terminal. The
// command building is pure so it's unit-testable and so `terminal.preview`
// can show exactly what would run without spawning anything.
//
// A shed is reached as `<shed>@<host> -p <sshPort>` — the shed name is the
// SSH username (shed-server's SSH daemon routes by it).

import Foundation

public struct TerminalCommand: Codable, Sendable, Equatable {
    /// The ssh command as an argv array.
    public let argv: [String]
    /// The ssh command as a shell-quoted single line (for display + for
    /// handing to a terminal app).
    public let command: String

    public init(argv: [String], command: String) {
        self.argv = argv
        self.command = command
    }
}

public enum TerminalLauncher {
    /// Build the ssh command to reach `shed` on `host`. When `session` is
    /// given, attach that tmux session.
    public static func sshCommand(shed: String, host: String, sshPort: Int, session: String? = nil) -> TerminalCommand {
        var argv = ["ssh", "-t", "\(shed)@\(host)", "-p", String(sshPort)]
        if let session, !session.isEmpty {
            argv += ["tmux", "attach", "-t", session]
        }
        return TerminalCommand(argv: argv, command: argv.map(shellQuote).joined(separator: " "))
    }

    /// Launch a command in the user's terminal. With no `template`, opens
    /// Terminal.app via AppleScript. A `template` is a shell command with a
    /// `{cmd}` placeholder, e.g. `ghostty -e {cmd}` — most flexible.
    public static func launchInTerminal(_ cmd: TerminalCommand, template: String? = nil) throws {
        if let template, !template.isEmpty {
            let expanded = template.replacingOccurrences(of: "{cmd}", with: cmd.command)
            try run("/bin/sh", ["-c", expanded])
        } else {
            let script = """
            tell application "Terminal"
                activate
                do script "\(appleScriptEscape(cmd.command))"
            end tell
            """
            try run("/usr/bin/osascript", ["-e", script])
        }
    }

    /// Single-quote a shell argument (delegates to the shared `shellQuote`).
    public static func shellQuote(_ s: String) -> String { ShedKit.shellQuote(s) }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ launchPath: String, _ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        try proc.run()
    }
}
