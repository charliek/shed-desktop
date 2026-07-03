#!/usr/bin/env bash
# Run shed-desktop's GTK (shed-gtk) tests in a shed (Apple VZ Linux microVM)
# from a Mac. The repo is mounted via --local-dir (edit on the Mac, build+test
# in the VM); .shed/provision.yaml installs the GTK4 stack + Rust once.
#
# Why a shed: shed-gtk (GTK4) can't build/run on macOS. shed-gtk needs no uinput
# tier (it's a dashboard, not roost's terminal), so Docker could also run this
# e2e — but a shed gives a real GTK4 env and matches the ecosystem loop.
#
# Box model: a long-lived `sd-gtk-dev` shed + a `sd-gtk-base` snapshot cache.
# Treat both as a CACHE — on a shed upgrade, run --reprovision (or
# `shed delete sd-gtk-dev -f; shed snapshot delete sd-gtk-base -f`). The build
# goes to a shed-local CARGO_TARGET_DIR so it never touches the Mac target/.
#
# Usage:
#   tools/shed/shed-test.sh                 # ensure box, build shed-gtk, run the GTK e2e
#   tools/shed/shed-test.sh --build-only    # just build in the shed
#   tools/shed/shed-test.sh --shell         # ensure box + drop into a shell
#   tools/shed/shed-test.sh --snapshot-base # cache the provisioned box as sd-gtk-base
#   tools/shed/shed-test.sh --reprovision   # delete box + snapshot, rebuild from scratch
#   tools/shed/shed-test.sh --stop          # stop the dev box (frees the VM)
#
# Env: SHED_BUILD_PKG=shed-core to smoke the loop before shed-gtk lands (M2).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHED=sd-gtk-dev
SNAP=sd-gtk-base
RT='$HOME/sdt'                                   # shed-local CARGO_TARGET_DIR (expanded in-guest)
UPPER="${SHED_DESKTOP_SHED_UPPER:-20G}"
PKG="${SHED_BUILD_PKG:-shed-gtk}"
log() { printf '\033[36m[shed-test]\033[0m %s\n' "$*"; }

have_shed() { shed list 2>/dev/null | awk '{print $1}' | grep -qx "$SHED"; }
shed_status() { shed list 2>/dev/null | awk -v s="$SHED" '$1==s {print $NF}'; }
have_snap() { shed snapshot list 2>/dev/null | awk '{print $1}' | grep -qx "$SNAP"; }
in_shed() { shed exec "$SHED" -- bash -lc "$1"; }

ensure_box() {
  if have_shed; then
    case "$(shed_status)" in
      *stopped*|*Stopped*) log "starting existing $SHED"; shed start "$SHED" >/dev/null ;;
      *) log "reusing running $SHED" ;;
    esac
  elif have_snap; then
    log "spawning $SHED from snapshot $SNAP (+ mounting repo)"
    shed create "$SHED" --from-snapshot "$SNAP" --local-dir "$REPO" --upper-size "$UPPER" >/dev/null
  else
    log "no box or snapshot — provisioning fresh (install hook; first run is slow)"
    shed create "$SHED" --local-dir "$REPO" --upper-size "$UPPER" >/dev/null
    log "TIP: run '$0 --snapshot-base' once to cache this for fast future boots"
  fi
}

build() {
  log "building $PKG in the shed (shed-local target; Mac target/ untouched)"
  in_shed "chmod +x ~/shed-desktop/tools/shed/build-in-shed.sh; SHED_BUILD_PKG=$PKG ~/shed-desktop/tools/shed/build-in-shed.sh"
}

run_e2e() {
  log "running the GTK e2e (pytest under Xvfb)"
  # Three knobs, each of which cost a debugging cycle in roost's loop:
  #  - XDG_RUNTIME_DIR must be a fresh dir, or the UI's socket lands somewhere the
  #    harness doesn't look and wait_alive times out.
  #  - GDK_BACKEND=x11 (matches CI): avoids the libEGL/DRI3 path under Xvfb.
  #  - system pytest (python3 -m pytest): there is no `uv` in the shed.
  in_shed "cd ~/shed-desktop && \
    SHED_GTK_BIN=$RT/debug/shed-desktop \
    SHED_GTK_TEST_MODE=1 GDK_BACKEND=x11 XDG_RUNTIME_DIR=/tmp/sdt-xdg \
    xvfb-run -a --server-args='-screen 0 2560x1440x24' \
    python3 -m pytest tools/shedgtktest -q"
}

case "${1:-}" in
  --reprovision)
    log "tearing down $SHED + $SNAP"
    have_shed && shed delete "$SHED" -f || true
    have_snap && shed snapshot delete "$SNAP" -f || true
    ensure_box; build; run_e2e ;;
  --snapshot-base)
    have_shed || { log "no $SHED to snapshot — run with no args first"; exit 1; }
    log "stopping $SHED to snapshot it (it restarts after)"
    shed stop "$SHED" >/dev/null
    have_snap && shed snapshot delete "$SNAP" -f >/dev/null || true
    shed snapshot create "$SHED" "$SNAP" --comment "shed-desktop gtk test base"
    shed start "$SHED" >/dev/null
    log "cached as snapshot $SNAP" ;;
  --stop)
    have_shed && shed stop "$SHED" && log "stopped $SHED (start again with any command)" ;;
  --shell)
    ensure_box; log "dropping into $SHED (repo at ~/shed-desktop)"; shed console "$SHED" ;;
  --build-only)
    ensure_box; build ;;
  ""|--run)
    ensure_box; build; run_e2e ;;
  *)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
