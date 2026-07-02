# Phase 2 — Prove the shared Rust core across platforms (macOS default-on + GTK/Linux client)

**Status:** IN PROGRESS — panel-reviewed (Codex + Kimi + CodeRabbit), hardened. **M0–M2 done**
(2026-07-02); M3 in progress (the `screenshot` op landed early); M4–M6 pending. Plan revised
2026-07-02 to add a **Mac-native GTK dev target** (Homebrew). All Rust-core + client work lives
on the single `feat/rust-core` branch.

## Context

Phase 1 (shipped, on `feat/rust-core`) extracted shed-desktop's shed-server protocol layer
into a shared Rust core:

- **`shed-core`** — a *pure* Rust crate (no UniFFI, no SwiftUI): HTTP + SSE clients, the
  defensive wire decoders, the control-token FSM, and leaf-cert TLS pinning.
- **`shed-core-ffi`** — a thin UniFFI staticlib wrapper consumed by the Swift app behind
  `SHED_DESKTOP_RUST_CORE` (off by default), with dual-backend e2e parity in CI.

Phase 2 makes that core *real* by proving it across platforms with actual clients, while the
credential broker (`shed-host-agent`) stays a **separate process** exactly as today. The
intent (maintainer-directed): "get the Rust port fully working on both mac and linux with
the rust foundation," sequencing the larger consolidation (absorbing the broker, merging
repos) for *after* the clients prove the foundation.

Concretely, Phase 2:

1. Makes the Rust core the **default** on macOS — properly gated (see M0), not a bare flag flip.
2. Gets **`shed-core` building and testing on Linux**, and hoists the create orchestration
   into the pure crate so both clients share it.
3. Stands up a **GTK/Linux app** on the same crate — a read-only dashboard first, then
   lifecycle + create — mirroring `../roost`'s rust+gtk toolchain and its
   pytest-over-IPC-under-Xvfb drivability model.
4. Leaves **`shed-host-agent` untouched and separate** on both platforms. It already builds
   and runs on Linux (see "Established facts").

### The boundary decision (why the broker is *not* absorbed now) — on record

The original Phase 2 sketch was "absorb `shed-host-agent` into the Rust core." That was
scoped and **deliberately deferred**:

- `shed-host-agent` is ~8,900 LOC of security-critical Go and is the one component that
  **holds the real keys** (SSH-agent proxying, AWS STS, Docker credential helpers). The app's
  bedrock invariant is "the app holds no credentials" (`architecture.md:61-64, 173-179`).
- **What actually violates the invariant is *linking a key-holder into the GUI process*, not
  "rewriting it in Rust."** A future Rust broker can preserve the invariant *if it stays a
  separate process* behind the same metadata-only IPC boundary. Absorbing it *in-process*
  (into `shed-core`/`shed-gtk`/the GUI) is what makes a GUI that already serves a `0600`
  socket and dials out *also* the SSH/AWS/Docker key custodian — a categorical attack-surface
  increase that re-introduces the fail-open/secure-downgrade risks currently isolated in a
  minimal fail-closed daemon.
- The Phase-1 thesis (kill 4–5× protocol duplication across languages) **does not apply to the
  broker**: it isn't duplicated per client — it's one Go binary both clients reach over the
  same UDS, and it already runs on Linux unmodified. Porting it to Rust would *create* a
  second security-critical implementation to keep at parity, for **zero** cross-platform-reuse
  gain — strictly negative until the deliberate consolidation step retires the Go binary.
- It depends on a Go `shed/sdk` (plugin-bus subscription, SSH-bootstrap minting) with **no
  Rust equivalent** — a faithful port needs that SDK built first (a large effort; the exact
  months are unquantified and must not become load-bearing for scheduling).

So the broker stays separate now and is replaced in Rust *later*, on the proven foundation,
as the final consolidation step (see `docs/roadmap.md`). "Consolidation" may *package* things
together, but the **process/security boundary remains** unless a new threat model explicitly
replaces it. The reusable, **key-free** part of the approval subsystem (PolicyEngine,
AuditStore, protocol codec, models) is ported into `shed-core` in **M6** when the GTK client
grows an approval pane.

