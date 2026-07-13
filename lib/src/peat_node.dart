// Copyright 2026 Defense Unicorns
// SPDX-License-Identifier: Apache-2.0

// peat_flutter — Dart facade over the UniFFI-generated peat-ffi bindings.
//
// Every call in this file crosses into a dedicated background isolate that
// owns the native `PeatNode` for this node's whole lifetime. Flutter's engine
// now runs the UI and platform-channel threads as a single merged thread
// (`FLTEnableMergedPlatformUIThread`, mandatory as of the current engine), so
// a synchronous FFI call issued from Dart used to only block platform-channel
// work; it now blocks frame rendering too. peat-flutter's own polling loops
// (node/cell/document reads every few hundred ms) are exactly the kind of
// call that's slow enough, and frequent enough, to starve the UI thread of
// any idle time — the app looks permanently frozen even though nothing has
// deadlocked. Moving the native object and all its calls off the UI isolate
// entirely removes that contention regardless of how slow any given call is.

import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:protobuf/protobuf.dart';

import 'generated/peat_ffi.dart';
import '../peat_flutter.dart' show openPeatFfiLib;

export 'generated/peat_ffi.dart'
    show
        NodeConfig,
        TransportConfigFFI,
        DocumentChange,
        OutboundFrame,
        ChangeType,
        ChangeOrigin,
        PeerInfo,
        PeerTransportState,
        TransportLink,
        TransportPathKind,
        NodeInfo,
        NodeStatus,
        CellInfo,
        CellStatus,
        CommandInfo,
        CommandStatus,
        BlobFetchStatus,
        BlobFetchStatusPending,
        BlobFetchStatusStarted,
        BlobFetchStatusDownloading,
        BlobFetchStatusCompleted,
        BlobFetchStatusFailed,
        MarkerInfo;

final _rng = Random();

String _newDocId() =>
    '${DateTime.now().millisecondsSinceEpoch}-${_rng.nextInt(0xFFFF).toRadixString(16).padLeft(4, '0')}';

// ── Isolate wire protocol ───────────────────────────────────────────────
//
// Plain data classes only (no closures, no native handles) so they survive
// being sent across the isolate boundary.

class _Call {
  final int id;
  final String method;
  final List<dynamic> args;
  _Call(this.id, this.method, this.args);
}

class _Result {
  final int id;
  final dynamic value;
  final String? error;
  _Result(this.id, this.value, [this.error]);
}

class _StreamEvent {
  final int streamId;
  final dynamic value;
  _StreamEvent(this.streamId, this.value);
}

class _StreamDone {
  final int streamId;
  _StreamDone(this.streamId);
}

class _Ready {
  final SendPort sendPort;
  _Ready(this.sendPort);
}

// ── Isolate-side server ─────────────────────────────────────────────────
//
// Owns the native PeatNode and every FFI-backed handle (SubscriptionHandle,
// BlobFetchHandle) for the node's whole lifetime. Runs entirely off the UI
// thread, so blocking/slow FFI calls here cost latency, not frozen frames.

