# Rust core (`shed-core`)

The shed-server protocol client — HTTP + SSE, control-token auth, TLS pinning,
and the wire DTOs — lives in a shared Rust core under `core/`, so the same logic
backs the macOS app today and a GTK app (and eventually Flutter) without being
re-implemented per language. See `plans/phase-1-rust-core.md` for the plan and
its panel review.

## Layout

A cargo workspace under `core/` (conventions mirror `../roost`):

- **`shed-core`** — a *pure* Rust lib (no UniFFI): wire DTOs + serde decoders
  (`models.rs`), the reqwest(rustls) client (`http.rs`), the SSE parser
  (`sse.rs`), leaf-cert pinning (`tls.rs`), and the control-token FSM
  (`token.rs`). A future GTK app links this crate directly.
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

The flag is **off by default** — Phase 1 ships the core alongside the Swift path
for parity, not as the default. CI runs the e2e suite against *both* backends;
the Rust leg asserts `identify.core=rust`, so a silent fallback to Swift fails
the run rather than passing falsely.

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
and the control-token FSM. Deferred: absorbing the approval subsystem (Phase 2),
a GTK front-end on the same core (Phase 3), a byte-level golden-JSON cross-backend
diff, and a release binary-size/cold-launch budget check.
