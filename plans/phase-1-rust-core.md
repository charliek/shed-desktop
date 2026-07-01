# Phase 1 — Rust protocol core behind a UniFFI bridge

Status: **panel-reviewed (Codex + Kimi K2.6 + CodeRabbit), revised, ready to implement**
Branch: `feat/rust-core`
Owner loop: every commit → `/simplify` → `/codex:rescue` (fallback `/cursor:rescue`) → `make test` (builds the core first) + `swift format lint` + `cargo clippy -- -D warnings` + `make e2e-ci` → commit. **Realism guardrail (per panel):** M0–M2 are reviewed before each lands (the FFI/callback boundaries are new); M3–M4 proceed autonomously only when the prior milestone is green and no unproven FFI boundary remains; **stop and report** if an FFI/threading boundary resists ~2 focused attempts, or on any destructive/ambiguous fork.

Extracts shed-desktop's networking/protocol logic into a reusable Rust core (a "shed client SDK") consumed by the Swift app now, a GTK app later (Phase 3), and eventually Flutter — eliminating the 4–5× duplication of the same protocol logic across Swift/Dart/TypeScript/Go. Phases 2 (approval spine) and 3 (GTK) are planned just-in-time after this lands.

---

## 1. Goal & scope (Phase 1 only)

Move the **read/write shed-server protocol client** and the **shed-server wire DTOs** into Rust, consumed by the macOS app via UniFFI behind a runtime flag, with **every existing test green** and **every IPC op behaviourally unchanged on the wire**.

**Port to Rust (wire DTOs only):** `Shed` (raw fields), `ServerInfo`, `SystemDiskUsage`/`DiskSize`/`DiskEntry`/`DiskTotals`, `ShedImage`, `EgressProfile`/`EgressProfileInfo`, `CreateShedRequest`, `ShedStatus`; the HTTP read client (`/api/info`, `/api/sheds`, `/api/system/df`, `/api/images`, `/api/egress/profiles` + host probe); lifecycle (start/stop/reset/delete); create-with-SSE; the control-token FSM; TLS leaf-cert pinning.

**Do NOT port (stays Swift):** `UIState`, `WindowMetrics`, `WindowState`, `CreateProgress`, `RcSession`/`RcKind`/`RcState`, `DashboardPane`, `ScreenshotSurface`, `ShedAction`, `ShedConfig` (YAML), and **all computed/display helpers** (`shortImageDigest`, `imageDisplay`, `imageLabel`, `shortRef`, `DateFormatting.parseFlexibleTimestamp`). These are IPC/UI/display concerns off the wire-decode path. *(Panel: model scope was too broad — `Models.swift` mixes wire DTOs with UI/IPC types.)*

Phase 0 (toolchain de-risk) is folded into **M0**, hardened to prove the *highest*-risk mechanisms up front.

## 2. Non-goals (deferred)

- Approval spine (Phase 2); GTK (Phase 3); host-agent absorption (Phase 4); Flutter (stretch).
- **Rust-default-on: NOT in Phase 1.** The flag ships **off**; Phase 1 ends at parity-green. Defaulting to Rust is a later phase after N-day dogfooding (and needs x86_64 — see §11).
- Deleting the Swift `Net/` path (stays behind the flag); moving IPC/screenshot/terminal/RC.
- x86_64 hardening beyond keeping the build green (arm64-first POC; universal is a tracked follow-up — `build-core.sh` documents the `lipo` path; Intel users stay on the Swift fallback until x86_64 lands).

## 3. The seam (exact anchors — verified against the code)

- **Construction site:** `AppModel.loadConfigAndClients()` (`Sources/ShedDesktopApp/AppModel.swift:367`) builds `clients: [String: ShedServerClient]`. In test mode it injects `mockBaseURL`, sets `pin = ""` and `provider = nil` (`:381`, `:391`).
- **SSE consumer:** `AppModel.startCreate()` (`:850`) does `for try await event in client.createShed(request)` → `CreateProgress`, polled by `createStatus(id)` (`:886`).
- **Wire types:** `Sources/ShedKit/Models/Models.swift` (double as IPC wire shapes).
- **Replaced logic:** `ShedServerClient`, `ControlTokenProvider`, `SSEClient` (parser), `CertPinning`.
- **The core is env-agnostic.** It never reads `SHED_DESKTOP_MOCK_BASE_URL`; base URL / pin / minter are **injected by `AppModel`**. Mock wiring stays in Swift. *(Corrects the earlier "Rust client honours MOCK_BASE_URL" claim — it does not.)*
- **Test-mode coverage caveat:** because test mode drops pin+provider, the hermetic e2e never exercises the Rust **TLS-pin or token-FSM** paths — those are covered **only by cargo tests**, which must therefore mirror the *full* fail-closed token suite + pin/redirect tests (§8 M3).

