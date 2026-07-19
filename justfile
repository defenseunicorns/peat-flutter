# peat-flutter development tasks

# Path to the peat workspace (sibling directory by default).
# Override: PEAT_WORKSPACE_DIR=/abs/path just gen-bindings
peat_workspace := env_var_or_default("PEAT_WORKSPACE_DIR", "../peat")

# Output dirs for generated sources
generated_dir := "lib/src/generated"
proto_dir     := "lib/src/proto"
proto_src     := peat_workspace + "/peat-schema/proto"

# Validate that both halves of the Dart ABI owned by this repository are
# consistent with the wrapper-built native artifact. The bindings in
# lib/src/generated/peat_ffi.dart and adapter in rust/src/dart_ffi.rs are
# maintained manually (the uniffi-bindgen-dart generator is not public).
#
# When peat-ffi's API surface changes, you need to update manually:
#   1. rust/src/dart_ffi.rs — add/remove uniffi_ffibuffer_* wrappers
#   2. lib/src/generated/peat_ffi.dart — add/remove Dart method stubs
#      (follow the existing patterns: argBuf/returnBuf layouts, _uniffiRead* decoders)
#   3. Run: just check-bindings  (this task) to verify checksums still pass at runtime
#
# Known manual fixes in peat_ffi.dart that must be preserved:
#   - bindingsContractVersion = 30  (matches uniffi 0.31 contract)
#   - createNode return: PeatNodeFfiCodec.lift((returnBuf + 0).ref.u64)
#   - subscribe callback arg: _DocumentCallbackCallbackBridge.instance.register(callback)
check-bindings:
    #!/usr/bin/env bash
    set -euo pipefail
    lib=$(ls rust/target/release/libpeat_ffi.{so,dylib} 2>/dev/null | head -1 || true)
    if [ -z "$lib" ]; then
        echo "ERROR: libpeat_ffi not found. Build with: just build-host"
        exit 1
    fi
    echo "Library: $lib"
    symbols=$(mktemp)
    trap 'rm -f "$symbols"' EXIT
    nm -g "$lib" 2>/dev/null | awk '{print $NF}' | sed 's/^_//' | sort -u > "$symbols"
    echo "Checking every Dart FFIBuffer lookup is exported..."
    missing=0
    expected=$(grep -oE "'uniffi_ffibuffer_peat_ffi_[^']+'" \
        lib/src/generated/peat_ffi.dart | tr -d "'" | sort -u)
    for sym in $expected \
        ffi_uniffi_peat_ffi_rustbuffer_from_bytes \
        ffi_uniffi_peat_ffi_rustbuffer_free \
        ffi_peat_ffi_uniffi_contract_version; do
        if ! grep -Fxq "$sym" "$symbols"; then
            echo "  MISSING: $sym"
            missing=$((missing + 1))
        fi
    done
    echo "Checking every Dart UniFFI checksum lookup is exported..."
    checksums=$(grep -oE "'uniffi_peat_ffi_checksum_[^']+'" \
        lib/src/generated/peat_ffi.dart | tr -d "'" | sort -u)
    for sym in $checksums; do
        if ! grep -Fxq "$sym" "$symbols"; then
            echo "  MISSING: $sym"
            missing=$((missing + 1))
        fi
    done
    [ $missing -eq 0 ] && echo "All Dart ABI symbols present." || exit 1

# Generate Dart proto stubs from peat-schema protos via protoc-gen-dart.
#
# Requires:
#   apt install protobuf-compiler   (or brew install protobuf)
#   dart pub global activate protoc_plugin
gen-proto:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{proto_dir}}"
    protos=$(find "{{proto_src}}" -name '*.proto')
    if [ -z "$protos" ]; then
        echo "ERROR: no .proto files found under {{proto_src}}"
        exit 1
    fi
    # shellcheck disable=SC2086
    protoc \
        --dart_out="{{proto_dir}}" \
        --experimental_allow_proto3_optional \
        -I "{{proto_src}}" \
        $protos
    echo "Proto stubs written to {{proto_dir}}/"

# Build libpeat_ffi for all Android ABIs via cargo-ndk, from the PUBLISHED
# peat-ffi crate via the rust/ wrapper (no ../peat checkout needed).
# Requires: cargo install cargo-ndk  +  Android NDK (ANDROID_NDK_HOME set).
build-android:
    cargo ndk \
        -t arm64-v8a -t armeabi-v7a -t x86_64 \
        -o android/src/main/jniLibs \
        build --release \
        --manifest-path "rust/Cargo.toml"

# Build peat-ffi for iOS (xcframework). macOS host only.
build-ios:
    ios/build-rust.sh

# Build peat-ffi as a universal macOS dylib. macOS host only.
build-macos:
    macos/build-rust.sh

# Build peat-ffi for the native Linux/Windows host.
# The CMake build for those platforms shells out to cargo, but this task lets
# you pre-build and verify outside of the Flutter CMake context.
build-host:
    cargo build --release \
        --manifest-path rust/Cargo.toml

# Regenerate proto stubs and verify bindings. Run after any peat-ffi surface change.
regen: gen-proto check-bindings

# Run dart analyze over the library sources.
analyze:
    dart analyze lib/
