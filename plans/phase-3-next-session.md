# Phase 3 done — next-session kickoff prompt

Paste the block below into a fresh session to resume. It's written to be understood cold (no
prior chat context needed). Update it as things land or the flow changes.

---

You're continuing a multi-session effort in `shed-desktop` (a native macOS menu-bar app for
the "shed" toolchain). We extracted the shed-server protocol layer into a shared **Rust core**
and built multi-platform clients on it. **All Rust-core + client work lives on ONE branch:
`feat/rust-core`.** Keep it that way — commit onto `feat/rust-core`.

**Read first:** `docs/roadmap.md`, `docs/enhancements.md`, `CLAUDE.md`, and — for what just
shipped — `plans/phase-3-enhancements.md`.

## Where things stand

- **Phase 1 (done):** `core/shed-core` (pure Rust: HTTP/SSE, decoders, control-token FSM, TLS
  pinning) + `core/shed-core-ffi` (UniFFI staticlib) consumed by the Swift app.
- **Phase 2 (done):** the Rust core is the macOS **default**; `shed-core` builds/tests on
  **Linux**; a **`shed-gtk`** GTK4/libadwaita client stands on it (dashboard + lifecycle +
  create, drivable over IPC), packaged as a `.deb`.
- **Phase 3 (✅ DONE, 2026-07-03 — P3.0–P3.8):** the enhancements backlog is closed out. The
  Linux binary/package is now **`shed-desktop`** (crate stays `shed-gtk`); a headless
  **`shedctl`** crate ships in the `.deb`; GTK gained single-instance handoff (an
  **`app.activate`** IPC op + a flock) and parallel multi-host fetches; the mac + Linux
  functional suites are **unified into one `tools/shedtest --target mac|gtk` harness** (the
  separate GTK harness retired); an adversarial coverage pass hardened all three surfaces; CI
  gained a `changes` path-filter + an `x86_64` Linux leg; and the **`.deb` release pipeline**
  is wired (`create-release → mac + linux → apt-charliek dispatch`; `apt install
  shed-desktop`). The branch is **CI-green on draft PR #26**.
- **Only P3.9 remains** — merge readiness — and it's the **maintainer's** call (below).

## Maintainer actions (GitHub-side — flagged, not auto-done)

These are yours; do NOT do them autonomously:

1. **Merge the apt-charliek PR** — the `packages.yaml` + README addition registering
   `shed-desktop` (prepared as a small PR against `charliek/apt-charliek`).
2. **Run `sanity-check-app`** once from the Actions UI to confirm the release-bot App reaches
   both this repo and `apt-charliek` (secrets already present; expected green). Also confirm
   arm64 runners are enabled (public repo → free) on the PR run.
3. **Mark PR #26 ready + merge `feat/rust-core` → `main`.**
4. **Cut the first `.deb`-bearing release** — a real `vX.Y.Z` tag via
   **`/release-workflows:release`** (a separate, later step; not part of the merge).

## What's next (the roadmap direction)

The active thrust is the **Tauri desktop client** — a real Linux client toward **full Mac↔Linux
parity** on the same `shed-core` (Tauri's backend *is* Rust → `shed-core` is a direct dep; it runs on
macOS [WKWebView, a UI-comparison loop vs the Swift app] **and** Linux [WebKitGTK, the shipped target],
like the GTK client). It's **panel-reviewed and split into three phases** — foundation → the approval
spine → agents/prefs/tray + release — landing in **one PR**, each phase `/planning:ask-panel`'d + refined
with the prior phase's learnings. The `spike/tauri` scaffold proved `shed-core`-in-Tauri is clean (live
against real hosts; the `CreateSink`→events seam bridges Swift/GTK/Tauri). **If it lands, it replaces the
GTK client as the shipped Linux app.** See **`plans/tauri-desktop.md`**. (A Flutter mobile spike is
superseded unless Tauri's **Android** target disappoints — mobile is a separate, later spike.)

Deferred / not without a fresh go-ahead:

- **Phase 4 (Rust-core-only)** — retire the Swift `URLSession` path (+ the `SHED_DESKTOP_RUST_CORE=0`
  fallback + its e2e leg) and unify config discovery via the FFI, after the Rust default has shipped ≥ 2
  releases. Relatedly, Tauri Phase A extracts a shared **`core/shed-app`** (the app-logic `Backend`) — a
  natural home the Swift app could eventually route through too. See `plans/phase-4-rust-core-only.md`.
- The **GTK approval pane** is subsumed by the Tauri client's **Phase B** (the approval spine ported to
  shared Rust, with the host-agent client + control-token minting).

## The flow — follow it every time

1. **New plan → panel review.** When you write a **new** plan, run
   `/planning:ask-panel <plan-path> — <focus>` (Codex + Kimi + CodeRabbit) and fold the
   findings in **before** implementing.
2. **Per commit:** `/simplify` → **`/cursor:rescue`** (currently primary — Codex is
   rate-limited; use `/codex:rescue` again once it recovers) → tests + lint → commit. Keep
   every commit green.
3. **Keep it drivable + tested** (the North Star): new UI/behavior ⇒ a new IPC op + harness
   coverage. Use the **`shedtest-mac`** skill for the macOS e2e loop and **`shedtest-linux`**
   for the GTK loop in a shed.

## Hard constraints (carried from Phase 1/2/3)

- Keep `shed-core` **pure** — no UniFFI, no SwiftUI (the GTK app + `shedctl` link it
  directly). FFI lives only in `shed-core-ffi`.
- Swift 6 strict concurrency; the tokio↔glib **panic-trap rules** for any `shed-gtk` change.
- Keep the Mac build **GTK-free**: `shed-gtk` stays out of `default-members`; `core-lint`
  stays `--workspace --exclude shed-gtk`.
- **Never** run real notarization or touch `.secrets/apple.env` autonomously; **never** cut a
  real release tag autonomously.
- Log any deferred QoL/enhancement items into `docs/enhancements.md` so they aren't lost.

## Housekeeping

- Branch: **`feat/rust-core`** (single branch). Don't `git push` or open PRs unless asked.
- End every commit message with these trailers (use the **current** session's URL for
  `Claude-Session`; the environment provides it):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: <current session URL>
  ```
