# Changelog

Notable changes to shed-desktop. Older releases (v0.0.1–v0.0.5) predate this file.

## Unreleased

### Added
- **Agent console button** — every Agents-pane row now has an **Open console**
  button that opens your configured terminal attached to the session's tmux
  (`ssh -t <shed>@<host> tmux attach -t rc-<slug>`), mirroring the Sheds pane.
  It's also the way to act on a `needs-trust` / `needs-auth` session (attach,
  trust the folder or `claude auth login`).

### Changed
- **Adopted the cross-tool RC Session Convention v1 (`SHED_RC_*`)** (#16) —
  remote-control tmux sessions now carry tool-neutral, versioned metadata
  (`SHED_RC_V/ID/DISPLAY_NAME/KIND/WORKDIR/CREATED_BY/CREATED_AT`, optional
  `SHED_RC_TARGET`) instead of the app-named `SRA_*` prefix, so shed-desktop,
  `shed-remote-agent`, the `shed` CLI, and future clients can discover and pick
  up each other's sessions. The Agents pane surfaces provenance ("made by … ·
  age"), labels legacy/unmanaged sessions and confirms before killing them, and
  forward-compatibly never drops a higher-version session. See
  [RC sessions](docs/reference/rc-sessions.md). **Clean break:** `SRA_*` is no
  longer written or read; recreate existing sessions to restore their metadata.
- Listing now reads one `tmux show-environment` dump per session (not one call
  per key) and pipes the batched list script to a remote `bash` over stdin (not
  `bash -c`), fixing tmux "not a terminal" failures on some shed images. Kill is
  idempotent (a missing session counts as success). The shed-side follow-up to
  surface this metadata over HTTP is tracked in
  [charliek/shed#199](https://github.com/charliek/shed/issues/199).

## v0.0.8 — 2026-06-13

### Added
- **SSH host-key pinning + native TLS certificate pinning** (#15) — desktop
  support for the shed v0.7.0 server hardening. Both terminal-launch paths use
  `StrictHostKeyChecking=yes` against `~/.shed/known_hosts`, and the client pins
  shed-server's self-signed TLS cert by SHA-256 fingerprint (fail-closed on a
  mismatch, on a non-https URL, and on plaintext redirects). `ShedConfig` reads
  `api_url`, `tls_cert_fingerprint`, and `control_token`; the client sends the
  bearer token and pins TLS when a server is configured for it. Default-off: a
  plain-http server with no pin or token behaves exactly as before.

## v0.0.7 — 2026-06-12

### Added
- **Terminal preset dropdown** (#11, #13, #14) — choose how shed opens a session
  terminal, with a per-terminal opener. Ships the verified macOS set: iTerm2
  (new tab, verified end-to-end) and Ghostty (opener corrected so it runs the
  shed command); Warp opens a new window. The WezTerm and Kitty presets were
  dropped as unverifiable on macOS.
- **Failure reason in the activity feed** — a failed or denied credential event
  now shows the host-agent's machine code (e.g. `REGISTRY_NOT_ALLOWED`,
  `APPROVAL_DENIED`) and a short reason on a second line, instead of burying the
  detail in the op line. Successful and anonymous rows are unchanged, and events
  from older host-agents (no `code`/`reason`) render exactly as before. Pairs
  with the shed-extensions audit `code`/`reason` enrichment.

## v0.0.6 — 2026-06-07

A full dashboard theme overhaul, redesigned modal sheets, and an app icon.

### Added
- **"Linen" theme** with a slate-blue accent (light + dark), built on
  appearance-aware color tokens (canvas/surface/border, warm text, accent,
  status/intent colors). Cards gain a surface fill + shadow; backend/namespace
  pills get semantic hues (vz = blue, firecracker = amber, ssh-agent = violet);
  shed action buttons are intent-tinted.
- **New shed** and **Launch agent** rebuilt as centered modal cards over a
  dimmed backdrop (shared sheet components), with CPU/Memory steppers and a
  green Launch CTA. New `ui.show_launch` IPC op (+ `shedctl ui show-launch`) so
  the launch modal is agent-drivable like create.
- **App icon** for the Dock/Finder, generated from the menu-bar glyph
  (`packaging/icon/regenerate.sh`).
- A testable `NSColor(hex:)` sRGB decoder in ShedKit (unit-tested).

### Changed
- The **menu-bar dropdown** is now an opaque, arrow-less panel that sizes to its
  content, with a system-accent hover highlight on its actions (replacing the
  translucent `NSPopover`).
- **Dashboard layout**: the header moved into the content pane with a
  full-height sidebar and larger pane titles; the main window keeps its standard
  titlebar.
