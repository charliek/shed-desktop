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
  store. The `shed-gtk` GTK/Linux client links this crate directly (no UniFFI).
- **`shed-core-ffi`** — a thin UniFFI wrapper (`crate-type = ["staticlib"]`)
  exposing a `ShedCore` object + records to Swift. `scripts/build-core.sh` builds
  it, runs `uniffi-bindgen`, and assembles a **static** `ShedCoreFFI.xcframework`
  linked into the app's Mach-O — no new dylib, so the release
  signing/notarization path is unaffected.

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
`plans/phase-2-rust-clients.md`). Deferred: the GTK approval pane (M6) and
absorbing/rewriting the credential broker in Rust (the final consolidation).
