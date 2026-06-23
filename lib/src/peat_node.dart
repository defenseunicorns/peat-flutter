// Copyright 2026 Defense Unicorns
// SPDX-License-Identifier: Apache-2.0

// peat_flutter — Dart facade over the UniFFI-generated peat-ffi bindings.

import 'dart:async';
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
        CommandStatus;

final _rng = Random();

String _newDocId() =>
    '${DateTime.now().millisecondsSinceEpoch}-${_rng.nextInt(0xFFFF).toRadixString(16).padLeft(4, '0')}';

/// Idiomatic Dart wrapper around the peat-ffi [PeatNode] UniFFI object.
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
/// final node = PeatFlutterNode.create(NodeConfig(
///   appId: 'my-app',
///   sharedKey: base64Key,
///   bindAddress: null,
///   storagePath: appDir.path,
///   transport: null,
/// ));
/// node.startSync();
///
/// node.subscribeChanges().listen((change) {
///   print('${change.collection}/${change.docId}');
/// });
/// ```
class PeatFlutterNode {
  final PeatNode _node;

  Timer? _changeTimer;
  Timer? _outboundTimer;
  Timer? _syncTimer;
  SubscriptionHandle? _subscription;
  StreamController<DocumentChange>? _changeCtrl;
  StreamController<OutboundFrame>? _outboundCtrl;

  PeatFlutterNode._(this._node);

  /// Wire the generated FFI bindings to the platform native library.
  /// Must be called once before any other [PeatFlutterNode] method.
  static void initialize() {
    configureDefaultBindings(dynamicLibrary: openPeatFfiLib());
  }

  /// Create a new peat mesh node.
  static PeatFlutterNode create(NodeConfig config) {
    return PeatFlutterNode._(createNode(config));
  }

  /// This node's hex-encoded unique identifier.
  String get nodeId => _node.nodeId();

  /// This node's iroh endpoint address (relay/derp URL form).
  String get endpointAddr {
    try { return _node.endpointAddr(); } catch (_) { return '—'; }
  }

  /// This node's bound socket address (host:port), if available.
  String? get endpointSocketAddr {
    try { return _node.endpointSocketAddr(); } catch (_) { return null; }
  }