void _isolateMain(SendPort mainSend) {
  final rp = ReceivePort();
  mainSend.send(_Ready(rp.sendPort));

  PeatNode? node;

  final subs = <int, SubscriptionHandle>{};
  final subTimers = <int, Timer>{};

  Timer? outboundTimer;

  final blobHandles = <int, BlobFetchHandle>{};
  final blobTimers = <int, Timer>{};
  final blobLast = <int, BlobFetchStatus?>{};

  Timer? syncTimer;

  void stopChangeStream(int streamId) {
    subTimers.remove(streamId)?.cancel();
    final sub = subs.remove(streamId);
    if (sub != null) {
      if (!sub.isClosed) sub.cancel();
      sub.close();
    }
  }

  void stopOutbound() {
    outboundTimer?.cancel();
    outboundTimer = null;
    if (node != null && !node!.isClosed) {
      try {
        node!.stopOutboundFrames();
      } catch (_) {}
    }
  }

  void stopBlobStream(int streamId) {
    blobTimers.remove(streamId)?.cancel();
    blobLast.remove(streamId);
    final handle = blobHandles.remove(streamId);
    if (handle != null) {
      if (!handle.isClosed) handle.dispose();
      handle.close();
    }
  }

  Future<dynamic> dispatch(String method, List<dynamic> args) async {
    switch (method) {
      case 'initialize':
        configureDefaultBindings(dynamicLibrary: openPeatFfiLib());
        return null;

      case 'create':
        node = createNode(args[0] as NodeConfig);
        return null;

      case 'nodeId':
        return node!.nodeId();

      case 'endpointAddr':
        try {
          final url = node!.endpointAddr();
          return url.isEmpty ? '—' : url;
        } catch (_) {
          return '—';
        }

      case 'endpointSocketAddr':
        try {
          return node!.endpointSocketAddr();
        } catch (_) {
          return null;
        }

      case 'publishSelf':
        node!.putNode(NodeInfo(
          id: args[0] as String,
          nodeType: 'peat-flutter',
          name: args[1] as String,
          status: args[2] as NodeStatus,
          lat: 0,
          lon: 0,
          hae: null,
          readiness: args[3] as double,
          capabilities: (args[4] as List).cast<String>(),
          cellId: null,
          batteryPercent: null,
          heartRate: null,
          lastHeartbeat: DateTime.now().millisecondsSinceEpoch,
        ));
        return null;

      case 'nodes':
        return node!.getNodes();

      case 'deleteNode':
        node!.deleteDocument('nodes', args[0] as String);
        return null;

      case 'deleteDocument':
        node!.deleteDocument(args[0] as String, args[1] as String);
        return null;

      case 'putMarker':
        node!.putMarker(args[0] as MarkerInfo);
        return null;

      case 'markers':
        return node!.getMarkers();

      case 'putCell':
        node!.putCell(args[0] as CellInfo);
        return null;

      case 'cells':
        return node!.getCells();

      case 'putCommand':
        node!.putCommand(args[0] as CommandInfo);
        return null;

      case 'commands':
        return node!.getCommands();

      case 'peerCount':
        return node!.peerCount();

      case 'connectedPeers':
        return node!.connectedPeers();

      case 'connectPeer':
        node!.connectPeer(PeerInfo(
          name: args[3] as String,
          nodeId: args[0] as String,
          addresses: (args[1] as List).cast<String>(),
          relayUrl: args[2] as String?,
        ));
        return null;

      case 'connectPeerNowait':
        node!.connectPeerNowait(PeerInfo(
          name: args[3] as String,
          nodeId: args[0] as String,
          addresses: (args[1] as List).cast<String>(),
          relayUrl: args[2] as String?,
        ));
        return null;

      case 'rememberPeer':
        node!.rosterRemember(
          args[0] as String,
          PeerInfo(
            name: args[4] as String,
            nodeId: args[1] as String,
            addresses: (args[2] as List).cast<String>(),
            relayUrl: args[3] as String?,
          ),
        );
        return null;

      case 'reconnectKnownPeers':
        node!.reconnectKnownPeers();
        return null;

      case 'wakeReconnect':
        node!.wakeReconnect();
        return null;

      case 'onPeerObserved':
        node!.onPeerObserved(args[0] as String);
        return null;

      case 'syncStats':
        return node!.syncStats();

      case 'startSync':
        node!.startSync();
        syncTimer?.cancel();
        final intervalMs = args[0] as int;
        syncTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
          if (node != null && !node!.isClosed) node!.requestSync();
        });
        return null;

      case 'stopSync':
        syncTimer?.cancel();
        syncTimer = null;
        node!.stopSync();
        return null;

      case 'putDocument':
        node!.putDocument(args[0] as String, args[1] as String, args[2] as String);
        return null;

      case 'getDocument':
        return node!.getDocument(args[0] as String, args[1] as String);

      case 'listDocuments':
        return node!.listDocuments(args[0] as String);

      case 'peerTransportStates':
        try {
          return node!.allPeerTransportStates();
        } on PeatErrorException {
          return const <PeerTransportState>[];
        } on StateError {
          return const <PeerTransportState>[];
        }

      case 'subscribeChanges_start':
        {
          final streamId = args[0] as int;
          final pollMs = args[1] as int;
          final sub = node!.subscribePoll();
          subs[streamId] = sub;
          subTimers[streamId] = Timer.periodic(Duration(milliseconds: pollMs), (_) {
            if (sub.isClosed) return;
            for (final c in sub.pollChanges()) {
              mainSend.send(_StreamEvent(streamId, c));
            }
          });
          return null;
        }

      case 'subscribeChanges_cancel':
        stopChangeStream(args[0] as int);
        return null;

      case 'startOutboundFrames_start':
        {
          outboundTimer?.cancel();
          node!.startOutboundFrames();
          final streamId = args[0] as int;
          final pollMs = args[1] as int;
          outboundTimer = Timer.periodic(Duration(milliseconds: pollMs), (_) {
            if (node == null || node!.isClosed) return;
            for (final f in node!.pollOutboundFrames()) {
              mainSend.send(_StreamEvent(streamId, f));
            }
          });
          return null;
        }

      case 'startOutboundFrames_cancel':
        stopOutbound();
        return null;

      case 'enableBlobTransfer':
        node!.enableBlobTransfer(args[0] as String?);
        return null;

      case 'blobAddPeer':
        node!.blobAddPeer(args[0] as String, args[1] as String);
        return null;

      case 'blobAddPeerId':
        node!.blobAddPeerId(args[0] as String);
        return null;

      case 'blobPut':
        return node!.blobPut(args[0] as Uint8List, args[1] as String);

      case 'blobExistsLocally':
        return node!.blobExistsLocally(args[0] as String);

      case 'blobEndpointId':
        return node!.blobEndpointId();

      case 'blobBoundAddr':
        return node!.blobBoundAddr();

      case 'blobDownload_start':
        {
          final streamId = args[0] as int;
          final hashHex = args[1] as String;
          final sizeBytes = args[2] as int;
          final peerIdHex = args[3] as String?;
          final pollMs = args[4] as int;
          final handle = node!.blobFetchStart(hashHex, sizeBytes, peerIdHex);
          blobHandles[streamId] = handle;
          blobLast[streamId] = null;
          blobTimers[streamId] = Timer.periodic(Duration(milliseconds: pollMs), (_) {
            if (handle.isClosed) return;
            final status = handle.status();
            if (status != blobLast[streamId]) {
              mainSend.send(_StreamEvent(streamId, status));
              blobLast[streamId] = status;
            }
            if (status is BlobFetchStatusCompleted || status is BlobFetchStatusFailed) {
              mainSend.send(_StreamDone(streamId));
              stopBlobStream(streamId);
            }
          });
          return null;
        }

      case 'blobDownload_cancel':
        stopBlobStream(args[0] as int);
        return null;

      case 'ingestInboundFrame':
        return node!.ingestInboundFrame(args[0] as String, args[1] as Uint8List);

      case 'ingestInboundLiteFrame':
        return node!.ingestInboundLiteFrame(args[0] as String, args[1] as Uint8List);

      case 'publishDocument':
        return node!.publishDocument(args[0] as String, args[1] as String);

      case 'crdtCounterValue':
        return node!.crdtCounterValue();

      case 'crdtCounterIncrement':
        return node!.crdtCounterIncrement(args[0] as int);

      case 'crdtCounterMerge':
        return node!.crdtCounterMerge(args[0] as String);

      case 'crdtCounterSnapshot':
        return node!.crdtCounterSnapshot();

      case 'crdtKvPut':
        return node!.crdtKvPut(args[0] as String, args[1] as String, args[2] as String);

      case 'crdtKvAll':
        return node!.crdtKvAll(args[0] as String);

      case 'crdtKvMerge':
        node!.crdtKvMerge(args[0] as String, args[1] as String);
        return null;

      case 'crdtKvSnapshot':
        return node!.crdtKvSnapshot(args[0] as String);

      case 'dispose':
        for (final id in subTimers.keys.toList()) {
          stopChangeStream(id);
        }
        stopOutbound();
        for (final id in blobTimers.keys.toList()) {
          stopBlobStream(id);
        }
        syncTimer?.cancel();
        syncTimer = null;
        if (node != null && !node!.isClosed) {
          try {
            node!.stopSync();
          } catch (_) {}
          try {
            node!.stopOutboundFrames();
          } catch (_) {}
          node!.close();
        }
        return null;

      default:
        throw StateError('Unknown PeatFlutterNode isolate method: $method');
    }
  }

  rp.listen((msg) {
    if (msg is _Call) {
      dispatch(msg.method, msg.args).then(
        (value) => mainSend.send(_Result(msg.id, value)),
        onError: (Object e) => mainSend.send(_Result(msg.id, null, e.toString())),
      );
    }
  });
}

