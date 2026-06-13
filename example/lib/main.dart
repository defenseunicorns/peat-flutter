// Copyright 2026 Defense Unicorns
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, Directory;
import 'dart:math' show min, Random;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle, SystemChrome, MethodChannel;
import 'package:path_provider/path_provider.dart';
import 'package:peat_flutter/peat_flutter.dart';
import 'package:peat_flutter/src/generated/peat_ffi.dart' show SyncStats, TransportConfigFFI;
import 'package:shared_preferences/shared_preferences.dart';

/// A single document change event for the activity feed.
class _ChangeEntry {
  final String changeType; // 'upsert' | 'delete'
  final String collection;
  final String docId;
  final String? contentPreview; // first 80 chars of JSON, pretty-ish
  final DateTime timestamp;

  _ChangeEntry({
    required this.changeType,
    required this.collection,
    required this.docId,
    this.contentPreview,
    required this.timestamp,
  });

  String get shortDocId {
    final parts = docId.split('-');
    if (parts.length >= 2) return '${parts.last.substring(0, min(8, parts.last.length))}';
    return docId.length > 8 ? '${docId.substring(0, 8)}…' : docId;
  }

  String get relativeTime {
    final diff = DateTime.now().difference(timestamp);
    if (diff.inSeconds < 2) return 'now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }
}

void main() {
  PeatFlutterNode.initialize();
  runApp(const PeatExampleApp());
}

class PeatExampleApp extends StatelessWidget {
  const PeatExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'peat-water',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF2768D4), useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF2768D4),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: const PeatExampleHome(),
    );
  }
}

class PeatExampleHome extends StatefulWidget {
  const PeatExampleHome({super.key});

  @override
  State<PeatExampleHome> createState() => _PeatExampleHomeState();
}

class _PeatExampleHomeState extends State<PeatExampleHome> {
  PeatFlutterNode? _node;
  String? _nodeId;
  String _hostName = '';
  String? _error;
  bool _starting = false;
  bool _stopping = false;
  bool _bleRunning = false;
  int _bleFrameCount = 0;
  int _blePeerCount = 0; // connected BLE peers (Android peat-btle bridge)
  // Android BLE transport bridge (peat-btle pipe) lives in native MainActivity.
  static const MethodChannel _bleChannel = MethodChannel('peat/ble');
  // Android Wi-Fi Direct (P2P) link — forms an infra-free LAN; iroh syncs over it.
  static const MethodChannel _wifiChannel = MethodChannel('peat/wifidirect');
  bool _wifiDirectOn = false;
  String _wifiDirectStatus = 'idle';
  int _wifiTunnelPeers = 0; // P2PWiFi TCP-tunnel link state (0/1)
  final List<_ChangeEntry> _changeLog = [];
  Timer? _changeLogTimer; // drives relative-time refresh
  // Content hashes: key → hash of last-seen raw JSON.
  // Show an entry only when content actually changed (new doc or mutation).
  // Survives stop/start so reconnect-triggered re-syncs of unchanged docs are silent.
  final Map<String, int> _contentHashes = {};
  List<String> _peers = [];
  SyncStats? _syncStats;
  String? _endpointAddr;
  String? _endpointSocketAddr;
  Timer? _peerTimer;

  // Cell and Command state
  CellInfo? _activeCell;
  List<CommandInfo> _commands = [];
  // Track last peer set so the leader can auto-reform on change.
  Set<String> _lastCellPeers = {};
  // Track command IDs we've already claimed so we don't double-increment.
  final Set<String> _claimedCommandIds = {};
  // Only auto-claim commands issued after this session started.
  int _sessionStartMs = 0;

  // Mission objective (leader-set, shared via CRDT)
  static const _missionCollection = 'mission';
  static const _missionDocId = 'objective';
  static const _litersPerPersonPerDay = 3;
  int _missionDays = 0;       // 0 = not set
  String? _missionSetBy;
  int _missionDaysDraft = 3;  // leader UI stepper

  int get _requiredLiters =>
      _missionDays > 0 && _roster.isNotEmpty
          ? _missionDays * _litersPerPersonPerDay * _roster.length
          : 0;

  // Node presence / G-Set roster
  // Capabilities are role-oriented: leader caps vs field caps
  static const _allCapabilities = [
    'leader', 'comms', 'logistics',   // command/support
    'recon', 'medical', 'transport',  // field roles
  ];
  late List<String> _myCapabilities;
  late TextEditingController _callsignCtrl;
  final FocusNode _callsignFocus = FocusNode();
  bool _editingCallsign = false;
  String _callsignPrev = ''; // for cancel
  List<NodeInfo> _roster = [];
  // Skew-immune liveness: last observed heartbeat value + LOCAL clock time we
  // saw it advance, keyed by node id. See the roster builder for rationale.
  final Map<String, int> _nodeHbSeen = {};
  final Map<String, int> _nodeSeenLocal = {};

  // PN-Counter CRDT: each node maintains its own (inc, dec) slot so
  // offline edits from multiple nodes merge additively on reconnect.
  // Total = Σ (inc_i - dec_i) across all nodes.
  static const _counterCollection = 'demo';
  // My own slot key — keyed on the NODE ID (unique crypto key) so that
  // two iOS devices with the same hostname don't collide.
  String _myCounterDocKey = ''; // set in _startNode from node.nodeId
  String get _myCounterDoc => _myCounterDocKey.isNotEmpty
      ? _myCounterDocKey
      : 'counter-${_hostName.replaceAll(' ', '_').replaceAll('·', '-')}';
  int _myInc = 0;
  int _myDec = 0;
  bool _counterDirty = false; // local edits not yet flushed to store
  // Contributions from peers: docId → (inc - dec)
  final Map<String, int> _peerContributions = {};
  // Friendly name for each peer's counter slot
  final Map<String, String> _peerNames = {};
  int get _counterValue => (_myInc - _myDec) + _peerContributions.values.fold(0, (a, b) => a + b);
  String? _counterLastBy;
  Timer? _counterTimer;
  StreamSubscription<DocumentChange>? _changeSub;
  StreamSubscription<OutboundFrame>? _outboundSub;
  int _publishCount = 0;

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  // NATO phonetic call signs — pick a random one as the default identity.
  static const _callsignPool = [
    'Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo', 'Foxtrot', 'Golf',
    'Hotel', 'India', 'Juliet', 'Kilo', 'Lima', 'Mike', 'November',
    'Oscar', 'Papa', 'Quebec', 'Romeo', 'Sierra', 'Tango', 'Uniform',
    'Victor', 'Whiskey', 'Xray', 'Yankee', 'Zulu',
  ];