### Non-goals (explicit deferrals)

- No absorbing `shed-host-agent` into Rust. No bundling or supervising it. It stays a
  separate install on both platforms, over today's Unix-socket interface. (Accepted, named UX
  cost: a Linux user who later wants approvals installs **two** packages — the `.deb` and the
  separate host-agent — until the consolidation step.)
- No merging `shed-core` into the `shed` repo, and no pulling in `shed-extensions` — that
  consolidation is sequenced after Flutter validates the boundary.
- Flutter is a later spike, noted in the roadmap, not built in this phase.

### Established facts (from exploration)

- **`shed-host-agent` builds + runs on Linux as-is.** Touch ID is build-tagged
  (`touchid_darwin.go` vs a `touchid_stub.go` deny-all gate on non-darwin); socket paths are
  already XDG-aware (`$XDG_RUNTIME_DIR/shed`); all deps are cross-platform;
  `.goreleaser.yaml` already ships a `linux/amd64+arm64` target. Zero changes needed.
- **The GTK v1 surface (dashboard + lifecycle + create) needs only shed-server over HTTP —
  no host-agent.** The broker only enters for credential *approvals* (deferred to M6).
- **`../roost` is the template.** It runs a Rust core + gtk4-rs/libadwaita app with the same
  drivability model shed-desktop uses (pytest over a JSON IPC socket, `*_TEST_MODE=1`,
  `wait_alive`, headless Xvfb in CI), and ships an nfpm `.deb`. Key references:
  `crates/roost-linux/src/main.rs:186-266` (runtime+IPC+glib wiring),
  `crates/roost-linux/src/app.rs:987` (`bootstrap` = the spawn/JoinHandle async pattern),
  `crates/roost-linux/src/app.rs:310-349` (`render_window_png` = the headless screenshot),
  `tools/roosttest/` (harness), `.github/workflows/ci.yml:315-408` (bare-`ubuntu-latest`
  Xvfb e2e). **roost uses no Docker for CI.**

## Development environment

Development is on macOS; **Linux is the primary *target*, but GTK4/libadwaita builds + runs
on macOS too** (revised 2026-07-02 — proven: `shed-gtk` builds, runs, and screenshots on the
dev Mac). Three tiers, matching the shed ecosystem's convention (see the `shedtest-linux`
skill):