// ── Main-isolate proxy ──────────────────────────────────────────────────

/// Idiomatic Dart wrapper around the peat-ffi [PeatNode] UniFFI object.
///
/// Every method call is proxied to a dedicated background isolate that owns
/// the native node for its whole lifetime — see the file comment for why
/// this indirection exists.
///
/// ## Initialization
///
/// Call [PeatFlutterNode.initialize] once at app startup (before [create]):
/// ```dart
/// void main() {
///   PeatFlutterNode.initialize();
///   runApp(const MyApp());
/// }
/// ```
///
/// ## Usage
/// ```dart
/// final node = await PeatFlutterNode.create(NodeConfig(
///   appId: 'my-app',
///   sharedKey: base64Key,
///   bindAddress: null,
///   storagePath: appDir.path,
///   transport: null,
/// ));
/// await node.startSync();
///
/// node.subscribeChanges().listen((change) {
///   print('${change.collection}/${change.docId}');
/// });
/// ```
class PeatFlutterNode {
  static SendPort? _isolateSend;
  static Future<SendPort>? _isolateSendFuture;
  static final _pending = <int, Completer<dynamic>>{};
  static int _nextCallId = 0;
  static int _nextStreamId = 0;

  StreamController<DocumentChange>? _changeCtrl;
  int? _changeStreamId;
  StreamController<OutboundFrame>? _outboundCtrl;
  int? _outboundStreamId;
  StreamController<BlobFetchStatus>? _blobCtrl;
  int? _blobStreamId;

