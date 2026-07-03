# Tauri desktop — a real Linux client toward Mac parity

Status: **panel-reviewed (Codex + Kimi K2.6 + CodeRabbit), 2026-07-03 — restructured into THREE phases
per unanimous feedback.** One roadmap; each phase is its own implementation effort (Phase B gets its
own security-focused plan + panel when we reach it). Premise validated by the `spike/tauri` scaffold.

**Decisions locked (2026-07-03):** branch = `tauri-desktop` **stacked on `feat/rust-core`** (rebase onto
`main` after PR #26 merges); frontend = **React + Vite + Tailwind + shadcn/ui** (themed to the linen
mockup); drivability = `dashboard.dump` primary + best-effort `app.screenshot`. The detailed **Phase A**
implementation plan (panel'd on its own) is [`tauri-phase-a.md`](tauri-phase-a.md).

## Why

The GTK client (Phase 2) proved the shared-Rust-core *architecture* but ships a read-only dashboard.
The maintainer wants **full Mac↔Linux feature parity (except egress)** with **minimal UI duplication** —
which the 3×-native-stacks path fights. **Tauri** is the highest-leverage bet: its backend *is* Rust, so
`shed-core` is a **direct dependency** and one web frontend covers Linux desktop (Android a later spike,
iOS post-roadmap). If it lands, Tauri becomes the shipped Linux client and the GTK MVP is retired.

## Premise — spike verdict: GO (desktop)

The `spike/tauri` scaffold (isolated to `tauri/`, on `spike/tauri`) ran **live against `localmac-dev`**
(HTTPS + pinned cert + control token): list → start → create (6 streamed SSE events → complete) →
delete/stop, state restored. Integration is **near-zero friction** (`shed-core` a plain path dep; the
`shed-gtk` `Backend` ported near-verbatim; commands are thin `async` shims). **The reusable seam:**
`shed-core`'s create is built on the `CreateSink` trait that already bridges Swift + GTK; for Tauri you
implement it and `app.emit("create-progress")` — **one trait bridges Swift, GTK, and Tauri**.
`withGlobalTauri:true` → the mockup's vanilla HTML/JS uses `invoke`/`listen` with zero bundler.

**But the spike only proved the *easy* half.** The panel flagged that the real work is porting the
Swift app-layer (poller/df/rollup, the approval spine, RC, token-minting) into platform-abstracted Rust,
and that several "quick wins" hide platform-specific code. Corrections folded below.

## Scope reality — three phases, not one

Reproducing the whole Mac app (37 IPC ops, five panes, the approval spine, RC, prefs, tray) on a new
stack — *plus* extracting+expanding a shared crate, porting security-critical Rust, a new harness leg,
and Linux packaging on a new WebView dependency — is **Phase 1 + Phase 2 combined**. Split at the
natural seams:

- **Phase A — A real Linux client** (foundation): shell + drivability + `shed-app` extraction +
  Sheds/System/Create/Terminal, hermetic. Shippable on its own.
- **Phase B — The approval spine, on Rust** (security-critical; its own plan + threat model + panel):
  the host-agent client + token minting + PolicyEngine + audit + the biometric gate + Approvals/Activity.
- **Phase C — Agents, prefs, tray, release**: RC agents, preferences, the tray, packaging transition,
  look-refinement, and the gated GTK retirement.

## Architecture (folded)

- **New `core/shed-app` crate** (gtk-free **and** tauri-free) — the app-logic layer: the `Backend`
  orchestration (config load + reload, per-host clients, the 5s poller, df/images, the reachability +
  "N unreachable" error rollup — **all of which are Swift-only today and must be *added*, not just
  moved**), plus (Phase B) the approval coordinator + host-agent runtime + audit writer + RC + terminal
  command-building. Depends on `shed-core`; **`shed-core` stays the pure protocol crate** (only the pure
  approval bits — `PolicyEngine`, models, the `HostAgentProtocol` codec, the audit *schema* — may land
  there; the stateful coordinator / `HostAgentClient` / `AuditStore` *writer* live in `shed-app`).
- **Platform-seam traits** (so `shed-app` stays UI-free, reused by GTK + Tauri + later Swift-via-FFI):
  `AuthGate` (returns a rich enum, not `bool`), `Notifier`, `Opener`/`TerminalSpawn`, `Clock`, `Paths`,
  and an `EventSink`. The webview never sees credentials — the gate is backend/native-mediated.
- **Drivability:** a newline-JSON IPC socket (reuse `shed-gtk/ipc.rs`) → a 3rd `tools/shedtest --target
  tauri`. **Resolved (T0):** `dashboard.dump` is the *required* drivability primitive for `--target tauri`
  (structured state — what the pytest suite asserts on); `app.screenshot` is *best-effort* — webview
  content-capture for pane assertions + an external tool (`grim` on Wayland / `scrot` on X11 /
  `screencapture` on Mac) for full-window; `tauri-driver` deferred. Tauri has *no* in-process
  native-window capture on Linux (unlike Mac's `CGWindowListCreateImage` / GTK's `GskRenderer`). Document
  the `identify` contract (`platform:"tauri"`, `core`/`test_mode`/`mock_base_url`) + which
  `test_shared.py` assertions the target must pass (that green suite *is* the T0/T1 bar).
- **Single-instance** via the Tauri `single-instance` plugin (mirrors `shed-gtk`'s flock + `app.activate`).
- **Runs on macOS (WKWebView) *and* Linux (WebKitGTK)** — like the GTK client: the **Mac build is the
  dev / UI-comparison loop** (run it side-by-side with the SwiftUI app to check parity feature-for-
  feature), **Linux is the shipped target** (validated in the shed). One frontend, two WebViews — the
  render-parity variable (H4/H5) that the WebKitGTK gate in A0b exists to catch.

## Feature → backend map

| Pane | HTTP methods in `shed-core`? | The gap (Swift-only orchestration to port into `shed-app`) |
|---|---|---|
| **Sheds** / **Create** / **System** (df) / **images** | ✓ | the 5s poller, reachability + "N unreachable" rollup, config-reload, image preload, create retention/cancel — all Swift `AppModel`; **plus per-server CONTROL-token minting** (Phase B) |
| **Terminal** | argv build is pure | *spawning* is platform-specific (`x-terminal-emulator`/`$TERMINAL`/presets); `openURL`→`xdg-open`; reveal-in-files |
| **Approvals** / **Activity** | — | the whole spine: `HostAgentClient` (UDS state machine), coordinator, `AuditStore`, biometric gate (Phase B) |
| **Agents (RC)** | — | SSH → `shed-ext-rc` orchestration (Phase C) |
| **Prefs / tray / nav shell** | — | UI + platform (XDG autostart, tray, XDG config persistence) |

---

## Phase A — A real Linux client (foundation)

- **A0a — IPC skeleton + harness.** The socket + `identify`(`platform:"tauri"`)/`ui.navigate`/
  `ui.show_window`/`app.screenshot` (the mechanism decided above) + single-instance; `tools/shedtest`
  gains a `TauriClient`, `--target tauri` launch/quit, and a hermetic mock. **Green before a frontend
  exists.** Accept: `--target tauri` identify + navigate pass; the shared `test_shared.py` smoke runs.
- **A0b — Frontend shell + WebKitGTK gate.** The sidebar (Sheds/Approvals/Agents/Activity/System +
  count badges + HOSTS list + "host agent · connected"), the linen theme from the committed mockup, pane
  stubs; the **React + Vite + Tailwind v3 + shadcn/ui** scaffold (Vite `beforeBuildCommand` builds
  `frontendDist`), shadcn themed to the linen mockup via CSS-vars; a strict CSP with nonces (the frontend
  makes no network calls). **Accept (machine-checked, not eyeballed): a stylelint/PostCSS build-ban on
  `oklch()`/`color-mix()`/`:has()`/container-queries/`@property`/`backdrop-filter` + HSL-only Tailwind (v3
  avoids these by default; v4 does not) + a computed-style IPC probe (`getComputedStyle` → resolved `rgb`)
  confirm WebKitGTK 4.1 (Ubuntu 24.04) actually rendered the theme; a `tauri-build-linux` Docker job
  (`webkit2gtk-4.1-dev` + `scrot`/`imagemagick`).** Visual = within-tolerance vs the
  mockup, not pixel-identical.
- **A1a — Extract `core/shed-app` (the keystone; hard split move→add).** **A1a-move:** move `Backend`
  **verbatim from `shed-gtk/backend.rs`** (keeps the hermetic guard + `CreateStore` — *not* the spike's
  real-config `Backend`) into `shed-app`, refactor `shed-gtk`, **delete `shed-gtk/src/backend.rs`** —
  Tauri-agnostic + independently revertable. **A1a-add:** add df/images/the 5s poller/the error-rollup/the
  reconnect path (+ a `config.reload` op) + the platform-seam traits (GTK ignores them). Accept: `cargo test
  -p shed-app` + `cargo test -p shed-gtk --lib` + `gtk-lint`/`gtk-build-linux` + **`e2e-gtk` (incl.
  `test_gtk.py`) still green**. (`shed-app` is a `core/` **default-member**; only `shed-gtk` stays excluded.)
- **A1b — Sheds + Create.** The per-host grouping, cards (status dot / backend badge / image tag /
  cpu·mem·uptime), status-gated action buttons (running→terminal/reset/stop, stopped→start/delete), the
  New-Shed dialog + live SSE progress + `create.cancel` (store the `AbortHandle`). Accept: the shared
  lifecycle/create `test_shared.py` pass at `--target tauri` **against the mock** (hermetic).
- **A1c — System + Terminal + terminal prefs.** The df cards; terminal launch (the platform spawn +
  `openURL`); the terminal-preset pref. Accept: `system.df` + terminal-preview shared tests pass, hermetic.

**Phase-A note (C2):** A runs against the **mock**, so token-minting isn't needed. Against a *real
secure* host the static config token is not security-parity — that lands with the host-agent client in
Phase B. A's acceptance is hermetic-only; do **not** claim secure-server parity at A.

---

## Phase B — The approval spine, on Rust (own plan + security review)

**Gated on C1:** confirm `shed-host-agent` runs + is reachable on Linux (the roadmap states it does).
**If it misbehaves on Linux, fix it in `../shed-extensions` and open a PR there** (developed + tested in
a shed) as a Phase-B prerequisite — *not* a hard blocker on this repo. Scope:

- **Pure → `shed-core`:** `PolicyEngine` (+ port `PolicyEngineTests`), the approval models, the
  `HostAgentProtocol` codec (+ `HostAgentProtocolTests`), the audit *schema*.
- **Stateful/I-O → `shed-app`:** the `HostAgentClient` UDS state machine — reconnect/backoff, correlated
  `token.get`/`token.response` with single-resume + per-request timeouts, **fail-closed on disconnect**
  (port the 221-line `HostAgentClientTests`); the approval coordinator (pending queue / grants / expiry /
  `respondAndAudit`); the `AuditStore` writer (append-only JSONL, platform `state_dir`); **per-server
  CONTROL-token minting (C2)** — fail-closed (no static-token fallback), matching the Mac model.
- **`AuthGate` trait** — returns `{approved, cancelled, unavailable, denied, error}` (not `bool`);
  **backend/native-mediated, never password-in-webview.** Linux first impl: native password/PAM for
  `biometrics-or-password`; **fail-closed** for biometrics-only and on unconfigured Linux (no
  biometric/PAM path). PAM-fprintd behind detection later; WebAuthn deferred. `Notifier` via D-Bus/Tauri.
- **The `decideApproval` security edge-cases as *required* tests** (H2): re-check expiry across the async
  gate (a request expired mid-prompt can't send a late approve); deny supersedes a live session grant;
  per-shed sticky vs per-session TTL; fail-closed drop of all pending on disconnect; re-evaluate pending
  on policy change; expire-to-deny after TTL.
- **UI + harness:** the Approvals pane (card: op/shed/"expires in Ns"/Deny/Approve+gate) + Activity feed
  + approval prefs (method/policy/TTL/per-shed); **generalize the mac-only fake-host-agent + policy-reset
  scaffolding in `conftest.py` to `--target tauri`**; capability-based shared approval tests.
- **Accept:** `cargo test -p shed-app` (client + coordinator + gate + audit); the Rust `HostAgentClient`
  handshakes with `fake_host_agent.py`; the **full approval matrix** (not one path) passes at
  `--target tauri`.

---

## Phase C — Agents, prefs, tray, release

- **Agents (RC):** port the SSH + `shed-ext-rc` orchestration (`rc.list/launch/kill/classify`) into
  `shed-app`; the pane (session cards, state pills, Open-in-Claude/console/kill) + the Launch dialog.
- **Preferences + persistence:** the remaining prefs (per-shed overrides, launch-at-login via **XDG
  autostart**); persist to `~/.config/shed-desktop/prefs.json` (XDG).
- **Tray — a known UX gap:** the Mac popover is a custom borderless `NSPanel` (running count + approvals +
  quick actions); Tauri's Linux tray is a **context menu**, not a custom popover. Decide: a simplified
  tray menu, or invest in a positioned tray-window (hard on Wayland).
- **Packaging transition (decision):** Tauri's own bundler (`cargo tauri build → .deb/AppImage`) vs the
  existing `nfpm` pipeline. The `.deb` must **declare the WebKitGTK/AppIndicator runtime deps** (it is NOT
  self-contained); **AppImage is 70 MB+ with glibc-baseline pain** (not free); update `packaging/nfpm.yaml`
  (drop the GTK deps) and `shedctl` (still resolves `SHED_GTK_SOCKET`/`shed-gtk.sock`); wire into the
  existing `apt-charliek` release flow.
- **Look-refinement:** within-tolerance pixel-match vs the committed mockup — 5–10 named reference
  screenshots (dashboard/approvals/activity/agents/prefs/tray) with tolerances; computer-use for the pass.
- **GTK retirement (gated, late):** flip the shipped Linux `.deb` from GTK to Tauri **only after**
  packaging + the WebKitGTK CI + approval prefs + one release-candidate validation pass are green — not
  mechanically at a milestone boundary.

---

## Key decisions (for the maintainer)

1. **C1 — `shed-host-agent` on Linux** (Phase-B prerequisite, *not* a hard blocker): confirm it runs;
   if it misbehaves, fix it in `../shed-extensions` + open a PR there (developed/tested in a shed).
2. **The Linux `AuthGate`** — the first shippable gate is a real privilege-boundary design (native
   password via PAM-helper/polkit vs an app credential store vs WebAuthn), **not a UX downgrade**.
   Recommend: PAM/native-password for `biometrics-or-password`, fail-closed elsewhere; fprintd later.
3. **`core/shed-app`** (new, gtk-free + tauri-free) — endorsed by all three reviewers.
4. **`app.screenshot` mechanism** — *resolved*: `dashboard.dump` is the drivability primitive;
   `app.screenshot` = webview-capture + external `grim`/`scrot` best-effort; `tauri-driver` deferred.
5. **Packaging** — Tauri bundler vs `nfpm`; the WebKitGTK dep + `shedctl` socket transition.
6. **GTK retirement timing** — the gated, post-RC decision above.
7. **Frontend build** — *resolved*: **React + Vite + Tailwind v3 + shadcn/ui** (maintainer's stack;
   shadcn ⇒ React; a local WebView makes bundle-size moot). **Tailwind v3** (not v4) — v4's default
   `oklch()`/`color-mix()`/`@property` output risks WebKitGTK 2.44; v3 is HSL-only. WebKitGTK CSS-parity is
   the A0b gate (stylelint ban + computed-style probe).
8. **Mac app stays SwiftUI** (out of scope now).

## Deferred
Mobile (a separate **Android**-first spike; different features; iOS post-roadmap). Egress. The macOS-only
bits (Sparkle/notarization) stay the Mac app's.

## Process
Three separate phase plans (A → B → C), each **`/planning:ask-panel`'d on its own** and refined with the
**learnings from the prior phase** before it's built (Phase B especially gets a dedicated
security-reviewed plan). **All phases land in ONE PR** — a single `tauri-desktop` branch **stacked on
`feat/rust-core`** (rebased onto `main` after PR #26 merges). Phase A's detailed plan is
[`tauri-phase-a.md`](tauri-phase-a.md) (panel'd on its own); B and C get theirs JIT. Commits via the
usual per-commit loop: `/simplify` → **`/cursor:rescue` (primary — Codex is rate-limited for now; use
Codex again once it recovers)** → tests + lint → commit. Panels lean on Kimi + CodeRabbit (+ Codex when
available). Each milestone green + drivable + hermetic; computer-use for the look-refinement passes.
