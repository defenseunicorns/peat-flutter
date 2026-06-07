import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:peat_flutter/peat_flutter.dart';

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
  String? _error;
  bool _starting = false;
  bool _bleRunning = false;
  int _bleFrameCount = 0;
  final List<String> _changeLog = [];
  StreamSubscription<DocumentChange>? _changeSub;
  StreamSubscription<OutboundFrame>? _outboundSub;
  int _publishCount = 0;

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

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
    _changeSub?.cancel();
    _outboundSub?.cancel();
    _node?.dispose();
    setState(() {
      _node = null;
      _nodeId = null;
      _changeSub = null;
      _outboundSub = null;
      _bleRunning = false;
      _bleFrameCount = 0;
    });
  }

  @override
  void dispose() {
    _changeSub?.cancel();
    _outboundSub?.cancel();
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
              Text('Node ID: $_nodeId',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontFamily: 'monospace')),
            ],

            const SizedBox(height: 12),

            // ---- node start/stop + publish ----
            Row(children: [
              Expanded(
                child: FilledButton(
                  onPressed:
                      _starting ? null : (hasNode ? _stopNode : _startNode),
                  child: Text(_starting
                      ? 'Starting…'
                      : (hasNode ? 'Stop Node' : 'Start Node')),
                ),
              ),
              if (hasNode) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _publishTest,
                    child: const Text('Publish Test Doc'),
                  ),
                ),
              ],
            ]),

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