  /// Publish this node's presence with capabilities into the mesh.
  /// Other nodes will see it via [getNodes].
  void publishSelf({
    required String nodeId,
    required String name,
    required List<String> capabilities,
    NodeStatus status = NodeStatus.active,
    double readiness = 1.0,
  }) {
    _node.putNode(NodeInfo(
      id: nodeId,
      nodeType: 'peat-flutter',
      name: name,
      status: status,
      lat: 0,
      lon: 0,
      hae: null,
      readiness: readiness,
      capabilities: capabilities,
      cellId: null,
      batteryPercent: null,
      heartRate: null,
      lastHeartbeat: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// All nodes known to the mesh (including this one).
  List<NodeInfo> get nodes => _node.getNodes();

  /// Remove a stale node entry from the local store.
  void deleteNode(String nodeId) =>
      _node.deleteDocument('nodes', nodeId);

  // ── Cell ──────────────────────────────────────────────────────────────

  /// Publish a cell (team) into the mesh.
  void putCell(CellInfo cell) => _node.putCell(cell);

  /// All cells known to the mesh.
  List<CellInfo> get cells => _node.getCells();

  // ── Command ───────────────────────────────────────────────────────────

  /// Publish a command into the mesh.
  void putCommand(CommandInfo cmd) => _node.putCommand(cmd);

  /// All commands known to the mesh.
  List<CommandInfo> get commands => _node.getCommands();

  /// Number of currently connected peers.
  int get peerCount => _node.peerCount();

  /// List of currently connected peer node IDs.
  List<String> get connectedPeers => _node.connectedPeers();

  /// Manually dial a peer by its endpoint info, bypassing mDNS discovery.
  ///
  /// Needed where raw-multicast mDNS can't run — notably a physical iOS device
  /// without the (Apple-restricted) multicast entitlement: it can't *discover*
  /// peers on the LAN, but it can still *dial* a known peer's [addresses]
  /// (unicast QUIC, which iOS permits) and/or [relayUrl].
  void connectPeer({
    required String nodeId,
    List<String> addresses = const [],
    String? relayUrl,
    String name = '',
  }) {
    _node.connectPeer(PeerInfo(
      name: name,
      nodeId: nodeId,
      addresses: addresses,
      relayUrl: relayUrl,
    ));
  }

  /// Non-blocking variant of [connectPeer]: the dial runs on the native runtime
  /// and this returns immediately. Use from the UI isolate (the blocking
  /// [connectPeer] freezes the isolate for the whole dial — ~seconds for an
  /// unreachable peer). On success the peer surfaces in [connectedPeers].
  void connectPeerNowait({
    required String nodeId,
    List<String> addresses = const [],
    String? relayUrl,
    String name = '',
  }) {
    _node.connectPeerNowait(PeerInfo(
      name: name,
      nodeId: nodeId,
      addresses: addresses,
      relayUrl: relayUrl,
    ));
  }

  // --- Reconnect supervisor -------------------------------------------------

  /// Remember a group member so the native reconnect supervisor can re-dial it
  /// across restarts, network changes, and transport switches. Call once per
  /// member when joining a group (e.g. from a scanned join token). Idempotent.
  ///
  /// This replaces app-side redial timers: once a peer is remembered, the
  /// supervisor keeps a live path up to it over whatever transport is reachable,
  /// with backoff and cross-transport dedup handled natively.
  void rememberPeer({
    required String groupId,
    required String nodeId,
    List<String> addresses = const [],
    String? relayUrl,
    String name = '',
  }) {
    _node.rosterRemember(
      groupId,
      PeerInfo(
        name: name,
        nodeId: nodeId,
        addresses: addresses,
        relayUrl: relayUrl,
      ),
    );
  }

  /// Gentle reconnect pass: dial any disconnected, eligible roster member now.
  /// Does not clear backoff. Cheap to call periodically.
  void reconnectKnownPeers() => _node.reconnectKnownPeers();

  /// Wake the supervisor after a broad connectivity change (network up, app
  /// foreground): clears backoff so every known peer is immediately eligible,
  /// then runs a pass. Call from `AppLifecycleState.resumed` and on
  /// connectivity-restored events.
  void wakeReconnect() => _node.wakeReconnect();

  /// Hint that a specific group member is reachable now — e.g. a BLE neighbour
  /// advertisement or a relay "peer online" signal. Dials it immediately if it
  /// isn't already connected and isn't backing off, bypassing the periodic tick
  /// (important inside a tight mobile background-execution budget).
  void onPeerObserved(String nodeId) => _node.onPeerObserved(nodeId);


  /// Current sync statistics (active, bytes sent/received).
  SyncStats get syncStats => _node.syncStats();

  /// Start mesh synchronisation and begin periodic sync requests.
  void startSync({Duration syncInterval = const Duration(seconds: 5)}) {
    _node.startSync();
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(syncInterval, (_) {
      if (!_node.isClosed) _node.requestSync();
    });
  }

  /// Stop mesh synchronisation.
  void stopSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _node.stopSync();
  }

  /// Store [message] (a proto-generated [GeneratedMessage]) into [collection]
  /// under [docId]. Publishes to connected peers via Automerge sync.
  void putMessage(String collection, String docId, GeneratedMessage message) {
    _node.putDocument(collection, docId, message.writeToJson());
  }

  /// Publish [jsonData] into [collection]. If [docId] is omitted a
  /// timestamp+random ID is generated. Returns the ID used.
  String publishRaw(String collection, String jsonData, {String? docId}) {
    final id = docId ?? _newDocId();
    _node.putDocument(collection, id, jsonData);
    return id;
  }

  /// Retrieve a document as a proto message, or null if not found.
  /// ```dart
  /// final track = node.getMessage('tracks', docId, Track());
  /// ```
  T? getMessage<T extends GeneratedMessage>(
    String collection,
    String docId,
    T defaultInstance,
  ) {
    final json = _node.getDocument(collection, docId);
    if (json == null) return null;
    return (defaultInstance.createEmptyInstance()..mergeFromJson(json)) as T;
  }

  /// Retrieve a raw JSON document, or null if not found.
  String? getRaw(String collection, String docId) =>
      _node.getDocument(collection, docId);

  /// Store a raw JSON document under [collection]/[docId]. Synced across the
  /// mesh via the universal-document transport (Iroh/WiFi/relay). The
  /// counterpart to [getRaw].
  void putRaw(String collection, String docId, String json) =>
      _node.putDocument(collection, docId, json);

  /// List all document IDs in [collection].
  List<String> listDocuments(String collection) =>
      _node.listDocuments(collection);

  /// Per-peer transport state — how each peer is currently reachable (iroh/BLE,
  /// direct/relay, link quality). Currently enumerates peers visible to iroh.
  /// Returns an empty list rather than throwing if the query fails.
  List<PeerTransportState> peerTransportStates() {
    try {
      return _node.allPeerTransportStates();
    } catch (_) {
      return const [];
    }
  }

  /// A broadcast [Stream] of document change events.
  ///
  /// Backed by [SubscriptionHandle.pollChanges] called every [pollInterval]
  /// (default 50 ms). Cancelling the stream also cancels the subscription.
  Stream<DocumentChange> subscribeChanges({
    Duration pollInterval = const Duration(milliseconds: 50),
  }) {
    _changeTimer?.cancel();
    _changeCtrl?.close();
    _subscription?.cancel();
    _subscription?.close();

    final sub = _node.subscribePoll();
    _subscription = sub;

    final ctrl = StreamController<DocumentChange>.broadcast(
      onCancel: () {
        _changeTimer?.cancel();
        // Guard: dispose() may have already cancelled+closed sub synchronously
        // before this async onCancel fires (broadcast "done" delivery is async).
        if (!sub.isClosed) sub.cancel();
        sub.close();
      },
    );
    _changeCtrl = ctrl;

    _changeTimer = Timer.periodic(pollInterval, (_) {
      if (ctrl.isClosed || sub.isClosed) return;
      for (final c in sub.pollChanges()) {
        ctrl.add(c);
      }
    });

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
    _outboundTimer?.cancel();
    _outboundCtrl?.close();

    _node.startOutboundFrames();

    final ctrl = StreamController<OutboundFrame>.broadcast(
      onCancel: () {
        _outboundTimer?.cancel();
        // Guard: dispose() closes _node before this async onCancel may fire.
        if (!_node.isClosed) _node.stopOutboundFrames();
      },
    );
    _outboundCtrl = ctrl;

    _outboundTimer = Timer.periodic(pollInterval, (_) {
      if (ctrl.isClosed || _node.isClosed) return;
      for (final f in _node.pollOutboundFrames()) {
        ctrl.add(f);
      }
    });

    return ctrl.stream;
  }

  /// Feed a BLE inbound frame (postcard bytes from peat-btle) into the mesh.
  ///
  /// Returns the document ID if the frame was accepted, null if unknown.
  String? ingestInboundFrame(String collection, Uint8List postcardBytes) =>
      _node.ingestInboundFrame(collection, postcardBytes);

  /// Feed a BLE inbound frame on the universal-Document ("ble-lite") codec.
  ///
  /// The counterpart of [ingestInboundFrame] for raw collections the typed
  /// translator declines (e.g. the demo counter, nodes/cells/mission/commands).
  /// Returns the document ID if accepted, null if the collection is unknown.
  String? ingestInboundLiteFrame(String collection, Uint8List envelopeBytes) =>
      _node.ingestInboundLiteFrame(collection, envelopeBytes);

  /// Publish a JSON document through the node layer so it reaches the ADR-059
  /// fan-out and is emitted over the bridged transports (BLE/Wi-Fi). Unlike
  /// [publishRaw]/[putDocument] (which write to storage_backend and bypass the
  /// fan-out), this is what makes a locally-authored doc sync to peers over
  /// BLE. The JSON's `id` field, if present, becomes the doc id (returned).
  String publishDocument(String collection, String json) =>
      _node.publishDocument(collection, json);

  // ── Shared water-supply Counter (CRDT-over-Automerge-over-BLE) ──────────
  // A self-contained Automerge Counter doc; its save() bytes (hex) ride the
  // BLE frame bus and merge natively (commutative/idempotent), so the caller
  // can broadcast/relay freely without dedup or ordering concerns.

  /// Current merged value of the shared water-supply Counter.
  int crdtCounterValue() => _node.crdtCounterValue();

  /// Apply [delta] liters; returns hex doc bytes to broadcast to peers.
  String crdtCounterIncrement(int delta) => _node.crdtCounterIncrement(delta);

  /// Merge an inbound peer doc (hex); returns the new value.
  int crdtCounterMerge(String hexDoc) => _node.crdtCounterMerge(hexDoc);

  /// Current hex doc bytes for periodic re-broadcast (late-joiner catch-up).
  String crdtCounterSnapshot() => _node.crdtCounterSnapshot();

  // Generic CRDT KV documents (nodes/commands/cells/mission).
  String crdtKvPut(String collection, String key, String valueJson) =>
      _node.crdtKvPut(collection, key, valueJson);
  String crdtKvAll(String collection) => _node.crdtKvAll(collection);
  void crdtKvMerge(String collection, String hexDoc) =>
      _node.crdtKvMerge(collection, hexDoc);
  String crdtKvSnapshot(String collection) => _node.crdtKvSnapshot(collection);

  /// Cancel all active subscriptions and release FFI resources.
  void dispose() {
    _changeTimer?.cancel();
    _outboundTimer?.cancel();
    _syncTimer?.cancel();
    _changeCtrl?.close();
    _outboundCtrl?.close();
    _subscription?.cancel();
    _subscription?.close();
    if (!_node.isClosed) {
      try { _node.stopSync(); } catch (_) {}
      try { _node.stopOutboundFrames(); } catch (_) {}
      _node.close();
    }
  }
}
