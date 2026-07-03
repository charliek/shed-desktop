# Roadmap & ideas

Directions we may take, not a schedule. Today's app is a complete macOS control surface —
dashboard + lifecycle, the remote-control launcher, the SSH-credential approval gate, the
System (disk) pane, and notarized Sparkle auto-update. The **active** thrust is the shared
Rust core and the multi-client story it unlocks; the rest are recorded so the gaps are
explicit. Smaller quality-of-life items and deferred follow-ups are collected in
[Known enhancements](enhancements.md).

## Shared Rust core & multi-client (active)

The shed-server protocol layer is being extracted into a shared **Rust core** (`shed-core`)
so the same logic backs every client instead of being re-implemented per language
(Swift/Dart/TypeScript/Go). The arc is sequenced so each step de-risks the next:

- **Phase 1 — the core (shipped).** `shed-core` — a *pure* Rust crate: HTTP/SSE clients,
  the defensive wire decoders, the control-token FSM, and leaf-cert TLS pinning — plus a
  thin `shed-core-ffi` UniFFI wrapper consumed by the Swift app behind
  `SHED_DESKTOP_RUST_CORE` (off by default), with dual-backend e2e parity. See
  `plans/phase-1-rust-core.md` and [Rust core](reference/rust-core.md).
- **Phase 2 — prove it across platforms (shipped).** Made the Rust core the **default**
  on macOS, got `shed-core` building/testing on **Linux**, and stood up a **GTK/Linux app**
  on the same crate — mirroring `../roost`'s rust+gtk toolchain (gtk4-rs + libadwaita, a
  pytest-over-IPC drivability harness under headless Xvfb, an nfpm `.deb`). The GTK app
  links `shed-core` directly (no UniFFI — that's Swift-only). `shed-host-agent` stays a
  **separate** process on both platforms; it already runs on Linux, so nothing is bundled or
  supervised. See `plans/phase-2-rust-clients.md`.
- **Phase 3 — close the backlog (shipped).** Before the next direction, the enhancements
  backlog Phase 2 accrued is closed out: the `shed-desktop` `.deb` now **ships** via
  `charliek/apt-charliek` (end users `apt install shed-desktop`), with a headless `shedctl`
  bundled alongside; the macOS and Linux functional suites are unified into one
  `tools/shedtest --target mac|gtk` harness; GTK gained single-instance handoff (an
  `app.activate` IPC op) and parallel multi-host fetches; and an adversarial coverage pass
  hardened all three surfaces. See `plans/phase-3-enhancements.md`.
- **Next — a real cross-platform client (Tauri).** A Tauri desktop client on the same core, built to
  **full Mac↔Linux feature parity** (except egress). Tauri's backend *is* Rust, so `shed-core` is a
  direct dependency and one web frontend covers desktop now (mobile later); it runs on macOS (WKWebView,
  a UI-comparison loop vs the Swift app) and Linux (WebKitGTK, the shipped target). The GTK MVP proved the
  architecture; this makes Linux a *real product* and, if it lands, **replaces the GTK client** as the
  shipped Linux app. Three panel-reviewed phases in one PR — foundation → the approval spine → agents/
  prefs/tray + release. See `plans/tauri-desktop.md`. (A **Flutter** mobile spike is superseded unless
  Tauri's mobile target disappoints.)
- **Then — a mobile client (Android-first).** A spike on the same core — Tauri if its Android target
  proves out, else Flutter — remote-only config + a phone-shaped UI; iOS is post-roadmap.
- **Later — consolidation.** Once the clients prove the foundation: move `shed-core` into the
  `shed` repo, pull `shed-extensions` in alongside it, and **replace `shed-host-agent` with
  a Rust implementation** on the shared core — retiring the separately-distributed broker
  binary and shrinking the install to one thing. This is the large, invisible-to-users
  refactor, deliberately sequenced **last** — and the broker rewrite, being security-critical
  (it holds the real keys; the app deliberately holds none today), lands on the most-proven
  foundation.

Why this order: a second and third consumer of `shed-core` validate its API *before* it's
entangled with `shed`'s build; user-facing multi-platform value ships before the plumbing
refactor; and the riskiest piece — the credential broker — comes last rather than first. The
alternative (absorbing the broker up front) was scoped and rejected for now: it's ~8,900 LOC
of key-holding Go, needs a Rust `shed/sdk` that doesn't exist yet, and would reverse the
"app holds no credentials" invariant. The Phase 2 plan records that analysis.

## Credentials

- **Gate AWS + Docker, not just SSH.** The host agent already streams an all-namespace audit
  feed, and the approval protocol is namespace-agnostic; only `ssh-agent` is *gated* today.
  Extending the gate to `aws-credentials` and `docker-credentials` is mostly wiring on the
  agent side — gated behind a clean policy story so frequent STS refreshes don't become
  prompt fatigue. See [Credential approvals](reference/approvals.md).
- **Auto-approve with constraints** — e.g. docker limited to a registry allowlist.
- **Approvals on the Linux client.** The Mac approval spine (PolicyEngine, AuditStore, the host-agent
  protocol codec, the domain models) is ~70% pure, key-free logic; porting it into the shared Rust core
  (`shed-app`) lets the **Tauri** Linux client show approvals too — with a backend-mediated native/PAM
  gate on Linux (biometrics stay macOS-only). This is **Phase B** of the Tauri client and gets its own
  security-reviewed plan; the host-agent client + control-token minting land with it. See
  `plans/tauri-desktop.md`.

## Broader control surface

The shed-server HTTP API exposes more than the app surfaces today. Natural additions, each
independently useful:

- A **global sessions** view (`/api/sessions` + the RC list, merged).
- **Snapshot** management (`/api/snapshots`).
- **Image** management (`/api/images`).
- **System prune** (`/api/system/prune`) alongside the existing disk-usage view.
- **Port-forwarding** UI on top of `/api/sheds/{name}/connect/{port}`.

## Distribution

- **DMG (macOS) + `.deb` (Linux).** The macOS app ships a Developer-ID-signed, notarized DMG
  with an EdDSA-signed Sparkle appcast. The GTK/Linux client **ships** as the `shed-desktop`
  nfpm `.deb` (built per-arch — amd64 + arm64 — on tag, with a headless `shedctl` bundled)
  via `charliek/apt-charliek`, so end users `apt install shed-desktop`. One `git tag vX.Y.Z`
  cuts both — each platform a thin native shell over the one Rust core. See `RELEASING.md`. The shipped
  Linux `.deb` will **flip from the GTK client to the Tauri client** once its Phase A ships + a
  release-candidate pass is green — a gated packaging transition (the `.deb` gains a WebKitGTK runtime
  dep; `plans/tauri-desktop.md` Phase C).

## Larger bets

- **Embedded terminal / in-app console** — today the app delegates to the user's terminal
  app; an in-app console (xterm.js in a `WKWebView`, or SwiftTerm) is a revisit only if that
  proves insufficient.
- **In-app host management** — writing `~/.shed/config.yaml` instead of read-only reflection.

Have an idea or a need? Open an issue.