## 4. Architecture decisions (revised per panel)

**Boundary — one process-wide `ShedCore` engine, shared tokio runtime.** NOT one runtime per host: `AppModel.reconnect()` rebuilds `clients` on every `~/.shed/config.yaml` change and would leak a runtime per reload. Per-host config (base URL, pin, minter) is passed per call or held in a cheap value handle. Methods are `async` and return only **`Sendable` UniFFI records**. Commit: the `ShedCore` handle is safely `Sendable`; **no non-`Sendable` UniFFI handle crosses the IPC/`MainActor` boundary** (same rule the repo states for `UiBridge`).

**Async — `reqwest`(rustls) on the shared tokio runtime, via UniFFI async.** The sync-`ureq`-in-a-`Task` fallback is **rejected as a drop-in**: a blocking FFI call in a plain `Task` occupies a cooperative-pool thread for the whole round-trip and can starve the pool that drives the UI/IPC (the app fans out across hosts with `withThrowingTaskGroup`). Commit to async and **prove it in M0**.

**crate-type = `["staticlib"]` (explicitly NOT `cdylib`).** Most UniFFI examples default to `cdylib`, which produces a `.dylib` that then needs embedding+signing+notarization — exactly the risk we avoid. The xcframework wraps the **static** library. M0 asserts mechanically that no `.dylib`/`@rpath` for the core appears (`otool -L`). Build with `MACOSX_DEPLOYMENT_TARGET=14.0` to match `Package.swift`'s `.macOS(.v14)`.

**HTTP + TLS.** `reqwest` `default-features = false, features = ["rustls-tls", "stream"]`. Custom rustls `ServerCertVerifier` compares the leaf DER's SHA-256 as `sha256:<lowercase-hex>` (byte-for-byte with `CertPinning.swift` / the Go clients); **fail-closed** on pin+non-https; **https-only redirect policy** (mirrors `PinningSessionDelegate.willPerformHTTPRedirection` refusing plaintext redirects). Replicate URLSession's **timeouts (8s GET / 15s writes)** and set the User-Agent explicitly. Confirm the unpinned-https case cannot arise (self-signed servers always carry a pin) — otherwise reqwest+rustls (webpki-roots) makes different trust decisions than URLSession.

**SSE — pull-based, exact semantics, bounded, timed out.** Rust drives `response.bytes_stream()` on its runtime into an owned create-state; exposes `create_start(req) -> id` + `create_status(id) -> CreateProgress`(snapshot). Swift's `startCreate`/`createStatus` forward — matching the existing poll-based IPC. Preserve **exactly**: cross-chunk line buffering (`bytes_stream()` yields `Bytes`, not lines — frames split across TCP segments), blank-line dispatch, CR stripping, `:`-comments, multiline `data:`, EOF flush, lossy-UTF-8, raw-progress fallback, `error` event → `message ?? code ?? raw`, stream-ends-without-`complete` → `"stream ended before a complete event"`. Bound the buffer (≙ `bufferingNewest(256)`). Add **idle + overall timeouts** so `create_status` polling can't hang the overnight loop.

**Token — FSM in Rust; async `TokenMinter` callback in Swift** (wraps `HostAgentClient.requestToken`). De-risk the Swift→Rust callback in **M0**. Preserve auth exactly: mint failure → **no** token (never the static one — no secure-by-default downgrade); non-stream 401 → invalidate + retry once; **create path mints inline once and does NOT 401-retry**, still fail-closed. Callbacks must not mutate `AppModel` state from a tokio thread — the minter is a pure async request/response returning a value.

**Models — decode in Rust; map records → Swift `Models` in a private adapter.** `RustShedCoreAdapter.swift` owns the mapping; generated UniFFI types are **private** to it. Keep computed helpers, `Codable`/IPC conformance, and timestamp parsing in Swift. **Timestamps are carried verbatim as strings, never normalized** (Swift stores `created_at`/`started_at` as `String`, parses only for display; normalizing `…-05:00` → `…Z` would corrupt the wire value).