  PeatFlutterNode._();

  static Future<SendPort> _ensureIsolate() {
    final existing = _isolateSendFuture;
    if (existing != null) return existing;
    final completer = Completer<SendPort>();
    _isolateSendFuture = completer.future;
    () async {
      final rp = ReceivePort();
      await Isolate.spawn(_isolateMain, rp.sendPort);
      late final StreamSubscription sub;
      sub = rp.listen((msg) {
        if (msg is _Ready) {
          _isolateSend = msg.sendPort;
          completer.complete(msg.sendPort);
        } else if (msg is _Result) {
          final c = _pending.remove(msg.id);
          if (msg.error != null) {
            c?.completeError(StateError(msg.error!));
          } else {
            c?.complete(msg.value);
          }
        } else if (msg is _StreamEvent) {
          _dispatchStreamEvent(msg.streamId, msg.value);
        } else if (msg is _StreamDone) {
          _dispatchStreamDone(msg.streamId);
        }
      });
      // Keep a reference alive so the analyzer doesn't flag `sub` as unused;
      // the isolate + its ReceivePort live for the app's whole lifetime.
      _keepAlive.add(sub);
    }();
    return completer.future;
  }

  static final _keepAlive = <StreamSubscription>[];
  static final _changeControllers = <int, StreamController<DocumentChange>>{};
  static final _outboundControllers = <int, StreamController<OutboundFrame>>{};
  static final _blobControllers = <int, StreamController<BlobFetchStatus>>{};

  static void _dispatchStreamEvent(int streamId, dynamic value) {
    _changeControllers[streamId]?.add(value as DocumentChange);
    _outboundControllers[streamId]?.add(value as OutboundFrame);
    _blobControllers[streamId]?.add(value as BlobFetchStatus);
  }

  static void _dispatchStreamDone(int streamId) {
    _blobControllers[streamId]?.close();
  }

  static Future<dynamic> _call(String method, [List<dynamic> args = const []]) async {
    final send = _isolateSend ?? await _ensureIsolate();
    final id = _nextCallId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    send.send(_Call(id, method, args));
    return completer.future;
  }

  /// Wire the generated FFI bindings to the platform native library.
  /// Must be called once before any other [PeatFlutterNode] method.
  ///
  /// This eagerly warms the background isolate so the first [create] call
  /// doesn't pay isolate-spawn latency on top of node creation.
  static void initialize() {
    unawaited(_ensureIsolate().then((_) => _call('initialize')));
  }

  /// Create a new peat mesh node.
  static Future<PeatFlutterNode> create(NodeConfig config) async {
    await _call('initialize');
    await _call('create', [config]);
    return PeatFlutterNode._();
  }

