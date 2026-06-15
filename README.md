# peat_flutter

A Flutter FFI plugin that brings the **peat** peer-to-peer mesh protocol to
mobile and desktop apps. It wraps the peat Rust stack — `peat-schema`,
`peat-protocol`, `peat-mesh`, and `peat-btle` — and exposes it to Dart through
`peat-ffi` (UniFFI), so a Flutter app can join a local mesh, discover peers, and
sync CRDT (Automerge) documents directly between devices.

peat is designed for **fully offline / disconnected environments**: there is no
central server. Nodes find each other on the local network (mDNS over UDP
multicast) or over the short-range Bluetooth LE transport (`peat-btle`) and
converge on shared state device-to-device.

## Purpose

This repository is the Flutter/Dart binding layer for peat. Its job is to:

- Provide a Dart facade (`PeatFlutterNode`) over the UniFFI-generated `peat-ffi`
  bindings — subscribing to document changes, publishing/reading proto-typed
  messages, and driving inbound/outbound frame exchange.
- Bundle the compiled native `peat-ffi` library for each target platform.

## Supported platforms

Android, iOS, macOS, Linux, and Windows (all via FFI).

## Constraints & design notes

This plugin was built under a few deliberate constraints worth knowing before
you build or contribute:

- **Native dependency.** The plugin links against `peat-ffi`, a Rust library
  from the [`peat`](https://github.com/defenseunicorns) workspace. Building the
  native library from source requires a checkout of that workspace as a sibling
  directory (default `../peat`, override with `PEAT_WORKSPACE_DIR`).
- **Generated sources are committed.** `lib/src/generated/` (FFI bindings) and
  `lib/src/proto/` (proto stubs) are committed so that consumers can build
  without the Rust / UniFFI / `protoc` toolchain. They only need to be
  regenerated when the native surface changes.
- **Bindings are maintained by hand.** The `uniffi-bindgen-dart` generator is
  not currently publicly available, so `lib/src/generated/peat_ffi.dart` is
  maintained manually. `just check-bindings` verifies it against the compiled
  library. See the [`justfile`](./justfile) for the specific invariants.
- **Pre-1.0.** The API surface is still evolving (current version `0.0.1`).

## Getting started

Add the plugin to a Flutter app and drive a node from Dart:

```dart
import 'package:peat_flutter/peat_flutter.dart';

final node = await PeatFlutterNode.create(/* ... */);
final sub = node.subscribeChanges((doc) {
  // react to synced document state
});
```

See [`example/lib/main.dart`](./example/lib/main.dart) for a complete demo app
(a peer-to-peer "water counter" that sums per-node state across a mesh cell).

### Run the example

```bash
cd example
flutter pub get
flutter run            # pick a connected device or desktop target
```

> The example bundles a prebuilt `peat-ffi` for the target platform. To build
> the native library yourself, see [Building native code](#building-native-code).

## Developer tasks

Tasks are driven by [`just`](https://github.com/casey/just) (see the
[`justfile`](./justfile)):

```bash
just analyze          # dart analyze lib/
just gen-proto        # regenerate Dart proto stubs from peat-schema
just check-bindings   # verify the generated FFI bindings against libpeat_ffi
just regen            # gen-proto + check-bindings
just build-host       # build peat-ffi for the native host
just build-android    # build peat-ffi for all Android ABIs (needs cargo-ndk + NDK)
just build-ios        # build PeatFFI.xcframework (macOS host only)
just build-macos      # build the universal macOS dylib (macOS host only)
```

### Test & lint

```bash
dart analyze lib/    # static analysis of the package (the CI gate; == just analyze)
flutter test         # unit tests (when present)
dart format .        # apply formatting (reported by CI, not yet gated)
```

CI runs these in [`.github/workflows`](./.github/workflows). The package
analysis (`dart analyze lib/`) gates merges; the example app's analysis and
formatting are reported informationally while the tree predates a format pass.

## Building native code

The `pubspec.yaml` marks this as an FFI plugin for each platform, which invokes
the native build and bundles the binaries:

- **Android:** Gradle invokes the Android NDK; `cargo-ndk` cross-compiles
  `peat-ffi`. See `android/build.gradle`.
- **iOS / macOS:** `ios/build-rust.sh` / `macos/build-rust.sh` produce a
  `PeatFFI.xcframework` / universal dylib that the podspecs wire in.
- **Linux / Windows:** `src/CMakeLists.txt` drives `cargo` at CMake build time.

### Regenerating bindings

FFI bindings in Dart are generated from the native header by
[`package:ffigen`](https://pub.dev/packages/ffigen):

```bash
dart run ffigen --config ffigen.yaml
```

Then reconcile any manual fixes per the notes in the [`justfile`](./justfile) and
run `just check-bindings`.

## iOS: multicast entitlement (required for direct device↔device discovery)

peat's local peer discovery (`peat_mesh::discovery::MdnsDiscovery`, backed by
iroh's `swarm-discovery` crate) finds peers via **raw UDP multicast**
(`224.0.0.251` / `ff02::fb`, port `5353`) — it does **not** use Apple's Bonjour
API. Since iOS 14, an app's own sockets cannot send/receive multicast unless the
app carries the `com.apple.developer.networking.multicast` entitlement. (The
`NSBonjourServices` / `NSLocalNetworkUsageDescription` keys in `Info.plist` only
cover the Bonjour *API*, which routes through the system `mDNSResponder` daemon —
they do **not** unlock raw multicast.)

Symptom without the entitlement: two iOS devices can each reach an unrestricted
node (e.g. a macOS peer) and sync transitively through it, but **never discover
each other directly**. mDNS needs multicast to flow both ways; an un-entitled iOS
node can't advertise itself, so two of them never complete the handshake. A macOS
node (no such restriction) brokers discovery and relays documents between them.

This repo already wires the entitlement: `example/ios/Runner/Runner.entitlements`
declares the key and `CODE_SIGN_ENTITLEMENTS` is set for Debug/Release/Profile.

### Apple approval (the entitlement is restricted)

The multicast entitlement must be granted by Apple for your team + bundle ID
before Automatic signing will include it — otherwise device builds fail with
*"Provisioning profile doesn't include the Multicast Networking capability."*

1. Submit the request: <https://developer.apple.com/contact/request/networking-multicast>
   (sign in as the team's Account Holder/Admin).
2. Provide the bundle ID (e.g. `com.defenseunicorns.peatFlutterExample`) and a
   justification, for example:

   > peat-water is a peer-to-peer local mesh application. It uses mDNS-based
   > service discovery over raw UDP multicast (via iroh/swarm-discovery) to find
   > peers on the same LAN and sync CRDT (Automerge) documents directly between
   > devices, including in fully offline/disconnected environments with no
   > internet or central server. The multicast entitlement is required so the app
   > can advertise and discover peers device-to-device; without it, two iOS
   > devices cannot find each other on the local network.

3. Approval typically takes 1–3 business days. Once granted, the
   *Multicast Networking* capability becomes available for the App ID; clean and
   rebuild (Xcode may need *Settings → Accounts → Download Manual Profiles*). No
   code change is needed — the wiring is already in place.

**Interim builds while the request is processing:** temporarily clear
`CODE_SIGN_ENTITLEMENTS` on the Runner target so device builds keep signing
(macOS-bridged sync still works). Restore it after approval.

## Project structure

- `lib/` — the Dart API of the plugin (`peat_flutter.dart`, `src/peat_node.dart`)
  and committed generated sources (`src/generated/`, `src/proto/`).
- `src/` — `CMakeLists.txt` driving the native build for Linux/Windows.
- platform folders (`android`, `ios`, `macos`, `linux`, `windows`) — native
  build/bundling for each target.
- `example/` — a runnable demo app.
- `docs/` — additional documentation, including [ADRs](./docs/adr/README.md).

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](./CONTRIBUTING.md) and
our [Code of Conduct](./CODE_OF_CONDUCT.md). To report a security issue, see
[SECURITY.md](./SECURITY.md).

## License

Licensed under the [Apache License, Version 2.0](./LICENSE).

```
Copyright 2026 Defense Unicorns
SPDX-License-Identifier: Apache-2.0
```
