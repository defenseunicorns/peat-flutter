# Onboarding: Iroh Relay Toggle (internet sync) — handoff

Adds a user-facing **"Enable Internet Relay"** toggle to the example app's
**About** tab. ON = the node's iroh endpoint opts into n0's hosted **public**
relay pool (`presets::N0`) so internet-connected devices sync **without a shared
LAN**, alongside the existing BLE/Wi-Fi mesh. OFF (default) = local-mesh-only,
no phone-home. It's a runtime per-node-start choice, so toggling **restarts the
node**.

## TL;DR status

| Layer | State |
|---|---|
| peat-mesh: runtime relay arg (`relay_policy_builder(enable_n0_relay)`) | ✅ merged + **published rc.42** |
| peat-ffi: `TransportConfigFFI.enable_n0_relay` field + wiring | ✅ merged (#989), **published 0.2.7** |
| peat-flutter: consume 0.2.7 + bindings field + About-tab toggle | ✅ on branch, **macOS verified** |
| iOS simulator run | ⏳ blocked by an unrelated prebuilt BLE blob (see Caveats) |
| Android on-device | ⏳ build rewire is mechanical, **not yet built on NDK** |
| Two-device cross-network relay-transit acceptance test | ⏳ manual, not yet run |

## Where the code is

**Branch: `feat/consume-published-peat-ffi`** (local, NOT pushed). 4 commits:
- `d31491a` consume published peat-ffi 0.2.5 + re-sync drifted bindings
- `389732b` consume 0.2.7 + About-tab relay toggle
- `808009e` stop tracking rust/ build artifacts; gitignore target/
- `80f6795` build native FFI from published peat-ffi via rust/ wrapper

`feat/iroh-relay-toggle` is an **earlier, superseded** version — ignore it.

What the branch changes:
- **`rust/`** — a new cdylib wrapper crate (mirrors peat-swift) that builds
  `libpeat_ffi` from the **published** `peat-ffi = "=0.2.7"` crate (no `../peat`
  checkout needed). Pins `features = ["sync","bluetooth","lite-bridge"]`.
- **`lib/src/generated/peat_ffi.dart`** — hand-maintained bindings: re-synced to
  0.2.7 + `enableN0Relay` field appended to `TransportConfigFFI` (+ codec).
- **`example/lib/main.dart`** — About-tab toggle (`_toggleIrohRelay`, persisted
  in shared_preferences; sets `enableN0Relay` on the node config; restarts node).
- **Build scripts** (`macos/ios/build-rust.sh`, `android/build.gradle`,
  `src/CMakeLists.txt`, `justfile`) — rewired to build the `rust/` wrapper
  instead of `../peat` source.

Upstream (already published to crates.io — no checkout needed):
- `peat-mesh 0.9.0-rc.42` carries `from_seed_with_discovery_at_addr(.., enable_n0_relay)`.
- `peat-ffi 0.2.7` carries `TransportConfigFFI.enable_n0_relay`.

## Build & run

```sh
git checkout feat/consume-published-peat-ffi

# macOS (VERIFIED end-to-end):
just build-macos          # builds rust/ wrapper -> macos/Frameworks/libpeat_ffi.dylib
cd example && flutter run -d macos

# Android (build rewire is mechanical; NOT yet built on NDK — verify this):
#   flutter run -d <android-device>   (gradle buildRustAndroid builds the wrapper)

# iOS: see Caveats — sim run is blocked by the peat_apple_ffi blob, NOT by this feature.
```

## How to test the feature

- **Quick (one device / sim):** open the **About** tab → toggle **Enable Internet
  Relay**. Node restarts; status flips on/off. (This alone just proves wiring.)
- **Acceptance test (the real one):** two devices on **different networks** (e.g.
  phone on cellular, laptop on Wi-Fi — explicitly NOT the same LAN, BLE out of
  range). Toggle relay **ON** on both, increment the water counter on one, confirm
  it converges on the other. Toggle **OFF** on both → they should stop syncing
  across networks (local-mesh-only). *Relay transit can't be exercised on one
  host / in a simulator — it needs real network separation.*

Automated coverage already green (run in the peat workspace):
- peat-mesh: `relay_policy_binds_in_both_postures` (unit), `relay_n0_sync_e2e` (hermetic loopback connect).
- peat-ffi: `create_node_honors_enable_n0_relay_in_both_postures`.

## Caveats / gotchas

- **`lite-bridge` is intentionally ON** in the wrapper: the demo's BLE relay uses
  `ble-lite` frames at runtime (`ingestInboundLiteFrame`). It's the microcontroller
  tier in general, but the demo currently requires it. Don't drop it without
  migrating the demo's BLE path off the lite envelope.
- **iOS sim is blocked by a SEPARATE library, not this feature.** The Runner links
  `example/ios/Frameworks/PeatAppleFFI.xcframework` (`peat_apple_ffi` — the native
  BLE bridge, a committed PREBUILT blob since #6 with no source/build-script in any
  local repo). `flutter build ios --simulator` fails to *link* it (config issue;
  the blob has the symbols). **It is NOT needed for the simulator or the relay
  feature** — the sim has no Bluetooth radio and relay rides iroh via peat-ffi. To
  run the sim, either (a) fix the Runner link/embed config (the blob is inert in
  sim), or (b) `#if !targetEnvironment(simulator)` the BLE bridge out so sim runs
  on peat-ffi alone. Its provenance is a separate, device-only concern.
- **Bindings are hand-maintained** (no public Dart uniffi-bindgen for this ABI).
  If peat-ffi's surface changes, re-sync `lib/src/generated/peat_ffi.dart` by hand
  (append Record fields LAST to match Rust codec order; bump the matching checksum
  constants). All 49 checksums currently match published 0.2.7 (contract v30).
- **Nothing is pushed.** The branch is local; decide push/PR after iOS/Android build.
