// Copyright 2026 Defense Unicorns
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, Directory;
import 'dart:math' show min, Random;

import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:flutter/services.dart' show SystemUiOverlayStyle, SystemChrome, MethodChannel, EventChannel;
import 'package:path_provider/path_provider.dart';
import 'package:device_info_plus/device_info_plus.dart';
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

class _PeatExampleHomeState extends State<PeatExampleHome>
    with WidgetsBindingObserver {
  PeatFlutterNode? _node;
  String? _nodeId;
  String _hostName = '';
  String? _error;
  bool _starting = false;
  bool _stopping = false;
  bool _bleRunning = false;
  int _bleFrameCount = 0;
  int _blePeerCount = 0; // connected BLE peers (Android peat-btle bridge)
  // Node-ids (32-bit, first 8 hex of the full node id) of DIRECTLY-connected
  // BLE peers — from the native bridge. Lets Connections mark a peer "direct"
  // vs "relayed" (reachable only via the CRDT relay = not in this set).
  Set<int> _directPeerIds = {};
  // Each node advertises its own direct-peer set in its presence doc; this maps
  // a node's short id -> the short ids IT reports as directly connected. A BLE
  // link is bidirectional, so we treat a peer as "direct" if it's in our set OR
  // we're in its set (the central side may not register the peer locally even
  // though the peripheral side does — e.g. the iPad dialing out to the phones).
  Map<int, Set<int>> _advertisedDirect = {};
  // Short ids of peers that advertise Wi-Fi-Direct capability (Android with
  // Wi-Fi on). The Wi-Fi badge only shows for these — iOS (iPad) is BLE-only.
  Set<int> _wifiPeers = {};
  // Android BLE transport bridge (peat-btle pipe) lives in native MainActivity.
  static const MethodChannel _bleChannel = MethodChannel('peat/ble');
  // iOS BLE inbound: native PeatBleBridge streams decrypted 0xAF relay payloads
  // here; Dart unwraps the envelope and ingests them into the mesh.
  static const EventChannel _bleRxChannel = EventChannel('peat/ble_rx');
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
  // The cell doc id. The leader publishes a single curated cell; its `members`
  // list is the source of truth for membership (read back by every node).
  static const _cellDocId = 'alpha-cell';
  // Committed cell membership, mirrored from the synced cell doc's `members`
  // list. Keyed by CALLSIGN — the stable interim identity (a node id churns on
  // reset/reinstall; a callsign does not, until a future hardware-based id).
  // Curated explicitly via Reform / Add / Remove — it does NOT auto-follow the
  // roster, so a node dropping out doesn't mutate the cell.
  final Set<String> _cellMembers = {};
  // node id -> callsign, for resolving roster + available nodes in the UI.
  final Map<String, String> _nodeNames = {};
  // Track command IDs we've already claimed so we don't double-increment.
  final Set<String> _claimedCommandIds = {};
  // Only auto-claim commands issued after this session started.
  int _sessionStartMs = 0;
  // Resupply transfer: a requestor credits its own "yours" +qty exactly once
  // when it sees ITS request flip to COMPLETED. The shared total is unchanged
  // (it's a transfer, not new water) — the leader debits its own "yours" -qty
  // on fulfill — so neither side touches the shared counter and no double-count.
  final Set<String> _claimedReqs = {};

  // Mission objective (leader-set, shared via CRDT)
  static const _missionCollection = 'mission';
  static const _missionDocId = 'objective';
  static const _litersPerPersonPerDay = 3;
  int _missionDays = 0;       // 0 = not set
  String? _missionSetBy;
  int _missionDaysDraft = 3;  // leader UI stepper

  int get _requiredLiters {
    if (_missionDays <= 0) return 0;
    // Crew size comes from the SYNCED cell document (the same value on every
    // node), NOT the local _roster — which only reflects this node's direct
    // BLE connections and so differs per node (e.g. a node one hop away sees a
    // smaller roster but the same cell). Fall back to the roster only before a
    // cell has formed.
    final crew = (_activeCell?.nodeCount ?? 0) > 0
        ? _activeCell!.nodeCount
        : _roster.length;
    return crew > 0 ? _missionDays * _litersPerPersonPerDay * crew : 0;
  }

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

  // Water supply is a PER-NODE holdings CRDT document: collection 'holdings',
  // keyed by callsign, value = that node's liters count. "yours" = my entry;
  // "total" = the SUM of all entries. Both derive from synced/persisted CRDT
  // state (no local-only tally that resets to 0 on restart), so they converge
  // and survive restarts. A transfer (fulfill) is requestor-entry +qty /
  // leader-entry -qty → the sum is unchanged.
  static const _holdingsCollection = 'holdings';
  // Build signature injected at compile time (--dart-define=PEAT_BUILD_ID=...).
  // When it differs from the last value we started with, the app binary was
  // redeployed — so we auto-wipe the persisted store on the next Start to avoid
  // the stale-counter "0/N" state (the shared total persists across a reinstall
  // but the local "yours" tally resets). Same build → no wipe, so a normal
  // mid-demo restart still converges. 'dev' is the default for un-stamped builds.
  static const _buildId = String.fromEnvironment('PEAT_BUILD_ID', defaultValue: 'dev');
  // Last value read from the local Automerge counter (the shared total).
  int _crdtTotal = 0;
  // This device's own cumulative contribution, for the "yours" display (local
  // tally only — the pool total is the CRDT value).
  int _myLiters = 0;
  int get _counterValue => _crdtTotal;
  Timer? _counterTimer;
  StreamSubscription<DocumentChange>? _changeSub;
  StreamSubscription<OutboundFrame>? _outboundSub;
  StreamSubscription<dynamic>? _bleRxSub; // iOS: inbound BLE relay payloads
  final Map<String, int> _lastTxMs = {}; // iOS: outbound frame de-dup (echo suppression)

  // CRDT-frame reassembly buffer (iOS receive). A large Automerge doc (hex)
  // exceeds the ~512B BLE wire ceiling, so _broadcastCrdt splits it into
  // fragments; we collect them here keyed by "collection:msgId" until the full
  // set arrives, then merge. Idempotent: re-sent/duplicate fragments are fine.
  final Map<String, Map<int, Uint8List>> _crdtReasm = {};
  // Last-touch wall-clock (ms) per partial set, so stale sets (sender died
  // mid-fragment, or a dropped fragment never arrives) can be evicted by AGE
  // instead of nuking the whole buffer on a size threshold — see _crdtReassemble.
  final Map<String, int> _crdtReasmTs = {};
  static const int _kCrdtReasmTtlMs = 15000;

  // Presence over the CRDT relay (the only transport that reliably carries
  // iPad<->Android both ways — the connection-based/lite path is asymmetric).
  // Change-detected PUT + round-robin catch-up keep the doc tiny and the radio
  // quiet. The "Connections" view is the UNION of this (direct + multi-hop
  // reachable) and the local connection-based store, per-device.
  String? _lastSelfNodeJson; // last identity/caps PUT (re-PUT only on change)

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
    WidgetsBinding.instance.addObserver(this);
    // Default capabilities by platform role; macOS = command post.
    if (Platform.isMacOS) {
      _myCapabilities = ['leader', 'comms', 'logistics'];
    } else if (Platform.isIOS) {
      _myCapabilities = ['recon', 'medical'];
    } else {
      _myCapabilities = ['comms'];
    }
    // Provisional random callsign until the device-derived one resolves async.
    final rng = Random();
    _hostName =
        '${_callsignPool[rng.nextInt(_callsignPool.length)]}-${rng.nextInt(90) + 10}';
    _callsignCtrl = TextEditingController(text: _hostName);
    _callsignPrev = _hostName;
    // Callsign = STABLE per-device identity. Prefer a saved (user-renamed) one;
    // otherwise derive deterministically from the device's hardware ID (Android
    // ANDROID_ID / iOS identifierForVendor) so a given device is ALWAYS the same
    // callsign across reinstalls/resets. This stabilizes everything keyed by
    // callsign (holdings, presence) and stops zombie identities accumulating.
    SharedPreferences.getInstance().then((prefs) async {
      final saved = prefs.getString('callsign');
      if (saved != null && saved.isNotEmpty) {
        if (mounted) setState(() {
          _callsignCtrl.text = saved;
          _callsignPrev = saved;
        });
        return;
      }
      final dev = await _deviceCallsign();
      if (dev != null && mounted) {
        setState(() {
          _hostName = dev;
          _callsignCtrl.text = dev;
          _callsignPrev = dev;
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
      // Auto-wipe the persisted store if the app binary changed since we last
      // started (a redeploy). This must run BEFORE the node opens the store.
      // Skipped for un-stamped 'dev' builds and on a same-build restart, so
      // only an actual reinstall triggers the clean slate.
      if (_buildId != 'dev' && prefs.getString('build_id') != _buildId) {
        var wiped = 0;
        if (await dir.exists()) {
          await for (final entry in dir.list()) {
            final name = entry.path.split(Platform.pathSeparator).last;
            if (entry is Directory &&
                (name == 'peat' || name.startsWith('peat-'))) {
              await entry.delete(recursive: true);
              wiped++;
            }
          }
        }
        await prefs.setString('build_id', _buildId);
        debugPrint('[peat] new build $_buildId — wiped $wiped stale store(s)');
        // Fresh slate: drop in-memory tallies that would otherwise show stale.
        _crdtTotal = 0;
        _myLiters = 0;
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
      // Seed the displayed total from the (re-synced) shared CRDT counter.
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
      var _catchupRotor = 0; // round-robins catch-up broadcasts, one per beat
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
          // Keep presence fresh (change-detected: only emits a CRDT frame when
          // identity/caps actually change, so it's cheap on a steady state).
          _publishSelf(_node!);
          // The SMALL, time-critical docs re-broadcast EVERY beat (4s): a peer
          // on a slightly lossier path needs frequent re-sends to collect all
          // fragments of a multi-fragment doc (the counter is one fragment so it
          // always lands; commands is 3+ fragments — at a 16s cadence a lossy
          // peer like A1 could never accumulate a full set, which is exactly why
          // it stopped seeing requests). The BULKY / slow-changing docs (nodes
          // presence, mission, cell) round-robin every ~16s — they change rarely
          // and also broadcast immediately on change, so the slow catch-up is
          // fine and keeps the channel from saturating.
          _flushMyCounter(_node!); // shared counter — small, every beat
          _broadcastCrdt('commands', _node!.crdtKvSnapshot('commands')); // every beat
          switch (_catchupRotor % 2) {
            case 0:
              _broadcastCrdt('nodes', _node!.crdtKvSnapshot('nodes'));
              break;
            case 1:
              // Only the SETTER re-broadcasts the mission (avoid concurrent
              // writes to the shared 'objective' that flash on the leader).
              if (_missionDays > 0 && _missionSetBy == _callsign) {
                _republishMission(_node!);
              }
              // Leader re-broadcasts the EXISTING committed cell (idempotent);
              // it does NOT auto-change membership (curated via Reform/Add/Remove).
              if (_myCapabilities.contains('leader') && _cellMembers.isNotEmpty) {
                _republishCell();
              }
              break;
          }
          _catchupRotor++;
        }
        // Clean up ghost entries that may have synced in from the peer.
        _cleanGhostNodes(_node!);
        // Connections source = UNION of the local connection-based store and the
        // CRDT presence doc (which relays mesh-wide, so it carries the nodes the
        // connection-based path misses — e.g. the iPad on the Androids). CRDT
        // entries win per id (always named). Per-device: direct + multi-hop.
        final crdtNodes = _crdtNodes(_node!);
        final crdtIds = crdtNodes.map((n) => n.id).toSet();
        final unionById = <String, NodeInfo>{};
        for (final n in _node!.nodes) {
          unionById[n.id] = n;
        }
        for (final n in crdtNodes) {
          unionById[n.id] = n;
        }
        final unionNodes = unionById.values.toList();
        // Refresh cell + command state.
        try {
          final cmds = _readCommands(_node!); // from the CRDT KV doc, not lite
          for (final c in cmds) {
            // Requestor receives its resupply: when MY request is fulfilled,
            // credit MY holdings entry +qty once (the transfer-in). It's a CRDT
            // put (persists + syncs); the leader debited its own entry -qty, so
            // the total (sum) is unchanged. Guard on session start so a COMPLETED
            // request already in the doc at launch isn't re-claimed on restart
            // (the holdings doc already reflects it).
            if (c.commandType == 'WATER_REQUEST' &&
                c.status == CommandStatus.completed &&
                c.originator == _nodeId &&
                c.createdAt >= _sessionStartMs &&
                _claimedReqs.add(c.id)) {
              final qty = _parseParams(c.parameters)['quantity'] as int? ?? 0;
              if (qty > 0) _adjustCounter(_node, qty);
            }
          }
          // Cell membership comes from the SYNCED cell doc's `members` list,
          // read as generic JSON (the typed `cells` accessor doesn't carry it).
          final cellFields = _docFields(_node!.getRaw('cells', _cellDocId));
          // node id -> callsign, for resolving the roster + available nodes.
          // Skip incomplete/ghost node docs (empty name or name == id).
          final names = <String, String>{
            for (final n in unionNodes)
              if (n.name.isNotEmpty && n.name != n.id) n.id: n.name,
          };
          // Membership is keyed by CALLSIGN. Tolerate a LEGACY cell doc that
          // still lists node ids (pre-migration): map self's id and any known
          // peer id to its callsign. Drop any member still left as an
          // unresolved node-id-shaped string — a dead identity from reset churn
          // whose self-doc is gone — so it can't clutter membership or the
          // counter. Once the leader re-advertises (_republishCell) the doc is
          // rewritten in clean callsign form.
          final members = ((cellFields?['members'] as List?) ?? const [])
              .map((e) => e.toString())
              .map((m) => m == _nodeId ? _callsign : (names[m] ?? m))
              .where((m) => !_looksLikeNodeId(m))
              .toSet();
          final cells = _node!.cells;
          if (mounted) setState(() {
            _activeCell = cells.isNotEmpty ? cells.first : null;
            _commands = cmds;
            _cellMembers
              ..clear()
              ..addAll(members);
            _nodeNames
              ..clear()
              ..addAll(names);
          });
          // (Removed the requester-side auto-claim: the fulfiller now delivers
          // the +qty directly into the shared CRDT pool at fulfill time, which
          // propagates to every node. Claiming here too would double-count.)
        } catch (_) {}

        setState(() {
          _peers = _node!.connectedPeers;
          _syncStats = _node!.syncStats;
          _endpointAddr = _node!.endpointAddr;
          _endpointSocketAddr = _node!.endpointSocketAddr;
          // BLE peers aren't in the iroh connected-set; poll the native bridge.
          // Both Android and iOS expose blePeerCount over the same channel.
          if ((Platform.isAndroid || Platform.isIOS) && _bleRunning) {
            _bleChannel.invokeMethod<int>('blePeerCount').then((c) {
              if (mounted && c != null && c != _blePeerCount) {
                final rising = _blePeerCount == 0 && c > 0;
                final grew = c > _blePeerCount; // any new peer (incl. 3rd node)
                setState(() => _blePeerCount = c);
                // A peer joined: the fan-out is change-driven and races the
                // connection, so push current state across NOW so the new node
                // appears in our Connections immediately. Fire on ANY increase
                // (not just 0->N) so a 3rd node joining an existing pair still
                // triggers the existing nodes to re-push.
                if (grew && _node != null) {
                  _publishSelf(_node!);
                  // Force a presence snapshot now (bypass _publishSelf's change-
                  // detect gate) so the new peer learns our callsign at once.
                  _broadcastCrdt('nodes', _node!.crdtKvSnapshot('nodes'));
                  _flushMyCounter(_node!);
                }
                // Heavier leader-owned re-publish only on the 0->N edge.
                if (rising && _node != null) {
                  // Re-broadcast leader-owned shared state to the just-joined
                  // peer (fan-out is change-driven, so a mission/cell set
                  // before this peer connected would never reach it). Only the
                  // mission's setter re-publishes it (avoid concurrent writes).
                  if (_missionDays > 0 && _missionSetBy == _callsign) {
                    _republishMission(_node!);
                  }
                  // Re-broadcast the EXISTING committed cell so the just-joined
                  // peer converges — do NOT auto-form/mutate membership here.
                  if (_myCapabilities.contains('leader') &&
                      _cellMembers.isNotEmpty) {
                    _republishCell();
                  }
                }
              }
            }).catchError((_) {});
            // Direct-BLE-peer node-ids → for the Connections direct/relayed mark.
            _bleChannel.invokeMethod<List<dynamic>>('blePeerIds').then((ids) {
              if (!mounted || ids == null) return;
              final next = ids.map((e) => (e as num).toInt()).toSet();
              if (next.length != _directPeerIds.length ||
                  !next.containsAll(_directPeerIds)) {
                setState(() => _directPeerIds = next);
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
          for (final n in unionNodes) {
            final prevHb = _nodeHbSeen[n.id];
            if (prevHb == null) {
              _nodeHbSeen[n.id] = n.lastHeartbeat;
            } else if (n.lastHeartbeat > prevHb) {
              _nodeHbSeen[n.id] = n.lastHeartbeat;
              _nodeSeenLocal[n.id] = localNow;
            }
          }
          final liveCutoff = localNow - const Duration(minutes: 3).inMilliseconds;
          // Connections = nodes THIS device can reach (per-device; not expected
          // to match across devices — that's the Cell's job). Qualifies if:
          // self, a connected peer, recently-advanced presence, OR present in
          // the CRDT presence doc (a relay-only / multi-hop peer). Named-only:
          // drop nodeId-only stubs that made the row flap.
          final allNodes = unionNodes
              .where((n) =>
                  n.id.length >= 16 &&
                  (n.id == _nodeId || (n.name.isNotEmpty && n.name != n.id)) &&
                  (n.id == _nodeId ||
                      _peers.contains(n.id) ||
                      crdtIds.contains(n.id) ||
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
    } catch (e, st) {
      debugPrint('[startfail] $e\n$st');
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
      // Mission rides the CRDT relay (same as counter/commands): the leader is
      // the only writer of the 'objective' key, so there's no LWW conflict, and
      // it converges mesh-wide (incl. relay-only followers) — unlike the old
      // connection-based publishDoc path, which didn't reach every node.
      final map = jsonDecode(node.crdtKvAll(_missionCollection))
          as Map<String, dynamic>;
      final f = map[_missionDocId];
      if (f is! Map<String, dynamic>) return;
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
    // CRDT relay (fragmented 0xAF frame): converges to every node, including
    // relay-only followers. Leader is the sole writer of 'objective'.
    try {
      final hex = node.crdtKvPut(_missionCollection, _missionDocId, json);
      _broadcastCrdt(_missionCollection, hex);
    } catch (_) {}
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
    // Idempotent catch-up re-broadcast of the current mission CRDT snapshot so
    // a peer that joined after it was set still converges.
    try {
      _broadcastCrdt(_missionCollection, node.crdtKvSnapshot(_missionCollection));
    } catch (_) {}
  }

  // Deterministic NATO callsign from the device's stable hardware ID (Android
  // ANDROID_ID / iOS identifierForVendor), so each physical device keeps one
  // identity across reinstalls/resets. Returns null if the ID is unavailable
  // (caller keeps the provisional random callsign).
  Future<String?> _deviceCallsign() async {
    String id = '';
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        id = (await info.androidInfo).id;
      } else if (Platform.isIOS) {
        id = (await info.iosInfo).identifierForVendor ?? '';
      }
    } catch (_) {}
    if (id.isEmpty) return null;
    var h = 0;
    for (final c in id.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    final name = _callsignPool[h % _callsignPool.length];
    final suffix = 10 + (h ~/ _callsignPool.length) % 90;
    return '$name-$suffix';
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
      // NOTE: intentionally KEEP the persisted install id (stable node id).
      // Minting a new id on every reset orphaned the device's prior counter doc
      // under its callsign, accumulating "zombie" docs across resets that
      // different peers deduped inconsistently -> totals never reconverged.
      // Reset is a clean LOCAL wipe; it does not try to drop this device's share
      // from the mesh total (that needs a tombstone the lite transport lacks).
      // Reset in-memory state. The Automerge counter doc (water.automerge)
      // lives under the deleted store dir, so it's wiped too; on restart the
      // node re-merges peers' snapshots and reconverges to the shared total.
      setState(() {
        _crdtTotal = 0;
        _myLiters = 0;
        _changeLog.clear();
        _contentHashes.clear();
        _crdtReasm.clear();
        _crdtReasmTs.clear();
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
    // Publish capabilities through the NODE layer (not putNode). putNode writes
    // a flat shape straight to storage_backend, which the fan-out doesn't
    // observe — so peers received an empty/id-only node and (on iOS) no frame
    // at all. Routing self-publish through the wrapped node-layer path the
    // counter uses makes capabilities sync over BLE and the remote roster show
    // the callsign. The wrapped JSON + changing last_heartbeat are identical on
    // Android and iOS so the two interoperate byte-for-byte.
    final json = jsonEncode({
      'id': id,
      'node_type': 'peat-flutter',
      'name': _callsign,
      'status': 'ACTIVE',
      'readiness': 1.0,
      'capabilities': _myCapabilities,
      'last_heartbeat': DateTime.now().millisecondsSinceEpoch,
    });
    if (Platform.isAndroid) {
      _bleChannel.invokeMethod('publishDoc',
          {'collection': 'nodes', 'json': json}).catchError((_) {
        node.publishSelf(nodeId: id, name: _callsign, capabilities: _myCapabilities);
        return null;
      });
    } else if (Platform.isIOS) {
      // iOS: publish via the Dart node layer directly (no JNI channel). This is
      // what reaches startOutboundFrames -> BLE; publishRaw/publishSelf write
      // to storage_backend and emit nothing.
      try {
        node.publishDocument('nodes', json);
      } catch (_) {
        node.publishSelf(nodeId: id, name: _callsign, capabilities: _myCapabilities);
      }
    } else {
      node.publishSelf(nodeId: id, name: _callsign, capabilities: _myCapabilities);
    }
    // Presence over the CRDT relay: write self into the `nodes` doc (callsign-
    // keyed) and broadcast over the fragmented 0xAF frame — the transport that
    // actually reaches every node both ways. Re-PUT only on an identity/caps
    // change (a PUT appends history); the throttled heartbeat re-broadcasts the
    // unchanged snapshot, which doesn't grow the doc.
    final stableJson = jsonEncode({
      'id': id,
      'node_type': 'peat-flutter',
      'name': _callsign,
      'status': 'ACTIVE',
      'readiness': 1.0,
      'capabilities': _myCapabilities,
      // Our directly-connected BLE peer short-ids, so peers can resolve the
      // link symmetrically (a direct link the other side sees but we don't).
      'direct_peers': (_directPeerIds.toList()..sort()),
      // Wi-Fi-Direct capable? (Android with Wi-Fi on). iOS is BLE-only, so the
      // Wi-Fi badge only shows between nodes that both advertise this.
      'wifi': Platform.isAndroid && _wifiDirectOn,
    });
    if (stableJson != _lastSelfNodeJson) {
      _lastSelfNodeJson = stableJson;
      try {
        final hex = node.crdtKvPut('nodes', _callsign, stableJson);
        _broadcastCrdt('nodes', hex);
      } catch (_) {}
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

  // A peat node id is a long hex string; a callsign is short human text. Used
  // to reject dead node-id identities that leaked into cell membership.
  static final _hexRe = RegExp(r'^[0-9a-fA-F]+$');
  static bool _looksLikeNodeId(String s) => s.length >= 32 && _hexRe.hasMatch(s);

  // Read the per-node holdings CRDT doc ({callsign: liters}). Returns this
  // node's own entry ("yours") and the SUM of all entries ("total") — both from
  // synced CRDT state, so they survive restarts and converge mesh-wide.
  ({int mine, int total}) _readHoldings(PeatFlutterNode node) {
    int mine = 0, total = 0;
    try {
      final map = jsonDecode(node.crdtKvAll(_holdingsCollection))
          as Map<String, dynamic>;
      for (final e in map.entries) {
        final v = (e.value is num)
            ? (e.value as num).toInt()
            : (int.tryParse('${e.value}') ?? 0);
        total += v;
        if (e.key == _callsign) mine = v;
      }
    } catch (_) {}
    return (mine: mine, total: total);
  }

  void _refreshCounter(PeatFlutterNode node) {
    // Inbound CRDT frames merge on receipt; here we surface yours + total from
    // the holdings doc. When all nodes' logs settle on the same total, the mesh
    // has converged.
    final h = _readHoldings(node);
    if (h.mine != _myLiters || h.total != _crdtTotal) {
      if (mounted) setState(() {
        _myLiters = h.mine;
        _crdtTotal = h.total;
      });
    }
  }

  // Catch-up re-broadcast of the holdings CRDT doc (small; idempotent merge).
  void _flushMyCounter(PeatFlutterNode node) =>
      _broadcastCrdt(_holdingsCollection, node.crdtKvSnapshot(_holdingsCollection));

  static const int _kCrdtTransport = 2; // matches BleBridge.kt TRANSPORT_CRDT

  // Broadcast an Automerge doc's save() bytes (hex) for [collection] as a
  // dedicated CRDT frame over BLE — NO lite-bridge. The bytes ride a
  // [0xAF][2=crdt][collLen][collection][hex] envelope; peat-btle's 0xAF opaque
  // relay carries it multi-hop, and peers MERGE it (commutative/idempotent).
  // Wire framing (transport=2): [0xAF][2][collLen][collection]
  //   [msgId:u32 BE][fragIdx:u8][fragCount:u8][chunk...]
  // The hex payload is split into fragments each <= the BLE wire ceiling so a
  // large Automerge doc (which exceeds ~512B once hex-doubled) survives the
  // radio instead of being silently truncated. msgId is content-addressed (a
  // hash of the whole payload) so every re-broadcast of the SAME doc yields
  // identical, interchangeable fragments — re-sends and cross-sender duplicates
  // reassemble harmlessly, and a dropped fragment self-heals on the next
  // heartbeat re-broadcast. The receiver reassembles, then merges (idempotent).
  static const int _kCrdtHdr = 6; // msgId(4) + fragIdx(1) + fragCount(1)
  // Max chunk so 3(env) + collLen(<=8) + 6(frag hdr) + chunk <= 512. 480 leaves margin.
  static const int _kCrdtChunk = 480;

  void _broadcastCrdt(String collection, String hex) {
    final coll = utf8.encode(collection);
    final payload = utf8.encode(hex); // hex string as bytes
    // Content-addressed message id (FNV-1a 32-bit over the payload).
    int msgId = 0x811c9dc5;
    for (final b in payload) {
      msgId = ((msgId ^ b) * 0x01000193) & 0xFFFFFFFF;
    }
    final int fragCount =
        payload.isEmpty ? 1 : ((payload.length + _kCrdtChunk - 1) ~/ _kCrdtChunk);
    final envelopes = <Uint8List>[];
    for (int idx = 0; idx < fragCount; idx++) {
      final int start = idx * _kCrdtChunk;
      final int end =
          (start + _kCrdtChunk < payload.length) ? start + _kCrdtChunk : payload.length;
      final int chunkLen = end - start;
      final env = Uint8List(3 + coll.length + _kCrdtHdr + chunkLen);
      env[0] = 0xAF;
      env[1] = _kCrdtTransport;
      env[2] = coll.length;
      env.setRange(3, 3 + coll.length, coll);
      final int h = 3 + coll.length;
      env[h] = (msgId >> 24) & 0xFF;
      env[h + 1] = (msgId >> 16) & 0xFF;
      env[h + 2] = (msgId >> 8) & 0xFF;
      env[h + 3] = msgId & 0xFF;
      env[h + 4] = idx;
      env[h + 5] = fragCount;
      env.setRange(h + _kCrdtHdr, env.length, payload.sublist(start, end));
      envelopes.add(env);
    }
    _sendCrdtFrames(envelopes);
  }

  // Send the fragment envelopes over the native BLE bridge. Both platforms now
  // fire every fragment without artificial spacing: the native bridges apply
  // proper flow control — Android queues, and the iOS bridge enqueues notify
  // writes and drains them on peripheralManagerIsReady (see BleBridge.swift
  // notifyQueue), which replaced the old 60ms-per-fragment iOS pacing hack that
  // worked around CoreBluetooth silently dropping rapid back-to-back writes.
  void _sendCrdtFrames(List<Uint8List> envelopes) {
    final String method = Platform.isAndroid ? 'crdtTx' : 'bleTx';
    for (final env in envelopes) {
      final Object arg = Platform.isAndroid ? {'bytes': env} : env;
      _bleChannel.invokeMethod(method, arg).catchError((_) => null);
    }
  }

  // Reassemble a CRDT fragment (iOS receive). Returns the full hex string once
  // every fragment of a message has arrived, else null. Buffers partial sets
  // keyed by "collection:msgId"; a re-sent complete set just overwrites.
  String? _crdtReassemble(
      String coll, int msgId, int fragIdx, int fragCount, Uint8List chunk) {
    if (fragCount <= 1) return utf8.decode(chunk); // single fragment, fast path
    final key = '$coll:$msgId';
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // Evict partial sets older than the TTL: a sender that died mid-fragment, or
    // a set missing a dropped fragment, would otherwise leak forever. Age-based
    // (not size-based) so a healthy in-flight set is never collateral.
    if (_crdtReasmTs.isNotEmpty) {
      _crdtReasmTs.removeWhere((k, t) {
        if (nowMs - t <= _kCrdtReasmTtlMs) return false;
        _crdtReasm.remove(k);
        return true;
      });
    }
    final parts = _crdtReasm.putIfAbsent(key, () => {});
    _crdtReasmTs[key] = nowMs;
    parts[fragIdx] = chunk;
    if (parts.length < fragCount) return null;
    final buf = BytesBuilder();
    for (int i = 0; i < fragCount; i++) {
      final p = parts[i];
      if (p == null) return null; // gap — wait for the missing fragment
      buf.add(p);
    }
    _crdtReasm.remove(key);
    _crdtReasmTs.remove(key);
    return utf8.decode(buf.toBytes());
  }

  void _writeCounter(PeatFlutterNode? node, bool increment) =>
      _adjustCounter(node, increment ? 1 : -1);

  /// Apply [delta] liters to THIS node's holdings entry in the CRDT doc and
  /// broadcast it. "yours" = my entry, "total" = sum of all entries — so a +/-
  /// here moves the total by delta, and a transfer (fulfill) is +qty on the
  /// requestor's entry / -qty on the leader's, leaving the sum unchanged.
  void _adjustCounter(PeatFlutterNode? node, int delta) {
    if (node == null) return;
    final h = _readHoldings(node);
    final newMine = h.mine + delta;
    final hex =
        node.crdtKvPut(_holdingsCollection, _callsign, newMine.toString());
    _broadcastCrdt(_holdingsCollection, hex);
    if (mounted) {
      setState(() {
        _myLiters = newMine;
        _crdtTotal = h.total - h.mine + newMine; // total moves by delta
      });
    }
  }

  // ── Cell card ────────────────────────────────────────────────────────

  // "Reform" / "Form Cell": commit the CURRENT roster as the explicit cell
  // membership. After this the cell is curated — Add/Remove edit it in place;
  // it no longer auto-tracks the roster.
  void _formCell() {
    final members = _roster.map((n) => n.name).toSet();
    _publishCell(members);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Alpha Cell reformed — ${members.length} member'
            '${members.length == 1 ? '' : 's'}: ${members.join(', ')}'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // "Add": include a node (by callsign) in the committed cell.
  void _addToCell(String callsign) => _publishCell({..._cellMembers, callsign});

  // "Remove": drop a node (by callsign) from the committed cell.
  void _removeFromCell(String callsign) =>
      _publishCell({..._cellMembers}..remove(callsign));

  // Steady re-advertise of the EXISTING membership (idempotent — no change).
  // Lets a reconnecting peer converge without the leader mutating the cell.
  void _republishCell() {
    if (_cellMembers.isEmpty) return;
    _publishCell(Set.of(_cellMembers));
  }

  // Publish the cell doc with an EXPLICIT member set. The `members` list is the
  // source of truth for membership (every node reads it back from the synced
  // doc); node_count / capabilities / leader are derived from it. A member that
  // isn't currently in the roster (offline peer) still counts toward membership.
  void _publishCell(Set<String> memberCallsigns) {
    final node = _node;
    if (node == null || memberCallsigns.isEmpty) return;
    final byCallsign = {for (final n in _roster) n.name: n};
    final known = memberCallsigns
        .map((cs) => byCallsign[cs])
        .whereType<NodeInfo>()
        .toList();
    final allCaps = known.expand((n) => n.capabilities).toSet().toList();
    // Prefer a member advertising 'leader'; fall back to this node (the curator).
    var leaderId = _nodeId ?? '';
    for (final n in known) {
      if (n.capabilities.contains('leader')) { leaderId = n.id; break; }
    }
    final active = memberCallsigns.length > 1;
    final cell = CellInfo(
      id: _cellDocId,
      name: 'Alpha Cell',
      status: active ? CellStatus.active : CellStatus.forming,
      nodeCount: memberCallsigns.length,
      centerLat: 0,
      centerLon: 0,
      capabilities: allCaps,
      formationId: null,
      leaderId: leaderId,
      lastUpdate: DateTime.now().millisecondsSinceEpoch,
      scenarioCommand: null,
    );
    // Mirror locally right away so the leader's UI updates without waiting for
    // the doc to round-trip back through the refresh read.
    if (mounted) setState(() {
      _cellMembers
        ..clear()
        ..addAll(memberCallsigns);
    });
    // Publish through the node layer (wrapped Document) so the cell reaches the
    // BLE/Wi-Fi fan-out and the other device actually receives it. putCell
    // writes a flat shape straight to storage that doesn't sync (and can't
    // carry `members`) — it's only the desktop/error fallback.
    final cellJson = jsonEncode({
      'id': cell.id,
      'name': cell.name,
      'status': active ? 'ACTIVE' : 'FORMING',
      'node_count': cell.nodeCount,
      'center_lat': 0,
      'center_lon': 0,
      'capabilities': allCaps,
      'members': memberCallsigns.toList(),
      'formation_id': null,
      'leader_id': leaderId,
      'last_update': cell.lastUpdate,
      'scenario_command': null,
    });
    if (Platform.isAndroid) {
      _bleChannel.invokeMethod('publishDoc',
          {'collection': 'cells', 'json': cellJson}).catchError((_) {
        node.putCell(cell);
        return null;
      });
    } else if (Platform.isIOS) {
      try { node.publishDocument('cells', cellJson); } catch (_) { node.putCell(cell); }
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
              // Leader-only: curate membership explicitly. The cell does NOT
              // auto-follow the roster — Remove drops a node, Add pulls one in
              // from Available Nodes, Reform re-commits the whole roster.
              if (_myCapabilities.contains('leader')) ...[
                const SizedBox(height: 8),
                Text('Members (${_cellMembers.length})',
                    style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.outline)),
                ..._cellMembers.map((callsign) {
                  final isMe = callsign == _callsign;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(children: [
                      const Icon(Icons.check_circle,
                          size: 14, color: Colors.green),
                      const SizedBox(width: 6),
                      Expanded(child: Text(callsign,
                          style: theme.textTheme.bodySmall)),
                      if (!isMe)
                        InkWell(
                          onTap: () => _removeFromCell(callsign),
                          child: Icon(Icons.remove_circle_outline,
                              size: 18, color: theme.colorScheme.error),
                        ),
                    ]),
                  );
                }),
                Builder(builder: (_) {
                  // Available = roster nodes (by callsign) not yet committed.
                  final available = _roster
                      .where((n) => !_cellMembers.contains(n.name))
                      .toList();
                  if (available.isEmpty) return const SizedBox.shrink();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 6),
                      Text('Available Nodes (${available.length})',
                          style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.outline)),
                      ...available.map((n) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(children: [
                          Icon(Icons.radio_button_unchecked,
                              size: 14, color: theme.colorScheme.outline),
                          const SizedBox(width: 6),
                          Expanded(child: Text(n.name,
                              style: theme.textTheme.bodySmall)),
                          InkWell(
                            onTap: () => _addToCell(n.name),
                            child: Icon(Icons.add_circle_outline,
                                size: 18, color: theme.colorScheme.primary),
                          ),
                        ]),
                      )),
                    ],
                  );
                }),
              ],
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
  // Commands are a generic CRDT KV doc ("commands"), keyed by command id —
  // Automerge-over-BLE, mesh-wide convergence, no lite-bridge. Add = put key;
  // fulfill = put same key with status:completed (LWW per key).
  void _publishCommand(PeatFlutterNode node, CommandInfo cmd) {
    final json = _cmdToJson(cmd);
    final hex = node.crdtKvPut('commands', cmd.id, json);
    _broadcastCrdt('commands', hex);
    // Low-latency delivery for this user action: the single paced send can lose
    // a fragment, and waiting for the 4s steady catch-up feels sluggish. Re-send
    // the commands snapshot a few times over the next ~2s so every fragment
    // lands quickly (idempotent merge — extra sends are harmless).
    for (final ms in const [350, 900, 1800]) {
      Future.delayed(Duration(milliseconds: ms), () {
        if (mounted && _node != null) {
          _broadcastCrdt('commands', _node!.crdtKvSnapshot('commands'));
        }
      });
    }
  }

  static String _cmdToJson(CommandInfo cmd) => jsonEncode({
        'id': cmd.id,
        'command_type': cmd.commandType,
        'target_id': cmd.targetId,
        'parameters': cmd.parameters, // kept as a string; _parseParams handles it
        'priority': cmd.priority,
        'status': cmd.status.name,
        'originator': cmd.originator,
        'created_at': cmd.createdAt,
        'last_update': cmd.lastUpdate,
      });

  // Parse the "nodes" CRDT KV doc ({callsign: {node...}}) into NodeInfo list —
  // the reachability source for Connections. Relays mesh-wide over the
  // fragmented 0xAF frame (so a node reachable only via a relay appears here),
  // callsign-keyed and always named (kills the nodeId<->callsign flapping the
  // connection-based store caused with half-synced, name-less stubs).
  List<NodeInfo> _crdtNodes(PeatFlutterNode node) {
    final out = <NodeInfo>[];
    final advertised = <int, Set<int>>{};
    final wifiPeers = <int>{};
    try {
      final map = jsonDecode(node.crdtKvAll('nodes')) as Map<String, dynamic>;
      for (final v in map.values) {
        if (v is! Map<String, dynamic>) continue;
        final id = v['id'] as String? ?? '';
        final name = v['name'] as String? ?? '';
        if (id.length < 16 || name.isEmpty || name == id) continue;
        // Record the direct-peer set this node advertises (for symmetric
        // direct-link detection — see _advertisedDirect).
        final short = int.tryParse(id.substring(0, 8), radix: 16);
        if (short != null) {
          advertised[short] = ((v['direct_peers'] as List?) ?? const [])
              .map((e) => (e as num).toInt())
              .toSet();
          if (v['wifi'] == true) wifiPeers.add(short);
        }
        final caps = (v['capabilities'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[];
        out.add(NodeInfo(
          id: id,
          nodeType: v['node_type'] as String? ?? 'peat-flutter',
          name: name,
          status: NodeStatus.active,
          lat: 0,
          lon: 0,
          hae: null,
          readiness: (v['readiness'] as num?)?.toDouble() ?? 1.0,
          capabilities: caps,
          cellId: null,
          batteryPercent: null,
          heartRate: null,
          lastHeartbeat: (v['last_heartbeat'] as num?)?.toInt() ?? 0,
        ));
      }
    } catch (_) {}
    _advertisedDirect = advertised;
    _wifiPeers = wifiPeers;
    return out;
  }

  // Parse the "commands" CRDT KV doc ({id: {cmd...}}) into CommandInfo list.
  List<CommandInfo> _readCommands(PeatFlutterNode node) {
    final out = <CommandInfo>[];
    try {
      final map = jsonDecode(node.crdtKvAll('commands')) as Map<String, dynamic>;
      for (final v in map.values) {
        if (v is! Map<String, dynamic>) continue;
        final statusName = (v['status'] as String?) ?? 'pending';
        final status = CommandStatus.values.firstWhere(
          (s) => s.name == statusName,
          orElse: () => CommandStatus.pending,
        );
        out.add(CommandInfo(
          id: v['id'] as String? ?? '',
          commandType: v['command_type'] as String? ?? '',
          targetId: v['target_id'] as String? ?? '',
          parameters: v['parameters'] as String? ?? '{}',
          priority: v['priority'] as int? ?? 1,
          status: status,
          originator: v['originator'] as String? ?? '',
          createdAt: v['created_at'] as int? ?? 0,
          lastUpdate: v['last_update'] as int? ?? 0,
        ));
      }
    } catch (_) {}
    return out;
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
    // Transfer model: fulfilling DISPENSES qty from the leader's own stock to
    // the requestor. The leader debits its own holdings entry -qty HERE (via
    // _adjustCounter, which writes the CRDT doc + broadcasts — NOT a local-only
    // tally that gets overwritten on the next refresh); the requestor credits
    // its own entry +qty when it sees this command go COMPLETED. Both touch the
    // SAME holdings doc on different keys, so the sum (total) is unchanged.
    try {
      final qty = _parseParams(cmd.parameters)['quantity'] as int? ?? 0;
      if (qty > 0) _adjustCounter(node, -qty);
    } catch (_) {}
    // Mark command as completed (for the requester's "fulfilled" UI).
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
    try {
      var decoded = jsonDecode(params);
      // The iOS publish path can double-encode `parameters` as a JSON *string*
      // (object -> "{\"quantity\":..}") rather than a nested object the way the
      // Android path does — so a single decode yields a String, not a Map, and
      // params['from'] comes back null ("unknown" requester, broken fulfill).
      // Decode once more in that case so iOS-originated commands resolve too.
      if (decoded is String) decoded = jsonDecode(decoded);
      return (decoded as Map).cast<String, dynamic>();
    } catch (e) {
      debugPrint('[peat] _parseParams failed for: $params ($e)');
      return {};
    }
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

  Color _collectionColor(String collection, ThemeData theme) {
    // Stable color per collection name
    final colors = [
      Colors.blue, Colors.purple, Colors.teal,
      Colors.orange, Colors.pink, Colors.indigo,
    ];
    return colors[collection.hashCode.abs() % colors.length];
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

    // iOS: peat-ffi has no native BLE transport, so Dart drives the poll API
    // and a native Swift radio (PeatBleBridge over peat-btle) does the I/O.
    //   outbound: startOutboundFrames -> wrap [0xAF][transport][collLen][coll][frame]
    //             -> MethodChannel bleTx -> PeatMeshWrapper.broadcastBytes -> radio.
    //   inbound : EventChannel relay payload (the same envelope, 0xAF-marked)
    //             -> unwrap -> ingestInboundFrame / ingestInboundLiteFrame.
    // The envelope is byte-identical to the Android BleBridge.kt wire format.
    if (Platform.isIOS) {
      // peat-btle node id: a stable 32-bit derived from the peat-ffi node id.
      final int bleNodeId = int.parse(node.nodeId.substring(0, 8), radix: 16);
      _bleChannel.invokeMethod('startBle', {
        'nodeId': bleNodeId,
        'callsign': _callsign,
      }).catchError((_) => null);

      // Inbound: unwrap the relay envelope and ingest into the mesh.
      _bleRxSub = _bleRxChannel.receiveBroadcastStream().listen((event) {
        if (event is! Uint8List || event.length < 3 || event[0] != 0xAF) return;
        final int transport = event[1];
        final int collLen = event[2];
        if (event.length < 3 + collLen) return;
        final String coll = utf8.decode(event.sublist(3, 3 + collLen));
        final Uint8List frame = Uint8List.sublistView(event, 3 + collLen);
        try {
          if (transport == _kCrdtTransport) {
            // CRDT frame: [msgId:u32][fragIdx:u8][fragCount:u8][chunk]. Reassemble
            // across fragments, then route by collection. "supply" -> counter;
            // else -> KV. Both merges are idempotent/commutative.
            if (frame.length < _kCrdtHdr) return;
            final int msgId = (frame[0] << 24) |
                (frame[1] << 16) |
                (frame[2] << 8) |
                frame[3];
            final int fragIdx = frame[4];
            final int fragCount = frame[5];
            final Uint8List chunk = Uint8List.sublistView(frame, _kCrdtHdr);
            final hex = _crdtReassemble(coll, msgId, fragIdx, fragCount, chunk);
            if (hex == null) return; // incomplete — wait for more fragments
            node.crdtKvMerge(coll, hex);
          } else if (transport == 1) {
            node.ingestInboundLiteFrame(coll, frame);
          } else {
            node.ingestInboundFrame(coll, frame);
          }
        } catch (_) {/* unknown collection / transient — ignore */}
      });

      // Outbound: drain the mesh fan-out, wrap, and hand to the native radio.
      final sub = node.startOutboundFrames().listen((frame) {
        // Coalesce identical frames: the fan-out re-emits echoes (ingested peer
        // docs) and redundant heartbeat re-advertises. Sending every copy
        // saturates the tiny BLE link and causes drops/thrash. Suppress a
        // byte-identical (collection, content) frame seen within the window;
        // a genuinely changed doc has different bytes and still goes out.
        final int contentHash = Object.hashAll(frame.bytes);
        final String dedupKey = '${frame.collection}:$contentHash';
        final int nowMs = DateTime.now().millisecondsSinceEpoch;
        final int? lastMs = _lastTxMs[dedupKey];
        if (lastMs != null && nowMs - lastMs < 2500) return;
        _lastTxMs[dedupKey] = nowMs;
        if (_lastTxMs.length > 64) {
          _lastTxMs.removeWhere((_, t) => nowMs - t > 10000);
        }
        final List<int> coll = utf8.encode(frame.collection);
        final int transport = frame.transportId == 'ble-lite' ? 1 : 0;
        final env = Uint8List(3 + coll.length + frame.bytes.length);
        env[0] = 0xAF;
        env[1] = transport;
        env[2] = coll.length;
        env.setRange(3, 3 + coll.length, coll);
        env.setRange(3 + coll.length, env.length, frame.bytes);
        _bleChannel.invokeMethod('bleTx', env).catchError((_) => null);
        if (mounted) setState(() => _bleFrameCount++);
      });
      setState(() {
        _outboundSub = sub;
        _bleRunning = true;
        _bleFrameCount = 0;
      });
      return;
    }

    // Other platforms (macOS/desktop): placeholder frame-count stream only.
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
    // iOS: stop the native radio + the inbound ingest BEFORE disposing the
    // node, so a late relay frame can't call ingest* on a freed node.
    if (Platform.isIOS) {
      _bleRxSub?.cancel();
      _bleRxSub = null;
      _bleChannel.invokeMethod('stopBle').catchError((_) => null);
      _bleRunning = false;
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
      _missionDays = 0;
      _missionSetBy = null;
      _activeCell = null;
      _commands = [];
      _claimedCommandIds.clear();
      _cellMembers.clear();
      _nodeNames.clear();
      _roster = [];
      // _contentHashes persists across stop/start intentionally.
      _stopping = false;
      // The shared total persists in the Automerge doc (water.automerge) and
      // re-syncs on restart; _myLiters (local tally) persists in memory.
      _bleRunning = false;
      _bleFrameCount = 0;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning to the foreground after a lock/background. iOS suspends BLE
    // scanning + advertising while backgrounded and does NOT auto-resume them:
    // CBCentralManager only (re)starts a scan inside centralManagerDidUpdateState
    // on a transition to .poweredOn, which never re-fires when Bluetooth was
    // already on. So without this, an iPhone that locked goes deaf/silent and
    // never rejoins the mesh. Kick the radio back on and re-publish our
    // heartbeat + counter so peers immediately see us as live again.
    if (state == AppLifecycleState.resumed && _node != null && _bleRunning) {
      if (Platform.isIOS) {
        _bleChannel.invokeMethod('bleResume').catchError((_) => null);
      }
      _publishSelf(_node!);
      _flushMyCounter(_node!);
    }
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
                              '$_myLiters / $_crdtTotal',
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
                    // (Removed the "N/M members in sync" indicator — it measured
                    // cell-member heartbeat presence, not counter convergence,
                    // and was misleading now that the total is a true CRDT merge.
                    // Per-node BLE connectivity is shown in the Node Roster.)
                  ],
                ),
              ),
            ),

            // ---- mission objective ----
            // Shown once a Cell exists. The LEADER sees it after forming the
            // cell (to set duration — the required-liters target depends on the
            // cell's crew size). FOLLOWERS see it read-only once the leader has
            // set a mission (so the synced objective is visible to everyone in
            // the cell). The setting controls inside the card are leader-gated.
            if (hasNode &&
                _cellMembers.isNotEmpty &&
                (_myCapabilities.contains('leader') || _missionDays > 0)) ...[
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
                    Text('Connections (${_roster.length})',
                          style: theme.textTheme.labelMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      ..._roster.map((n) {
                        final isMe = n.id == _nodeId;
                        // Direct vs relayed: the BLE bridge reports the node-ids
                        // (32-bit = first 8 hex of the full id) of peers we're
                        // DIRECTLY connected to. A roster node not in that set is
                        // reachable only through another node (multi-hop) — it
                        // still synced here via the CRDT relay. Nothing is
                        // "disconnected": everything listed IS reachable.
                        int? shortId;
                        try {
                          shortId = int.parse(n.id.substring(0, 8), radix: 16);
                        } catch (_) {}
                        final myShort = _nodeId != null && _nodeId!.length >= 8
                            ? int.tryParse(_nodeId!.substring(0, 8), radix: 16)
                            : null;
                        // Direct if: we're fully meshed (connected to at least as
                        // many BLE peers as there are OTHER nodes — so every peer
                        // must be a direct link), OR we positively identify the
                        // link (our blePeerIds, or the peer advertises us — a BLE
                        // link is bidirectional). The mesh-count check covers the
                        // case where peat-btle reports a connection as nodeId=0 so
                        // we can't match it per-peer, but we ARE linked to everyone.
                        final otherCount = _roster.length - 1;
                        final fullyMeshed =
                            otherCount > 0 && _blePeerCount >= otherCount;
                        final isDirect = !isMe &&
                            (fullyMeshed ||
                                (shortId != null &&
                                    (_directPeerIds.contains(shortId) ||
                                        (myShort != null &&
                                            (_advertisedDirect[shortId]
                                                    ?.contains(myShort) ??
                                                false)))));
                        const bleBlue = Color(0xFF2196F3);
                        final transports = <Widget>[];
                        if (isMe) {
                          transports.add(Icon(Icons.person,
                              size: 14, color: theme.colorScheme.primary));
                        } else if (isDirect) {
                          // Direct BLE neighbor. Add the Wi-Fi badge ONLY if the
                          // peer is Wi-Fi-Direct-capable (advertised) AND we have
                          // a tunnel up — Wi-Fi Direct is Android-only, so the
                          // iPad (iOS, BLE-only) never gets it.
                          transports.add(const Icon(Icons.bluetooth,
                              size: 14, color: bleBlue));
                          if (_wifiTunnelPeers > 0 &&
                              shortId != null &&
                              _wifiPeers.contains(shortId)) {
                            transports.add(const Icon(Icons.wifi,
                                size: 14, color: Colors.green));
                          }
                        } else {
                          // Relayed / multi-hop: reachable via another node.
                          transports.add(Icon(Icons.alt_route,
                              size: 14, color: Colors.orange.shade700));
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
                                    style: theme.textTheme.bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.bold),
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
                    Text('My Capabilities',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
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
                  if (Platform.isAndroid)
                    _aboutRow(theme, 'Peers (Wi-Fi)', '$_wifiTunnelPeers connected'),
                ],
                if ((Platform.isAndroid || Platform.isIOS) && _bleRunning)
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
