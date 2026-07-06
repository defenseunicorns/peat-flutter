// Headless smoke test for the hand-written blob-transfer FFI bindings
// (peat#1013, peat#1017, peat-mesh#274).
//
// Exercises the new ffibuffer calls (enableBlobTransfer, blobPut, blobAddPeer,
// blobAddPeerId, blobExistsLocally, blobEndpointId, blobBoundAddr,
// blobFetchStart, BlobFetchHandle.status/dispose) against two real nodes so a
// bad buffer layout in dart_ffi.rs or peat_ffi.dart surfaces as a crash/throw
// here rather than only on-device. Not a unit test — run manually:
//
//   cargo build --release -p peat-ffi --features sync,bluetooth,lite-bridge
//   dart run tool/smoke_blob.dart /path/to/libpeat_ffi.dylib
//
// Uses sync-only (no BLE) so it runs in a plain Dart process without
// CoreBluetooth/app-bundle context.

import 'dart:io';
import 'dart:typed_data';

import 'package:peat_flutter/src/generated/peat_ffi.dart';

NodeConfig _config(String appId, String storagePath) => NodeConfig(
      appId: appId,
      sharedKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      bindAddress: '127.0.0.1:0',
      storagePath: storagePath,
      transport: null,
    );

void main(List<String> args) {
  final libPath = args.isNotEmpty
      ? args.first
      : '/Users/kit/Code/Peat/peat/target/release/libpeat_ffi.dylib';
  if (!File(libPath).existsSync()) {
    stderr.writeln('lib not found: $libPath');
    exit(2);
  }

  configureDefaultBindings(libraryPath: libPath);

  final tmpA = Directory.systemTemp.createTempSync('peat-smoke-blob-a-');
  final tmpB = Directory.systemTemp.createTempSync('peat-smoke-blob-b-');
  PeatNode? nodeA;
  PeatNode? nodeB;
  try {
    nodeA = createNode(_config('blob-smoke', tmpA.path));
    nodeB = createNode(_config('blob-smoke', tmpB.path));
    print('OK   createNode x2');

    // --- enable + basic put/exists/endpoint/bound-addr -----------------------
    nodeA.enableBlobTransfer('127.0.0.1:0');
    nodeB.enableBlobTransfer('127.0.0.1:0');
    print('OK   enableBlobTransfer x2');

    final aEndpointId = nodeA.blobEndpointId();
    final aBoundAddr = nodeA.blobBoundAddr();
    if (aEndpointId == null || aBoundAddr == null) {
      throw StateError('expected non-null blobEndpointId/blobBoundAddr after enable');
    }
    print('OK   blobEndpointId=$aEndpointId blobBoundAddr=$aBoundAddr');

    final data = Uint8List.fromList('smoke test blob payload'.codeUnits);
    final hash = nodeA.blobPut(data, 'text/plain');
    if (hash.isEmpty) {
      throw StateError('expected non-empty hash from blobPut');
    }
    print('OK   blobPut -> $hash');

    if (!nodeA.blobExistsLocally(hash)) {
      throw StateError('expected blob to exist locally on A after put');
    }
    if (nodeB.blobExistsLocally(hash)) {
      throw StateError('B should not have the blob yet');
    }
    print('OK   blobExistsLocally (A=true, B=false)');

    // --- direct P2P mode: blobAddPeer (explicit addr) + blobFetchStart(peerId) ---
    nodeB.blobAddPeer(aEndpointId, aBoundAddr);
    print('OK   blobAddPeer (explicit address)');

    final directHandle = nodeB.blobFetchStart(hash, data.length, aEndpointId);
    print('OK   blobFetchStart (direct mode) returned a handle');

    BlobFetchStatus status = directHandle.status();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (status is! BlobFetchStatusCompleted &&
        status is! BlobFetchStatusFailed &&
        DateTime.now().isBefore(deadline)) {
      sleep(const Duration(milliseconds: 100));
      status = directHandle.status();
    }
    print('OK   direct fetch terminal status: $status');
    if (status is! BlobFetchStatusCompleted) {
      throw StateError('expected direct fetch to complete, got $status');
    }
    directHandle.dispose();
    print('OK   BlobFetchHandle.dispose (idempotent-safe)');

    // --- blobAddPeerId (id-only registration) sanity check -------------------
    final fakePeerId = 'c' * 64;
    nodeB.blobAddPeerId(fakePeerId);
    print('OK   blobAddPeerId (id-only registration, no crash)');

    // --- mesh-sync mode: blobFetchStart(peerId: null) on an already-local blob ---
    final localHandle = nodeA.blobFetchStart(hash, data.length, null);
    BlobFetchStatus localStatus = localHandle.status();
    final localDeadline = DateTime.now().add(const Duration(seconds: 5));
    while (localStatus is! BlobFetchStatusCompleted &&
        localStatus is! BlobFetchStatusFailed &&
        DateTime.now().isBefore(localDeadline)) {
      sleep(const Duration(milliseconds: 50));
      localStatus = localHandle.status();
    }
    print('OK   mesh-sync fetch (already local) terminal status: $localStatus');
    if (localStatus is! BlobFetchStatusCompleted) {
      throw StateError('expected local short-circuit fetch to complete, got $localStatus');
    }
    localHandle.dispose();

    print('SMOKE OK');
  } catch (e, st) {
    stderr.writeln('SMOKE FAILED: $e\n$st');
    exitCode = 1;
  } finally {
    try {
      nodeA?.close();
    } catch (_) {}
    try {
      nodeB?.close();
    } catch (_) {}
    try {
      tmpA.deleteSync(recursive: true);
    } catch (_) {}
    try {
      tmpB.deleteSync(recursive: true);
    } catch (_) {}
  }
}
