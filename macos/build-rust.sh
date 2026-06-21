#!/usr/bin/env bash
# Build the native FFI as a universal macOS dylib from the PUBLISHED peat-ffi
# crate via the rust/ wrapper (no ../peat checkout required).
# Produces macos/Frameworks/libpeat_ffi.dylib (lipo of arm64 + x86_64).
#
# Requires: Xcode command-line tools, Rust macOS targets.
#   rustup target add aarch64-apple-darwin x86_64-apple-darwin
#
# Usage:
#   macos/build-rust.sh   # or: just build-macos
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_DIR="${SCRIPT_DIR}/../rust"
FRAMEWORKS_DIR="${SCRIPT_DIR}/Frameworks"
MANIFEST="${RUST_DIR}/Cargo.toml"

# The wrapper pins the published peat-ffi version + feature set
# (sync,bluetooth,lite-bridge) in rust/Cargo.toml — nothing to pass here.
echo "==> Building libpeat_ffi for aarch64-apple-darwin (published peat-ffi via rust/ wrapper)"
cargo build --release \
    --manifest-path "${MANIFEST}" \
    --target aarch64-apple-darwin

echo "==> Building libpeat_ffi for x86_64-apple-darwin"
cargo build --release \
    --manifest-path "${MANIFEST}" \
    --target x86_64-apple-darwin

echo "==> Lipo-ing universal dylib"
mkdir -p "${FRAMEWORKS_DIR}"
lipo -create \
    "${RUST_DIR}/target/aarch64-apple-darwin/release/libpeat_ffi.dylib" \
    "${RUST_DIR}/target/x86_64-apple-darwin/release/libpeat_ffi.dylib" \
    -output "${FRAMEWORKS_DIR}/libpeat_ffi.dylib"

echo "==> Built ${FRAMEWORKS_DIR}/libpeat_ffi.dylib"