**Flag — runtime env `SHED_DESKTOP_RUST_CORE`,** read once in `ShedBackend.start(profile:)` (like `testMode`), default **off**, forwarded by `tools/shedtest/ui.py`, and **reported by `identify`** (additive `core: "rust"|"swift"` field — safe, mirrors how `test_mode` is reported) so the parity run *proves* the active backend. Do **not** globally flip the flag over the whole Swift unit suite: `ShedServerClientTokenTests`/`…EgressTests` use `URLProtocol` stubs that cannot intercept `reqwest`; Rust-path Swift tests use loopback HTTP servers instead.

## 5. Repo & build layout (roost conventions) + artifact ordering

```
core/
  Cargo.toml            # [workspace] members = ["shed-core","shed-core-ffi"]; shared lints; profiles
  rust-toolchain.toml   # channel = "stable" (avoid an exact-version re-download under the sandbox)
  fixtures/             # canonical wire-JSON fixtures shared by cargo + Swift adapter tests
  shed-core/            # PURE Rust lib (crate-type lib; staticlib comes from the ffi crate). GTK links this.
    src/{lib,models,http,sse,tls,token}.rs
    tests/
  shed-core-ffi/        # crate-type = ["staticlib"]; #[uniffi::export] over shed-core → Swift
    src/lib.rs
core/artifacts/         # generated ShedCoreFFI.xcframework + ShedCore.swift (gitignored)
scripts/build-core.sh   # cargo build (arm64) → uniffi-bindgen → static xcframework (staleness-gated)
```

Workspace `[workspace.package]` (edition 2021), `[workspace.lints]` (`unsafe_op_in_unsafe_fn`, `needless_collect`, `needless_pass_by_value` = warn), and release profile (`lto="thin"`, `codegen-units=1`, `strip`) mirror `../roost/Cargo.toml`. Deps proven to build here by the M0 spike: reqwest 0.12 (rustls), tokio, serde, uniffi 0.28, httpmock 0.7.

**Artifact ordering (panel — real gotcha).** `Package.swift`'s `.binaryTarget` points at the gitignored `core/artifacts/…xcframework`, so a bare `swift build`/`swift test` fails on a fresh checkout until `build-core.sh` runs. Fix: `Makefile` `build`/`test`/`bundle` depend on `core`; the owner loop uses `make test`/`make build` (never bare `swift`); **CI builds the core before any Swift step**; document that bare `swift build` needs `make core` first. (Alternative — commit a checksummed `.binaryTarget(url:checksum:)` — heavier, rejected for the POC.)

## 6. Packaging / signing (static proof; drop notarytool)

`scripts/bundle.sh` already ad-hoc-signs even debug with `--options runtime` (hardened runtime) + `Resources/ShedDesktop.entitlements`; `cs.disable-library-validation` is only for the ad-hoc Sparkle framework. A **staticlib linked into the `ShedDesktop` Mach-O adds no new signable artifact**. M0 asserts mechanically:

- crate is `crate-type = ["staticlib"]`;
- `otool -L Contents/MacOS/ShedDesktop` shows **no new dylib/@rpath** for the core;
- `lipo -info` arch matches the runner; `codesign --verify --deep --strict` clean; hardened-runtime flags unchanged; app launches; `make e2e-ci` green.

**Drop "notarytool dry-run"** (no real dry-run; it uses release credentials in `scripts/notarize.sh`). The structural proxies above prove notarization-safety; the actual notary submission is left to the user/release. rustls (ring/aws-lc-rs) needs no JIT/unsigned-memory entitlements — pure-Rust TLS avoids the system-OpenSSL/notarization mess.

## 7. Files created / modified

