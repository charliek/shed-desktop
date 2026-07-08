# Phase 4 — Swift on the Rust core only

Status: **stub / not yet scheduled.** Deferred from Phase 3 (locked decision #3). Do this
**after** the Rust core has shipped as the macOS default for **≥ 2 releases** — i.e. once the
`SHED_DESKTOP_RUST_CORE=0` rollback window has closed.

Branch: **`feat/rust-core`** (single branch, as with Phase 1/2/3) unless the maintainer says
otherwise.

## Why this phase

Phases 1–3 stood the shared Rust core up as the macOS **default**, built a GTK/Linux client
on it, and shipped the `.deb`. Two Swift implementations now shadow the Rust core purely as a
rollback hedge. Both are "delete a Swift impl, rely on Rust" — so they batch into one phase,
run once the rollback window closes and the risk of needing the Swift path back is gone.

## Items

### (a) Retire the Swift `URLSession` path

Remove the legacy Swift `URLSession` client that `ShedServerClient` falls back to, the
`SHED_DESKTOP_RUST_CORE=0` escape hatch, and the `=0` Swift-fallback e2e leg in CI. The Rust
core becomes the *only* backend on macOS.

- Resolves the **"Harden the flaky Swift-fallback e2e leg"** backlog item (the flaky leg is
  deleted, not hardened).
- `identify.core` collapses to always `rust` on macOS; the golden cross-backend diff has
  nothing left to compare and retires with the Swift path.

### (b) Unify config discovery via the FFI

Retire the Swift `ShedConfig` parser and route the macOS app's host discovery through the
Rust `shed-core` `config` module over the FFI, so `~/.shed/config.yaml` has a **single**
parser instead of two.

- The cross-language parity test (Swift `ShedConfig` vs Rust `config`) **guards the two
  parsers until the switch**, then retires with the Swift one.

## Gating & sequencing

- **Precondition:** the Rust default has shipped for ≥ 2 releases with no rollback needed.
- Each item is independently shippable; keep every commit green + drivable (an IPC op +
  harness coverage for any behavior change), per the standing conventions.
- **Hard constraints carried forward:** `shed-core` stays pure (no UniFFI/SwiftUI); Swift 6
  strict concurrency; never run real notarization or touch `.secrets/apple.env`; never cut a
  real release tag autonomously.

## Not in scope (still their own tracks)

- The GTK approval pane (M6, after the Flutter spike — see `docs/roadmap.md`).
- Absorbing / rewriting the credential broker in Rust (the final consolidation — roadmap).
