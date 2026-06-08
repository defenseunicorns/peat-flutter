import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:peat_flutter/peat_flutter.dart';
import 'package:peat_flutter/src/generated/peat_ffi.dart' show SyncStats;

void main() {
  PeatFlutterNode.initialize();
  runApp(const PeatExampleApp());
}

class PeatExampleApp extends StatelessWidget {
  const PeatExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'peat_flutter example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
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
  final List<String> _changeLog = [];
  List<String> _peers = [];
  SyncStats? _syncStats;
  Timer? _peerTimer;

  // Shared CRDT counter — persists across node start/stop
  // When offline, +/- edits are buffered locally and flushed on reconnect.
  static const _counterCollection = 'demo';
  static const _counterDocId = 'counter';
  int _counterValue = 0;
  String? _counterLastBy;
  bool _counterDirty = false; // local edits made while offline
  Timer? _counterTimer;
  StreamSubscription<DocumentChange>? _changeSub;
  StreamSubscription<OutboundFrame>? _outboundSub;
  int _publishCount = 0;

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    if (Platform.isIOS) {
      _hostName = 'iPhone (simulator)';
    } else if (Platform.isMacOS) {
      _hostName = 'macOS · ${Platform.localHostname.split('.').first}';
    } else {
      _hostName = Platform.operatingSystem;
    }
  }

  Future<void> _startNode() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final dir = await getApplicationSupportDirectory();
      final node = PeatFlutterNode.create(NodeConfig(
        appId: 'peat-flutter-example',
        // Test-only shared key. Replace with a real base64-encoded 32-byte key:
        //   openssl rand -base64 32
        // WARNING: all-zeros key → every example instance on the same LAN will
        // mesh with each other. Fine for local dev; replace before sharing.
        sharedKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        bindAddress: null,
        storagePath: '${dir.path}/peat',
        transport: null,
      ));
      node.startSync();

      // On connect: flush any offline edits, or pull peer's latest value.
      _refreshCounter(node);
      _counterTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (!mounted || _node == null) return;
        _refreshCounter(_node!);
      });

      _peerTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (!mounted || _node == null) return;
        setState(() {
          _peers = _node!.connectedPeers;
          _syncStats = _node!.syncStats;
        });
      });

      final sub = node.subscribeChanges().listen((change) {
        if (!mounted) return;
        setState(() {
          _changeLog.insert(
            0,
            '[${change.changeType.name}] ${change.collection}/${change.docId}',
          );
          if (_changeLog.length > 100) _changeLog.removeLast();
        });
      });

      setState(() {
        _node = node;
        _nodeId = node.nodeId;
        _changeSub = sub;
        _starting = false;
      });
    } catch (e) {
      setState(() {
        _error = e is UnimplementedError
            ? 'Run `just gen-bindings` to generate Rust→Dart FFI bindings, '
                'then rebuild the example.'
            : 'Failed to start node: $e';
        _starting = false;
      });
    }
  }

  void _refreshCounter(PeatFlutterNode node) {
    if (_counterDirty) {
      // Flush local edits made while offline before accepting peer values.
      _writeCounter(node, _counterValue);
      return;
    }
    final raw = node.getRaw(_counterCollection, _counterDocId);
    if (raw == null) {
      // Nothing in the mesh yet — publish our local value.
      _writeCounter(node, _counterValue);
      return;
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final v = map['value'] as int? ?? 0;
      final by = map['by'] as String?;
      if (mounted && (v != _counterValue || by != _counterLastBy)) {
        setState(() {
          _counterValue = v;
          _counterLastBy = by;
        });
      }
    } catch (_) {}
  }

  void _writeCounter(PeatFlutterNode? node, int value) {
    setState(() {
      _counterValue = value;
      _counterLastBy = _hostName;
    });
    if (node != null) {
      final json = jsonEncode({'value': value, 'by': _hostName});
      node.publishRaw(_counterCollection, json, docId: _counterDocId);
      setState(() => _counterDirty = false);
    } else {
      // Offline — mark dirty so we flush on next connect.
      setState(() => _counterDirty = true);
    }
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
      setState(() {
        _changeLog.insert(0, '[pub] test/$docId');
        if (_changeLog.length > 100) _changeLog.removeLast();
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _startBle() {
    final node = _node;
    if (node == null || _bleRunning) return;
    // On mobile, Dart owns the radio via flutter_blue_plus:
    //   1. Add `flutter_blue_plus` to example/pubspec.yaml.
    //   2. Call FlutterBluePlus.scan() and connect to peat peripherals.
    //   3. On each GATT notification, call peat-btle's onBleDataReceived() to
    //      strip GATT framing / decrypt → postcardBytes.
    //   4. Feed postcardBytes to node.ingestInboundFrame(collection, bytes).
    // Outbound frames produced by Rust are received here and must be written
    // as GATT characteristics to connected peripherals.
    try {
      final sub = node.startOutboundFrames().listen((frame) {
        if (!mounted) return;
        setState(() => _bleFrameCount++);
        // TODO: write frame.bytes to the GATT characteristic for frame.transportId
      });
      setState(() {
        _outboundSub = sub;
        _bleRunning = true;
        _bleFrameCount = 0;
      });
    } catch (e) {
      setState(() => _error = 'BLE fan-out failed: $e');
    }
  }

  void _stopBle() {
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
    try { _node?.dispose(); } catch (_) {}
    Future.delayed(const Duration(milliseconds: 800), () {
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
      _stopping = false; // reset handled by Future.delayed above
      // Keep _counterValue and _counterDirty so offline edits persist.
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
    _node?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasNode = _node != null;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('peat_flutter example'),
        backgroundColor: theme.colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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

            if (_nodeId != null) ...[
              const SizedBox(height: 4),
              Text('$_hostName',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              Text(
                '${_nodeId!.substring(0, 8)}…${_nodeId!.substring(_nodeId!.length - 8)}',
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 4),
              Row(children: [
                Icon(
                  _peers.isEmpty ? Icons.wifi_off : Icons.wifi,
                  size: 14,
                  color: _peers.isEmpty ? theme.colorScheme.outline : Colors.green,
                ),
                const SizedBox(width: 4),
                Text(
                  _peers.isEmpty
                      ? 'No peers connected'
                      : '${_peers.length} peer${_peers.length == 1 ? '' : 's'} connected',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _peers.isEmpty ? theme.colorScheme.outline : Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ]),
              if (_peers.isNotEmpty)
                ...(_peers.map((p) => Text(
                  '  • ${p.length > 16 ? '${p.substring(0, 8)}…${p.substring(p.length - 8)}' : p}',
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ))),
              if (_syncStats != null)
                Text(
                  '↑${_syncStats!.bytesSent}B  ↓${_syncStats!.bytesReceived}B',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.outline,
                  ),
                ),
            ],

            const SizedBox(height: 12),

            // ---- node start/stop ----
            FilledButton(
              onPressed: (_starting || _stopping) ? null : (hasNode ? _stopNode : _startNode),
              child: Text(_starting
                  ? 'Starting…'
                  : (_stopping ? 'Stopping…' : (hasNode ? 'Stop Node' : 'Start Node'))),
            ),

            // ---- shared CRDT counter (always visible) ----
            const SizedBox(height: 16),
            Card(
              color: _counterDirty
                  ? theme.colorScheme.tertiaryContainer.withOpacity(0.4)
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Shared Counter',
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
                          icon: const Icon(Icons.remove),
                          iconSize: 28,
                          onPressed: () => _writeCounter(_node, _counterValue - 1),
                        ),
                        const SizedBox(width: 24),
                        Text(
                          '$_counterValue',
                          style: theme.textTheme.displaySmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 24),
                        IconButton.filledTonal(
                          icon: const Icon(Icons.add),
                          iconSize: 28,
                          onPressed: () => _writeCounter(_node, _counterValue + 1),
                        ),
                      ],
                    ),
                    if (_counterLastBy != null)
                      Text(
                        'last write: $_counterLastBy',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                  ],
                ),
              ),
            ),

            // ---- mobile BLE section ----
            if (hasNode && _isMobile) ...[
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: _bleRunning ? _stopBle : _startBle,
                child: Text(_bleRunning
                    ? 'Stop BLE ($_bleFrameCount outbound frames)'
                    : 'Start BLE Outbound'),
              ),
            ],

            const SizedBox(height: 16),
            Text('Document changes',
                style: theme.textTheme.titleSmall),
            const Divider(height: 8),

            // ---- change log ----
            Expanded(
              child: _changeLog.isEmpty
                  ? const Center(
                      child: Text('No changes yet — start node and publish.'))
                  : ListView.builder(
                      itemCount: _changeLog.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          _changeLog[i],
                          style: theme.textTheme.bodySmall
                              ?.copyWith(fontFamily: 'monospace'),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
