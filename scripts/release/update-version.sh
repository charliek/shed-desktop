#!/usr/bin/env bash
# Bump the single version manifest for shed-desktop.
#
# Pure-Swift package: the top-level VERSION file is the only place the
# marketing version lives (bundle.sh + shedctl identify both read it).
# The release-workflows convention calls this with the new X.Y.Z.
#
# Usage: scripts/release/update-version.sh 0.2.0

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <X.Y.Z>" >&2
  exit 1
fi

NEW_VERSION="$1"
if ! printf '%s' "${NEW_VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "error: version must be semver X.Y.Z, got '${NEW_VERSION}'" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

printf '%s\n' "${NEW_VERSION}" > "${REPO_ROOT}/VERSION"
echo "VERSION -> ${NEW_VERSION}"