  /// This node's hex-encoded unique identifier.
  Future<String> get nodeId async => await _call('nodeId') as String;

  /// The iroh relay URL this node is registered at (https:// form), or '—'
  /// if the relay connection has not yet been established.
  Future<String> get endpointAddr async => await _call('endpointAddr') as String;

  /// This node's bound socket address (host:port), if available.
  Future<String?> get endpointSocketAddr async =>
      await _call('endpointSocketAddr') as String?;

  /// Publish this node's presence with capabilities into the mesh.
  /// Other nodes will see it via [nodes].
  Future<void> publishSelf({
    required String nodeId,
    required String name,
    required List<String> capabilities,
    NodeStatus status = NodeStatus.active,
    double readiness = 1.0,
  }) =>
      _call('publishSelf', [nodeId, name, status, readiness, capabilities]);

  /// All nodes known to the mesh (including this one).
  Future<List<NodeInfo>> get nodes async =>
      (await _call('nodes') as List).cast<NodeInfo>();

  /// Remove a stale node entry from the local store.
  Future<void> deleteNode(String nodeId) => _call('deleteNode', [nodeId]);

  /// Delete a document by collection and id. Propagates across the mesh.
  Future<void> deleteDocument(String collection, String docId) =>
      _call('deleteDocument', [collection, docId]);

  // ── Markers ───────────────────────────────────────────────────────────

  /// Place or update a map marker (OR-Set entry). To soft-delete, publish a
  /// [MarkerInfo] with `deleted: true` — the tombstone propagates via CRDT.
  Future<void> putMarker(MarkerInfo marker) => _call('putMarker', [marker]);

  /// All markers known to the mesh, including soft-deleted tombstones.
  /// Filter on [MarkerInfo.deleted] to show only live pins.
  Future<List<MarkerInfo>> get markers async =>
      (await _call('markers') as List).cast<MarkerInfo>();

  // ── Cell ──────────────────────────────────────────────────────────────

  /// Publish a cell (team) into the mesh.
  Future<void> putCell(CellInfo cell) => _call('putCell', [cell]);

  /// All cells known to the mesh.
  Future<List<CellInfo>> get cells async =>
      (await _call('cells') as List).cast<CellInfo>();

  // ── Command ───────────────────────────────────────────────────────────

  /// Publish a command into the mesh.
  Future<void> putCommand(CommandInfo cmd) => _call('putCommand', [cmd]);

  /// All commands known to the mesh.
  Future<List<CommandInfo>> get commands async =>
      (await _call('commands') as List).cast<CommandInfo>();

  /// Number of currently connected peers.
  Future<int> get peerCount async => await _call('peerCount') as int;

  /// List of currently connected peer node IDs.
  Future<List<String>> get connectedPeers async =>
      (await _call('connectedPeers') as List).cast<String>();

  /// Manually dial a peer by its endpoint info, bypassing mDNS discovery.
  ///
  /// Needed where raw-multicast mDNS can't run — notably a physical iOS device
  /// without the (Apple-restricted) multicast entitlement: it can't *discover*
  /// peers on the LAN, but it can still *dial* a known peer's [addresses]
  /// (unicast QUIC, which iOS permits) and/or [relayUrl].
  Future<void> connectPeer({
    required String nodeId,
    List<String> addresses = const [],
    String? relayUrl,
    String name = '',
  }) =>
      _call('connectPeer', [nodeId, addresses, relayUrl, name]);

  /// Non-blocking variant of [connectPeer]: the dial runs on the native
  /// runtime and this returns as soon as the isolate has enqueued it. On
  /// success the peer surfaces in [connectedPeers].
  Future<void> connectPeerNowait({
    required String nodeId,
    List<String> addresses = const [],
    String? relayUrl,
    String name = '',
  }) =>
      _call('connectPeerNowait', [nodeId, addresses, relayUrl, name]);

  // --- Reconnect supervisor -------------------------------------------------

  /// Remember a group member so the native reconnect supervisor can re-dial it
  /// across restarts, network changes, and transport switches. Call once per
  /// member when joining a group (e.g. from a scanned join token). Idempotent.
  ///
  /// This replaces app-side redial timers: once a peer is remembered, the
  /// supervisor keeps a live path up to it over whatever transport is reachable,
  /// with backoff and cross-transport dedup handled natively.
  Future<void> rememberPeer({
    required String groupId,
    required String nodeId,
    List<String> addresses = const [],
    String? relayUrl,
    String name = '',
  }) =>
      _call('rememberPeer', [groupId, nodeId, addresses, relayUrl, name]);

