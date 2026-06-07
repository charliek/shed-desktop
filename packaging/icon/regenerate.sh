#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from the SF-symbol glyph (see
# generate-icon.swift). Pass through flags, e.g. --bg 2E5C8A --fg FFFFFF.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"
MASTER="${DIR}/master.png"

swift "${DIR}/generate-icon.swift" --out "${MASTER}" "$@"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "${ICONSET}"
emit() { sips -z "$1" "$1" "${MASTER}" --out "${ICONSET}/$2" >/dev/null; }
emit 16   icon_16x16.png
emit 32   icon_16x16@2x.png
emit 32   icon_32x32.png
emit 64   icon_32x32@2x.png
emit 128  icon_128x128.png
emit 256  icon_128x128@2x.png
emit 256  icon_256x256.png
emit 512  icon_256x256@2x.png
emit 512  icon_512x512.png
cp "${MASTER}" "${ICONSET}/icon_512x512@2x.png"

iconutil -c icns "${ICONSET}" -o "${ROOT}/Resources/AppIcon.icns"
echo "wrote ${ROOT}/Resources/AppIcon.icns"
