cmake_minimum_required(VERSION 3.10)
project(peat_flutter_library VERSION 0.0.1 LANGUAGES C)

# Android: cargo-ndk is invoked directly from android/build.gradle.
# macOS/iOS: xcframework/dylib produced by ios/build-rust.sh and podspec.
# This file is only active for Linux and Windows desktop targets.
if(ANDROID OR APPLE)
  add_library(peat_flutter INTERFACE)
  return()
endif()

# Build libpeat_ffi from the PUBLISHED peat-ffi crate via the rust/ wrapper
# (no ../peat checkout required). The wrapper pins the peat-ffi version +
# feature set (sync,bluetooth,lite-bridge) in rust/Cargo.toml.
# Allow override for non-standard layouts: cmake -DPEAT_RUST_DIR=/path/to/rust
if(NOT DEFINED PEAT_RUST_DIR)
  get_filename_component(PEAT_RUST_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../rust"
    ABSOLUTE)
endif()

if(NOT EXISTS "${PEAT_RUST_DIR}/Cargo.toml")
  message(FATAL_ERROR
    "rust/ wrapper crate not found at ${PEAT_RUST_DIR}. "
    "Set -DPEAT_RUST_DIR=<path> on the cmake invocation.")
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64")
    set(RUST_TARGET "aarch64-unknown-linux-gnu")
  else()
    set(RUST_TARGET "x86_64-unknown-linux-gnu")
  endif()
  set(PEAT_LIB_NAME "libpeat_ffi.so")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
  set(RUST_TARGET "x86_64-pc-windows-msvc")
  set(PEAT_LIB_NAME "peat_ffi.dll")
else()
  message(FATAL_ERROR "Unsupported platform in src/CMakeLists.txt: ${CMAKE_SYSTEM_NAME}")
endif()

set(PEAT_LIB "${PEAT_RUST_DIR}/target/${RUST_TARGET}/release/${PEAT_LIB_NAME}")

add_custom_command(
  OUTPUT "${PEAT_LIB}"
  COMMAND cargo build --release
    --manifest-path "${PEAT_RUST_DIR}/Cargo.toml"
    --target "${RUST_TARGET}"
  WORKING_DIRECTORY "${PEAT_RUST_DIR}"
  COMMENT "cargo build libpeat_ffi from published peat-ffi (${RUST_TARGET})"
  VERBATIM
)

add_custom_target(peat_ffi_build ALL DEPENDS "${PEAT_LIB}")

# Import the cargo-built library so the platform CMakeLists can reference it
# via $<TARGET_FILE:peat_flutter> and Flutter's bundled-libraries mechanism
# will copy it into the app bundle.
add_library(peat_flutter SHARED IMPORTED GLOBAL)
add_dependencies(peat_flutter peat_ffi_build)
set_target_properties(peat_flutter PROPERTIES IMPORTED_LOCATION "${PEAT_LIB}")
