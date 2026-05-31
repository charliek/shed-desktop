# First Run

Launch `ShedDesktop.app`. It runs as a menu-bar item (no Dock icon) and opens the
dashboard window on first launch.

## The dashboard

- **Sheds** — every shed across all configured hosts, grouped by host, with status, image
  variant, backend, resource sizing, and uptime. Updated by polling each `shed-server`.
- **Approvals**, **Agents**, **Activity** — placeholders until M2/M3 land.
- **Hosts** (sidebar footer) — each configured server with a reachability dot.

## The menu bar

The status item shows the running-shed count. Its dropdown lists running sheds and quick
actions (open dashboard, quit). The approval queue is added in M3.

## Configuration

The host list comes from `~/.shed/config.yaml`:

```yaml
servers:
    my-server:
        host: localhost
        http_port: 8080
        ssh_port: 2222
default_server: my-server
```

shed-desktop does not modify this file in v1 — manage hosts with the `shed` CLI.
