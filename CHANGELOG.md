## 0.0.1

* Initial scaffold: Flutter FFI plugin over peat-ffi v0.2.5 (UniFFI 0.28).
  Dart facade: `PeatFlutterNode` with `subscribeChanges`, `startOutboundFrames`,
  `ingestInboundFrame`, proto-typed `getMessage`/`publishMessage`.
* `CellInfo.platformCount` renamed to `nodeCount` (ADR-068 node vocabulary, peat#969).
* Android: `preBuild` Gradle task cross-compiles peat-ffi via cargo-ndk.
* Linux/Windows: `src/CMakeLists.txt` drives cargo at CMake build time.
* iOS/macOS: `ios/build-rust.sh` produces `PeatFFI.xcframework`; podspec wires it in.
* Consume published peat-ffi `0.2.8` (was `0.2.7`); add `PeatNode.connectPeerNowait`
  Dart binding — a non-blocking, fire-and-forget connect that doesn't freeze the
  calling isolate on the dial (peat#995).
