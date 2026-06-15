#!/usr/bin/env bash
# Build peat-ffi as a static xcframework for iOS.
# Produces ios/Frameworks/PeatFFI.xcframework containing:
#   - aarch64-apple-ios          (physical device)
#   - lipo'd simulator slice     (aarch64-apple-ios-sim + x86_64-apple-ios)
#
# Requires: Xcode command-line tools, Rust iOS targets, protoc.
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
#
# Usage:
#   PEAT_WORKSPACE_DIR=/path/to/peat ios/build-rust.sh   # or just: just build-ios
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PEAT_DIR="${PEAT_WORKSPACE_DIR:-"${SCRIPT_DIR}/../../peat"}"
FRAMEWORKS_DIR="${SCRIPT_DIR}/Frameworks"
FEATURES="sync,bluetooth,lite-bridge"
MANIFEST="${PEAT_DIR}/Cargo.toml"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"

echo "==> Building peat-ffi for aarch64-apple-ios (device)"
cargo build --release \
    --manifest-path "${MANIFEST}" \
    -p peat-ffi \
    --features "${FEATURES}" \
    --target aarch64-apple-ios

echo "==> Building peat-ffi for aarch64-apple-ios-sim"
cargo build --release \
    --manifest-path "${MANIFEST}" \
    -p peat-ffi \
    --features "${FEATURES}" \
    --target aarch64-apple-ios-sim

echo "==> Building peat-ffi for x86_64-apple-ios (simulator)"
cargo build --release \
    --manifest-path "${MANIFEST}" \
    -p peat-ffi \
    --features "${FEATURES}" \
    --target x86_64-apple-ios

echo "==> Lipo-ing simulator slices"
SIM_LIPO_DIR="${FRAMEWORKS_DIR}/sim-lipo"
mkdir -p "${SIM_LIPO_DIR}"
lipo -create \
    "${PEAT_DIR}/target/aarch64-apple-ios-sim/release/libpeat_ffi.a" \
    "${PEAT_DIR}/target/x86_64-apple-ios/release/libpeat_ffi.a" \
    -output "${SIM_LIPO_DIR}/libpeat_ffi.a"

echo "==> Creating PeatFFI.xcframework"
DEVICE_HDR="${FRAMEWORKS_DIR}/device-include"
SIM_HDR="${FRAMEWORKS_DIR}/sim-include"
mkdir -p "${DEVICE_HDR}" "${SIM_HDR}"
XCFRAMEWORK="${FRAMEWORKS_DIR}/PeatFFI.xcframework"
rm -rf "${XCFRAMEWORK}"
xcodebuild -create-xcframework \
    -library "${PEAT_DIR}/target/aarch64-apple-ios/release/libpeat_ffi.a" \
    -headers "${DEVICE_HDR}" \
    -library "${SIM_LIPO_DIR}/libpeat_ffi.a" \
    -headers "${SIM_HDR}" \
    -output "${XCFRAMEWORK}"

echo "==> Built ${XCFRAMEWORK}"
