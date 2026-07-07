# Rust core (`shed-core`)

The shed-server protocol client — HTTP + SSE, control-token auth, TLS pinning,
and the wire DTOs — lives in a shared Rust core under `core/`, so the same logic
backs both the macOS app and the GTK/Linux client (`shed-gtk`) today (Flutter
later) without being re-implemented per language. See `plans/phase-1-rust-core.md`
and `plans/phase-2-rust-clients.md` for the plans + panel reviews.

## Layout

A cargo workspace under `core/` (conventions mirror `../roost`):

- **`shed-core`** — a *pure* Rust lib (no UniFFI): wire DTOs + serde decoders
  (`models.rs`), the reqwest(rustls) client (`http.rs`), the SSE parser
  (`sse.rs`), leaf-cert pinning (`tls.rs`), and the control-token FSM
  (`token.rs`), plus a `config` parser and a pull-based `create` orchestration
  store — and now **`rc.rs`** (pure Remote-Control: the pane classifier, the
  `shed-ext-rc` + non-interactive SSH argv builders, and the wire DTOs). The Linux
  clients (`shed-gtk`, `shedctl`) link this crate directly (no UniFFI).
- **`shed-core-ffi`** — a thin UniFFI wrapper (`crate-type = ["staticlib"]`)
  exposing a `ShedCore` object + records to Swift. `scripts/build-core.sh` builds
  it, runs `uniffi-bindgen`, and assembles a **static** `ShedCoreFFI.xcframework`
  linked into the app's Mach-O — no new dylib, so the release
  signing/notarization path is unaffected.
- **`shed-app`** — the UI-free app-logic layer (`Backend`), a workspace
  default-member; consumed by `shed-gtk` and (as a cross-workspace path dep) the
  Tauri client. Holds the **`RcRunner` portability seam** (`rc.rs`, behind the
  non-default `rc = ["tokio/process"]` feature) — the trait where a future mobile
  in-process-SSH runner replaces the desktop subprocess runner, so one
  `RcService` serves every frontend.
- **`shed-gtk`** — the GTK4/libadwaita **Linux client**. Its `[[bin]]` is renamed to
  **`shed-desktop`** — the shipped Linux binary and the `.deb` package name (the crate keeps
  the name `shed-gtk`; the socket/env stay `SHED_GTK_*`). A second launch hands off to the
  running instance via an `app.activate` IPC op guarded by a single-instance flock. Excluded
  from `default-members`, so the Mac build never touches GTK.
- **`shedctl`** — a headless UDS/IPC client (no GTK dep) shipped in the `.deb` alongside
  `shed-desktop`, mirroring the macOS Swift `shedctl`. It *is* in `default-members`, so `make
  core-test`/`core-lint` cover it on the Mac.
- **Tauri client** — *not* a `core/` workspace member, but a consumer:
  `tauri/src-tauri` is its own standalone cargo workspace that takes `shed-core` +
  `shed-app` as cross-workspace **path deps** (the cross-platform desktop client —
  see `plans/tauri-phase-{a,b,c}.md`).

`make core` builds it; `make build` / `make bundle` / CI build it before any
SwiftPM step (the `.binaryTarget` path must exist first). The generated artifacts
under `core/artifacts/` are gitignored.

## How the Swift app uses it

`ShedServerClient` (ShedKit) delegates to the core when `SHED_DESKTOP_RUST_CORE=1`
and otherwise keeps its existing `URLSession` path. `RustShedCoreAdapter` maps the
Rust records to the app's Swift `Models` (which double as the IPC wire shapes),
so every IPC op stays byte-unchanged. `identify` reports `core: rust|swift`.

The Rust core is the macOS **default** (Phase 2 M0); `SHED_DESKTOP_RUST_CORE=0`
forces the Swift path (a rollback escape hatch kept ≥2 releases). A per-host
adapter-construction failure fails **loudly** rather than silently downgrading. CI
runs the e2e suite on the default (rust) plus a `=0` Swift-fallback leg, and a
golden-JSON cross-backend byte-diff guards parity; `identify.core` reports which
backend is active.

## Invariants preserved (parity with the Swift client)

- **Defensive decoding**: `{"sheds": null}` → `[]`, omitted optionals, lenient
  `ShedStatus`, `"?"` name sentinels, and timestamps carried verbatim (parsing
  stays in Swift).
- **Auth, fail-closed**: a provider mint failure sends **no** token (never the
  static one — no secure-by-default downgrade); a 401 invalidates + retries once
  (provider-backed only); create mints once with no retry.
- **TLS**: leaf SHA-256 pin (`sha256:<lowercase-hex>`), fail-closed on a
  non-`https://` URL.
- **SSE create**: cross-chunk framing, and the `error` / stream-ended-without-
  `complete` terminal semantics.

## Building & testing

```bash
make core            # build the staticlib + regenerate the xcframework
make core-test       # cargo test the workspace
make core-lint       # cargo clippy -D warnings
make test            # swift tests (builds the core first)
SHED_DESKTOP_RUST_CORE=1 make e2e-ci   # the hermetic e2e with the Rust backend
```

Rust changes need `cargo`/`rustup` (the workspace pins the channel in
`core/rust-toolchain.toml`).

## Status & scope

Phase 1 (this core) covers the read client, lifecycle, SSE create, TLS pinning,
and the control-token FSM. Phase 2 (done) made it the macOS default (with a
golden-JSON cross-backend byte-diff + a size/cold-launch budget), got `shed-core`
building/testing on **Linux**, hoisted the create orchestration + a `config` parser
into it, and stood up the **`shed-gtk`** GTK/Linux client on the same crate (see
`plans/phase-2-rust-clients.md`). Phase 3 (done) shipped the `shed-desktop` `.deb` via
`charliek/apt-charliek` (`apt install shed-desktop`) with a bundled `shedctl`, unified the
macOS + Linux functional suites into one `tools/shedtest --target mac|gtk` harness (the
earlier separate GTK harness retired), and hardened GTK (single-instance handoff, parallel
multi-host fetches); the release pipeline is `create-release → mac + linux → apt-charliek
dispatch` (see `RELEASING.md` and `plans/phase-3-enhancements.md`). Deferred to
`plans/phase-4-rust-core-only.md`: retiring the Swift `URLSession` path + unifying config via
the FFI. Still deferred: the GTK approval pane (M6) and absorbing/rewriting the credential
broker in Rust (the final consolidation). A Tauri cross-platform client (`tauri/`) is now
built on `shed-core` + `shed-app` — Phases A (read/lifecycle/create) + B (the approval spine)
are merged; Phase C (tray, the Agents/RC pane, mac parity, hardening) is in progress on
`tauri-phase-c`. See `plans/tauri-phase-{a,b,c}.md`.
