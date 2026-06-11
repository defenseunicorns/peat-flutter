# peat_flutter

A new Flutter FFI plugin project.

## Getting Started

This project is a starting point for a Flutter
[FFI plugin](https://flutter.dev/to/ffi-package),
a specialized package that includes native code directly invoked with Dart FFI.

## Project structure

This template uses the following structure:

* `src`: Contains the native source code, and a CmakeFile.txt file for building
  that source code into a dynamic library.

* `lib`: Contains the Dart code that defines the API of the plugin, and which
  calls into the native code using `dart:ffi`.

* platform folders (`android`, `ios`, `windows`, etc.): Contains the build files
  for building and bundling the native code library with the platform application.

## Building and bundling native code

The `pubspec.yaml` specifies FFI plugins as follows:

```yaml
  plugin:
    platforms:
      some_platform:
        ffiPlugin: true
```

This configuration invokes the native build for the various target platforms
and bundles the binaries in Flutter applications using these FFI plugins.

This can be combined with dartPluginClass, such as when FFI is used for the
implementation of one platform in a federated plugin:

```yaml
  plugin:
    implements: some_other_plugin
    platforms:
      some_platform:
        dartPluginClass: SomeClass
        ffiPlugin: true
```

A plugin can have both FFI and method channels:

```yaml
  plugin:
    platforms:
      some_platform:
        pluginClass: SomeName
        ffiPlugin: true
```

The native build systems that are invoked by FFI (and method channel) plugins are:

* For Android: Gradle, which invokes the Android NDK for native builds.
  * See the documentation in android/build.gradle.
* For iOS and MacOS: Xcode, via CocoaPods.
  * See the documentation in ios/peat_flutter.podspec.
  * See the documentation in macos/peat_flutter.podspec.
* For Linux and Windows: CMake.
  * See the documentation in linux/CMakeLists.txt.
  * See the documentation in windows/CMakeLists.txt.

## Binding to native code

To use the native code, bindings in Dart are needed.
To avoid writing these by hand, they are generated from the header file
(`src/peat_flutter.h`) by `package:ffigen`.
Regenerate the bindings by running `dart run ffigen --config ffigen.yaml`.

## Invoking native code

Very short-running native functions can be directly invoked from any isolate.
For example, see `sum` in `lib/peat_flutter.dart`.

Longer-running functions should be invoked on a helper isolate to avoid
dropping frames in Flutter applications.
For example, see `sumAsync` in `lib/peat_flutter.dart`.

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

## Flutter help

For help getting started with Flutter, view our
[online documentation](https://docs.flutter.dev), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

