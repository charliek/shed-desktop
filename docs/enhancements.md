# Known enhancements & QoL backlog

A running backlog of smaller quality-of-life and improvement deferrals — things too small to
be roadmap *directions* but worth not losing. It holds **only open work**: what has shipped
is recorded in the phase plans (`plans/`) and the [roadmap](roadmap.md), not here, and the
batched "delete-the-Swift-path" cleanups live in `plans/phase-4-rust-core-only.md`.

**How to add:** append a row in the right category with a Value/Effort estimate.

**Legend** — **Value:** High / Med / Low. **Effort:** XS / S / M / L.

## Rust core & parity

| Item | Value | Effort | Description |
|---|---|---|---|
| Generalize the golden-JSON cross-backend diff | Low | S | Extend beyond M0's set to *all* backend-sensitive IPC payloads, as a standing parity guard. |
| Full pinned-HTTPS handshake integration test | Low | M | A local rustls server + an `rcgen` self-signed cert, hit through a pinned `Client`. The pin *decision* + the redirect policy are already unit-tested. |
| Non-numeric `http_port` — validate vs silently default to 8080 | Med | S | `config.rs` — decide validate-vs-default, then test. |
| Explicit-null shed `name` decode — error vs `"?"` sentinel | Low | S | `models.rs` — decide error-vs-sentinel, then test. |

## CI & build

| Item | Value | Effort | Description |
|---|---|---|---|
| Release-bundle size gate in CI | Low | S | Today only `make m0-gates` enforces release size (pre-ship); fold a release-bundle size check into per-PR CI. |
| Harden the flaky Swift-fallback e2e leg | Med | S | The `SHED_DESKTOP_RUST_CORE=0` leg occasionally flakes under CI load; resolves when that path is removed in Phase 4. |

## Tauri / Linux client

| Item | Value | Effort | Description |
|---|---|---|---|
| Native-Linux test skill | Low | S | A shed-desktop analog of roost's `popos-test` (run the Tauri suite directly on a Linux box, no shed). |

## Testing (P3.7 audit follow-ups)

| Item | Value | Effort | Description |
|---|---|---|---|
| Oversized/malformed IPC frame test | Med | M | Target-divergent: mac 16 MiB / parse-error vs the Linux client's 1 MiB / `bad_request`; needs raw-socket harness plumbing. |
| `dashboard.dump` before first render → `[]` | Low | S | Racy — no deterministic pre-render signal to wait on. |
| `single_instance` Io-branch + `XDG_RUNTIME_DIR`-unset fallback | Low | S | Hard to trigger a non-`WouldBlock` flock error deterministically. |
| create stream does-not-401-retry assertion | Low | S | Pin the no-downgrade guarantee (create mints once, never retries on 401). |
| `create.start` best-effort UI-notify when the receiver is dropped | Low | S | Cover the path where the `create.start` reply receiver is already gone. |
