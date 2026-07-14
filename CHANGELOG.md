## 0.1.0

* First real versioned release — everything below had accumulated on `main`
  unreleased since the `0.0.1` scaffold.
* **Background-isolate proxy for `PeatFlutterNode`** (#24, #25). Every native
  FFI call now runs on a persistent background isolate instead of the UI
  isolate, fixing UI freezes/unresponsiveness (button taps, scrolls) caused by
  synchronous FFI calls blocking Flutter's merged UI/platform thread.
* **MarkerInfo OR-Set facade + `deleteDocument` + delete-event visibility**
  (#21, peat#2, peat#3).
* **`blobDownload` facade + hand-maintained blob FFI bindings** (#20).
* Consume published peat-ffi `0.2.8` → `0.2.10`, transitively picking up
  peat-mesh `0.9.0-rc.48`'s IPv6 reachability fix — a broken IPv6 route was
  being advertised despite no functional path, causing formation-auth
  handshakes to time out and tear down relay connections (peat-flutter#22:
  "relay connection is constantly dropped between the apps"). See
  [peat-mesh#304](https://github.com/defenseunicorns/peat-mesh/pull/304).

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
