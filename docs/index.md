# shed-desktop

A native macOS menu-bar application that ties the [shed](https://github.com/charliek/shed)
toolchain into one resident control surface: list and create sheds across hosts, launch
Claude remote-control agents, approve credential requests from the shed-extensions host
agent, and watch a live activity feed.

It is a coordinator — it runs no sheds and holds no credentials. It observes and drives
components that already exist on the developer's Mac and on shed hosts (see
[Architecture](reference/architecture.md) for the full picture):

- **shed lifecycle** — HTTP to one or more `shed-server` instances, discovered from
  `~/.shed/config.yaml`; live create-progress over SSE.
- **credentials / approvals** — a Unix-domain-socket channel to `shed-host-agent`
  (the headline feature; see [Credential approvals](reference/approvals.md)).
- **terminals + remote control** — SSH into a shed and drive `tmux`, launching the user's
  terminal app for interactive attach.

## Status

Shipping. The dashboard, lifecycle/create, RC agent launcher, the credential-approval gate,
the System (disk) pane, and Sparkle auto-update are all implemented; first release `v0.0.1`.

| Area | What | State |
|---|---|---|
| Dashboard + IPC spine | Read-only dashboard across hosts; the drivability socket + screenshots | ✅ |
| Lifecycle + create | start/stop/reset/delete, create with live SSE progress, terminal launch | ✅ |
| Agents | Remote-control launcher (ported RC classifier), Agents pane | ✅ |
| Approval gate | Multi-server SSH approval over UDS, policy engine, notifications, merged audit feed | ✅ |
| System | Per-host disk usage (`/api/system/df`) | ✅ |
| Packaging | Launch-at-login, preferences, DMG + Sparkle EdDSA auto-update | ✅ |

## Design principles

- **Native + small.** SwiftUI menu-bar app; launches instantly; no Dock icon by default.
- **Drivable + testable.** The app exposes a JSON IPC control socket and an in-process
  screenshot op, so every change is verified by a no-sleep functional harness — not by a
  human clicking. See [Test automation](development/test-automation.md).
- **Fail-closed security.** The app never holds secrets; a missing or unresponsive app
  results in credential denial, matching the host agent's unanswered-prompt behavior.
