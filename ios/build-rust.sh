#!/usr/bin/env bash
# Build the native FFI as a static xcframework for iOS from the PUBLISHED
# peat-ffi crate via the rust/ wrapper (no ../peat checkout required).
# Produces ios/Frameworks/PeatFFI.xcframework containing:
#   - aarch64-apple-ios          (physical device)
#   - lipo'd simulator slice     (aarch64-apple-ios-sim + x86_64-apple-ios)
#
# Requires: Xcode command-line tools, Rust iOS targets.
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
#
# Usage:
#   ios/build-rust.sh   # or: just build-ios
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_DIR="${SCRIPT_DIR}/../rust"
FRAMEWORKS_DIR="${SCRIPT_DIR}/Frameworks"
MANIFEST="${RUST_DIR}/Cargo.toml"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"

# The wrapper pins the published peat-ffi version + feature set
# (sync,bluetooth,lite-bridge) in rust/Cargo.toml — nothing to pass here.
echo "==> Building libpeat_ffi for aarch64-apple-ios (device)"
cargo build --release --manifest-path "${MANIFEST}" --target aarch64-apple-ios

echo "==> Building libpeat_ffi for aarch64-apple-ios-sim"
cargo build --release --manifest-path "${MANIFEST}" --target aarch64-apple-ios-sim

echo "==> Building libpeat_ffi for x86_64-apple-ios (simulator)"
cargo build --release --manifest-path "${MANIFEST}" --target x86_64-apple-ios

echo "==> Lipo-ing simulator slices"
SIM_LIPO_DIR="${FRAMEWORKS_DIR}/sim-lipo"
mkdir -p "${SIM_LIPO_DIR}"
lipo -create \
    "${RUST_DIR}/target/aarch64-apple-ios-sim/release/libpeat_ffi.a" \
    "${RUST_DIR}/target/x86_64-apple-ios/release/libpeat_ffi.a" \
    -output "${SIM_LIPO_DIR}/libpeat_ffi.a"

echo "==> Creating PeatFFI.xcframework"
DEVICE_HDR="${FRAMEWORKS_DIR}/device-include"
SIM_HDR="${FRAMEWORKS_DIR}/sim-include"
mkdir -p "${DEVICE_HDR}" "${SIM_HDR}"
XCFRAMEWORK="${FRAMEWORKS_DIR}/PeatFFI.xcframework"
rm -rf "${XCFRAMEWORK}"
xcodebuild -create-xcframework \
    -library "${RUST_DIR}/target/aarch64-apple-ios/release/libpeat_ffi.a" \
    -headers "${DEVICE_HDR}" \
    -library "${SIM_LIPO_DIR}/libpeat_ffi.a" \
    -headers "${SIM_HDR}" \
    -output "${XCFRAMEWORK}"

echo "==> Built ${XCFRAMEWORK}"
