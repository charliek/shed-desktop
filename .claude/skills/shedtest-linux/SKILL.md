---
name: shedtest-linux
description: Run shed-desktop's GTK (shed-gtk) Linux tests from a Mac inside a shed VM. shed-gtk is the Rust/GTK4 Linux sibling of the macOS app, built on the shared shed-core crate; it cannot build or run on macOS, so a shed (Apple VZ Linux microVM with a real Ubuntu kernel) is the local loop — edit on the Mac, build+test in the VM. Use when asked to build/run/verify shed-gtk, the GTK e2e suite, or the Linux build of shed-core locally on a Mac (vs. only on CI). For running the same tests on a native Linux box, see the popos-test pattern in ../roost; for the macOS app's own tests, see shedtest-mac.
---

# Linux (GTK) testing on a Mac, via a shed

shed-desktop is growing a Rust + GTK4 Linux client (`core/shed-gtk`) on the same
`shed-core` crate the macOS app uses (see `plans/phase-2-rust-clients.md`). GTK4
+ libadwaita + the Xvfb pytest loop only run on Linux. A **shed** is an Apple VZ
Linux microVM with a real Ubuntu kernel, so it builds and drives the GTK app; the
repo is mounted via VirtioFS (`--local-dir`), so you edit on the Mac and
build+test in the VM.

> **Simpler than roost's `linux-test`.** shed-gtk is a *dashboard*: X11/Xvfb only.
> It has no libghostty-vt (no zig) and no terminal pointer-drag, so this loop
> drops roost's ghostty build and its cage/seatd/weston/`uinput` tier. Because it
> needs no `uinput`, Docker could also run the GTK e2e — but a shed gives a real
> GTK4 environment and matches the ecosystem loop.

## Status (Phase 2)

- **The create→provision→mount→build spine is validated end-to-end.**
  `SHED_BUILD_PKG=shed-core tools/shed/shed-test.sh --build-only` provisioned a
  fresh `sd-gtk-dev`, mounted the repo at `~/shed-desktop`, and built `shed-core`
  shed-local at `~/sdt` — the Mac `core/target/` untouched. (`shed-core` itself:
  51 tests pass + clippy clean on aarch64 Linux, via Docker and the shed.) Re-run
  that smoke anytime with the same command.
- **`shed-gtk` + `tools/shedgtktest`: built in Phase 2 (M2–M3).** The wrapper below
  targets them; until they land, use the `SHED_BUILD_PKG=shed-core` smoke. **Keep
  this file updated as the GTK loop lands and you hit real gotchas** (the roost
  `linux-test` skill exists because each trap saved the next session an hour).

## Prerequisites

- `shed` CLI installed + a shed-server online (`shed server list` shows `online`;
  the default `localmac-dev` is an Apple VZ server on this Mac). If shed isn't set
  up, see the `shed` skill / the ../shed macOS quickstart, and stop + tell the user.
- macOS / Apple Silicon.

## Run it (one wrapper)

`tools/shed/shed-test.sh` provisions on first use (via `.shed/provision.yaml` →
`.shed/scripts/install.sh`) and builds **shed-local** so your Mac `core/target/`
is never clobbered (the mount is a different arch). Run it from the repo root. The
persistent `sd-gtk-dev` box IS the day-to-day cache (stop/start reuses its build
cache); the **snapshot is opt-in** — a bare run does NOT auto-snapshot, so run
`--snapshot-base` once if you want fast cold re-creates after a teardown:

```bash
tools/shed/shed-test.sh                 # ensure box, build shed-gtk, run the GTK e2e
tools/shed/shed-test.sh --build-only    # just build in the shed
tools/shed/shed-test.sh --shell         # drop into the dev shed (repo at ~/shed-desktop)
tools/shed/shed-test.sh --snapshot-base # cache the provisioned box for fast future boots
tools/shed/shed-test.sh --reprovision   # rebuild box + snapshot from scratch
tools/shed/shed-test.sh --stop          # stop the VM when done (it's a heavy env)

# Before shed-gtk exists, smoke the whole loop against the pure core:
SHED_BUILD_PKG=shed-core tools/shed/shed-test.sh --build-only
```

