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

- **Phase 1 (done):** `core/shed-core` (pure Rust: HTTP/SSE, decoders, control-token FSM,
  TLS pinning) + `core/shed-core-ffi` (UniFFI staticlib) consumed by the Swift app.
- **Phase 2 (✅ DONE, 2026-07-02 — M0–M5):** the Rust core is the macOS **default**
  (`SHED_DESKTOP_RUST_CORE=0` forces Swift; loud per-host fail; golden cross-backend diff +
  size/cold-launch ship-gates); `shed-core` builds/tests on **Linux** (CI + Docker) with the
  create orchestration + `config` parser hoisted in; and a **`shed-gtk`** GTK4/libadwaita
  client stands on it — dashboard + lifecycle + create, drivable over IPC (`dashboard.dump`
  truth op + `screenshot`), tested under Xvfb (`tools/shedgtktest`) and packaged as a `.deb`
  (install-validated in a clean container). **Mac-native GTK** (Homebrew) is a first-class
  dev loop; **Linux is the shipped target**. Docs (architecture/rust-core/CLAUDE) updated.
- **Only M6 remains** (scoped but DEFERRED — after Flutter, per `docs/roadmap.md`): the GTK
  approval pane. The `sd-gtk-dev` shed is provisioned + stopped (`tools/shed/shed-test.sh`)
  and the Mac Homebrew GTK loop is faster for most GTK dev.

## Your task

Phase 2 (M0–M5) is complete. The remaining scoped work is **M6** (the GTK approval pane),
which the plan explicitly defers until after the Flutter spike — do NOT start it without a
fresh go-ahead. Milestone order from `plans/phase-2-rust-clients.md`:

- **M0** — make the Rust core the macOS **default** (properly gated). ✅ **DONE
  (2026-07-01).**
- **M1** — `shed-core` on Linux CI + hoist the create orchestration into pure
  `shed-core`. ✅ **DONE (2026-07-01).**
- **M2** — `shed-gtk` skeleton + minimal IPC (identify/wait_alive/sheds.list) +
  the full-schema config parser. ✅ **DONE (2026-07-02):** the `core/shed-gtk`
  crate (libadwaita dashboard + tokio↔glib async bridge + newline-JSON IPC:
  identify/sheds.list/screenshot), verified on aarch64 Linux (Docker) **and this
  Mac** (Homebrew GTK — now a first-class dev loop; `make gtk-run`/`gtk-build`).
- **M3** — GTK drivability: a `dashboard.dump` truth op + screenshot + pytest under
  Xvfb. ✅ **DONE (2026-07-02):** `dashboard.dump` + `tools/shedgtktest` (4 tests) +
  an `e2e-gtk` Xvfb CI job; verified on Mac (native) and headless Linux (Docker+Xvfb).
- **M4** — GTK lifecycle + create (+ the deadlock/cancel tests). ✅ **DONE (2026-07-02):**
  IPC shed.{start,stop,reset,delete} + create.{start,status,cancel} on the pure CreateStore
  + a live create-progress banner; shedgtktest lifecycle/create/cancel/deadlock tests (8/8
  on Mac + a headless-Linux smoke).
- **M5** — `.deb` packaging + docs. ✅ **DONE (2026-07-02):** nfpm `.deb` + install-validate
  in a clean ubuntu:24.04 container + a `deb` CI job; stale `architecture.md`/`rust-core.md`
  references fixed; `CLAUDE.md` updated; plan status flipped.
- **M6** — GTK approval pane. **Scoped but DEFERRED** — after Flutter (per the roadmap); not
  part of Phase 2. **This is the only remaining Phase 2 milestone.** Port the key-free
  approval spine (PolicyEngine, AuditStore, host-agent protocol codec, models) into
  `shed-core`; add a Linux gate (libnotify + a PIN/passphrase dialog — biometrics stay
  macOS-only); the host-agent stays the separate key-holder over its UDS.

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
