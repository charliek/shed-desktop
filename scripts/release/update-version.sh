#!/usr/bin/env bash
# Bump shed-desktop's release version across the manifests it owns — one tag,
# one version everywhere.
#
#   - VERSION          the macOS app's marketing version (bundle.sh + shedctl
#                      identify read it); drives the DMG + Sparkle appcast.
#   - core/Cargo.toml  the Rust workspace ([workspace.package].version; every
#                      member inherits via version.workspace = true). The .deb's
#                      version is tag-derived at build time, but we keep the
#                      workspace version aligned so `grep` shows one version and
#                      the `--locked` CI stays green. core/Cargo.lock is
#                      regenerated so the per-member entries match (the roost /
#                      release-workflows cargo-workspace pattern).
#
# Contract (cc-plugins release-workflows references/update-version/README.md):
#   - one arg: semver X.Y.Z or X.Y.Z-suffix, no `v` prefix
#   - idempotent (a same-version re-run leaves the tree unchanged)
#   - no network (--offline)
#   - verifies its own work
#   - does NOT `git add` (the release flow stages + commits)
#
# Usage: scripts/release/update-version.sh 0.2.0

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <X.Y.Z[-suffix]>" >&2
  exit 2
fi
V="$1"
if [[ ! "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$ ]]; then
  echo "error: '$V' is not semver (X.Y.Z or X.Y.Z-suffix)" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# 1. The macOS marketing version.
printf '%s\n' "${V}" > "${REPO_ROOT}/VERSION"
echo "VERSION -> ${V}"

# 2. The Rust workspace version. Variable whitespace on the LHS (tolerant of a
#    reflow) → a single-space replacement, matching core/Cargo.toml's layout.
#    `^version = "..."` is the only line-anchored version in the file (deps are
#    inline `{ version = "..." }`), so the anchored replace is safe.
cd "${REPO_ROOT}/core"
sed -i.bak -E 's/^version[[:space:]]*=[[:space:]]*"[^"]+"/version = "'"$V"'"/' Cargo.toml
rm -f Cargo.toml.bak
if ! grep -q "^version = \"$V\"" Cargo.toml; then
  echo "error: core/Cargo.toml's [workspace.package].version did not update to $V." >&2
  echo "       Inspect by hand — the sed pattern may not match the current layout." >&2
  exit 1
fi

# 3. Regenerate core/Cargo.lock so the workspace-member entries match. --offline is
#    safe: only internal version strings change, not the dep tree. Resolve cargo
#    even from a non-login shell (make / a release subprocess) via ~/.cargo/env.
if ! command -v cargo >/dev/null 2>&1 && [ -f "${HOME}/.cargo/env" ]; then
  # shellcheck disable=SC1091
  . "${HOME}/.cargo/env"
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found (install Rust via rustup, or put it on PATH)." >&2
  exit 1
fi
cargo update --workspace --offline >/dev/null
if ! grep -q "^version = \"$V\"" Cargo.lock; then
  echo "error: core/Cargo.lock did not update to $V — a member may override the version." >&2
  exit 1
fi
echo "core/Cargo.toml + core/Cargo.lock -> ${V}"
