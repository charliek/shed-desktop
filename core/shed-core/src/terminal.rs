//! Pure terminal-command building: the ssh argv that drops a user into a shed
//! (optionally attaching a tmux session), shared by every client's
//! `terminal.preview`. No spawning — how a terminal app is opened (the preset
//! openers) is platform-specific and lives in the clients.
//!
//! A shed is reached as `<shed>@<host> -p <sshPort>` (the shed name is the SSH
//! username; shed-server's SSH daemon routes by it), pinning the server's host
//! key in the shed CLI's `known_hosts` with strict checking. Mirrors the Swift
//! `TerminalLauncher.sshCommand` + `ShedSSH.hostKeyOptions`.

use serde::Serialize;

/// The ssh command as an argv array + a shell-quoted single line (for display
/// and for handing to a terminal app).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TerminalCommand {
    pub argv: Vec<String>,
    pub command: String,
}

/// Build the ssh command to reach `shed` on `host:ssh_port`, pinning the server's
/// host key in `known_hosts` with `StrictHostKeyChecking=yes` (the shed CLI's
/// posture, so a changed/unknown key is rejected). A non-empty `session` attaches
/// that tmux session. Pure — the caller resolves `host`/`ssh_port` from config and
/// `known_hosts` from the environment.
pub fn ssh_command(
    shed: &str,
    host: &str,
    ssh_port: u16,
    known_hosts: &str,
    session: Option<&str>,
) -> TerminalCommand {
    let mut argv = vec![
        "ssh".to_string(),
        "-t".to_string(),
        "-o".to_string(),
        "StrictHostKeyChecking=yes".to_string(),
        "-o".to_string(),
        format!("UserKnownHostsFile={known_hosts}"),
        format!("{shed}@{host}"),
        "-p".to_string(),
        ssh_port.to_string(),
    ];
    if let Some(session) = session.filter(|s| !s.is_empty()) {
        argv.extend(["tmux", "attach", "-t", session].map(String::from));
    }
    let command = argv
        .iter()
        .map(|a| shell_quote(a))
        .collect::<Vec<_>>()
        .join(" ");
    TerminalCommand { argv, command }
}

/// POSIX single-quote a shell argument (only when it contains anything outside a
/// conservative safe set), so the `command` line re-parses to the same argv.
fn shell_quote(s: &str) -> String {
    let safe = !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"@%-_=+:,./".contains(&b));
    if safe {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', r"'\''"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssh_command_pins_host_key_and_targets_the_shed() {
        let c = ssh_command("web", "10.0.0.5", 2222, "/home/u/.shed/known_hosts", None);
        assert_eq!(
            c.argv,
            [
                "ssh", "-t",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "UserKnownHostsFile=/home/u/.shed/known_hosts",
                "web@10.0.0.5", "-p", "2222",
            ]
        );
        // The shell line round-trips (no quoting needed for these safe args).
        assert_eq!(
            c.command,
            "ssh -t -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/home/u/.shed/known_hosts web@10.0.0.5 -p 2222"
        );
    }

    #[test]
    fn ssh_command_attaches_tmux_when_session_given() {
        let c = ssh_command("web", "h", 22, "/k", Some("main"));
        assert_eq!(&c.argv[c.argv.len() - 4..], ["tmux", "attach", "-t", "main"]);
        // An empty session is treated as none.
        let c0 = ssh_command("web", "h", 22, "/k", Some(""));
        assert!(!c0.argv.contains(&"tmux".to_string()));
    }

    #[test]
    fn shell_quote_escapes_unsafe_args() {
        // A known_hosts path with a space must be quoted so the line re-parses.
        let c = ssh_command("web", "h", 22, "/home/a b/.shed/known_hosts", None);
        assert!(c.command.contains("'UserKnownHostsFile=/home/a b/.shed/known_hosts'"));
        assert_eq!(shell_quote("it's"), r"'it'\''s'");
    }
}
