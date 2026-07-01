#!/usr/bin/env bash
# Build the Rust shed-core, generate its Swift UniFFI bindings, and assemble a
# STATIC-library xcframework the Swift package links.
#
# Static (not cdylib) is deliberate: the Rust code is sealed into the
# ShedDesktop Mach-O with no new dylib to sign or notarize — the release
# signing/notarization path is structurally unaffected. See
# plans/phase-1-rust-core.md §5–6.
#
# Outputs (gitignored, under core/artifacts/):
#   ShedCoreFFI.xcframework   — static lib + C headers + module.modulemap
#   ShedCoreSwift/*.swift     — the generated UniFFI Swift (the ShedCore target's sources)
#
# Usage: scripts/build-core.sh [debug|release]   (default: debug)
set -euo pipefail

CONFIG="${1:-debug}"
case "${CONFIG}" in
  release|debug) ;;
  *) echo "usage: build-core.sh [debug|release]" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CORE_DIR="${REPO_ROOT}/core"
ART="${CORE_DIR}/artifacts"
CRATE="shed_core_ffi"

# cargo on PATH even from a non-login shell (make / CI).
if ! command -v cargo >/dev/null 2>&1 && [ -f "${HOME}/.cargo/env" ]; then
  # shellcheck disable=SC1091
  . "${HOME}/.cargo/env"
fi

CARGO_FLAGS=()
[ "${CONFIG}" = "release" ] && CARGO_FLAGS+=(--release)
# Match Package.swift's .macOS(.v14).
export MACOSX_DEPLOYMENT_TARGET=14.0

# ---- staleness guard --------------------------------------------------
# Regenerating the bindings + xcframework is ~2-5s (xcodebuild-dominated) and,
# because it rewrites the artifacts, forces a downstream SwiftPM recompile. Skip
# it when the inputs (this script + the Rust sources/manifests + config) are
# unchanged and the artifacts already exist.
ART_SWIFT="${ART}/ShedCoreSwift/${CRATE}.swift"
XCFW="${ART}/ShedCoreFFI.xcframework"
STAMP="${ART}/.build-core.stamp"
compute_stamp() {
  {
    echo "config=${CONFIG}"
    # `< file` (stdin) so the hash is content-only, independent of the
    # invocation path (make uses a relative path, bundle.sh an absolute one).
    shasum < "${BASH_SOURCE[0]}"
    find "${CORE_DIR}" -type f \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'Cargo.lock' \) \
      -not -path '*/target/*' -not -path '*/artifacts/*' -print0 | sort -z | xargs -0 shasum
  } | shasum | awk '{print $1}'
}
WANT_STAMP="$(compute_stamp)"
if [ -d "${XCFW}" ] && [ -f "${ART_SWIFT}" ] && [ -f "${STAMP}" ] \
   && [ "$(cat "${STAMP}")" = "${WANT_STAMP}" ]; then
  echo "==> core up to date (${WANT_STAMP:0:12}); skipping rebuild"
  exit 0
fi

echo "==> cargo build (${CONFIG}) shed-core-ffi staticlib"
# arm64-only for now (dev machine + Rust-default-off POC; Intel uses the Swift
# fallback). Universal: build each triple, `lipo -create` the per-arch libs, then
# create-xcframework with the fat lib.
( cd "${CORE_DIR}" && cargo build -p shed-core-ffi "${CARGO_FLAGS[@]}" )

LIB="${CORE_DIR}/target/${CONFIG}/lib${CRATE}.a"
[ -f "${LIB}" ] || { echo "error: staticlib not found at ${LIB}" >&2; exit 1; }

GEN="${CORE_DIR}/target/uniffi-gen"
rm -rf "${GEN}"; mkdir -p "${GEN}"
echo "==> generate Swift bindings"
( cd "${CORE_DIR}" && cargo run -q -p shed-core-ffi --bin uniffi-bindgen -- \
    generate --library "${LIB}" --language swift --out-dir "${GEN}" )

# Headers dir for the xcframework: the FFI header + a module.modulemap (clang
# looks for that exact filename). uniffi emits <crate>FFI.modulemap — rename it.
HDR="${GEN}/headers"
mkdir -p "${HDR}"
cp "${GEN}/${CRATE}FFI.h" "${HDR}/"
cp "${GEN}/${CRATE}FFI.modulemap" "${HDR}/module.modulemap"

echo "==> assemble static xcframework"
mkdir -p "${ART}"
rm -rf "${ART}/ShedCoreFFI.xcframework"
xcodebuild -create-xcframework \
  -library "${LIB}" -headers "${HDR}" \
  -output "${ART}/ShedCoreFFI.xcframework" >/dev/null

# The generated Swift is the ShedCore SwiftPM target's sole source.
rm -rf "${ART}/ShedCoreSwift"; mkdir -p "${ART}/ShedCoreSwift"
cp "${GEN}/${CRATE}.swift" "${ART}/ShedCoreSwift/${CRATE}.swift"

# crate-type = ["staticlib"] guarantees a .a (never a dylib); the real no-dylib
# gate is the otool -L check on the linked binary in bundle.sh. Record the input
# stamp so an unchanged core short-circuits next time.
echo "${WANT_STAMP}" > "${STAMP}"

echo "==> core artifacts ready:"
echo "    ${ART}/ShedCoreFFI.xcframework (static)"
echo "    ${ART}/ShedCoreSwift/${CRATE}.swift"