  /// Gentle reconnect pass: dial any disconnected, eligible roster member now.
  /// Does not clear backoff. Cheap to call periodically.
  Future<void> reconnectKnownPeers() => _call('reconnectKnownPeers');

  /// Wake the supervisor after a broad connectivity change (network up, app
  /// foreground): clears backoff so every known peer is immediately eligible,
  /// then runs a pass. Call from `AppLifecycleState.resumed` and on
  /// connectivity-restored events.
  Future<void> wakeReconnect() => _call('wakeReconnect');

  /// Hint that a specific group member is reachable now — e.g. a BLE neighbour
  /// advertisement or a relay "peer online" signal. Dials it immediately if it
  /// isn't already connected and isn't backing off, bypassing the periodic tick
  /// (important inside a tight mobile background-execution budget).
  Future<void> onPeerObserved(String nodeId) => _call('onPeerObserved', [nodeId]);

  /// Current sync statistics (active, bytes sent/received).
  Future<SyncStats> get syncStats async => await _call('syncStats') as SyncStats;

  /// Start mesh synchronisation and begin periodic sync requests.
  Future<void> startSync({Duration syncInterval = const Duration(seconds: 5)}) =>
      _call('startSync', [syncInterval.inMilliseconds]);

  /// Stop mesh synchronisation.
  Future<void> stopSync() => _call('stopSync');

  /// Store [message] (a proto-generated [GeneratedMessage]) into [collection]
  /// under [docId]. Publishes to connected peers via Automerge sync.
  Future<void> putMessage(String collection, String docId, GeneratedMessage message) =>
      _call('putDocument', [collection, docId, message.writeToJson()]);

  /// Publish [jsonData] into [collection]. If [docId] is omitted a
  /// timestamp+random ID is generated. Returns the ID used.
  Future<String> publishRaw(String collection, String jsonData, {String? docId}) async {
    final id = docId ?? _newDocId();
    await _call('putDocument', [collection, id, jsonData]);
    return id;
  }

  /// Retrieve a document as a proto message, or null if not found.
  /// ```dart
  /// final track = await node.getMessage('tracks', docId, Track());
  /// ```
  Future<T?> getMessage<T extends GeneratedMessage>(
    String collection,
    String docId,
    T defaultInstance,
  ) async {
    final json = await _call('getDocument', [collection, docId]) as String?;
    if (json == null) return null;
    return (defaultInstance.createEmptyInstance()..mergeFromJson(json)) as T;
  }

  /// Retrieve a raw JSON document, or null if not found.
  Future<String?> getRaw(String collection, String docId) async =>
      await _call('getDocument', [collection, docId]) as String?;

  /// Store a raw JSON document under [collection]/[docId]. Synced across the
  /// mesh via the universal-document transport (Iroh/WiFi/relay). The
  /// counterpart to [getRaw].
  Future<void> putRaw(String collection, String docId, String json) =>
      _call('putDocument', [collection, docId, json]);

  /// List all document IDs in [collection].
  Future<List<String>> listDocuments(String collection) async =>
      (await _call('listDocuments', [collection]) as List).cast<String>();

  /// Per-peer transport state — how each peer is currently reachable (iroh/BLE,
  /// direct/relay, link quality). Currently enumerates peers visible to iroh.
  /// Returns an empty list rather than throwing if the query fails.
  Future<List<PeerTransportState>> peerTransportStates() async =>
      (await _call('peerTransportStates') as List).cast<PeerTransportState>();

  /// A broadcast [Stream] of document change events.
  ///
  /// Backed by isolate-side polling every [pollInterval] (default 50 ms).
  /// Cancelling the stream also cancels the underlying subscription.
  Stream<DocumentChange> subscribeChanges({
    Duration pollInterval = const Duration(milliseconds: 50),
  }) {
    final previous = _changeStreamId;
    if (previous != null) {
      unawaited(_call('subscribeChanges_cancel', [previous]));
      _changeControllers.remove(previous);
    }
    _changeCtrl?.close();

    final streamId = _nextStreamId++;
    _changeStreamId = streamId;
    final ctrl = StreamController<DocumentChange>.broadcast(
      onCancel: () {
        unawaited(_call('subscribeChanges_cancel', [streamId]));
        _changeControllers.remove(streamId);
      },
    );
    _changeCtrl = ctrl;
    _changeControllers[streamId] = ctrl;

    unawaited(_call('subscribeChanges_start', [streamId, pollInterval.inMilliseconds]));

    return ctrl.stream;
  }

