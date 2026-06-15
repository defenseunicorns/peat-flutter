// Copyright 2026 Defense Unicorns
// SPDX-License-Identifier: Apache-2.0

import 'dart:ffi';
import 'dart:io';

export 'src/peat_node.dart'
    show
        PeatFlutterNode,
        NodeConfig,
        TransportConfigFFI,
        DocumentChange,
        OutboundFrame,
        ChangeType,
        PeerInfo,
        PeerTransportState,
        NodeInfo,
        NodeStatus,
        CellInfo,
        CellStatus,
        CommandInfo,
        CommandStatus;

/// Opens the peat_ffi native library for the current platform.
///
/// Called automatically by [PeatFlutterNode.initialize]; you do not need to
/// call this directly unless you are configuring the bindings manually.
DynamicLibrary openPeatFfiLib() {
  if (Platform.isIOS) {
    // Statically linked via ios/Frameworks/PeatFFI.xcframework.
    return DynamicLibrary.process();
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libpeat_ffi.so');
  }
  if (Platform.isMacOS) {
    return DynamicLibrary.open('libpeat_ffi.dylib');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('peat_ffi.dll');
  }
  throw UnsupportedError(
      'peat_flutter: unsupported platform ${Platform.operatingSystem}');
}
