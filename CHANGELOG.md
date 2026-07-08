# Changelog

Notable changes to shed-desktop. Older releases (v0.0.1–v0.0.5) predate this file.

## v0.0.14 — 2026-07-08

### Changed
- **Update feed moved to the shed monorepo.** `SUFeedURL` now points at
  `https://charliek.github.io/shed/appcast.xml`. This is the final release from the
  standalone `charliek/shed-desktop` repo — development has moved into
  [`charliek/shed`](https://github.com/charliek/shed) (under `desktop/` + `crates/`),
  and all later releases ship from there on shed's version line. Existing installs
  take this one update through the old feed and are migrated to the new feed with no
  reinstall. The old GitHub Pages feed keeps serving as a fallback.

## v0.0.13 — 2026-06-28

### Changed
- **Developer ID signing + notarization** (#25) — release DMGs are now signed with a
  Developer ID Application certificate and notarized by Apple, so a downloaded build
  opens with a normal double-click (the Gatekeeper-bypass `FIRST-LAUNCH.txt` is omitted
  on notarized builds). Existing ad-hoc installs auto-update across the transition —
  Sparkle's EdDSA key is unchanged. Signing activates only when the full set of Apple
  secrets is present (the all-or-nothing `CAN_NOTARIZE` gate), falling back to an
  ad-hoc build otherwise.

## v0.0.12 — 2026-06-26

### Added
- **Optional initial prompt/command when launching a session** (#24) — the New
  session sheet accepts an initial prompt (for `claude-rc`) or command (for `shell`),
  delivered once the session is ready.
- **Egress → Profiles view** (#23) — a read-only pane showing each shed's resolved
  egress profiles and rules.

### Changed
- **Egress pane discoverability** (#22) — the egress pane is surfaced in the UI and in
  the `shedctl` + smoke tooling so it's reachable rather than hidden.

## v0.0.11 — 2026-06-19

### Changed
- **Remote-control sessions now run through the shared `shed-ext-rc` guest binary**
  (#21) instead of shed-desktop building the SSH+tmux commands itself — it invokes
  `shed-ext-rc create --wait` / `list` / `kill` over SSH and decodes the neutral
  JSON DTO, so sessions it creates are byte-compatible with (and viewable in)
  shed-remote-agent. Requires a shed image that ships `shed-ext-rc`
  (shed-extensions v0.4.6+); an older shed reports it as not installed.
- **RC kinds renamed to RC Session Convention v2** (#21): `agent`→`claude-broker`,
  `repl`→`claude-rc` (now the default), `shell` unchanged; the session display name
  is now `<shed>/<slug>`. `SHED_RC_V` is bumped to 2 with no v1 aliasing — a
  pre-v2 session renders as legacy/unmanaged.

## v0.0.10 — 2026-06-18

### Added
- **Diagnostic log** (#20) — a rotated, token-redacted `shed-desktop.log` under
  `~/Library/Logs/ShedDesktop/`, recording config resolution (each server's
  resolved endpoint + pin/token state) and per-host probe results, surfaced via a
  **Diagnostics** action in the Activity view. The breadcrumbs that turn a "why is
  this host unreachable?" investigation into a one-line answer.
- **Per-host unreachable reason** (#20) — an unreachable host now shows *why* on
  hover in the sidebar (e.g. "connection refused (http://…:8080)") instead of a
  bare gray dot; tokens are scrubbed before the reason reaches the UI.
- **Reconnect + automatic config reload** (#20) — a manual **Reconnect** action
  reloads `~/.shed/config.yaml` and rebuilds clients on demand, and an FSEvents
  watch on `~/.shed` does it automatically — so a server changing endpoint (e.g.
  open→secure) is picked up without relaunching the app.

## v0.0.9 — 2026-06-15

### Added
- **Host-agent-minted control tokens for secure servers** (#19) — the desktop
  now obtains its API **control** token from the local shed-host-agent over the
  approval socket (`token.get`) instead of a static config token, with a cached,
  single-flight provider that refreshes near expiry and re-mints on a 401. When
  the host agent is unavailable the app degrades to a graceful offline state
  rather than hanging. Companion to the shed v0.7.1 secure-by-default auth.
- **View-only Egress activity pane** (#203) — a read-only feed of a shed's
  outbound-network decisions, streamed from the host agent's egress-audit
  subscriber. Pairs with shed's opt-in egress control.
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
