# shed-desktop

A native macOS menu-bar application that ties the [shed](https://github.com/charliek/shed)
toolchain into one resident control surface: list and create sheds across hosts, launch
Claude remote-control agents, approve credential requests from the shed-extensions host
agent, and watch a live activity feed.

It is a coordinator — it runs no sheds and holds no credentials. It observes and drives
components that already exist on the developer's Mac and on shed hosts:

- **shed lifecycle + events** — HTTP to one or more `shed-server` instances, discovered
  from `~/.shed/config.yaml`.
- **credentials / approvals** — a Unix-domain-socket channel to `shed-host-agent`
  (the headline feature; see the [design spec](spec.md)).
- **terminals + remote control** — SSH into a shed and drive `tmux`, launching the user's
  terminal app for interactive attach.

## Status

Under active development. Milestones:

| Milestone | Scope | State |
|-----------|-------|-------|
| M0 | Read-only dashboard across hosts; the IPC drivability spine | building |
| M1 | Lifecycle (start/stop/reset/delete), create with live progress, terminal launch | planned |
| M2 | Remote-control agent launcher (ported RC classifier) | planned |
| M3 | The shed-desktop credential approval gate (cross-repo) | planned |
| M4 | Notifications, launch-at-login, packaging + signing | planned |

## Design principles

- **Native + small.** SwiftUI menu-bar app; launches instantly; no Dock icon by default.
- **Drivable + testable.** The app exposes a JSON IPC control socket and an in-process
  screenshot op, so every change is verified by a no-sleep functional harness — not by a
  human clicking. See [Test automation](development/test-automation.md).
- **Fail-closed security.** The app never holds secrets; a missing or unresponsive app
  results in credential denial, matching the host agent's unanswered-prompt behavior.
