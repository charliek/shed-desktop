#!/usr/bin/env bash
# ShedDesktop.app bundling.
#
# Wraps the SwiftPM executable output into a proper macOS .app bundle so
# the binary can be Finder-launched / `open`ed / referenced by its bundle
# identifier. Touch ID (LAContext) and the menu-bar accessory activation
# policy require a real bundle — a bare SwiftPM binary won't do.
#
# What this does:
#   1. Builds the ShedDesktop + shedctl executables (default: debug).
#   2. Assembles build/ShedDesktop.app with the standard layout —
#      Contents/MacOS/ShedDesktop, Contents/Info.plist,
#      Contents/Resources/, Contents/Resources/bin/shedctl.
#   3. Substitutes @VERSION@ in Resources/Info.plist.template with the
#      contents of the top-level VERSION file (or $SHED_DESKTOP_VERSION).
#   4. Ad-hoc code-signs (inner shedctl first, then the outer .app).
#
# What this does NOT do (M4 follow-ups): Developer ID signing,
# notarization, DMG, Sparkle embedding/appcast.
#
# Usage:
#   ./scripts/bundle.sh                 # debug build (default)
#   ./scripts/bundle.sh release
#   SHED_DESKTOP_VERSION=0.2.0 ./scripts/bundle.sh

set -euo pipefail

CONFIG="${1:-debug}"
case "${CONFIG}" in
  release|debug) ;;
  *)
    echo "error: configuration must be 'release' or 'debug', got '${CONFIG}'" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Version: the top-level VERSION file is the single source of truth for a
# pure-Swift package. The release workflow overrides via the git tag.
FILE_VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION" 2>/dev/null || echo "")"
VERSION="${SHED_DESKTOP_VERSION:-${FILE_VERSION:-0.0.0}}"
APP_NAME="ShedDesktop"
BUNDLE_ID="ai.stridelabs.ShedDesktop"
TEMPLATE_PLIST="${REPO_ROOT}/Resources/Info.plist.template"
ENT_FILE="${REPO_ROOT}/Resources/ShedDesktop.entitlements"
ICON_SRC="${REPO_ROOT}/Resources/AppIcon.icns"

OUT_DIR="${REPO_ROOT}/build"
APP_DIR="${OUT_DIR}/${APP_NAME}.app"

echo "==> Building ${APP_NAME} + shedctl (${CONFIG}) from SwiftPM"
pushd "${REPO_ROOT}" >/dev/null
swift build -c "${CONFIG}" --product ShedDesktop
swift build -c "${CONFIG}" --product shedctl
SWIFT_BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
popd >/dev/null

APP_BIN="${SWIFT_BIN_DIR}/ShedDesktop"
CTL_BIN="${SWIFT_BIN_DIR}/shedctl"
for b in "${APP_BIN}" "${CTL_BIN}"; do
  if [ ! -x "${b}" ]; then
    echo "error: swift build did not produce ${b}" >&2
    exit 1
  fi
done

echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources/bin"

cp "${APP_BIN}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

cp "${CTL_BIN}" "${APP_DIR}/Contents/Resources/bin/shedctl"
chmod +x "${APP_DIR}/Contents/Resources/bin/shedctl"
echo "    Embedded: ${APP_DIR}/Contents/Resources/bin/shedctl"

echo "==> Stamping Info.plist (version=${VERSION})"
sed -e "s/@VERSION@/${VERSION}/g" "${TEMPLATE_PLIST}" \
  > "${APP_DIR}/Contents/Info.plist"

printf "APPL????" > "${APP_DIR}/Contents/PkgInfo"

# Any SwiftPM resource bundles (none yet, but defensively copy so future
# resources land under Contents/Resources where Bundle.main resolves them).
for bundle in "${SWIFT_BIN_DIR}"/*.bundle; do
  [ -d "${bundle}" ] || continue
  cp -R "${bundle}" "${APP_DIR}/Contents/Resources/"
done

if [ -f "${ICON_SRC}" ]; then
  cp "${ICON_SRC}" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc codesign. Inner (shedctl) first, then the outer .app — codesign
# seals nested code into the outer signature. A real Developer ID lands in
# M4 (set SHED_DESKTOP_DEVELOPER_ID_IDENTITY + the notarization secrets).
SIGN_IDENTITY="${SHED_DESKTOP_DEVELOPER_ID_IDENTITY:--}"
TS_FLAG=""
if [ "${SIGN_IDENTITY}" != "-" ]; then
  TS_FLAG="--timestamp"
fi
if ! command -v codesign >/dev/null 2>&1; then
  if [ "${SHED_DESKTOP_ALLOW_UNSIGNED:-0}" = "1" ]; then
    echo "==> warn: codesign not found; SHED_DESKTOP_ALLOW_UNSIGNED=1, shipping unsigned"
  else
    echo "error: codesign not found (set SHED_DESKTOP_ALLOW_UNSIGNED=1 to bypass)" >&2
    exit 1
  fi
else
  if [ "${SIGN_IDENTITY}" = "-" ]; then
    echo "==> Ad-hoc codesign (set SHED_DESKTOP_DEVELOPER_ID_IDENTITY for a notarizable build)"
  else
    echo "==> Developer ID codesign (identity: ${SIGN_IDENTITY})"
  fi
  codesign_or_die() {
    local target="$1"
    # shellcheck disable=SC2086  # TS_FLAG must word-split (empty => no flag)
    if codesign --force --sign "${SIGN_IDENTITY}" \
         --entitlements "${ENT_FILE}" \
         --options runtime \
         ${TS_FLAG} \
         "${target}"
    then
      return 0
    fi
    if [ "${SHED_DESKTOP_ALLOW_UNSIGNED:-0}" = "1" ]; then
      echo "    warn: codesign(${target}) failed; SHED_DESKTOP_ALLOW_UNSIGNED=1, continuing"
      return 0
    fi
    echo "    error: codesign(${target}) failed (set SHED_DESKTOP_ALLOW_UNSIGNED=1 to bypass)" >&2
    exit 1
  }
  codesign_or_die "${APP_DIR}/Contents/Resources/bin/shedctl"
  codesign_or_die "${APP_DIR}"
fi

echo "==> Bundled: ${APP_DIR}"
echo "    Bundle ID:    ${BUNDLE_ID}"
echo "    Version:      ${VERSION}"
echo "    Executable:   ${APP_DIR}/Contents/MacOS/${APP_NAME}"
echo "    Embedded CLI: ${APP_DIR}/Contents/Resources/bin/shedctl"
echo
echo "Launch with: open '${APP_DIR}'"
