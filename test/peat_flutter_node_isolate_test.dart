// Copyright 2026 Defense Unicorns
// SPDX-License-Identifier: Apache-2.0

// Round-trip smoke test for the background-isolate proxy layer added to fix
// the merged-UI/platform-thread freeze (peat-flutter#24/#25 QA finding:
// "no test coverage of the new isolate proxy layer").
//
// Requires the compiled peat-ffi native library for the host platform.
// CI's `test` job runs pure-Dart tests on ubuntu-latest with no native
// artifact built (see CONTRIBUTING.md / ci.yaml) — this test detects that
// up front and skips itself rather than failing, so it still runs for real
// wherever the library IS available (local development on a platform where
// it's been built, or CI jobs extended to build it first).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peat_flutter/peat_flutter.dart';

bool _nativeLibAvailable() {
  try {
    openPeatFfiLib();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  final available = _nativeLibAvailable();
  if (!available) {
    test(
      'isolate round-trip smoke test (skipped — no native library available)',
      () {},
      skip:
          'peat_ffi native library not found for this platform/host; '
          'see CONTRIBUTING.md for how to build it locally.',
    );
    return;
  }

  test('PeatFlutterNode round-trips through the background isolate', () async {
    PeatFlutterNode.initialize();

    final tempDir = await Directory.systemTemp.createTemp('peat_flutter_test_');
    addTearDown(
      () => tempDir.delete(recursive: true).catchError((_) => tempDir),
    );

    final node = await PeatFlutterNode.create(
      NodeConfig(
        appId: 'peat-flutter-isolate-test',
        sharedKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        bindAddress: null,
        storagePath: tempDir.path,
        transport: null,
      ),
    );

    // A second create() while this node is live must fail loudly, not
    // silently leak/overwrite the native handle (peat-flutter#25 QA).
    await expectLater(
      PeatFlutterNode.create(
        NodeConfig(
          appId: 'peat-flutter-isolate-test-2',
          sharedKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          bindAddress: null,
          storagePath: tempDir.path,
          transport: null,
        ),
      ),
      throwsA(isA<PeatFlutterProxyError>()),
    );

    // Basic reads round-trip through the isolate and back.
    final id = await node.nodeId;
    expect(id, isNotEmpty);

    final nodes = await node.nodes;
    expect(nodes, isA<List<NodeInfo>>());

    // A document write + read round-trips correctly.
    final docId = await node.publishRaw('test', '{"hello":"world"}');
    final raw = await node.getRaw('test', docId);
    expect(raw, '{"hello":"world"}');

    // Flutter-owned typed facades use peat-ffi's generic document API. This
    // guards against reintroducing stale native get/put marker/command symbols.
    const marker = MarkerInfo(
      uid: 'marker-1',
      markerType: 'b-m-p-w',
      lat: 38.0,
      lon: -77.0,
      hae: null,
      ts: 1234,
      callsign: 'test',
      color: null,
      cellId: null,
      deleted: false,
    );
    await node.putMarker(marker);
    expect(await node.markers, contains(marker));

    const command = CommandInfo(
      id: 'command-1',
      commandType: 'MOVE',
      targetId: 'node-1',
      parameters: '{}',
      priority: 1,
      status: CommandStatus.pending,
      originator: 'test',
      createdAt: 1234,
      lastUpdate: 1234,
    );
    await node.putCommand(command);
    expect(await node.commands, contains(command));

    // subscribeChanges: the stream delivers the write above, and
    // cancelling it correctly stops isolate-side polling (no error/leak).
    final changeReceived = Completer<void>();
    final sub = node
        .subscribeChanges(pollInterval: const Duration(milliseconds: 20))
        .listen((change) {
          if (!changeReceived.isCompleted) changeReceived.complete();
        });
    await node.publishRaw('test', '{"another":"change"}');
    await changeReceived.future.timeout(const Duration(seconds: 5));
    await sub.cancel();

    // dispose() tears down cleanly with no error.
    await node.dispose();
  });
}