- **Mac-native GTK (Homebrew)** — `brew install gtk4 libadwaita`, then `make gtk-run` /
  `make gtk-build`: the fastest inner loop for eyeballing + IPC-driving the UI. `shed-gtk` is
  a workspace member but **not** a `default-member`, so the macOS app's `make
  core-test`/`core-lint` never build GTK — it's opt-in. Linux stays the shipped target; this
  is a dev / UI-comparison convenience (mirrors `../roost`, which runs its `roost-linux` GTK
  UI on Mac the same way). Users run the native Swift app; the Mac GTK run is dev-only.
- **Docker on macOS** — `make core-linux` / `make gtk-build-linux`: Linux build/test parity
  (no GUI needed for the crate build + lib tests).
- **A shed (Linux VM)** or bare Linux for the full GTK *e2e* (GTK + Xvfb + pytest, M3).

**GL/headless parity is a real trap** (CodeRabbit): roost's `e2e-gtk` runs on bare
`ubuntu-latest`, which ships mesa/llvmpipe, so `render_window_png` works headless with only
`GDK_BACKEND=x11`. A *minimal* container lacks mesa and the GTK `GskRenderer` fails (empty
render / error) even though it passes on GitHub's runners. Therefore:

- `Dockerfile.linux` base = **`ubuntu:24.04`** (ships GTK 4.14; 22.04's GTK 4.6 is too old for
  the `v4_12` feature), and must install `libgtk-4-dev libadwaita-1-dev pkg-config`,
  **`libgl1-mesa-dri`** (headless GL), and **`build-essential`** (a C toolchain for `ring`).
- Set `GDK_BACKEND=x11`; fall back to `GSK_RENDERER=cairo` for the headless path if the GL
  renderer misbehaves.
- **Decide explicitly:** CI runs the GTK e2e on **bare `ubuntu-latest`** (true parity with
  roost), with Docker as a *local-only* convenience. The `Dockerfile.linux` is for local
  reproduction, not the CI gate.

## Milestones

Each milestone is independently committable and keeps every existing suite green. Per commit:
`/simplify` → `/codex:rescue` (`/cursor:rescue` fallback) → tests + lint → commit.

**Ordering note:** M0 (macOS default flip) is *technically independent* of M1–M6 — it carries
the phase's only user-facing risk. **M1 (Linux core) must be green before M0 ships the
default**, and M0's real ship-gate is the Phase-1 deferred safety nets below (not merely a
green e2e). The GTK milestones (M2–M5) can proceed in parallel with M0's dogfooding window.

### M0 — macOS: the Rust core becomes the default (properly gated) — ✅ DONE (2026-07-01)

> **Landed:** `ShedBackend` defaults `rustCore` on (`!= "0"`); `ShedServerClient` fails a
> host **loudly** (via `configError`) when the Rust adapter can't construct instead of a
> silent Swift downgrade; `tools/shedtest/ui.py` inverted (unset ⇒ rust, `=0` forwarded).
> Ship-gates realized as `tools/shedtest/m0_ship_gates.py` (`make m0-gates`) + a CI step:
> arm64-only Mach-Os, a binary-size budget, a cold-launch budget, and a **byte-identical
> cross-backend golden diff** of `sheds.list`/`system.df`/`images.list` (Rust vs Swift).
> Verified: build, 121 Swift units, both e2e legs (rust default + `=0` swift, 64 each), and
> the gate on debug + release bundles all green; release binary 8.6 MB, arm64-only. The
> stale `architecture.md`/`rust-core.md` "flag off by default" lines are fixed in **M5**
> (tracked in `docs/enhancements.md`); the dogfooding window before a release ships is the
> maintainer's gate.

Code change (small): default `SHED_DESKTOP_RUST_CORE` **on** in `ShedBackend.start`
(`Sources/ShedKit/Backend/ShedBackend.swift:74`); `SHED_DESKTOP_RUST_CORE=0` forces the Swift
path (kept as a rollback escape hatch for **≥2 releases**, not removed).

Correctness fixes this flip *requires* (both code-grounded):

- **No silent per-host fallback.** `ShedServerClient` builds the adapter with `try?`
  (`Sources/ShedKit/Net/ShedServerClient.swift:76`), so `identify.core=rust` can mask a
  *per-host* Swift fallback when adapter construction fails. Make construction failure fail
  that host **loudly** (surface it, don't silently fall back) unless `=0`.
- **Invert the harness.** `tools/shedtest/ui.py:128` computes `want_core = "rust" if env=="1"
  else "swift"` and `:107-108` only forwards the flag when `=="1"`. After the flip, **unset
  must mean rust**, and the `=0` leg must be forwarded. Add `tools/shedtest/ui.py` to the
  modified files.

Ship-gate (the deferred Phase-1 safety nets — this flip is exactly what they were for):

- **Golden-JSON cross-backend byte-diff** of backend-sensitive IPC payloads (Rust vs Swift),
  not just a green e2e. (Deferred in Phase 1 §10/§11.)
- **Binary-size + cold-launch budget** check on the release bundle (no regression).
- **Arch:** verify the shipped app is arm64-only today (`scripts/build-core.sh:66-67` builds
  the core arm64-only; release on `macos-15` with **no `lipo`**), so the x86_64 precondition
  Phase 1 flagged is moot *for current users* — **state and verify this**. If the app ever
  goes universal, the arm64-only core becomes a default-on trap: `ShedBackend.start` must
  then arch-gate the default (not just read an env flag), or the xcframework must go universal
  via `lipo`.
- **Dogfooding window** before the default ships in a release (Phase 1 §2 required this).

- **Acceptance:** `make e2e-ci` with no flag reports `identify.core=rust` (harness inverted);
  the `=0` leg is green; no host silently falls back while `identify.core=rust`; golden-JSON
  diff clean; size/cold-launch within budget; arm64-only assumption verified; all Swift unit
  suites green; the bundle `otool -L` no-dylib gate still holds.

### M1 — `shed-core` builds + tests on Linux, and the create orchestration moves into it — ✅ DONE (2026-07-01)

> **Landed:** the create orchestration (`create_start`/`create_status`/`create_cancel`)
> is hoisted into pure `shed-core` as `create::CreateStore` (an owned, `Arc`-backed store
> that spawns the SSE task on an injected `tokio::runtime::Handle` — the FFI passes
> `Handle::current()`, GTK will pass its `rt_handle`); the FFI keeps a process-wide
> singleton + `From` conversions and is now a thin delegate (byte-identical Swift API —
> both e2e legs stay green, 64 each). `shed-core` builds + tests on Linux via a
> `core-linux` CI job (bare `ubuntu-latest`, `-p shed-core --all-targets --locked` +
> clippy) and `make core-linux` (`Dockerfile.linux`, ubuntu:24.04 + build-essential for
> `ring`); proven locally in Docker (aarch64) and on Mac — **56 tests + clippy + fmt
> clean**. Added a rustls pin-verifier accept/reject test + a redirect-fail-closed test so
> the pin/redirect paths run on Linux (the GTK e2e's plain-HTTP mock never reaches them);
> a full pinned-TLS *handshake* integration test is deferred (tracked in
> `docs/enhancements.md`).

- Add a `core-linux` CI job (bare `ubuntu-latest`): `cargo test -p shed-core --all-targets
  --locked` + `cargo clippy -p shed-core --all-targets -- -D warnings`. Scope to
  `-p shed-core` so the macOS-only `shed-core-ffi` (uniffi) is never dragged in. Include a
  **pinned-HTTPS/rustls integration test** and **redirect + non-`https://` pin fail-closed**
  tests running on Linux (not only pure-fingerprint units) — the GTK e2e uses a plain-HTTP
  mock and will *never* exercise pin/token paths, so those stay cargo-only on Linux.
