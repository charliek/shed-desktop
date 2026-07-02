#!/usr/bin/env bash
# One-time provisioning for shed-desktop's shed-gtk Linux test loop (runs ONCE
# per shed; the shed records it). Installs the GTK4 stack, headless GL
# (Xvfb + llvmpipe), pytest, and a Rust toolchain.
#
# No cage/seatd/weston/uinput: shed-gtk is X11/Xvfb-only (a dashboard), unlike
# roost's terminal which also needs the Wayland pointer-drag (uinput) tier.
set -euo pipefail
log() { printf '[install] %s\n' "$*"; }

export DEBIAN_FRONTEND=noninteractive
log "apt: GTK4 + libadwaita + build deps + headless GL + Xvfb + pytest"
sudo apt-get update -y
sudo apt-get install -y \
  libgtk-4-dev libadwaita-1-dev pkg-config \
  build-essential libgl1-mesa-dri \
  xvfb python3 python3-pytest ca-certificates curl

# Rust via rustup (stable >= the workspace MSRV). The shed image may not ship
# cargo; `rustup -y` appends ~/.cargo/env to the shell rc, so `shed exec bash
# -lc` (a login shell) picks it up on the next command.
if ! command -v cargo >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
  log "installing Rust (rustup, minimal, stable)"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
fi
log "done"
