// Headless smoke test for the hand-written reconnect-supervisor FFI bindings.
//
// Exercises the four new ffibuffer calls (roster_remember, reconnect_known_peers,
// wake_reconnect, on_peer_observed) against a real node so a bad buffer layout
// surfaces as a crash/throw here rather than only on-device. Not a unit test —
// run manually:
//
//   cargo build --release -p peat-ffi --features sync   # in ../peat
//   dart run tool/smoke_reconnect.dart \
//     /Users/caidenplummer/code/peat/target/release/libpeat_ffi.dylib
//
// Uses sync-only (no BLE) so it runs in a plain Dart process without
// CoreBluetooth/app-bundle context.

import 'dart:io';

import 'package:peat_flutter/src/generated/peat_ffi.dart';

void main(List<String> args) {
  final libPath = args.isNotEmpty
      ? args.first
      : '/Users/caidenplummer/code/peat/target/release/libpeat_ffi.dylib';
  if (!File(libPath).existsSync()) {
    stderr.writeln('lib not found: $libPath');
    exit(2);
  }

  configureDefaultBindings(libraryPath: libPath);

  final tmp = Directory.systemTemp.createTempSync('peat-smoke-');
  PeatNode? node;
  try {
    node = createNode(NodeConfig(
      appId: 'peat-flutter-example',
      sharedKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      bindAddress: '127.0.0.1:0',
      storagePath: tmp.path,
      // Non-null transport (matches the app) — exercises the TransportConfigFFI
      // encode path, which must serialize all 6 Rust fields incl. enableN0Relay.
      transport: const TransportConfigFFI(
        enableBle: true,
        bleMeshId: null,
        blePowerProfile: 'balanced',
        transportPreference: null,
        collectionRoutesJson: null,
      ),
    ));
    print('OK   createNode -> ${node.nodeId()}');

    // A plausible-looking (fake) peer: 64 hex chars, unroutable address. The
    // supervisor will try to dial it and fail — that's fine; we're testing the
    // call marshalling, not connectivity.
    final fakePeer = PeerInfo(
      name: 'bravo',
      nodeId: 'a' * 64,
      addresses: const ['127.0.0.1:59999'],
      relayUrl: null,
    );

    node.rosterRemember('peat-flutter-example', fakePeer);
    print('OK   rosterRemember (group + PeerInfo args)');

    // Idempotent re-remember + a relay_url-present variant (Option<String> arg).
    node.rosterRemember(
        'peat-flutter-example',
        PeerInfo(
          name: 'charlie',
          nodeId: 'b' * 64,
          addresses: const [],
          relayUrl: 'https://relay.example',
        ));
    print('OK   rosterRemember (empty addresses + relay_url)');

    node.reconnectKnownPeers();
    print('OK   reconnectKnownPeers (handle-only)');

    node.wakeReconnect();
    print('OK   wakeReconnect (handle-only)');

    node.onPeerObserved('a' * 64);
    print('OK   onPeerObserved (known peer)');

    node.onPeerObserved('f' * 64);
    print('OK   onPeerObserved (unknown peer -> no-op)');

    // Let the spawned dials run a beat so any panic in the async path surfaces.
    sleep(const Duration(seconds: 2));

    // Validate the DocumentChange decode now that it carries `origin`: the Rust
    // Record serializes a 4th field and the Dart decoder throws on leftover
    // bytes, so a successful decode proves the layouts agree. A local write must
    // surface as a change whose origin is Local.
    final sub = node.subscribePoll();
    node.putDocument('smoke', 'doc-1', '{"v":1}');
    sleep(const Duration(milliseconds: 500));
    final changes = sub.pollChanges();
    print('OK   pollChanges decoded ${changes.length} change(s)');
    for (final c in changes) {
      print('     ${c.collection}:${c.docId} ${c.changeType} origin=${c.origin}');
    }
    if (changes.isEmpty) {
      throw StateError('expected at least one change from the local write');
    }
    if (!changes.any((c) => c.collection == 'smoke' && c.origin.isLocal)) {
      throw StateError('expected a Local-origin change for the smoke write');
    }
    print('OK   DocumentChange.origin decoded (Local)');
    sub.cancel();

    print('SMOKE OK');
  } catch (e, st) {
    stderr.writeln('SMOKE FAILED: $e\n$st');
    exitCode = 1;
  } finally {
    try {
      node?.close();
    } catch (_) {}
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}
