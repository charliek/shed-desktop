# Phase 2 — next-session kickoff prompt

Paste the block below into a fresh session to resume the Rust-core work. It's
written to be understood cold (no prior chat context needed). Update it as
milestones land or the flow changes.

---

You're continuing a multi-session effort in `shed-desktop` (a native macOS
menu-bar app for the "shed" toolchain). We're extracting the shed-server protocol
layer into a shared **Rust core** and building multi-platform clients on it.
**All Rust-core + client work lives on ONE branch: `feat/rust-core`.** Keep it
that way — commit onto `feat/rust-core`; don't spin up a new branch per phase.

**Read first:** `plans/phase-2-rust-clients.md` (the contract), `docs/roadmap.md`,
`docs/enhancements.md`, and `CLAUDE.md`.

## Where things stand

- **Phase 1 (done):** `core/shed-core` — a *pure* Rust crate (HTTP/SSE, defensive
  decoders, control-token FSM, TLS pinning) — plus `core/shed-core-ffi` (a UniFFI
  staticlib) consumed by the Swift app behind `SHED_DESKTOP_RUST_CORE` (currently
  **off** by default), with dual-backend e2e parity.
- **Phase 2 (planned + de-risked; implementation NOT started):** the panel-hardened
  plan is `plans/phase-2-rust-clients.md`. Already proven: `shed-core` builds + **51
  tests pass + clippy clean on aarch64 Linux** (Docker and a shed). The shed-based
  GTK test loop is validated end-to-end, and a provisioned `sd-gtk-dev` shed is
  **stopped and ready** (`tools/shed/shed-test.sh`).

## Your task

Implement Phase 2 in milestone order from `plans/phase-2-rust-clients.md`:

- **M0** — make the Rust core the macOS **default** (properly gated). *Start here* —
  it's the one milestone buildable + verifiable natively on the Mac.
- **M1** — `shed-core` on Linux CI + hoist the create orchestration into pure
  `shed-core`.
- **M2** — `shed-gtk` skeleton + minimal IPC (identify/wait_alive/sheds.list) +
  the full-schema config parser.
- **M3** — GTK drivability: a `dashboard.dump` truth op + screenshot + pytest under
  Xvfb.
- **M4** — GTK lifecycle + create (+ the deadlock/cancel tests).
- **M5** — `.deb` packaging + docs (fix the stale `architecture.md`/`rust-core.md`
  references; update `CLAUDE.md`).
- **M6** — GTK approval pane. **Scoped but deferred** — do NOT start it as part of
  Phase 2.

## The flow — follow it every time

1. **Per phase plan → panel review.** Phase 2's plan is already panel-reviewed, so
   M0–M6 don't each need it. But if you *materially revise* the Phase 2 plan, or
   when you write a **new** plan (e.g. Phase 3), run
   `/planning:ask-panel <plan-path> — <focus>` (Codex + Kimi + CodeRabbit) and fold
   the findings in **before** implementing.
2. **Per commit:** `/simplify` → `/codex:rescue` (fallback `/cursor:rescue` if Codex
   has trouble) → run tests + lint → commit. Keep every commit green.
3. **Keep it drivable + tested** (the North Star: the app is drivable/observable by
   an agent over IPC). New UI/behavior ⇒ a new IPC op + harness coverage. Use the
   **`shedtest-mac`** skill for the macOS e2e loop and **`shedtest-linux`** for the
   GTK loop in a shed (the `sd-gtk-dev` box is provisioned + stopped;
   `tools/shed/shed-test.sh`).

## Hard constraints (from the plan + repo conventions)

- Keep `shed-core` **pure** — no UniFFI, no SwiftUI (the GTK app links it
  directly). FFI lives only in `shed-core-ffi`.
- Swift 6 strict concurrency. For the GTK app, obey the **tokio↔glib panic-trap
  rules** in the plan's M2: spawn `shed-core` futures on `rt_handle` and `.await`
  the JoinHandle *inside* `glib::spawn_future_local`; never poll a reqwest future
  on the glib executor; flatten `!Send` GTK objects to plain data before crossing
  threads; never hold a `RefCell` borrow across `.await`.
- **M0 specifics:** make Rust-adapter construction failure fail the host **loudly**
  (no silent `try?` fallback to Swift) unless `SHED_DESKTOP_RUST_CORE=0`, and invert
  the harness (`tools/shedtest/ui.py`) so unset ⇒ rust. Gate the default-on *ship*
  on the golden-JSON cross-backend diff + a size/cold-launch budget + verifying the
  app ships arm64-only today (`scripts/build-core.sh` builds the core arm64-only).
- On macOS, exclude `shed-gtk` from workspace builds (`default-members` in
  `core/Cargo.toml` + `--exclude shed-gtk` in `make core-test`/`core-lint`) so the
  Mac side never tries to build GTK.
- **Never** run real notarization or touch the user's Apple credentials
  (`.secrets/apple.env`) autonomously.
- Log any deferred QoL/enhancement items into `docs/enhancements.md` so they aren't
  lost.

## Autonomy

Execute the plan autonomously. Only stop for (a) destructive actions we haven't
discussed, or (b) a large decision with no clear best path given the project's
direction. Otherwise keep going and give a status at the end.

## Housekeeping

- Branch: **`feat/rust-core`** (single branch). Don't `git push` or open PRs unless
  asked — those are the maintainer's call.
- End every commit message with these trailers (use the **current** session's URL
  for `Claude-Session`; the environment provides it):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: <current session URL>
  ```
- As milestones land, tick them off in `plans/phase-2-rust-clients.md` and keep
  this kickoff file honest for the next resume.
