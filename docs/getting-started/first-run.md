# First Run

Launch `ShedDesktop.app`. It runs as a menu-bar item (no Dock icon) and opens the
dashboard window on first launch.

## The dashboard

The sidebar selects a pane:

- **Sheds** — every shed across all configured hosts, grouped by host, with status, image
  variant, backend, resource sizing, and uptime; per-shed start/stop/reset/delete + open
  terminal, and a create-shed sheet with live progress. Updated by polling each `shed-server`.
- **Approvals** — pending credential-approval requests from `shed-host-agent`, with
  Approve / Deny (optionally Touch ID) and "always allow". Empty unless the host agent is
  configured to delegate — see [Credential approvals](../reference/approvals.md).
- **Agents** — remote-control (Claude) sessions per shed, with state pills and "Open in
  Claude" for ready ones.
- **Activity** — the merged audit feed (host-agent credentials + the app's decisions), with
  a "Reveal log" button.
- **System** — per-host disk usage (images / sheds / snapshots / orphans).
- **Hosts** (sidebar footer) — each configured server with a reachability dot.

## The menu bar

The status item shows the running-shed count and a pending-approval badge. Its dropdown
lists pending approvals (inline Approve/Deny) and running sheds, plus **Open dashboard**,
**Preferences…**, **Check for Updates…** (Sparkle), and **Quit**.

## Preferences

**Preferences…** (in the menu) covers launch-at-login, the terminal command template, and
the approval policy (default mode + per-namespace / per-shed overrides). The full set of
settings — and the environment-variable overrides — is in
[Configuration](../reference/configuration.md).

## Configuration

The host list comes from `~/.shed/config.yaml` (read-only — manage hosts with the `shed`
CLI):

```yaml
servers:
    my-server:
        host: localhost
        http_port: 8080
        ssh_port: 2222
default_server: my-server
```