## The three knobs that each cost a debugging cycle (carried from roost)

The `run_e2e` step in `shed-test.sh` sets these; if you drive the harness by hand,
you need them too:

- **`XDG_RUNTIME_DIR` must be a fresh dir** (the wrapper uses `/tmp/sdt-xdg`).
  The GTK app puts its IPC socket at `$XDG_RUNTIME_DIR/shed-gtk/shed-gtk.sock`
  (with a `/tmp/shed-gtk-$uid` fallback); if unset, the UI uses the fallback but
  the harness looks at the `$XDG_RUNTIME_DIR` path → `wait_alive` times out. The
  #1 trap in roost's loop.
- **`GDK_BACKEND=x11`** (matches CI). Without it GTK4 hits the libEGL/DRI3 path
  under Xvfb and the UI never becomes ready. If the GL renderer still misbehaves
  in a lean box, add `GSK_RENDERER=cairo`.
- **system `python3 -m pytest`** — there is no `uv` in the shed (CI uses `uv run`).
  `.shed/scripts/install.sh` installs `python3-pytest`.

## Hermeticity (mirror the macOS harness)

The GTK e2e must be hermetic like the Mac one (`tools/shedtest/conftest.py` passes
**both** a mock base URL and a fixture config): set `SHED_GTK_MOCK_BASE_URL`
(redirect hosts to the in-shed Python mock, reusing `tools/shedtest/mockserver.py`)
**and** `SHED_GTK_SHED_CONFIG` (point at `tools/shedtest/fixtures/config.yaml`, so
there's a host list) — never fall back to the real `~/.shed/config.yaml`.
`wait_alive` should assert `identify` echoes `platform=gtk`, `core=rust`, and the
mock base URL.

## Visual screenshot on real Linux

The GTK `screenshot` op renders the window's own `GskRenderer` to PNG bytes
in-process (like roost's `render_window_png` — no OS capture), so it works
headless. To eyeball the *real* Linux render from the Mac: launch the shed binary
under Xvfb, drive it to a `screenshot --out ~/shed-desktop/core/target/.shot.png`
(the mount is gitignored under `core/target`), and open it on the Mac. GTK chrome
differs Linux↔macOS, so this is the way to see the true Linux look.

## How it works (so you can debug it)

- **`.shed/provision.yaml`** → **`.shed/scripts/install.sh`** — one-time: apt GTK4
  + libadwaita + pkg-config + `build-essential` (for `ring`) + `libgl1-mesa-dri`
  (headless GL) + Xvfb + `python3-pytest`, and Rust via rustup. No `startup` hook
  (no uinput/seat perms to open).
- **`tools/shed/build-in-shed.sh`** — points `CARGO_TARGET_DIR` at a shed-local dir
  (`~/sdt`) so the Linux build never touches the macOS artifacts in the mount, and
  `cargo build -p shed-gtk` (or `$SHED_BUILD_PKG`). The harness reads `SHED_GTK_BIN`
  (`~/sdt/debug/shed-desktop`) to find the shed-local binary.
- **Box model:** a long-lived `sd-gtk-dev` shed + a `sd-gtk-base` snapshot cache.
  Treat both as a *cache* — a shed upgrade may invalidate them; `--reprovision`
  (or delete both) and re-run. The snapshot boots a fresh box in seconds instead
  of re-running the install hook. Default upper layer is small; the wrapper asks
  for `--upper-size 20G` (apt + cargo target need room).

## Gotchas

- First provision + first build are slow (apt + a cold cargo build under
  VirtioFS); the snapshot + shed-local cargo cache make repeat runs fast.
- `shed exec` runs `bash -lc` (login PATH, so rustup's `~/.cargo/bin` is on PATH).
- Piping a hung test through `| tail` loses its output (Python buffers stdout off
  a tty; a kill drops the buffer). Use `python3 -u … > file 2>&1` when the thing
  you're testing might hang.
- If the GTK build fails on a missing system lib, add it to
  `.shed/scripts/install.sh` and `--reprovision` (or `apt-get install` it in a
  `--shell` and re-snapshot).
