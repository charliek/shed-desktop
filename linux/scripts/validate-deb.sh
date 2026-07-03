#!/usr/bin/env bash
# Install the shed-desktop .deb in a CLEAN ubuntu:24.04 container and assert the
# installed binary launches (its runtime deps resolve) and answers identify.
# Used by `make deb-validate` and the CI deb job — proves the .deb's `depends:`
# are correct on a machine without the -dev packages.
set -euo pipefail

DEB="${1:?usage: validate-deb.sh <path-to-.deb>}"
DEB_DIR="$(cd "$(dirname "${DEB}")" && pwd)"
DEB_FILE="$(basename "${DEB}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Install-validating ${DEB_FILE} in a clean ubuntu:24.04 container"
docker run --rm \
  -v "${DEB_DIR}:/pkg:ro" \
  -v "${SCRIPT_DIR}:/scripts:ro" \
  ubuntu:24.04 bash -lc "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # apt resolves the .deb's runtime deps (libgtk-4-1, libadwaita-1-0, libc6).
    apt-get install -y -qq /pkg/${DEB_FILE} xvfb python3 >/dev/null
    command -v shed-desktop
    python3 /scripts/deb_identify_check.py
  "
