# Credential approvals

The headline feature: `shed-host-agent` delegates SSH-signing approval decisions to
shed-desktop over a local Unix-domain socket, and streams an all-namespace audit feed
the app surfaces in **Activity**. The app holds no credentials — only request metadata
crosses the socket, and the agent stays the sole credential holder.

## Enabling it

In the host agent's `~/.config/shed/extensions.yaml`:

```yaml
ssh:
  approval:
    method: shed-desktop      # route SSH-sign approvals to the app
desktop:
  enabled: true               # serve the local UDS the app connects to
  socket_path: ~/Library/Application Support/shed/host-agent.sock
  timeout_ms: 25000           # fail-closed (deny) if the app doesn't answer in time
```

Restart the host agent, then launch shed-desktop. The **Approvals** pane header shows
`gate: shed-desktop` once connected; if the agent is down it shows
`host agent not connected`. The same state is observable over IPC as
`ui.state.host_agent_connected`.

It is **default-off**: with no `desktop:` block (or `enabled: false`) the agent behaves
exactly as before — no socket, no behavior change. AWS and Docker credentials are
**audit-only** (auto-vended, streamed to Activity); only `ssh-agent` is gated.

## Policy

Each request is decided by the [`PolicyEngine`](architecture.md), most-specific match first:

```
session grant  >  per-(server,shed) rule  >  per-namespace rule  >  default mode
```

- **Default mode** — Preferences → Approval policy: *Touch ID each time* (default),
  *Prompt*, *Auto-approve*, or *Auto-deny*.
- **Per-namespace overrides** — Preferences → Per-namespace overrides. Inherit the default
  or pin a mode per namespace.
- **Per-shed "always allow"** — the *Always allow for `<server>/<shed>`* button on an
  approval card persists a per-`(server, shed)` auto-approve rule (managed under
  Preferences → Per-shed overrides). Identical shed names on different servers don't
  collide — rules are keyed by `(server, shed)`, matching the agent's own isolation.
- **Session grants** — a 4-hour in-memory grant (not persisted).

When the gate prompts, an actionable **Approve / Deny** notification is posted so the
decision is reachable without the dashboard. With no matching rule the engine fails safe to
a Touch ID prompt.

## Fail-closed

The agent denies a request when **no app is connected**, when the app **doesn't answer
within `timeout_ms`**, or on a **disconnect mid-request** — the same outcome as an
unanswered local prompt today. The app likewise auto-denies a queued request when its
countdown expires.

## Verifying it live

Everything above is exercised hermetically by the pytest harness against a Python fake
agent (`make e2e-ci`). The one path a fake can't prove — the **real Go agent ↔ real Swift
app** wire protocol — is covered by `scripts/live-verify.sh`:

```bash
# Non-disruptive: builds a real host-agent, starts it on a private socket with
# no plugin-bus servers, launches the real app pointed at it, and asserts the
# hello/hello_ack handshake (ui.state.host_agent_connected). Touches no brew
# service and no shed server.
./scripts/live-verify.sh --handshake

# Full SSH-sign drive: stops the brew host-agent (restored on exit), watches
# every server, and waits for you to trigger a real sign inside a shed
# (ssh in, then a git op). Approves it via shedctl, asserts the response, then
# checks fail-closed (quit the app → the next sign is denied).
./scripts/live-verify.sh --full
```

The script builds the agent from `../shed-extensions` (override with
`SHED_EXTENSIONS_SRC`). It is not part of CI — it needs a real VM in the loop.