  /// Registers the BLE translator fan-out and returns a broadcast [Stream]
  /// of outbound frames. On mobile, write each [OutboundFrame.bytes] to the
  /// relevant GATT characteristic after your own GATT framing + encryption.
  ///
  /// Cancelling the stream or calling [dispose] stops the fan-out.
  Stream<OutboundFrame> startOutboundFrames({
    Duration pollInterval = const Duration(milliseconds: 50),
  }) {
    final previous = _outboundStreamId;
    if (previous != null) {
      unawaited(_call('startOutboundFrames_cancel'));
      _outboundControllers.remove(previous);
    }
    _outboundCtrl?.close();

    final streamId = _nextStreamId++;
    _outboundStreamId = streamId;
    final ctrl = StreamController<OutboundFrame>.broadcast(
      onCancel: () {
        unawaited(_call('startOutboundFrames_cancel'));
        _outboundControllers.remove(streamId);
      },
    );
    _outboundCtrl = ctrl;
    _outboundControllers[streamId] = ctrl;

    unawaited(_call('startOutboundFrames_start', [streamId, pollInterval.inMilliseconds]));

    return ctrl.stream;
  }

  /// Enable the parallel blob-transfer endpoint (peat#1013). Call once before
  /// [blobPut]/[blobDownload]. [bindAddr] defaults to an ephemeral port when
  /// null.
  Future<void> enableBlobTransfer([String? bindAddr]) =>
      _call('enableBlobTransfer', [bindAddr]);

  /// Register a known blob peer by hex endpoint id and explicit address.
  Future<void> blobAddPeer(String peerIdHex, String address) =>
      _call('blobAddPeer', [peerIdHex, address]);

  /// Register a known blob peer by hex endpoint id only — no static address,
  /// so relay/DNS discovery resolves the route. Prefer this over
  /// [blobAddPeer] when the peer may be on a different network/NAT.
  Future<void> blobAddPeerId(String peerIdHex) => _call('blobAddPeerId', [peerIdHex]);

  /// Store bytes in the local blob store. Returns the content hash as hex.
  Future<String> blobPut(Uint8List data, String contentType) async =>
      await _call('blobPut', [data, contentType]) as String;

  /// Check if a blob exists locally without a network fetch.
  Future<bool> blobExistsLocally(String hashHex) async =>
      await _call('blobExistsLocally', [hashHex]) as bool;

  /// This node's blob endpoint id as hex, or null if blob transfer is disabled.
  Future<String?> blobEndpointId() async => await _call('blobEndpointId') as String?;

  /// This node's bound blob endpoint address as "ip:port", or null if blob
  /// transfer is disabled.
  Future<String?> blobBoundAddr() async => await _call('blobBoundAddr') as String?;

  /// Download a blob by content hash (peat#1013), as a broadcast [Stream] of
  /// progress. Two delivery modes:
  ///
  ///  - Mesh-sync (default): omit [peerIdHex] — the mesh's automatic,
  ///    health-filtered candidate-peer selection tries to fetch the blob from
  ///    any known peer, independent of when/whether this call is made.
  ///  - Direct P2P: pass [peerIdHex] to pull straight from that peer,
  ///    bypassing candidate selection entirely — no fallback to another
  ///    peer on failure. The peer must already be known via [blobAddPeer] or
  ///    [blobAddPeerId].
  ///
  /// The stream closes itself once a terminal [BlobFetchStatusCompleted] or
  /// [BlobFetchStatusFailed] status is emitted. Cancelling the stream early
  /// disposes the underlying fetch (aborts the transfer).
  Stream<BlobFetchStatus> blobDownload(
    String hashHex,
    int sizeBytes, {
    String? peerIdHex,
    Duration pollInterval = const Duration(milliseconds: 100),
  }) {
    final previous = _blobStreamId;
    if (previous != null) {
      unawaited(_call('blobDownload_cancel', [previous]));
      _blobControllers.remove(previous);
    }
    _blobCtrl?.close();

    final streamId = _nextStreamId++;
    _blobStreamId = streamId;
    final ctrl = StreamController<BlobFetchStatus>.broadcast(
      onCancel: () {
        unawaited(_call('blobDownload_cancel', [streamId]));
        _blobControllers.remove(streamId);
      },
    );
    _blobCtrl = ctrl;
    _blobControllers[streamId] = ctrl;

    unawaited(_call('blobDownload_start',
        [streamId, hashHex, sizeBytes, peerIdHex, pollInterval.inMilliseconds]));

    return ctrl.stream;
  }