- `Dockerfile.linux` + `make core-linux` reproduce the same locally (must `apt-get install
  build-essential` for `ring`).
- **Hoist create orchestration into pure `shed-core`.** The pull-based create-store +
  `tokio::spawn` glue currently lives in `core/shed-core-ffi/src/lib.rs:389-561` (Swift-only,
  behind UniFFI). Move `create_start(req) -> id` / `create_status(id) -> progress` /
  `create_cancel(id)` into pure `shed-core`; the FFI wrapper and (M4) GTK both consume it —
  otherwise the create logic gets written a third time, the exact duplication Phase 1 exists
  to kill. Keep the Swift e2e green across the move.
- **Acceptance:** green `cargo test`/`clippy` for `shed-core` on Linux (local Docker + CI,
  amd64 in CI, arm64 via local Docker); create orchestration lives in `shed-core` with the
  macOS dual-backend e2e still green. No source changes expected in the read path (reqwest-
  rustls/ring/tokio are cross-platform); fix any that surface.

### M2 — `shed-gtk` skeleton: read-only dashboard, verifiable over IPC — ✅ DONE (2026-07-02)

> **Landed:** `shed_core::config` (the Swift `ShedConfig` port, parity-tested via
> `core/fixtures/config_sample.yaml` + `ConfigParityTests.swift`); the `core/shed-gtk` crate —
> a workspace member but **not** a `default-member`, so Mac `core-test`/`core-lint` stay
> GTK-free. It has a libadwaita dashboard listing sheds fetched via shed-core, the tokio↔glib
> async bridge (one-shot read: `rt.spawn` + the `JoinHandle` awaited inside
> `glib::spawn_future_local`; a `UiRequest` mpsc drained on the glib thread for `!Send` ops),
> and a newline-JSON IPC server — `identify` (echoing core=rust / platform=gtk / hermeticity),
> `sheds.list`, and `screenshot` (rendered via the window's own `GskRenderer`, an M3 op pulled
> forward for UI comparison). Verified on **both** aarch64 Linux (Docker) and this Mac
> (Homebrew GTK): `cargo build`/`clippy`/`--lib` tests green, and an over-the-socket drive
> returns the fixture sheds + a real PNG. **Mac-native GTK is proven + folded into the plan**
> (see Development environment). **Remaining for M3:** a `dashboard.dump` truth op + the
> `tools/shedgtktest` pytest harness under Xvfb + the `e2e-gtk` CI gate.