**Created (Rust):** `core/Cargo.toml`, `core/rust-toolchain.toml`, `core/fixtures/*.json`, `core/shed-core/{Cargo.toml, src/{lib,models,http,sse,tls,token}.rs, tests/*}`, `core/shed-core-ffi/{Cargo.toml, src/lib.rs}`, `scripts/build-core.sh`, `docs/reference/rust-core.md`.
**Created (Swift):** `Sources/ShedKit/Net/RustShedCoreAdapter.swift` (private mapping), `Tests/ShedKitTests/RustCoreFFISmokeTests.swift` (M0 canary), `Tests/ShedKitTests/RustCoreParityTests.swift` (golden-JSON equivalence).
**Created (generated → gitignored):** `core/artifacts/ShedCoreFFI.xcframework`, `core/artifacts/ShedCore.swift`.
**Modified:** `Package.swift` (binaryTarget + `ShedCore` target + `ShedKit` dep); `Makefile` (`core*` targets; `build`/`test`/`bundle` depend on `core`); `scripts/bundle.sh` (build core first); `.gitignore` (`core/target/`, `core/artifacts/`); `.github/workflows/ci.yml` (rustup bootstrap + core-before-swift + both-backend e2e); `Sources/ShedKit/Net/ShedServerClient.swift` (flag-gated adapter); `Sources/ShedDesktopApp/IPCHandlerImpl.swift` (`identify` gains `core`); `tools/shedtest/ui.py` (forward `SHED_DESKTOP_RUST_CORE`); `tools/shedtest/mockserver.py` (add `/api/egress/profiles`); `docs/reference/{architecture,ipc}.md`.
**Unchanged — must stay green:** the IPC layer (`Sources/ShedKit/IPC/*`, most of `IPCHandlerImpl.swift`), all **37 IPC ops**' wire behaviour, the other 18 unit-test suites, `tools/shedtest/*` assertions.

## 8. Milestones (each = one or more reviewed commits)

**M0 — De-risk gate (GO/NO-GO). Front-loads the hard mechanisms.**
Scaffold `core/` workspace. `shed-core` gets a **real** async fn returning a record + typed error, a pull-based streaming create-state, and an **async `TokenMinter` callback**; exercise **cancellation**. `shed-core-ffi` (`staticlib`) exports them; `build-core.sh` generates Swift + a static xcframework and asserts no dylib. Wire `Package.swift` + `ShedCore` + adapter + Makefile/CI ordering. `identify` gains `core`.
- **Canary:** `RustCoreFFISmokeTests.swift` under `-strict-concurrency=complete` constructs `ShedCore`, calls the async fn, drives the callback, and cancels — proving async-FFI + `Sendable` + callbacks + cancellation. **No new IPC op** (the canary is a unit test).
- **M0a (CI gate, automatable):** `make core` + `make test` + `make bundle` + `otool`/`lipo`/`codesign --verify --deep --strict` + launch + `make e2e-ci` green.
- **M0b (manual, tracked, NOT a CI gate):** notarytool with the user's release creds.
- **If static-link/async-FFI can't be made to work in ~2 focused attempts → STOP and report.**

**M1 — DTO models port + invariants + equivalence.** Rust records + serde with the **exact** invariants: `{"sheds": null}` and omitted both → `[]` (`Option<Vec<_>>` + `unwrap_or_default()`, *not* `#[serde(default)] Vec` which errors on explicit null); `host` stamped post-decode in **both** the list path and the SSE-`complete` path; `ShedStatus` needs **both** `#[serde(default)]` (absent→unknown) **and** `#[serde(other)]` (unknown value→unknown); `"?"` name sentinels for `ShedImage`/`DiskEntry`; `?? 0/false/[]` disk defaults; timestamps carried **verbatim**. Canonical fixtures in `core/fixtures/`. **Equivalence test** (the anti-regression backbone): for every fixture, `RustCore.decode→map` produces a Swift `Model` **byte-equal** to `JSONDecoder.decode` of the same bytes. cargo tests mirror `ModelDecodingTests` line-for-line.