  @override
  void initState() {
    super.initState();
    // Default capabilities by platform role; macOS = command post.
    if (Platform.isMacOS) {
      _myCapabilities = ['leader', 'comms', 'logistics'];
    } else if (Platform.isIOS) {
      _myCapabilities = ['recon', 'medical'];
    } else {
      _myCapabilities = ['comms'];
    }
    // Random unique default callsign: e.g. "Tango-47"
    final rng = Random();
    _hostName =
        '${_callsignPool[rng.nextInt(_callsignPool.length)]}-${rng.nextInt(90) + 10}';
    _callsignCtrl = TextEditingController(text: _hostName);
    _callsignPrev = _hostName;
    // Load persisted callsign (device identity) from prefs. Capabilities are
    // NOT persisted here — they live in this node's Peat document and are
    // restored from the store on node start (see _startNode), so a database
    // reset clears them (correct) and they still sync to peers + survive a
    // restart via the store.
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString('callsign');
      if (mounted) {
        setState(() {
          if (saved != null && saved.isNotEmpty) {
            _callsignCtrl.text = saved;
            _callsignPrev = saved;
          }
        });
      }
    });
    // Leaving the field (tap away) exits edit mode.
    _callsignFocus.addListener(() {
      if (!_callsignFocus.hasFocus && _editingCallsign && mounted) {
        setState(() => _editingCallsign = false);
      }
    });
  }

  void _beginEditCallsign() {
    _callsignPrev = _callsignCtrl.text;
    setState(() => _editingCallsign = true);
    // Select-all after the field is built so typing replaces.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _callsignCtrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _callsignCtrl.text.length,
      );
      _callsignFocus.requestFocus();
    });
  }

  Future<void> _startNode() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    // Give the previous session's Tokio tasks time to drain and release
    // the redb file lock before we attempt to open it.
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted || !_starting) return; // user cancelled while waiting
    try {
      final dir = await getApplicationSupportDirectory();
      // CRITICAL: the iroh node id is derived from a deterministic seed =
      // app_id + storage_path (peat-ffi). On Android every device uses the same
      // package path (/data/user/0/<pkg>/files/peat), so without a unique
      // suffix BOTH phones derive the SAME node id and can never mesh (and the
      // roster/counter shows one identity for two devices). Append a persisted
      // per-install id so each device gets a stable, unique node identity.
      final prefs = await SharedPreferences.getInstance();
      var installId = prefs.getString('install_id');
      if (installId == null) {
        installId =
            '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
            '${Random().nextInt(1 << 31).toRadixString(36)}';
        await prefs.setString('install_id', installId);
      }
      final storagePath = '${dir.path}/peat-$installId';
      final node = PeatFlutterNode.create(NodeConfig(
        appId: 'peat-flutter-example',
        // Test-only shared key. Replace with a real base64-encoded 32-byte key:
        //   openssl rand -base64 32
        // WARNING: all-zeros key → every example instance on the same LAN will
        // mesh with each other. Fine for local dev; replace before sharing.
        sharedKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        bindAddress: null,
        storagePath: storagePath,
        // Enable BLE so peat-ffi registers its (stub) Android BLE transport into
        // ANDROID_BLE_TRANSPORT — required for bleAddPeerJni and the outbound
        // fan-out to emit "ble" frames. The real radio is peat-btle (BleBridge);
        // peat-ffi's stub adapter is just the mesh's BLE transport endpoint.
        transport: const TransportConfigFFI(
          enableBle: true,
          bleMeshId: null,
          blePowerProfile: 'balanced',
          transportPreference: null,
          collectionRoutesJson: null,
        ),
      ));
      node.startSync();
      _startBle(node); // auto-start BLE on all platforms
      // Auto-start Wi-Fi Direct on Android too (infra-free LAN for iroh). Still
      // pops the one-time "invite to connect" prompt the first time.
      if (Platform.isAndroid && !_wifiDirectOn) {
        _wifiChannel.invokeMethod<bool>('startWifiDirect').then((ok) {
          if (mounted) setState(() => _wifiDirectOn = ok ?? false);
        }).catchError((_) {});
      }

      _sessionStartMs = DateTime.now().millisecondsSinceEpoch;
      // Key the counter slot on the unique node ID so two iOS devices
      // with the same hostname don't collide in the store.
      _myCounterDocKey = 'counter-${node.nodeId.substring(0, 16)}';
      // On connect: flush offline edits + read peer contributions.
      _refreshCounter(node);
      _counterTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (!mounted || _node == null) return;
        _refreshCounter(_node!);
        _refreshMission(_node!);
      });

      // Restore my capabilities from MY node document in the store (the Peat
      // document — NOT app prefs), if a prior session persisted them. Must run
      // before the first _publishSelf so stored caps win over the platform
      // default. A database reset wipes the store, so this finds nothing and
      // falls through to the default — exactly the desired reset behavior.
      final selfCaps = node.nodes
          .where((n) => n.id == node.nodeId && n.capabilities.isNotEmpty)
          .toList();
      if (selfCaps.isNotEmpty) {
        _myCapabilities = selfCaps.first.capabilities;
        if (mounted) setState(() {});
      }

      // Publish this node's presence + current counter into the mesh
      // immediately on start, so a node that just restarted pushes its own
      // state to the peer near-instantly (rather than waiting for the first
      // heartbeat). The peer's state comes back via its heartbeat re-advertise.
      _publishSelf(node);
      _flushMyCounter(node);

      var _heartbeatTick = 0;
      _peerTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (!mounted || _node == null) return;
        // Re-publish self every 2 min to keep heartbeat fresh for peers.
        _heartbeatTick++;
        if (_heartbeatTick >= 2) { // 2 × 2s = 4s. Bounds comms-recovery
          // convergence: with the BLE radio kept up across a node restart,
          // neither side sees a disconnect/reconnect edge, so this steady
          // re-advertise is what makes a reconnecting node catch up — at 20s
          // that was a ~10s average lag (unacceptable for the demo); 4s caps
          // worst-case convergence at one beat. Traffic stays modest (a few
          // small frames/node) and ingestion is idempotent + echo-suppressed.
          _heartbeatTick = 0;
          _publishSelf(_node!);
          // Re-broadcast owned shared state every beat so a peer that was
          // OFFLINE and reconnects converges to current within ~20s — without
          // depending on the BLE peer-count rising edge (BLE disconnect
          // detection lags, so the still-online node may never see a 0→1 edge
          // to trigger a one-shot re-push). The fan-out is otherwise
          // change-driven; this is the steady re-advertise that makes
          // comms-recovery / convergence-on-reconnect reliable. Re-publishing
          // an unchanged CRDT doc is idempotent on the receiver.
          _flushMyCounter(_node!);
          if (_missionDays > 0) _republishMission(_node!);
          if (_myCapabilities.contains('leader') && _roster.isNotEmpty) {
            _formCell();
          }
        }
        // Clean up ghost entries that may have synced in from the peer.
        _cleanGhostNodes(_node!);
        // Refresh cell and command state.
        try {
          final cells = _node!.cells;
          final cmds = _node!.commands;
          if (mounted) setState(() {
            _activeCell = cells.isNotEmpty ? cells.first : null;
            _commands = cmds;
          });
          // Leader: auto-reform the cell when ROSTER membership changes — not
          // the iroh `_peers` set (empty on Android), which is why the cell
          // never grew to include the joining peer. Re-forms only on change,
          // so no churn; once the peer appears in the roster the cell becomes
          // a 2-member cell and re-publishes.
          if (_myCapabilities.contains('leader') &&
              cells.isNotEmpty &&
              _roster.isNotEmpty &&
              _nodeId != null) {
            final currentMembers = _roster.map((n) => n.id).toSet();
            if (currentMembers != _lastCellPeers) {
              _lastCellPeers = currentMembers;
              _formCell();
            }
          }
          // Auto-claim fulfilled resupply requests addressed to this node.
          // Guard: only claim commands issued IN THIS SESSION to prevent
          // re-claiming old commands on restart (which would double-count).
          for (final cmd in cmds) {
            if (cmd.status == CommandStatus.completed &&
                cmd.commandType == 'WATER_REQUEST' &&
                cmd.createdAt >= _sessionStartMs &&
                !_claimedCommandIds.contains(cmd.id)) {
              final params = _parseParams(cmd.parameters);
              if (params['from'] == _callsign) {
                final qty = params['quantity'] as int? ?? 0;
                _claimedCommandIds.add(cmd.id);
                _adjustCounter(_node, qty); // atomic: receive all at once
              }
            }
          }
        } catch (_) {}

        final seen = <String>{};
        setState(() {
          _peers = _node!.connectedPeers;
          _syncStats = _node!.syncStats;
          _endpointAddr = _node!.endpointAddr;
          _endpointSocketAddr = _node!.endpointSocketAddr;
          // BLE peers aren't in the iroh connected-set; poll the native bridge.
          if (Platform.isAndroid && _bleRunning) {
            _bleChannel.invokeMethod<int>('blePeerCount').then((c) {
              if (mounted && c != null && c != _blePeerCount) {
                final rising = _blePeerCount == 0 && c > 0;
                setState(() => _blePeerCount = c);
                // Rising edge (0 -> N): the BLE fan-out is change-driven and
                // its startup Initial-snapshot races the peer connection, so a
                // peer that joins after we published gets nothing until our
                // next edit. Push current state across now: re-publish our
                // capabilities (so we appear in the peer's roster immediately,
                // not up to 120s later) and flush the counter (so its value
                // converges without waiting for a fresh tap).
                if (rising && _node != null) {
                  _publishSelf(_node!);
                  _flushMyCounter(_node!);
                  // Re-broadcast leader-owned shared state to the just-joined
                  // peer (fan-out is change-driven, so a mission/cell set
                  // before this peer connected would never reach it).
                  if (_missionDays > 0) _republishMission(_node!);
                  if (_myCapabilities.contains('leader') && _roster.isNotEmpty) {
                    _formCell();
                  }
                }
              }
            }).catchError((_) {});
          }
          if (Platform.isAndroid && _wifiDirectOn) {
            _wifiChannel.invokeMethod<Map>('wifiDirectStatus').then((m) {
              final s = (m?['status'] as String?) ?? 'idle';
              if (mounted && s != _wifiDirectStatus) {
                setState(() => _wifiDirectStatus = s);
              }
            }).catchError((_) {});
            // Tunnel connection state (the real P2PWiFi carrier link), not the
            // dead iroh peer set.
            _wifiChannel.invokeMethod<int>('wifiTunnelPeers').then((c) {
              if (mounted && c != null && c != _wifiTunnelPeers) {
                setState(() => _wifiTunnelPeers = c);
              }
            }).catchError((_) {});
          }
          // Liveness uses LOCAL receipt time, not the peer's clock-stamped
          // `lastHeartbeat`. Comparing a remote heartbeat against our own
          // clock breaks under clock skew (observed: two phones ~7 min apart
          // → the ahead phone treats the behind phone's fresh heartbeat as
          // already-expired and drops it from the roster). Instead, each time
          // a node's heartbeat advances we stamp the LOCAL clock; a node is
          // "live" if we saw it advance within the window — skew-immune.
          final localNow = DateTime.now().millisecondsSinceEpoch;
          for (final n in _node!.nodes) {
            final prevHb = _nodeHbSeen[n.id];
            if (prevHb == null || n.lastHeartbeat > prevHb) {
              _nodeHbSeen[n.id] = n.lastHeartbeat;
              _nodeSeenLocal[n.id] = localNow;
            }
          }
          final liveCutoff = localNow - const Duration(minutes: 3).inMilliseconds;
          final allNodes = _node!.nodes
              .where((n) =>
                  n.id.length >= 16 &&
                  (n.id == _nodeId ||
                      _peers.contains(n.id) ||
                      (_nodeSeenLocal[n.id] ?? 0) >= liveCutoff))
              .toList();
          // Keep most-recent entry per callsign name (dedup reconnects with a
          // new node id), preferring the freshest by local-receipt time.
          allNodes.sort((a, b) =>
              (_nodeSeenLocal[b.id] ?? 0).compareTo(_nodeSeenLocal[a.id] ?? 0));
          final byName = <String, NodeInfo>{};
          for (final n in allNodes) {
            byName[n.name] ??= n;
          }
          // STABLE display order: self first, then by callsign. Sorting the
          // displayed roster by last-receipt made rows leapfrog every few
          // seconds (both nodes heartbeat every 4s) — the "bouncing" roster.
          _roster = byName.values.toList()
            ..sort((a, b) {
              if (a.id == _nodeId) return -1;
              if (b.id == _nodeId) return 1;
              return a.name.compareTo(b.name);
            });
        });
      });

      // Refresh relative timestamps every 10 s
      _changeLogTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (mounted) setState(() {});
      });

      // Pre-populate content hashes so unchanged docs re-synced by the peer
      // are silent. Only new content (new doc or mutation) shows in the feed.
      for (final col in ['test', 'demo']) {
        try {
          for (final id in node.listDocuments(col)) {
            final raw = node.getRaw(col, id);
            if (raw != null) _contentHashes['$col/$id'] = raw.hashCode;
          }
        } catch (_) {}
      }
      // Clear the feed so this session starts fresh.
      setState(() => _changeLog.clear());

      final sub = node.subscribeChanges().listen((change) {
        if (!mounted) return;
        // Internal collections shown elsewhere — skip in the feed.
        if (change.collection == 'nodes' || change.collection == 'mission') return;
        final key = '${change.collection}/${change.docId}';

        // Fetch content and compute hash. Only surface the event if the
        // content actually changed — this silences re-syncs of unchanged
        // docs while still showing updates from the other device.
        String? preview;
        try {
          final raw = node.getRaw(change.collection, change.docId);
          if (raw == null) return; // doc vanished
          final newHash = raw.hashCode;
          final knownHash = _contentHashes[key];
          if (knownHash == newHash) return; // same content, skip
          _contentHashes[key] = newHash;   // record new hash

          final map = jsonDecode(raw) as Map<String, dynamic>?;
          if (map != null) {
            if (change.docId.startsWith('counter-') || change.docId == 'counter') {
              final inc = map['inc'] as int? ?? 0;
              final dec = map['dec'] as int? ?? 0;
              final by = map['by'] as String? ?? '';
              preview = 'value: ${inc - dec}  ·  by: $by';
            } else {
              preview = map.entries
                  .take(3)
                  .map((e) {
                    final v = e.value?.toString() ?? 'null';
                    return '${e.key}: ${v.length > 20 ? '${v.substring(0, 20)}…' : v}';
                  })
                  .join('  ·  ');
            }
          } else {
            preview = raw.length > 60 ? '${raw.substring(0, 60)}…' : raw;
          }
        } catch (_) {
          return;
        }
        setState(() {
          _changeLog.insert(0, _ChangeEntry(
            changeType: change.changeType.name,
            collection: change.collection,
            docId: change.docId,
            contentPreview: preview,
            timestamp: DateTime.now(),
          ));
          if (_changeLog.length > 50) _changeLog.removeLast();
        });
      });

      setState(() {
        _node = node;
        _nodeId = node.nodeId;
        _changeSub = sub;
        _starting = false;
      });
    } catch (e) {
      // Rust's create_node already retries redb open for up to 30s internally.
      // No Dart-level retry — that would create parallel competing runtimes.
      setState(() {
        _error = e is UnimplementedError
            ? 'Run `just gen-bindings` to regenerate FFI bindings.'
            : 'Failed to start node: $e';
        _starting = false;
      });
    }
  }


  void _refreshMission(PeatFlutterNode node) {
    try {
      // Mission is published through the node layer (wrapped as {fields:{..}});
      // read via the shared extractor so days/by come from the right level
      // (a top-level read returned null, so the mission never updated).
      final f = _docFields(node.getRaw(_missionCollection, _missionDocId));
      if (f == null) return;
      final days = f['days'] as int? ?? 0;
      final by = f['by'] as String?;
      if (mounted && (days != _missionDays || by != _missionSetBy)) {
        setState(() {
          _missionDays = days;
          _missionSetBy = by;
        });
      }
    } catch (_) {}
  }

  void _setMission(PeatFlutterNode node, int days) {
    final json = jsonEncode({
      'id': _missionDocId,
      'days': days,
      'by': _callsign,
      'liters_per_person_per_day': _litersPerPersonPerDay,
    });
    if (Platform.isAndroid) {
      // Route through the node layer so it fans out over BLE (same as counter).
      _bleChannel.invokeMethod('publishDoc',
          {'collection': _missionCollection, 'json': json}).catchError((_) {
        node.publishRaw(_missionCollection, json, docId: _missionDocId);
        return null;
      });
    } else {
      node.publishRaw(_missionCollection, json, docId: _missionDocId);
    }
    setState(() {
      _missionDays = days;
      _missionSetBy = _callsign;
      _missionDaysDraft = days;
    });
  }

  /// Re-broadcast the current mission without mutating local state. Used by the
  /// peer-connect trigger so a peer that joined after the mission was set still
  /// receives it (the fan-out only emits on change).
  void _republishMission(PeatFlutterNode node) {
    if (_missionDays <= 0) return;
    final json = jsonEncode({
      'id': _missionDocId,
      'days': _missionDays,
      'by': _missionSetBy ?? _callsign,
      'liters_per_person_per_day': _litersPerPersonPerDay,
    });
    if (Platform.isAndroid) {
      _bleChannel.invokeMethod('publishDoc',
          {'collection': _missionCollection, 'json': json}).catchError((_) {
        node.publishRaw(_missionCollection, json, docId: _missionDocId);
        return null;
      });
    } else {
      node.publishRaw(_missionCollection, json, docId: _missionDocId);
    }
  }

  String get _callsign => _callsignCtrl.text.trim().isEmpty
      ? _hostName
      : _callsignCtrl.text.trim();

  Future<void> _resetDatabase() async {
    if (_node != null) return; // must be stopped first
    try {
      final dir = await getApplicationSupportDirectory();
      // The node's store is "${dir}/peat-<installId>" (unique per install to
      // avoid node-id collisions). The old code deleted a hard-coded
      // "${dir}/peat" that never existed, so reset silently did nothing.
      // Delete every "peat" / "peat-*" store dir here.
      var removed = 0;
      if (await dir.exists()) {
        await for (final entry in dir.list()) {
          final name = entry.path.split(Platform.pathSeparator).last;
          if (entry is Directory && (name == 'peat' || name.startsWith('peat-'))) {
            await entry.delete(recursive: true);
            removed++;
          }
        }
      }
      // Reset in-memory state
      setState(() {
        _myInc = 0;
        _myDec = 0;
        _counterDirty = false;
        _peerContributions.clear();
        _peerNames.clear();
        _changeLog.clear();
        _contentHashes.clear();
        _claimedCommandIds.clear();
        _commands = [];
        _activeCell = null;
        _missionDays = 0;
        _missionSetBy = null;
        _error = null;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(removed > 0
              ? 'Local database reset — $removed store${removed == 1 ? '' : 's'} cleared. Start the node for a clean slate.'
              : 'No local store found — already clean.'),
        ));
      }
    } catch (e) {
      setState(() => _error = 'Reset failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Reset failed: $e')));
      }
    }
  }

  void _publishSelf(PeatFlutterNode node) {
    final id = node.nodeId;
    _cleanGhostNodes(node);
    if (Platform.isAndroid) {
      // Publish capabilities through the node layer (publishDoc →
      // publishDocumentJni), NOT putNode. putNode writes a flat shape straight
      // to storage_backend, but the fan-out and BLE ingest operate on wrapped
      // mesh Documents — a flat-stored node doesn't round-trip its fields
      // through the fan-out, so peers received an empty/id-only node. Routing
      // self-publish through the same wrapped path the counter uses makes
      // capabilities sync over BLE and the remote roster show the callsign.
      final json = jsonEncode({
        'id': id,
        'node_type': 'peat-flutter',
        'name': _callsign,
        'status': 'ACTIVE',
        'readiness': 1.0,
        'capabilities': _myCapabilities,
        'last_heartbeat': DateTime.now().millisecondsSinceEpoch,
      });
      _bleChannel.invokeMethod('publishDoc',
          {'collection': 'nodes', 'json': json}).catchError((_) {
        // Fallback to the uniffi path (local-only) if the node publish fails.
        node.publishSelf(nodeId: id, name: _callsign, capabilities: _myCapabilities);
        return null;
      });
    } else {
      node.publishSelf(nodeId: id, name: _callsign, capabilities: _myCapabilities);
    }
    // Persist callsign so it survives app restarts
    SharedPreferences.getInstance()
        .then((p) => p.setString('callsign', _callsign));
  }

  void _cleanGhostNodes(PeatFlutterNode node) {
    // Remove ONLY structurally-invalid entries (bad/placeholder node id).
    //
    // We deliberately do NOT delete by "name == _hostName": `_hostName` is a
    // random default callsign and callsigns persist across runs, so two
    // devices frequently share one — the name rule then deletes the *real*
    // peer every 2s (roster "populates then drops"). De-duplication of
    // same-callsign entries is already handled for display by the `byName`
    // map in the roster builder, so name-based deletion is both unsafe and
    // redundant.
    for (final n in node.nodes) {
      final isGhost = n.id.length < 16 || n.id == 'unknown';
      if (isGhost) {
        try { node.deleteNode(n.id); } catch (_) {}
      }
    }
  }

  /// Extract the counter payload ({inc, dec, by}) from a stored doc, handling
  /// both shapes: node-published docs arrive wrapped as a mesh Document
  /// (`{"id":..,"fields":{inc,dec,by},"updated_at":..}`), while legacy
  /// `publishRaw`/`put_document` writes are flat (`{inc,dec,by}`). Reading the
  /// wrong level is why a synced peer counter showed 0 (the value was under
  /// `fields`, not at top level).
  Map<String, dynamic>? _docFields(String? raw) {
    if (raw == null) return null;
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final fields = map['fields'];
    return (fields is Map<String, dynamic>) ? fields : map;
  }

  void _refreshCounter(PeatFlutterNode node) {
    // Flush local dirty edits first (offline changes take precedence).
    if (_counterDirty) {
      _flushMyCounter(node);
    }
    // Read all counter docs to collect peer contributions.
    final docs = node.listDocuments(_counterCollection);
    // DIAG: what does the store actually hold for the demo collection?
    print('COUNTERDBG mine=$_myCounterDoc listDocuments(demo)=$docs');
    final updated = <String, int>{};
    for (final docId in docs) {
      if (!docId.startsWith('counter-')) continue;
      if (docId == _myCounterDoc) {
        // Restore my own state if we don't have it yet.
        if (_myInc == 0 && _myDec == 0 && !_counterDirty) {
          try {
            final f = _docFields(node.getRaw(_counterCollection, docId));
            if (f != null && mounted) setState(() {
              _myInc = f['inc'] as int? ?? 0;
              _myDec = f['dec'] as int? ?? 0;
            });
          } catch (_) {}
        }
        continue;
      }
      try {
        final f = _docFields(node.getRaw(_counterCollection, docId));
        if (f != null) {
          updated[docId] = (f['inc'] as int? ?? 0) - (f['dec'] as int? ?? 0);
          final by = f['by'] as String?;
          if (by != null) _peerNames[docId] = by;
        }
      } catch (_) {}
    }
    if (mounted && updated != _peerContributions) {
      setState(() => _peerContributions
        ..clear()
        ..addAll(updated));
    }
  }

  void _flushMyCounter(PeatFlutterNode node) {
    if (Platform.isAndroid) {
      // Publish through the node layer (native publishDocumentJni) so the
      // counter reaches the ADR-059 fan-out and syncs over BLE — put_document
      // writes straight to storage_backend and bypasses the fan-out (that's why
      // capabilities synced but the counter didn't). Carry the doc id in "id".
      final json = jsonEncode(
          {'id': _myCounterDoc, 'inc': _myInc, 'dec': _myDec, 'by': _callsign});
      _bleChannel.invokeMethod('publishDoc',
          {'collection': _counterCollection, 'json': json}).catchError((_) {
        // Fallback: storage_backend write (local only) if node publish fails.
        node.publishRaw(_counterCollection, json, docId: _myCounterDoc);
        return null;
      });
    } else {
      final json = jsonEncode({'inc': _myInc, 'dec': _myDec, 'by': _callsign});
      node.publishRaw(_counterCollection, json, docId: _myCounterDoc);
    }
    setState(() {
      _counterDirty = false;
      _counterLastBy = _callsign;
    });
  }

  void _writeCounter(PeatFlutterNode? node, bool increment) =>
      _adjustCounter(node, increment ? 1 : -1);

  /// Apply [delta] in a single atomic write — avoids multi-write races
  /// when resupply fulfillment needs to move N liters at once.
  void _adjustCounter(PeatFlutterNode? node, int delta) {
    setState(() {
      if (delta > 0) _myInc += delta; else _myDec += -delta;
      _counterLastBy = _callsign;
    });
    if (node != null) {
      _flushMyCounter(node);
    } else {
      setState(() => _counterDirty = true);
    }
  }

  // ── Cell card ────────────────────────────────────────────────────────

  void _formCell() {
    final node = _node;
    if (node == null) return;
    // Members = the live roster (self + BLE-reachable peers). The old code
    // used {_nodeId, ..._peers}, but _peers is the iroh connected-set, which
    // is empty on Android (iroh can't connect) — so the cell only ever held
    // self and the peer never joined. The roster is the real membership.
    final activeNodes = _roster.toList();
    if (activeNodes.isEmpty) return;
    final allCaps = activeNodes
        .expand((n) => n.capabilities)
        .toSet()
        .toList();
    final leader = activeNodes
        .firstWhere((n) => n.capabilities.contains('leader'),
            orElse: () => activeNodes.first)
        .id;
    final cell = CellInfo(
      id: 'alpha-cell',
      name: 'Alpha Cell',
      status: activeNodes.length > 1 ? CellStatus.active : CellStatus.forming,
      nodeCount: activeNodes.length,
      centerLat: 0,
      centerLon: 0,
      capabilities: allCaps,
      formationId: null,
      leaderId: leader,
      lastUpdate: DateTime.now().millisecondsSinceEpoch,
      scenarioCommand: null,
    );
    if (Platform.isAndroid) {
      // Publish through the node layer (wrapped Document) so the cell reaches
      // the BLE fan-out and the other device actually receives it. putCell
      // writes a flat shape straight to storage that doesn't sync.
      final json = jsonEncode({
        'id': cell.id,
        'name': cell.name,
        'status': activeNodes.length > 1 ? 'ACTIVE' : 'FORMING',
        'node_count': cell.nodeCount,
        'center_lat': 0,
        'center_lon': 0,
        'capabilities': allCaps,
        'formation_id': null,
        'leader_id': leader,
        'last_update': cell.lastUpdate,
        'scenario_command': null,
      });
      _bleChannel.invokeMethod('publishDoc',
          {'collection': 'cells', 'json': json}).catchError((_) {
        node.putCell(cell);
        return null;
      });
    } else {
      node.putCell(cell);
    }
  }

  Widget _buildCellCard(ThemeData theme) {
    final cell = _activeCell;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.groups_outlined, size: 16),
              const SizedBox(width: 6),
              Text('Cell Formation',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              if (_myCapabilities.contains('leader'))
                FilledButton(
                  onPressed: _roster.isNotEmpty ? _formCell : null,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(cell != null ? 'Reform' : 'Form Cell',
                      style: const TextStyle(fontSize: 12)),
                ),
            ]),
            const SizedBox(height: 6),
            if (cell != null) ...[
              Row(children: [
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cell.status == CellStatus.active
                        ? Colors.green
                        : Colors.orange,
                  ),
                ),
                const SizedBox(width: 6),
                Text(cell.name,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                // The cell's actual member count (what the leader formed it
                // with). The old code counted the iroh `_peers` set + self,
                // which is always 1 on Android (iroh never connects) — so the
                // cell always read "1 node" no matter the real membership.
                Text('${cell.nodeCount} nodes',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ]),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                children: cell.capabilities.take(6).map((c) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(c,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(fontSize: 10,
                              color: theme.colorScheme.onPrimaryContainer)),
                )).toList(),
              ),
            ] else if (!_myCapabilities.contains('leader'))
              Text('Awaiting cell formation from leader.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline,
                          fontStyle: FontStyle.italic)),
          ],
        ),
      ),
    );
  }

  // ── Command card ─────────────────────────────────────────────────────

  /// Publish a command so it actually syncs over BLE. Like cells/nodes, the
  /// flat `putCommand` write doesn't reach the fan-out — route through the node
  /// layer (wrapped Document) on Android. `parameters` is sent as a nested
  /// object (not a quoted string) so the Rust side reconstructs it verbatim.
  void _publishCommand(PeatFlutterNode node, CommandInfo cmd) {
    if (Platform.isAndroid) {
      final json = jsonEncode({
        'id': cmd.id,
        'command_type': cmd.commandType,
        'target_id': cmd.targetId,
        'parameters': jsonDecode(cmd.parameters),
        'priority': cmd.priority,
        'status': cmd.status.name.toUpperCase(),
        'originator': cmd.originator,
        'created_at': cmd.createdAt,
        'last_update': cmd.lastUpdate,
      });
      _bleChannel.invokeMethod('publishDoc',
          {'collection': 'commands', 'json': json}).catchError((_) {
        node.putCommand(cmd);
        return null;
      });
    } else {
      node.putCommand(cmd);
    }
  }

  void _issueWaterRequest(int quantity) {
    final node = _node;
    if (node == null) return;
    final id = 'req-${DateTime.now().millisecondsSinceEpoch}';
    _publishCommand(node, CommandInfo(
      id: id,
      commandType: 'WATER_REQUEST',
      targetId: 'leader',
      parameters: '{"quantity": $quantity, "from": "$_callsign"}',
      priority: 1,
      status: CommandStatus.pending,
      originator: _nodeId ?? '',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      lastUpdate: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  void _fulfillCommand(CommandInfo cmd) {
    final node = _node;
    if (node == null) return;
    // Leader DECREMENTS their own supply (giving water away).
    // The requester will auto-increment their slot when they see COMPLETED.
    try {
      final params = jsonDecode(cmd.parameters) as Map<String, dynamic>;
      final qty = params['quantity'] as int? ?? 0;
      _adjustCounter(node, -qty); // atomic: give all at once
    } catch (_) {}
    // Mark command as completed so the requester can claim it.
    _publishCommand(node, CommandInfo(
      id: cmd.id,
      commandType: cmd.commandType,
      targetId: cmd.targetId,
      parameters: cmd.parameters,
      priority: cmd.priority,
      status: CommandStatus.completed,
      originator: cmd.originator,
      createdAt: cmd.createdAt,
      lastUpdate: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  Widget _buildCommandCard(ThemeData theme) {
    final isLeader = _myCapabilities.contains('leader');
    final pending = _commands
        .where((c) => c.status == CommandStatus.pending)
        .toList();
    final recent = _commands
        .where((c) => c.status != CommandStatus.pending)
        .take(2)
        .toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.send_outlined, size: 16),
              const SizedBox(width: 6),
              Text('Resupply Requests',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              FilledButton(
                onPressed: _node != null
                    ? () {
                        if (isLeader) {
                          // No commander above — add directly to own supply.
                          _adjustCounter(_node, 5);
                        } else {
                          _issueWaterRequest(5);
                        }
                      }
                    : null,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(isLeader ? 'Self-resupply +5L' : 'Request 5L',
                    style: const TextStyle(fontSize: 12)),
              ),
            ]),
            const SizedBox(height: 6),
            if (pending.isEmpty && recent.isEmpty && isLeader)
              Text('No pending requests.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline,
                          fontStyle: FontStyle.italic)),
            ...pending.map((cmd) {
              final params = _parseParams(cmd.parameters);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Container(width: 8, height: 8,
                      decoration: const BoxDecoration(
                          shape: BoxShape.circle, color: Colors.orange)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${params['from'] ?? 'unknown'} requests ${params['quantity']}L',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  if (isLeader)
                    GestureDetector(
                      onTap: () => _fulfillCommand(cmd),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('Fulfill',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: Colors.green)),
                      ),
                    ),
                ]),
              );
            }),
            ...recent.map((cmd) {
              final params = _parseParams(cmd.parameters);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Icon(Icons.check_circle_outline, size: 14,
                      color: theme.colorScheme.outline),
                  const SizedBox(width: 6),
                  Text(
                    '${params['from'] ?? '?'} +${params['quantity']}L — fulfilled',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ]),
              );
            }),
          ],
        ),
      ),
    );
  }

  Map<String, dynamic> _parseParams(String params) {
    try { return jsonDecode(params) as Map<String, dynamic>; }
    catch (_) { return {}; }
  }

  Widget _aboutRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(
          width: 80,
          child: Text(label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
        ),
        Expanded(
          child: Text(value,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
  }

  Widget _buildMissionCard(ThemeData theme) {
    final isLeader = _myCapabilities.contains('leader');
    final required = _requiredLiters;
    final current = _counterValue;
    final pct = required > 0 ? (current / required).clamp(0.0, 1.0) : 0.0;
    final statusColor = pct >= 0.8
        ? Colors.green
        : pct >= 0.5
            ? Colors.orange
            : Colors.red;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.flag_outlined, size: 16),
              const SizedBox(width: 6),
              Text('Mission Objective',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 8),

            // Leader: day stepper
            if (isLeader) ...[
              Row(children: [
                Text('Duration:', style: theme.textTheme.bodySmall),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _missionDaysDraft > 1
                      ? () => setState(() => _missionDaysDraft--)
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('$_missionDaysDraft day${_missionDaysDraft == 1 ? '' : 's'}',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _missionDaysDraft < 30
                      ? () => setState(() => _missionDaysDraft++)
                      : null,
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _node != null
                      ? () => _setMission(_node!, _missionDaysDraft)
                      : null,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Set'),
                ),
              ]),
              const SizedBox(height: 6),
            ],

            if (_missionDays > 0) ...[
              // Supply requirement summary
              Text(
                '$_missionDays-day mission · ${_roster.length} node${_roster.length == 1 ? '' : 's'} · '
                '${_litersPerPersonPerDay}L/person/day → ${required}L required',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 8),
              // Progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 10,
                  backgroundColor: theme.colorScheme.surfaceVariant,
                  color: statusColor,
                ),
              ),
              const SizedBox(height: 6),
              // Single row: liters + who set it on the left, percent on the
              // right. (Was three cramped, overlapping lines.)
              Row(children: [
                Text(
                  '${current}L / ${required}L',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.bold, color: statusColor),
                ),
                if (_missionSetBy != null)
                  Flexible(
                    child: Text(
                      '  ·  set by $_missionSetBy',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const Spacer(),
                Text(
                  '${(pct * 100).round()}%',
                  style: theme.textTheme.bodySmall?.copyWith(color: statusColor),
                ),
              ]),
            ] else if (!isLeader)
              Text('Awaiting mission objective from leader.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline,
                          fontStyle: FontStyle.italic)),
          ],
        ),
      ),
    );
  }

  Widget _contribChip({
    required BuildContext context,
    required String label,
    required int value,
    required ThemeData theme,
    required bool isMe,
  }) {
    final color = isMe ? theme.colorScheme.primary : theme.colorScheme.secondary;
    // Shorten label: "macOS · H42W5J2K26" → "macOS", "iPhone (simulator)" → "iPhone"
    final shortLabel = label.split(' ·').first.split(' (').first.trim();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        '$shortLabel: $value',
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Color _collectionColor(String collection, ThemeData theme) {
    // Stable color per collection name
    final colors = [
      Colors.blue, Colors.purple, Colors.teal,
      Colors.orange, Colors.pink, Colors.indigo,
    ];
    return colors[collection.hashCode.abs() % colors.length];
  }

  void _publishTest() {
    final node = _node;
    if (node == null) return;
    final count = ++_publishCount;
    try {
      final docId = node.publishRaw(
        'test',
        '{"seq":$count,"ts":${DateTime.now().millisecondsSinceEpoch}}',
      );
      // The subscription listener will add this to the change feed.
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _startBle([PeatFlutterNode? explicit]) {
    final node = explicit ?? _node;
    if (node == null || _bleRunning) return;

    // Android: the real BLE transport is peat-btle, driven natively in
    // MainActivity (BleBridge). It owns the outbound fan-out via
    // subscribeOutboundFramesJni, so we must NOT also drain it here with
    // startOutboundFrames() — that would split frames between two consumers.
    if (Platform.isAndroid) {
      _bleChannel.invokeMethod<bool>('startBle').then((ok) {
        if (!mounted) return;
        setState(() => _bleRunning = ok ?? false);
      }).catchError((e) {
        if (!mounted) return;
        // e.g. permissions not granted yet — user grants then taps again.
        setState(() => _bleRunning = false);
      });
      return;
    }

    // Other platforms: existing placeholder frame-count stream.
    try {
      final sub = node.startOutboundFrames().listen((frame) {
        if (!mounted) return;
        setState(() => _bleFrameCount++);
      });
      setState(() {
        _outboundSub = sub;
        _bleRunning = true;
        _bleFrameCount = 0;
      });
    } catch (_) {
      // BLE unavailable on this platform — silently ignore.
    }
  }

  // Wi-Fi Direct: form an infrastructure-free P2P LAN so iroh (mDNS) can
  // discover + sync without an AP/hotspot. Tap on BOTH phones; one becomes the
  // group owner. iroh does the actual document sync over the formed link.
  void _toggleWifiDirect() {
    if (!Platform.isAndroid) return;
    if (_wifiDirectOn) {
      _wifiChannel.invokeMethod('stopWifiDirect').catchError((_) {});
      setState(() {
        _wifiDirectOn = false;
        _wifiDirectStatus = 'idle';
      });
    } else {
      _wifiChannel.invokeMethod<bool>('startWifiDirect').then((ok) {
        if (!mounted) return;
        setState(() => _wifiDirectOn = ok ?? false);
      }).catchError((_) {
        if (!mounted) return;
        setState(() => _wifiDirectOn = false);
      });
    }
  }

  void _stopBle() {
    if (Platform.isAndroid) {
      _bleChannel.invokeMethod('stopBle').catchError((_) {});
      setState(() => _bleRunning = false);
      return;
    }
    _outboundSub?.cancel();
    setState(() {
      _outboundSub = null;
      _bleRunning = false;
    });
  }

  void _stopNode() {
    setState(() => _stopping = true);
    _changeSub?.cancel();
    _outboundSub?.cancel();
    _peerTimer?.cancel();
    _counterTimer?.cancel();
    _changeLogTimer?.cancel();
    // UNBIND the BLE bridge from this node BEFORE freeing it — without
    // stopping the radio. The bridge's outbound subscription is bound to this
    // node; unbinding drops its handle (so a late inbound frame can't touch
    // the freed node) while keeping the BLE link connected. On restart,
    // _startBle → BleBridge.start() RE-BINDS the new node (re-subscribes
    // outbound + new handle). (Fully stopping/re-initializing the radio here
    // did not reconnect cleanly — "no connection after restart"; and leaving
    // it bound to the old node left it "running but deaf".)
    if (Platform.isAndroid) {
      _bleChannel.invokeMethod('unbindBle').catchError((_) => null);
    }
    try { _node?.dispose(); } catch (_) {}
    // Release the native global's owning reference to the node (set by
    // create_node) so the node can actually be freed now that Dart has
    // dropped its handle. Done at node teardown, not BLE stop — the node
    // outlives BLE start/stop. See peat#978.
    if (Platform.isAndroid) {
      _bleChannel.invokeMethod('clearGlobalNodeHandle').catchError((_) => null);
    }
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) setState(() => _stopping = false);
    });
    setState(() {
      _node = null;
      _nodeId = null;
      _changeSub = null;
      _outboundSub = null;
      _peerTimer = null;
      _counterTimer = null;
      _peers = [];
      _syncStats = null;
      _counterLastBy = null;
      _myCounterDocKey = '';
      _peerNames.clear();
      _missionDays = 0;
      _missionSetBy = null;
      _activeCell = null;
      _commands = [];
      _claimedCommandIds.clear();
      _lastCellPeers = {};
      _roster = [];
      // _contentHashes persists across stop/start intentionally.
      _stopping = false;
      // Keep _myInc/_myDec/_counterDirty/_peerContributions so offline
      // edits and peer values persist across stop/start cycles.
      _bleRunning = false;
      _bleFrameCount = 0;
    });
  }

  @override
  void dispose() {
    _changeSub?.cancel();
    _outboundSub?.cancel();
    _peerTimer?.cancel();
    _counterTimer?.cancel();
    _changeLogTimer?.cancel();
    _callsignCtrl.dispose();
    _callsignFocus.dispose();
    _node?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasNode = _node != null;
    final theme = Theme.of(context);

    // Paint the status bar blue to match the header strip.
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Color(0xFF2768D4),
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));

    return DefaultTabController(
      length: 3,
      child: Scaffold(
      resizeToAvoidBottomInset: false,
      // No AppBar — we draw the blue header manually so tabs sit flush
      // against the safe area with zero dead space.
      body: Column(children: [
        // Blue header: status bar inset + tab bar, no toolbar height gap
        Material(
          color: const Color(0xFF2768D4),
          child: Column(children: [
            SizedBox(height: MediaQuery.of(context).padding.top),
            const TabBar(
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              indicatorColor: Colors.white,
              dividerColor: Colors.transparent,
              labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              unselectedLabelStyle: TextStyle(fontSize: 13),
              tabs: [
                Tab(height: 42, icon: Icon(Icons.water_drop, size: 16), text: 'Operations'),
                Tab(height: 42, icon: Icon(Icons.timeline, size: 16), text: 'Activity'),
                Tab(height: 42, icon: Icon(Icons.info_outline, size: 16), text: 'About'),
              ],
            ),
          ]),
        ),
        Expanded(child: TabBarView(
        children: [
          // ── Tab 0: Operations ────────────────────────────────────────
          Column(
          children: [
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
            // ---- status / error banner ----
            if (_error != null)
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                        fontSize: 13),
                  ),
                ),
              ),

            // ---- callsign + node start/stop on one line ----
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: _editingCallsign
                      // Edit mode: inline text field
                      ? TextField(
                          controller: _callsignCtrl,
                          focusNode: _callsignFocus,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 2),
                            border: InputBorder.none,
                            focusedBorder: UnderlineInputBorder(
                              borderSide: BorderSide(
                                  color: theme.colorScheme.primary, width: 2),
                            ),
                            suffixIcon: GestureDetector(
                              onTap: () {
                                _callsignCtrl.text = _callsignPrev;
                                setState(() => _editingCallsign = false);
                                _callsignFocus.unfocus();
                              },
                              child: const Icon(Icons.close, size: 16),
                            ),
                          ),
                          onSubmitted: (_) {
                            if (hasNode) _publishSelf(_node!);
                            setState(() => _editingCallsign = false);
                            _callsignFocus.unfocus();
                          },
                        )
                      // Display mode: tappable text
                      : GestureDetector(
                          onTap: _beginEditCallsign,
                          child: Row(children: [
                            Text(
                              _callsign,
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.edit_outlined,
                                size: 14,
                                color: theme.colorScheme.outline),
                          ]),
                        ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: (_starting || _stopping)
                      ? null
                      : (hasNode ? _stopNode : _startNode),
                  style: FilledButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: (_starting || _stopping)
                      ? Row(mainAxisSize: MainAxisSize.min, children: [
                          SizedBox(
                            width: 12, height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: Theme.of(context).colorScheme.onPrimary,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _stopping ? 'Stopping…' : 'Starting…',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ])
                      : Text(hasNode ? 'Stop' : 'Start',
                          style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),


            const SizedBox(height: 12),

            // ---- shared CRDT counter (always visible) ----
            const SizedBox(height: 10),
            Card(
              color: _counterDirty
                  ? theme.colorScheme.tertiaryContainer.withOpacity(0.4)
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('💧', style: TextStyle(fontSize: 16)),
                        const SizedBox(width: 6),
                        Text('Water Supply (L)',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        if (!hasNode)
                          Chip(
                            label: const Text('✈ offline'),
                            labelStyle: theme.textTheme.labelSmall,
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          )
                        else if (_counterDirty)
                          Chip(
                            label: const Text('⟳ syncing'),
                            labelStyle: theme.textTheme.labelSmall,
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton.filledTonal(
                          icon: const Icon(Icons.remove_circle_outline),
                          iconSize: 28,
                          tooltip: 'Consume 1L',
                          onPressed: () => _writeCounter(_node, false),
                        ),
                        const SizedBox(width: 24),
                        Column(
                          children: [
                            Text(
                              '${_myInc - _myDec} / $_counterValue',
                              style: theme.textTheme.displaySmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            Text('yours / total L',
                                style: theme.textTheme.labelSmall
                                    ?.copyWith(color: theme.colorScheme.outline)),
                          ],
                        ),
                        const SizedBox(width: 24),
                        IconButton.filledTonal(
                          icon: const Icon(Icons.add_circle_outline),
                          iconSize: 28,
                          tooltip: 'Resupply 1L',
                          onPressed: () => _writeCounter(_node, true),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // ---- mission objective ----
            if (hasNode) ...[
              const SizedBox(height: 12),
              _buildMissionCard(theme),
            ],

            // ---- cell formation ----
            if (hasNode) ...[
              const SizedBox(height: 10),
              _buildCellCard(theme),
            ],

            // ---- command / resupply ----
            if (hasNode) ...[
              const SizedBox(height: 10),
              _buildCommandCard(theme),
            ],

            // ---- node roster (primary situational awareness) ----
            if (_roster.isNotEmpty) ...[
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Node Roster (${_roster.length})',
                          style: theme.textTheme.labelMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      ..._roster.map((n) {
                        final isMe = n.id == _nodeId;
                        // "Connected" = we've received this peer's heartbeat
                        // recently (skew-immune local-receipt liveness), NOT the
                        // iroh `_peers` set — iroh-over-WiFiDirect connects then
                        // dies on Android, so it falsely showed a dead Wi-Fi link.
                        final sinceSeen = DateTime.now().millisecondsSinceEpoch -
                            (_nodeSeenLocal[n.id] ?? 0);
                        final isConnected = isMe || sinceSeen < 25000;
                        // Per-peer transport badges: show EVERY live carrier so
                        // BLE + P2PWiFi appear together when both are up. These
                        // are app-level carrier links (BLE mesh / Wi-Fi Direct
                        // TCP tunnel); for the 2-node demo they're global, shown
                        // against the live peer. iroh's _peers is intentionally
                        // not used (dead on these phones).
                        const bleBlue = Color(0xFF2196F3);
                        final bleUp = !isMe && isConnected && _blePeerCount > 0;
                        final wifiUp = !isMe && isConnected && _wifiTunnelPeers > 0;
                        final transports = <Widget>[];
                        if (isMe) {
                          transports.add(Icon(Icons.person,
                              size: 14, color: theme.colorScheme.primary));
                        } else if (!isConnected) {
                          transports.add(Icon(Icons.bluetooth_disabled,
                              size: 14, color: theme.colorScheme.outline));
                        } else {
                          if (bleUp) {
                            transports.add(const Icon(Icons.bluetooth,
                                size: 14, color: bleBlue));
                          }
                          if (wifiUp) {
                            transports.add(const Icon(Icons.wifi,
                                size: 14, color: Colors.green));
                          }
                          if (transports.isEmpty) {
                            // Live (heartbeating) but carrier flags not up yet.
                            transports.add(const Icon(Icons.lan,
                                size: 14, color: Colors.green));
                          }
                        }
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(children: [
                            // One badge per live carrier (BLE blue, Wi-Fi green).
                            Row(mainAxisSize: MainAxisSize.min, children: [
                              for (var i = 0; i < transports.length; i++) ...[
                                if (i > 0) const SizedBox(width: 2),
                                transports[i],
                              ],
                            ]),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    n.name, // callsign
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: isConnected
                                          ? null
                                          : theme.colorScheme.outline,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Wrap(
                              spacing: 3,
                              children: n.capabilities
                                  .take(5)
                                  .map((c) => Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 4, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: theme.colorScheme.surfaceVariant,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(c,
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(fontSize: 10)),
                                      ))
                                  .toList(),
                            ),
                          ]),
                        );
                      }),
                  ],
                ),
              ),
            ),
            ], // roster isNotEmpty

            // ---- capabilities (secondary — configure role) ----
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text('My Capabilities',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const Spacer(),
                      if (hasNode)
                        TextButton(
                          onPressed: () {
                            if (_node != null) _publishSelf(_node!);
                          },
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text('publish',
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.colorScheme.primary)),
                        ),
                    ]),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: _allCapabilities.map((cap) {
                        final selected = _myCapabilities.contains(cap);
                        return FilterChip(
                          label: Text(cap),
                          labelStyle: theme.textTheme.labelSmall,
                          selected: selected,
                          onSelected: (v) {
                            setState(() {
                              if (v) {
                                _myCapabilities = [..._myCapabilities, cap];
                              } else {
                                _myCapabilities = _myCapabilities
                                    .where((c) => c != cap)
                                    .toList();
                              }
                            });
                            // Re-publish so peers see the change and it's
                            // persisted in this node's Peat document (the store),
                            // NOT app prefs — a database reset then clears it.
                            if (_node != null) _publishSelf(_node!);
                          },
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),

            // BLE starts automatically with the node — no manual button needed.

                    ]), // SliverChildListDelegate
                  ), // SliverList
                ), // SliverPadding
              ], // slivers
            ), // CustomScrollView
          ), // Expanded
          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
          ],  // Column children (Operations tab)
          ), // Column (Operations tab)

          // ── Tab 1: Activity ──────────────────────────────────────────
          Column(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Text('Document changes', style: theme.textTheme.titleSmall),
                const Spacer(),
                if (_changeLog.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(() => _changeLog.clear()),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 0),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text('clear', style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
                  ),
              ]),
            ),
            const Divider(height: 1),
          Expanded(
              child: _changeLog.isEmpty
                  ? Center(
                      child: Text(
                        hasNode
                            ? 'No changes yet — publish a doc to see activity.'
                            : 'Start a node to see document activity.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                        textAlign: TextAlign.center,
                      ))
                  : ListView.separated(
                      itemCount: _changeLog.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 48),
                      itemBuilder: (_, i) {
                        final e = _changeLog[i];
                        final collColor = _collectionColor(e.collection, theme);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Collection badge
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: collColor.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Center(
                                  child: Text(
                                    e.collection.substring(0, min(3, e.collection.length)).toUpperCase(),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: collColor,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              // Content
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(children: [
                                      Text(
                                        '${e.collection} / ${e.shortDocId}',
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          fontWeight: FontWeight.w600,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: e.changeType == 'upsert'
                                              ? Colors.green.withOpacity(0.15)
                                              : Colors.red.withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          e.changeType,
                                          style: theme.textTheme.labelSmall?.copyWith(
                                            color: e.changeType == 'upsert'
                                                ? Colors.green.shade700
                                                : Colors.red.shade700,
                                          ),
                                        ),
                                      ),
                                    ]),
                                    if (e.contentPreview != null)
                                      Text(
                                        e.contentPreview!,
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: theme.colorScheme.onSurface.withOpacity(0.7),
                                          fontFamily: 'monospace',
                                          fontSize: 11,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                  ],
                                ),
                              ),
                              // Relative time
                              Text(
                                e.relativeTime,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ]), // Column (Activity tab)

          // ── Tab 2: About ─────────────────────────────────────────────
          SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Branding
                Center(
                  child: Image.asset('PEAT.png', width: 100, height: 100),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Column(children: [
                    Text('peat-water',
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    Text('powered by peat mesh',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline)),
                  ]),
                ),
                const SizedBox(height: 12),
                Text(
                  'A demonstration of Defense Unicorns\' Peat mesh protocol — '
                  'a secure, peer-to-peer, CRDT-based data synchronization '
                  'framework designed for disconnected and degraded network '
                  'environments.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'This demo shows real-time water supply tracking across a '
                  'mesh of nodes using a PN-Counter CRDT, with leader-assigned '
                  'mission objectives and automatic peer discovery via mDNS.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                // Node info
                Text('This Node',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                if (_nodeId != null) ...[
                  _aboutRow(theme, 'Node ID', _nodeId!),
                  _aboutRow(theme, 'Callsign', _callsign),
                ],
                if (_syncStats != null) ...[
                  _aboutRow(theme, 'Sent', '${_syncStats!.bytesSent} B'),
                  _aboutRow(theme, 'Received', '${_syncStats!.bytesReceived} B'),
                  _aboutRow(theme, 'Peers (Wi-Fi)', '$_wifiTunnelPeers connected'),
                ],
                if (Platform.isAndroid && _bleRunning)
                  _aboutRow(theme, 'Peers (BLE)', '$_blePeerCount connected'),
                if (Platform.isAndroid) ...[
                  _aboutRow(theme, 'Wi-Fi Direct', _wifiDirectStatus),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _toggleWifiDirect,
                      icon: Icon(_wifiDirectOn ? Icons.wifi_off : Icons.wifi_tethering, size: 18),
                      label: Text(_wifiDirectOn ? 'Stop Wi-Fi Direct' : 'Start Wi-Fi Direct'),
                    ),
                  ),
                  Text(
                    'Tap on both phones (no Wi-Fi/AP needed). Accept the '
                    '"invite to connect" prompt; then Stop/Start the node so iroh '
                    'binds to the P2P link.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline, fontStyle: FontStyle.italic),
                  ),
                ],
                if (_nodeId != null) ...[
                  const SizedBox(height: 12),
                  Text('Network Diagnostics',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  _aboutRow(theme, 'Endpoint',
                      (_endpointAddr == null || _endpointAddr!.isEmpty)
                          ? '— (not advertising)'
                          : _endpointAddr!),
                  _aboutRow(theme, 'Socket',
                      _endpointSocketAddr ?? '— (no bound address)'),
                  _aboutRow(theme, 'Discovered',
                      _peers.isEmpty ? 'none yet' : '${_peers.length} peer(s)'),
                  if (_peers.isNotEmpty)
                    for (final p in _peers)
                      _aboutRow(theme, '·',
                          p.length > 24 ? '${p.substring(0, 24)}…' : p),
                ],
                if (_nodeId == null)
                  Text('Start a node to see details.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline,
                              fontStyle: FontStyle.italic)),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                const Divider(),
                const SizedBox(height: 4),
                Text('Reset', style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold, color: Colors.red)),
                const SizedBox(height: 4),
                Text(
                  'Stop the node on ALL devices before resetting. '
                  'If any peer is still running, it will sync its data back.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: hasNode ? null : _resetDatabase,
                  icon: const Icon(Icons.delete_forever_outlined,
                      size: 16, color: Colors.red),
                  label: Text(
                    hasNode ? 'Stop node first' : 'Reset local database',
                    style: TextStyle(
                        color: hasNode ? theme.colorScheme.outline : Colors.red,
                        fontSize: 13),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                        color: hasNode
                            ? theme.colorScheme.outline.withOpacity(0.3)
                            : Colors.red.withOpacity(0.5)),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(height: 16),
                Text('© 2026 Defense Unicorns',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
                Text('github.com/defenseunicorns/peat-flutter',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline,
                            fontFamily: 'monospace')),
              ],
            ),
          ),

          ], // TabBarView children
        )), // TabBarView + Expanded
        ], // Column children (header + content)
      ), // Column body
      ), // Scaffold
    ); // DefaultTabController
  }
}
