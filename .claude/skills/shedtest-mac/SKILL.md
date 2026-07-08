---
name: shedtest-mac
description: Run and debug shed-desktop's macOS app end-to-end tests — the hermetic pytest harness that drives the real app over its IPC socket and captures in-process screenshots, plus the Swift unit tests and the Rust-core parity leg. Use when asked to run the Mac tests, verify a UI/behavior change by driving the app, debug an e2e failure, add a harness test, or check screenshot/IPC ops. The Linux client is the Tauri app; its render gate is `make tauri-build-linux` (WebKitGTK in Docker), and the shipped Linux `.deb` is built from it.
---

# macOS app end-to-end + unit tests

shed-desktop's north star is that the app is **drivable and observable by an
agent**: every change is verified by launching the real app and driving it over
the IPC socket (and reading in-process screenshots), not by asking a human to
click. This skill is that loop.

## The fast path

```bash
make build            # Rust core (xcframework) + swift build — run before bare swift build/test
make test             # Swift unit tests (ShedKit) + the Rust FFI canary
make e2e-ci           # hermetic e2e: bundles the app, TEST_MODE + in-process mock, fresh
```

- **`make e2e-ci`** is CI parity and the one to trust: it sets
  `SHED_DESKTOP_TEST_MODE=1` and points every HTTP client at an **in-process mock
  shed-server** (`tools/shedtest/mockserver.py`), so no real shed-server is
  touched. `identify` is checked up front to confirm hermeticity.
- **`make e2e`** drives a running/auto-launched app for quick local iteration.
- The harness lives in `tools/shedtest/` (pytest); it speaks the same JSON IPC
  protocol as `shedctl`.

## Driving the app by hand (shedctl)

The bundle ships the CLI driver at
`build/ShedDesktop.app/Contents/Resources/bin/shedctl`:

```bash
make run                                                   # build + launch the bundle
build/ShedDesktop.app/Contents/Resources/bin/shedctl ui show-window
build/ShedDesktop.app/Contents/Resources/bin/shedctl screenshot --surface window --out /tmp/s.png
build/ShedDesktop.app/Contents/Resources/bin/shedctl sheds list
```

The screenshot op renders in-process (no screen-recording TCC grant needed), so
it works headless in CI.

## Conventions that keep the harness reliable

- **Condition-waits, never sleeps.** Use `wait_until` / `wait_alive` (readiness is
  gated on the app answering, not on a timer).
- **Hermetic.** The harness launches the app with `SHED_DESKTOP_TEST_MODE=1` +
  `SHED_DESKTOP_MOCK_BASE_URL` so all HTTP hits the in-process mock. Never point a
  test at a real server. Fixtures live in `tools/shedtest/fixtures/`.
- **New UI ⇒ new IPC op + harness coverage.** When you add UI or behavior, add the
  IPC op that lets an agent observe/drive it, and a pytest that exercises it. That
  is the definition of done here, not a manual click-through.

## Rust-core parity leg

The shed-server protocol path can run through the shared Rust core
(`SHED_DESKTOP_RUST_CORE`). `identify.core` reports `rust|swift`, and `wait_alive`
asserts it, so a silent fallback fails the run rather than passing falsely:

```bash
# run the same hermetic suite through the Rust core (Phase 2 makes this the default):
SHED_DESKTOP_RUST_CORE=1 make e2e-ci
# force the legacy Swift URLSession path (rollback escape hatch):
SHED_DESKTOP_RUST_CORE=0 make e2e-ci
```

If a run reports `identify.core=rust` but a host silently fell back to Swift,
that's a bug to fix (adapter construction must fail loudly, not `try?` away) — see
`plans/phase-2-rust-clients.md` M0.

## Real-launch smokes (the paths the hermetic suite gates off)

```bash
make smoke-real-launch    # non-test launch survival (real notification path; issue #2)
make smoke-launch-window  # user launch opens the dashboard; reopen reaches it (issue #4)
make smoke                # drive the app + capture labeled screenshots
```

## Gotchas

- Run `make build` (or `make core`) before a bare `swift build`/`swift test` — the
  Swift package links a static xcframework generated from the Rust core, so that
  path must exist first. `bundle.sh` / `make e2e-ci` build it themselves.
- Do **not** run `swift format -i` on the whole tree reflexively — match the
  existing 4-space style; formatting churn muddies review.
- The control socket + lock live under `~/Library/Caches/ShedDesktop/` and are NOT
  moved by `SHED_DESKTOP_STATE_DIR`, so the harness + a dev session agree on them.