**M2 — Read client + shared transport (incl. the 401 shell) + parity harness.** `info`/`listSheds`/`systemDF`/`listImages`/`egressProfiles`; build the **shared transport** with timeouts + https-only-redirect + UA **and the 401→invalidate→retry-once shell using a no-op minter now** (so M3 doesn't re-touch it); `ShedClientError` parity. Add `/api/egress/profiles` to `mockserver.py`. Forward the flag in `ui.py`; assert `core=rust` via `identify`. **Golden-JSON cross-backend diff** for `ui.state`/`sheds.list`/`system.df`/`images.list` under both flags against the same fixtures. e2e flag-on green.

**M3 — TLS pin + token FSM (cargo-covered — no e2e reach).** rustls leaf pin + **redirect tests** (https-only); async `TokenMinter`; `ControlTokenProvider` FSM (single-flight, refresh window, invalidate). cargo mirrors the **full fail-closed token suite** — `mint-failure → no token, never static` and the same **through the retry** — plus `CertPinningTests` and the 401-remint-retry. (Test mode is unpinned/tokenless, so cargo is the *sole* guard here.)

**M4 — Lifecycle + SSE create (pull-based).** start/stop/reset/delete; `create_start`/`create_status`; **fragmented-frame SSE tests** (split mid-line and mid-blank-line across chunks); create-path no-retry + fail-closed; terminal semantics; idle/overall timeout. `test_lifecycle.py` create-streams-to-complete green flag-on.

**M5 — Phase 1 checkpoint (flag stays OFF).** Parity CI matrix green (both backends + golden-diff); **budgets:** release `.app` grows ≤ 4 MB and cold-launch delta ≤ 200 ms (else pause + re-evaluate); docs (`architecture.md` diagram, new `rust-core.md`, README Rust prereq); explicitly **accept** the dual-implementation + doubled macOS CI (billed 10×) + Intel-on-Swift steady state, with a "bake-then-delete Swift `Net/`" trigger noted for a later phase.

## 9. Test strategy

- **Golden-JSON equivalence** is the backbone (`e2e green both flags` alone can pass while a field the harness doesn't assert — `image_digest`, `active_namespaces`, `started_at`, `last_error` — differs, or while it silently fell back to Swift).
- cargo mirrors every ported decoder/FSM incl. **fail-closed token** cases and **fragmented SSE**; Swift decoder tests become adapter contract tests.
- Backend is **observable** (`identify.core`) and asserted on the flag-on leg; the flag is **forwarded** by `ui.py`.
- Don't globally flip the flag over `URLProtocol`-based unit tests; Rust-path Swift tests use loopback servers.
- Fixtures are canonical in `core/fixtures/`; a CI check keeps the Swift/Rust fixture sets identical (single source or hash-parity).
- Denominator (verified): **19 suites / 117 Swift test fns; 64 pytest fns; 37 IPC ops (~10 backend-sensitive).**

## 10. Definition of done (executable)

1. `make test` (19 suites / 117 fns) green — core built first.
2. `cargo test` green; `cargo clippy -- -D warnings` clean; `swift format lint` clean (generated `ShedCore.swift` excluded).
3. `make e2e-ci` green with `SHED_DESKTOP_RUST_CORE` **unset and =1**, `identify` asserting `core=rust` on the flag-on leg.
4. **Golden-JSON cross-backend diff clean** for the backend-sensitive read ops.
5. Named smokes green: `smoke-real-launch` + `smoke-launch-window`.
6. **Static proof:** crate-type staticlib; `otool -L` no new dylib; `codesign --verify --deep --strict`; hardened-runtime unchanged; app launches.
7. Binary-size + cold-launch budgets met or explicitly waived.
8. Docs updated; CI builds Rust (rustup) before Swift and runs the parity matrix.
   *(M0b notarytool is tracked separately — not a CI gate.)*

## 11. Risks & steady-state costs

| Risk | Mitigation |
|---|---|
| async-over-FFI / cancellation / callbacks | **Front-loaded to M0** (real async + callback + cancellation canary under strict concurrency). |
| staticlib vs cdylib (notarization) | `crate-type=["staticlib"]`; mechanical `otool`/`codesign` M0 check. |
| SSE cross-chunk framing | reqwest `Bytes` stream → re-implement line buffering; fragmented-frame tests. |
| `Sendable` / tokio-runtime leak | Single shared runtime; `Sendable` handle; no handle across the IPC boundary. |
| Silent wire drift (triple representation) | Golden-JSON equivalence per fixture (not "mirror tests"). |
| Transport-default drift (timeouts/UA/redirects) | Replicate 8s/15s timeouts + https-only redirects; explicit UA. |
| CI cost / dual maintenance / Intel | Named + accepted for Phase 1; flag stays off; Intel on Swift until x86_64. |

## 12. Open questions — resolved

Async (commit); staticlib (yes); map-at-adapter (yes — converge Rust/Swift models only at Phase 4); runtime flag + `identify.core` (yes); UniFFI isolated in `shed-core-ffi` (yes); single shared runtime, per-host config passed per call (yes). **Residual to ratify:** exact size/launch budgets (4 MB / 200 ms proposed); single-source vs hash-check for shared fixtures.
