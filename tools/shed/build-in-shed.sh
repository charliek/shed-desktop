#!/usr/bin/env bash
# Build shed-gtk INSIDE a shed, keeping every artifact shed-local so the
# VirtioFS-mounted repo's macOS build outputs (core/target) are never clobbered
# (the mount is a different arch). Re-runnable.
#
# Set SHED_BUILD_PKG=shed-core to smoke the shed loop before shed-gtk exists
# (Phase 2 M2) — shed-core builds today and its 51 tests pass on Linux.
set -euo pipefail
log() { printf '[build-in-shed] %s\n' "$*"; }

REPO="${SHED_DESKTOP_REPO:-$HOME/shed-desktop}"
PKG="${SHED_BUILD_PKG:-shed-gtk}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/sdt}"   # shed-local, NOT on the mount
mkdir -p "$CARGO_TARGET_DIR"

cd "$REPO/core"
log "cargo build -p $PKG  (target -> $CARGO_TARGET_DIR)"
cargo build -p "$PKG"
log "done: $CARGO_TARGET_DIR/debug/$PKG"
