#!/usr/bin/env bash
# Build the shed-desktop Linux .deb: cargo build --release the shed-gtk +
# shedctl binaries, stage them + packaging assets, and run nfpm to emit
# out/shed-desktop_<ver>_<arch>.deb.
#
# Run on the target architecture (no cross-compile): an amd64 deb is built on
# amd64, arm64 on arm64. Prereqs (Ubuntu/Debian): libgtk-4-dev libadwaita-1-dev
# pkg-config build-essential, a Rust toolchain, and nfpm on PATH
# (https://nfpm.goreleaser.com). `make deb` runs this inside the Linux Docker.
#
# Usage: ./linux/scripts/build-deb.sh 0.0.1
set -euo pipefail

VERSION="${1:-}"
if [ -z "${VERSION}" ]; then
  echo "usage: $0 <version>   (e.g. 0.0.1 or 0.0.1-dev)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

# Debian arch name: prefer dpkg (the real target); fall back to uname on a
# non-Debian dev host (a layout smoke — the deb won't be functional there).
if command -v dpkg >/dev/null 2>&1; then
  SHED_GTK_ARCH="$(dpkg --print-architecture)"
else
  case "$(uname -m)" in
    x86_64|amd64) SHED_GTK_ARCH="amd64" ;;
    aarch64|arm64) SHED_GTK_ARCH="arm64" ;;
    *) echo "error: unsupported arch $(uname -m)" >&2; exit 1 ;;
  esac
fi
export SHED_GTK_ARCH
export SHED_GTK_VERSION="${VERSION}"

echo "==> cargo build --release -p shed-gtk -p shedctl"
( cd core && cargo build --release -p shed-gtk -p shedctl )

CARGO_TARGET="${CARGO_TARGET_DIR:-${REPO_ROOT}/core/target}"
BIN="${CARGO_TARGET}/release/shed-desktop"
CTL="${CARGO_TARGET}/release/shedctl"
for b in "${BIN}" "${CTL}"; do
  if [ ! -x "${b}" ]; then
    echo "error: expected binary not found: ${b}" >&2
    exit 1
  fi
done

echo "==> Staging dist/"
rm -rf "${REPO_ROOT}/dist"
mkdir -p "${REPO_ROOT}/dist"
install -m 0755 "${BIN}" "${REPO_ROOT}/dist/shed-desktop"
install -m 0755 "${CTL}" "${REPO_ROOT}/dist/shedctl"

echo "==> nfpm pkg (version=${SHED_GTK_VERSION}, arch=${SHED_GTK_ARCH})"
mkdir -p "${REPO_ROOT}/out"
nfpm pkg --packager deb --config "${REPO_ROOT}/packaging/nfpm.yaml" --target "${REPO_ROOT}/out/"

echo "==> Built:"
ls -1 "${REPO_ROOT}"/out/*.deb