  /// Feed a BLE inbound frame (postcard bytes from peat-btle) into the mesh.
  ///
  /// Returns the document ID if the frame was accepted, null if unknown.
  Future<String?> ingestInboundFrame(String collection, Uint8List postcardBytes) async =>
      await _call('ingestInboundFrame', [collection, postcardBytes]) as String?;

  /// Feed a BLE inbound frame on the universal-Document ("ble-lite") codec.
  ///
  /// The counterpart of [ingestInboundFrame] for raw collections the typed
  /// translator declines (e.g. the demo counter, nodes/cells/mission/commands).
  /// Returns the document ID if accepted, null if the collection is unknown.
  Future<String?> ingestInboundLiteFrame(String collection, Uint8List envelopeBytes) async =>
      await _call('ingestInboundLiteFrame', [collection, envelopeBytes]) as String?;

  /// Publish a JSON document through the node layer so it reaches the ADR-059
  /// fan-out and is emitted over the bridged transports (BLE/Wi-Fi). Unlike
  /// [publishRaw]/[putRaw] (which write to storage_backend and bypass the
  /// fan-out), this is what makes a locally-authored doc sync to peers over
  /// BLE. The JSON's `id` field, if present, becomes the doc id (returned).
  Future<String> publishDocument(String collection, String json) async =>
      await _call('publishDocument', [collection, json]) as String;

  // ── Shared water-supply Counter (CRDT-over-Automerge-over-BLE) ──────────
  // A self-contained Automerge Counter doc; its save() bytes (hex) ride the
  // BLE frame bus and merge natively (commutative/idempotent), so the caller
  // can broadcast/relay freely without dedup or ordering concerns.

  /// Current merged value of the shared water-supply Counter.
  Future<int> crdtCounterValue() async => await _call('crdtCounterValue') as int;

  /// Apply [delta] liters; returns hex doc bytes to broadcast to peers.
  Future<String> crdtCounterIncrement(int delta) async =>
      await _call('crdtCounterIncrement', [delta]) as String;

  /// Merge an inbound peer doc (hex); returns the new value.
  Future<int> crdtCounterMerge(String hexDoc) async =>
      await _call('crdtCounterMerge', [hexDoc]) as int;

  /// Current hex doc bytes for periodic re-broadcast (late-joiner catch-up).
  Future<String> crdtCounterSnapshot() async =>
      await _call('crdtCounterSnapshot') as String;

  // Generic CRDT KV documents (nodes/commands/cells/mission).
  Future<String> crdtKvPut(String collection, String key, String valueJson) async =>
      await _call('crdtKvPut', [collection, key, valueJson]) as String;
  Future<String> crdtKvAll(String collection) async =>
      await _call('crdtKvAll', [collection]) as String;
  Future<void> crdtKvMerge(String collection, String hexDoc) =>
      _call('crdtKvMerge', [collection, hexDoc]);
  Future<String> crdtKvSnapshot(String collection) async =>
      await _call('crdtKvSnapshot', [collection]) as String;

  /// Cancel all active subscriptions and release FFI resources.
  Future<void> dispose() async {
    final changeId = _changeStreamId;
    if (changeId != null) _changeControllers.remove(changeId);
    final outboundId = _outboundStreamId;
    if (outboundId != null) _outboundControllers.remove(outboundId);
    final blobId = _blobStreamId;
    if (blobId != null) _blobControllers.remove(blobId);

    await _changeCtrl?.close();
    await _outboundCtrl?.close();
    await _blobCtrl?.close();

    await _call('dispose');
  }
}