- New workspace member `core/shed-gtk` (a `lib.rs` testable surface + a `main.rs` binary),
  deps: `gtk4 = "0.10"` (v4_12), `libadwaita = "0.8"` (v1_4), `glib = "0.21"`, `tokio`, and
  `shed-core` by path (**no UniFFI**). Add `default-members = ["shed-core", "shed-core-ffi"]`
  to `core/Cargo.toml` and switch Mac-side `make core-test`/`core-lint` to exclude `shed-gtk`
  (`--exclude shed-gtk`, mirroring roost `ci.yml:85`'s `--exclude roost-linux`), so macOS dev
  + CI never try to build GTK.
- **Host discovery ported into `shed-core` — full schema, no YAML crate.** Port the Swift
  `ShedConfig` (`Sources/ShedKit/Models/ShedConfig.swift`) as a `config` module: the tiny
  indentation parser (replicate it exactly, no YAML dependency), carrying **all** per-server
  fields — `host`, `http_port`, `ssh_port`, **`control_token`, `api_url`,
  `tls_cert_fingerprint`**, lowercasing, `default_server`, and the `resolvedEndpoint()`
  behavior — because secure/token-gated Linux hosts need them. Add a **cross-language parity
  test** against shared fixtures (the config analog of Phase 1's golden-JSON backbone); leave
  the Swift parser in place for now (unify later).
- **Hermeticity hooks (both, mirroring the Mac harness — `tools/shedtest/conftest.py:46-51`
  passes *both*):** `SHED_GTK_MOCK_BASE_URL` (redirect hosts to the mock) **and**
  `SHED_GTK_SHED_CONFIG` (a config-path override → point the GTK e2e at
  `tools/shedtest/fixtures/config.yaml`). Without the config override, CI has an empty host
  list and nothing to render/drive. Never fall back to the developer's real
  `~/.shed/config.yaml` in tests.
- **Minimal IPC in M2** (so the milestone is agent-verifiable now, not only after M3): a Rust
  IPC server (newline-JSON over a UDS at `$XDG_RUNTIME_DIR/shed-gtk/shed-gtk.sock`, with a
  `/tmp/shed-gtk-$uid` fallback when `XDG_RUNTIME_DIR` is unset — roost `ui.py:80`) exposing
  `identify` (echoing `core=rust`, `platform=gtk`, `test_mode`, **and the mock base URL**, so
  `wait_alive` can assert hermeticity like `ui.py:129-131`), `wait_alive`, and `sheds.list`.
  `SHED_GTK_TEST_MODE=1` unlocks test-only ops.
- **Async bridge (the panic-trap spec — these are runtime panics, not compile errors):**
  - Build a multi-threaded tokio runtime at startup; pass its `Handle` into the `App`
    (roost `main.rs:186-266`). GTK widgets and `Rc<RefCell<…>>` state live **only** on the
    glib main thread.
  - **One-shot reads:** `rt_handle.spawn(shed_core_future)` and `.await` the returned
    `JoinHandle` *inside* `glib::spawn_future_local` (roost `bootstrap`, `app.rs:987`). Never
    poll a reqwest/`shed-core` future directly on the glib executor → "no reactor running"
    panic. `tokio::spawn` from GTK also panics (no ambient runtime) — always `rt_handle.spawn`.
  - **Streaming** (M4 SSE create-progress): bridge via `tokio::sync::mpsc`/`async-channel`,
    drained on the glib thread — *that's* what channels are for, not one-shot reads.
  - **`!Send` flattening:** convert GTK/`glib` objects to plain `Send` data on the main thread
    before crossing to a worker or over IPC (roost flattens `glib::Bytes` → `Vec<u8>` in
    `render_window_png`, `app.rs:346-349`) — the direct parallel to the Swift rule "never
    return the non-`Sendable` `UiBridge` across the actor boundary" (`CLAUDE.md`).
  - Never hold a `RefCell` borrow across `.await`; main-thread request handlers must not block
    on network; `rt.block_on` only once, before `app.run()` (roost `main.rs:220`).
- **UI:** a libadwaita window with a per-server shed list (name, status dot, host) fetched via
  `shed-core` `info`/`list_sheds`. Read-only.
- **Acceptance:** `cargo build -p shed-gtk` (Linux); launched headless with the fixture config
  + mock, `wait_alive` passes (asserting `platform=gtk`, `core=rust`, mock base URL), and
  `sheds.list` over IPC returns the fixture sheds. `cargo test -p shed-gtk` (the `lib.rs`
  surface: IPC dispatch, config parsing) runs **without a display**.

### M3 — `shed-gtk` drivability: a data-dump truth op + screenshot + pytest under Xvfb

- **The assertion backbone is a data op, not the screenshot** (CodeRabbit): roost's
  determinism rests on `tab.dump` (state-as-text) with the screenshot as best-effort
  diagnostics. shed-gtk needs an analogous `dashboard.dump` (the rendered rows as structured
  data) as the truth. The `screenshot` op mirrors roost's `render_window_png` (renders the
  window's own `GskRenderer` → PNG bytes on the GTK thread, `!Send`-flattened to `Vec<u8>`,
  sent over IPC with a frame-size guard); its acceptance is only "**returns a non-empty PNG of
  expected dimensions**," so a hard gate isn't coupled to the container's GL stack.
- A pytest harness under `tools/shedgtktest/` that launches the GTK binary as a
  harness-owned process with **temp config/state/log dirs + temp `XDG_RUNTIME_DIR`, a
  sanitized inherited env, and captured stdout/stderr uploaded as a CI artifact**, and
  **reuses the existing Python mock** (`tools/shedtest/mockserver.py`). `wait_alive` gates
  readiness and asserts the hermeticity fields.
- CI: an `e2e-gtk` job on **bare `ubuntu-latest`** under Xvfb (apt: `libgtk-4-dev
  libadwaita-1-dev pkg-config`; `xvfb-run`, `GDK_BACKEND=x11`), a required check.
- **Acceptance:** headless pytest drives the GTK app — `dashboard.dump` matches the fixture
  sheds, `screenshot` returns a non-empty PNG — green in CI and local Docker.

### M4 — `shed-gtk` lifecycle + create

- start / stop / reset / delete + create-with-live-SSE-progress in the GTK UI, on the **pure
  `shed-core` create orchestration** (from M1); create-progress streamed via a channel drained
  on the glib thread. IPC ops + pytest coverage for each (mirroring the Mac harness's
  lifecycle/create tests against the mock).
- **Cancellation:** cancelling a create must cancel the tokio task *and* stop the UI polling.
- **Deadlock test:** a GTK e2e test that calls `sheds.list` while a create is in progress,
  verifying the UI doesn't deadlock.
- **Acceptance:** the GTK app drives full lifecycle and shows live create-progress; the
  cancellation + deadlock tests pass; the GTK e2e suite is green.

### M5 — packaging (`.deb`) + docs

- An nfpm `.deb` for `shed-gtk` (roost's `linux/scripts/build-deb.sh` + `packaging/nfpm.yaml`
  pattern): `/usr/bin/shed-gtk` (consider also a `shedctl`-equivalent CLI as roost ships
  `roost` + `roostctl`), a `.desktop` entry, an icon; runtime deps `libgtk-4-1`,
  `libadwaita-1-0`, `libc6`. amd64 (+ arm64 if straightforward). **Validate the `.deb` by
  installing it in a clean `ubuntu:24.04` container and asserting the binary launches and
  answers `identify`.**
- **Versioning/release:** three versions now coexist — the Mac app (`0.0.13`), the Rust
  workspace (`core/Cargo.toml` `0.0.1`), the `.deb`. M5 either sketches how the GTK client is
  versioned/released (GitHub release asset? apt repo? folded into a release workflow, per
  roost's dual-platform `release.yml`) **or explicitly defers release wiring** — build-in-CI
  ≠ shipped. (Suggest: build + install-validate in CI now; defer apt/release wiring.)
- Docs: update `architecture.md` (multi-client + the GTK sibling; **fix the stale line
  `architecture.md:8` that still says the Rust flag is off by default**), `rust-core.md`
  (**fix `rust-core.md:65` that still calls approvals "Phase 2" / GTK "Phase 3"**; add the
  Linux + `shed-gtk` consumer), **`CLAUDE.md`** (the new build targets, the Docker/shed dev
  loop, the GTK IPC socket path), and flip this plan's status. The roadmap is already updated.
- **Acceptance:** a `.deb` builds and install-validates in a clean container; docs updated and
  stale references fixed; the North-Star drivability holds for the GTK app.

### M6 — GTK approval pane (deferred, but a committed, scoped milestone)

Named a milestone (not a vague "fast-follow") so the GTK app reaches feature parity rather
than shipping as a second-class citizen — but **sequenced after M5** and after Flutter
validation per the roadmap.

- Port the **key-free** approval spine into `shed-core`: PolicyEngine (pure decision matrix),
  AuditStore (JSONL), the host-agent protocol codec, and the domain models. None of these
  touch key material.
- **Linux approval gate (no Touch ID):** `libnotify` for the notification + a PIN/passphrase
  dialog for the gate (the biometric path stays macOS-only; the host-agent already returns a
  deny-all gate on non-darwin, and the *desktop* app is what presents the interactive gate).
- The host-agent stays the separate key-holder over its UDS (already runs on Linux).
- **Acceptance:** the GTK app shows pending approvals, applies policy, and round-trips a
  decision to a Linux host-agent; the spine has cross-backend parity with the Swift path.

## Files

**Created:**

- `core/shed-gtk/Cargo.toml`, `core/shed-gtk/src/{main.rs, lib.rs, app.rs, ipc.rs, ...}`
- `core/shed-core/src/config.rs` (+ `lib.rs` export) — full-schema host discovery.
- `tools/shedgtktest/` — the GTK pytest harness (reusing `tools/shedtest/mockserver.py` and
  `tools/shedtest/fixtures/config.yaml`).
- `Dockerfile.linux` (or `docker/`) — the local Linux build/test image (ubuntu:24.04 + GTK +
  mesa + build-essential).
- `packaging/nfpm.yaml` + `linux/scripts/build-deb.sh` — the `.deb` build.
- `skills/shedtest-mac/SKILL.md`, `skills/shedtest-linux/SKILL.md` — the test-loop skills.

**Modified:**

- `core/Cargo.toml` — add the `shed-gtk` member **and** `default-members = ["shed-core",
  "shed-core-ffi"]`.
- `core/shed-core-ffi/src/lib.rs` — thin the create logic to wrap the hoisted `shed-core`
  orchestration.
- `Sources/ShedKit/Backend/ShedBackend.swift` — default `SHED_DESKTOP_RUST_CORE` on.
- `Sources/ShedKit/Net/ShedServerClient.swift` — fail loudly (no silent per-host Swift
  fallback) when the Rust adapter fails to construct and the core is the default.
- `tools/shedtest/ui.py` — invert `want_core`/flag-forwarding for default-on.
- `.github/workflows/ci.yml` — a `changes` path-filter job (so Linux/GTK jobs skip Mac-only /
  docs-only PRs); Mac e2e default-Rust + a `=0` Swift-fallback leg (gated to run on `main` /
  Swift-networking PRs to bound cost); new `core-linux`, `gtk-build`, `e2e-gtk` (bare
  `ubuntu-latest`) jobs; fold into the `ci-success` aggregator.
- `Makefile` — `core-linux`, `gtk-build`, `e2e-gtk`, `deb` targets; Mac `core-test`/`core-lint`
  exclude `shed-gtk`.
- `CLAUDE.md`, `docs/reference/{architecture.md, rust-core.md}`, `mkdocs.yml` (if a GTK page is
  added).

## Acceptance criteria (Phase 2 is done when)

1. The macOS app runs the Rust core **by default** (`identify.core=rust`, no flag; harness
   inverted; no silent per-host fallback); the golden-JSON byte-diff + size/cold-launch budget
   pass; the arm64-only shipping assumption is verified; the `=0` Swift fallback is reachable
   for ≥2 releases; Mac e2e + units green.
2. `shed-core` builds + tests green on **Linux** (CI amd64 + local Docker arm64), including
   pinned-HTTPS + fail-closed pin tests; the create orchestration lives in pure `shed-core`.
3. A **GTK/Linux** app on `shed-core` shows the dashboard, drives full lifecycle + create,
   and is **IPC-drivable** with a `dashboard.dump` truth op + a non-empty `screenshot`, green
   under headless Xvfb on bare `ubuntu-latest`.
4. A `.deb` packages the GTK client and **install-validates** in a clean container.
5. `shed-host-agent` is unchanged and separate on both platforms; no bundling/supervise code.
6. Docs (CLAUDE.md, architecture, rust-core, roadmap) reflect the multi-client foundation and
   the deferred consolidation, with the stale flag/phase references fixed.

(M6 — the GTK approval pane — is scoped here but explicitly *after* Phase 2 ships.)

## Test plan

- `make core-test core-lint` (macOS, excluding `shed-gtk`) + `make core-linux` (Docker) + the
  `core-linux` CI job (`--all-targets --locked`, pinned-HTTPS + fail-closed pin tests).
- The macOS hermetic e2e with the Rust core as **default** (harness inverted) + golden-JSON
  cross-backend byte-diff + a `SHED_DESKTOP_RUST_CORE=0` Swift-fallback leg.
- A new GTK hermetic e2e (pytest + the shared mock + fixture config) under Xvfb on bare
  `ubuntu-latest`. Minimum test files: `test_gtk_identify.py` (core=rust/platform=gtk/mock
  URL), `test_gtk_dashboard.py` (`dashboard.dump` vs fixtures), `test_gtk_lifecycle.py`,
  `test_gtk_create.py` (SSE progress + cancel + the deadlock test), `test_gtk_screenshot.py`
  (non-empty PNG).
- Swift unit suites unchanged and green.
- Condition-waits (`wait_alive`, `wait_until`) throughout — never sleeps.

## Repo conventions followed

- `shed-core` stays **SwiftUI-free and UniFFI-free** so the GTK app links it directly; FFI
  lives only in `shed-core-ffi`.
- **North-Star drivability:** the GTK app is IPC-drivable with a data-dump truth op +
  screenshot, against a hermetic in-process mock, verified by an agent — not by asking a human
  to click.
- Rust: workspace lints, `clippy -D warnings`, defensive decoders with pinning tests.
- All rust+gtk specifics (bindings versions, the tokio+glib bridge, nfpm packaging, the Xvfb
  CI job) mirror `../roost`.

## Repo-location decision (flagged for review)

`shed-gtk` lives as a new member of the existing `core/` workspace **inside shed-desktop**
for now — the least-sprawl option (no new repo), and a clean `git mv` into `shed` later. The
cost is real and handled: (1) it breaks Mac-side `--workspace` commands unless
`default-members` + `--exclude shed-gtk` are used (High-3 above); (2) the repo name is a
temporary mismatch (a Linux app crate under "shed-desktop") — note it in the README; (3) three
version numbers coexist (M5). If build isolation becomes awkward, a sibling `linux/` Cargo
workspace *inside this repo* is cleaner than a new repo. Alternative rejected for now:
extracting `core/` into its own repo (adds a publish/version burden the maintainer wants to
avoid until consolidation).

## Risks

- **macOS default flip** — the residual risks are exactly the deferred Phase-1 gates
  (byte-parity, perf) and arch; M0's blast radius is bounded to the shed-server HTTP path
  (approvals/RC/screenshot/notifications stay Swift regardless of the flag), so it can't
  regress the approval gate.
- **Building GTK from macOS** — mitigated by Docker + a shed + headless-harness verification
  (no GUI display needed).
- **Headless GL parity** — the real trap (see Dev environment): bare-runner mesa vs minimal
  container; resolved by base image + mesa + `GSK_RENDERER=cairo` fallback + a data-dump truth
  op instead of a screenshot gate.
- **`shed-core` on Linux** — low risk (pure cross-platform deps); `ring` needs
  `build-essential`; proven in M1 *before* GTK.
- **Async bridge** — the highest-risk GTK code; the panic-trap spec in M2 is the mitigation.
- **Scope** — a second client is large; milestones are independently committable and span
  multiple sessions.
