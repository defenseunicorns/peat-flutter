// iOS BLE bridge: pipes the peat-btle radio (CoreBluetooth) <-> peat-ffi mesh.
//
// Mirrors the Android `BleBridge.kt` external-radio pattern, but orchestrated
// from Dart via the poll API:
//   outbound: Dart polls peat-ffi `startOutboundFrames` -> sends each
//             [0xAF][transport][collLen][coll][frame] envelope down `bleTx`
//             -> PeatMeshWrapper.broadcastBytes (opaque relay, unencrypted)
//             -> CoreBluetooth write/notify.
//   inbound:  CoreBluetooth value -> PeatMeshWrapper.onBleData ->
//             DataReceivedResult.relayData (the 0xAF payload) -> EventChannel
//             -> Dart strips the envelope -> ingestInboundFrame / Lite.
//
// peat-btle 0.4.0 runs UNENCRYPTED here (constructed with meshId only, like the
// Android `PeatBtle(meshId=...)` path), so broadcastBytes is a passthrough and
// there is no ECDH handshake.
//
// Wire UUIDs (must match the Android peat-btle radio):
//   - advertise + scan: the 16-bit alias 0xF47A (Android advertises this; its
//     scan filter is empty so it discovers us by our PEAT_ name + this UUID).
//   - GATT service / characteristic: the 128-bit f47ac10b / f47a0003.
import Foundation
import CoreBluetooth
import Flutter

private let PEAT_SERVICE_UUID_16 = CBUUID(string: "F47A")
private let PEAT_SERVICE_UUID_128 = CBUUID(string: "F47AC10B-58CC-4372-A567-0E02B2C3D479")
private let PEAT_DOC_CHAR_UUID = CBUUID(string: "F47A0003-58CC-4372-A567-0E02B2C3D479")

private func blog(_ msg: String) { NSLog("[PeatBLE] %@", msg) }

// MARK: - CoreBluetooth radio (adapted from the peat-btle iOS demo)

final class PeatBLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, CBPeripheralManagerDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheralManager!
    private var discovered: [String: CBPeripheral] = [:]
    private var connected: [String: CBPeripheral] = [:]      // we are Central
    private var subscribedCentrals: [CBCentral] = []          // we are Peripheral
    private var docCharacteristic: CBMutableCharacteristic?
    private var serviceAdded = false
    // Outbound notify backpressure queue (Peripheral role). iOS's
    // updateValue(...) returns false when the notify transmit queue is full and
    // SILENTLY DROPS the value; we hold it here and retry on
    // peripheralManagerIsReady(toUpdateSubscribers:). This is the proper flow
    // control that lets Dart fire all fragments at once (no 60ms pacing hack).
    // Bounded: oldest frames are dropped if a stuck subscriber backs it up — the
    // 4s snapshot gossip re-sends the whole doc, so a dropped fragment recovers.
    private var notifyQueue: [Data] = []
    private static let maxNotifyQueue = 256

    var localDeviceName = "PEAT_peatwtr-00000000"

    var onDataReceived: ((String, Data) -> Void)?
    var onPeerConnected: ((String) -> Void)?
    var onPeerDisconnected: ((String) -> Void)?

    var peerCount: Int { connected.count + subscribedCentrals.count }

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
        peripheral = CBPeripheralManager(delegate: self, queue: nil)
    }

    // Re-arm scan + advertise after a foreground transition. iOS stops both
    // while the app is backgrounded, and CBCentralManager only auto-starts a
    // scan inside centralManagerDidUpdateState on a .poweredOn transition —
    // which does NOT re-fire when Bluetooth was already on. Without this an
    // iPhone that locked stays deaf (not scanning) and silent (not advertising)
    // and never rejoins the mesh.
    func resume() {
        if central?.state == .poweredOn && central?.isScanning == false {
            central.scanForPeripherals(withServices: [PEAT_SERVICE_UUID_16],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
        if peripheral?.state == .poweredOn {
            if !serviceAdded { setupGattService() }
            else if peripheral?.isAdvertising == false { startAdvertising() }
        }
    }

    func stop() {
        if central?.isScanning == true { central.stopScan() }
        for (_, p) in connected { central.cancelPeripheralConnection(p) }
        connected.removeAll(); discovered.removeAll(); subscribedCentrals.removeAll()
        notifyQueue.removeAll()
        if peripheral?.isAdvertising == true { peripheral.stopAdvertising() }
        peripheral?.removeAllServices()
        serviceAdded = false
        docCharacteristic = nil
    }

    // ----- Peripheral role (advertise + GATT server) -----

    private func setupGattService() {
        guard !serviceAdded else { return }
        let char = CBMutableCharacteristic(
            type: PEAT_DOC_CHAR_UUID,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )
        let service = CBMutableService(type: PEAT_SERVICE_UUID_128, primary: true)
        service.characteristics = [char]
        docCharacteristic = char
        peripheral.add(service)
        serviceAdded = true
    }

    private func startAdvertising() {
        guard peripheral.state == .poweredOn else { return }
        // Advertise the 16-bit alias + a PEAT_ name so Android recognizes + mesh-matches us.
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: localDeviceName,
            CBAdvertisementDataServiceUUIDsKey: [PEAT_SERVICE_UUID_16],
        ])
    }

    func peripheralManagerDidUpdateState(_ pm: CBPeripheralManager) {
        if pm.state == .poweredOn { setupGattService() }
    }

    func peripheralManager(_ pm: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if error == nil { startAdvertising() } else { blog("didAdd service error: \(error!)") }
    }

    func peripheralManager(_ pm: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for req in requests {
            if let data = req.value { onDataReceived?("central:" + req.central.identifier.uuidString, data) }
            pm.respond(to: req, withResult: .success)
        }
    }

    func peripheralManager(_ pm: CBPeripheralManager, central c: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if !subscribedCentrals.contains(where: { $0.identifier == c.identifier }) {
            subscribedCentrals.append(c)
            onPeerConnected?("central:" + c.identifier.uuidString)
            blog("central subscribed (\(subscribedCentrals.count))")
        }
    }

    func peripheralManager(_ pm: CBPeripheralManager, central c: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeAll { $0.identifier == c.identifier }
        onPeerDisconnected?("central:" + c.identifier.uuidString)
    }

    // ----- Central role (scan + connect + GATT client) -----

    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        if cm.state == .poweredOn {
            cm.scanForPeripherals(withServices: [PEAT_SERVICE_UUID_16],
                                  options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = p.identifier.uuidString
        if connected[id] != nil { return }
        discovered[id] = p
        cm.connect(p, options: nil)   // auto-connect, like Android's onDeviceDiscovered
    }

    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) {
        let id = p.identifier.uuidString
        p.delegate = self
        connected[id] = p
        discovered.removeValue(forKey: id) // `connected` now holds the strong ref
        p.discoverServices([PEAT_SERVICE_UUID_128])
        onPeerConnected?(id)
    }

    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        let id = p.identifier.uuidString
        connected.removeValue(forKey: id)
        onPeerDisconnected?(id)
        // peat-btle keeps the link up across restarts; rediscovery re-connects.
    }

    func centralManager(_ cm: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        discovered.removeValue(forKey: p.identifier.uuidString) // free the connect-phase ref
        blog("didFailToConnect \(p.identifier.uuidString): \(error?.localizedDescription ?? "?")")
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid == PEAT_SERVICE_UUID_128 {
            p.discoverCharacteristics([PEAT_DOC_CHAR_UUID], for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] where c.uuid == PEAT_DOC_CHAR_UUID {
            p.setNotifyValue(true, for: c)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        onDataReceived?(p.identifier.uuidString, data)
    }

    // ----- Outbound: send to every connected peer (both roles) -----

    func sendData(_ data: Data) {
        // Peripheral (notify) path: enqueue + drain honoring backpressure so a
        // full transmit queue never silently drops a fragment (see notifyQueue).
        if docCharacteristic != nil, !subscribedCentrals.isEmpty {
            notifyQueue.append(data)
            if notifyQueue.count > PeatBLEManager.maxNotifyQueue {
                notifyQueue.removeFirst(notifyQueue.count - PeatBLEManager.maxNotifyQueue)
            }
            drainNotifyQueue()
        }
        // Central (write) path: .withResponse writes are queued + flow-controlled
        // by CoreBluetooth itself, so they don't drop — send directly.
        for (_, p) in connected {
            guard let s = p.services?.first(where: { $0.uuid == PEAT_SERVICE_UUID_128 }),
                  let c = s.characteristics?.first(where: { $0.uuid == PEAT_DOC_CHAR_UUID }) else { continue }
            let kind: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
            p.writeValue(data, for: c, type: kind)
        }
    }

    // Push as many queued notifications as iOS will accept. updateValue returns
    // false when the transmit queue is full; we stop and resume from
    // peripheralManagerIsReady(toUpdateSubscribers:).
    private func drainNotifyQueue() {
        guard let char = docCharacteristic else { notifyQueue.removeAll(); return }
        while let next = notifyQueue.first {
            if peripheral.updateValue(next, for: char, onSubscribedCentrals: nil) {
                notifyQueue.removeFirst()       // accepted into the transmit queue
            } else {
                break                            // full — resume on ...IsReady...
            }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers pm: CBPeripheralManager) {
        drainNotifyQueue()
    }
}

// MARK: - Bridge: radio <-> peat-btle PeatMesh <-> Flutter channels

final class PeatBleBridge: NSObject, FlutterStreamHandler {
    private let radio = PeatBLEManager()
    private var mesh: PeatMeshWrapper?
    private var rxSink: FlutterEventSink?
    private var started = false

    private func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    static func register(messenger: FlutterBinaryMessenger) {
        let bridge = PeatBleBridge()
        let method = FlutterMethodChannel(name: "peat/ble", binaryMessenger: messenger)
        let event = FlutterEventChannel(name: "peat/ble_rx", binaryMessenger: messenger)
        event.setStreamHandler(bridge)
        method.setMethodCallHandler { [weak bridge] call, result in
            bridge?.handle(call, result) ?? result(FlutterMethodNotImplemented)
        }
    }

    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "startBle":
            let args = call.arguments as? [String: Any]
            let nodeId = UInt32(truncatingIfNeeded: (args?["nodeId"] as? Int) ?? Int.random(in: 1...0x7FFFFFFF))
            let callsign = (args?["callsign"] as? String) ?? "iphone"
            startBle(nodeId: nodeId, callsign: callsign)
            result(true)
        case "stopBle", "unbindBle":
            stopBle()
            result(true)
        case "bleResume":
            // App returned to foreground. iOS suspended scan/advertise while
            // backgrounded and won't auto-restart them; kick them back on.
            if started { radio.resume() }
            result(true)
        case "bleTx":
            guard let m = mesh else { result(false); return }
            if let payload = (call.arguments as? FlutterStandardTypedData)?.data {
                radio.sendData(m.broadcastBytes(payload: payload))
            }
            result(true)
        case "blePeerCount":
            result(radio.peerCount)
        case "blePeerIds":
            // Node-ids (32-bit) of directly-connected mesh peers, so Dart can
            // mark Connections rows "direct" vs "relayed". The mesh layer knows
            // peer node-ids (the radio only knows CoreBluetooth UUIDs).
            result((mesh?.getConnectedPeers() ?? []).map { Int($0.nodeId) })
        case "isBleRunning":
            result(started)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startBle(nodeId: UInt32, callsign: String) {
        if started { return }
        let m = PeatMeshWrapper(nodeId: nodeId, callsign: callsign,
                                meshId: "peatwtr", peripheralType: .soldierSensor)
        radio.localDeviceName = m.deviceName()
        radio.onPeerConnected = { id in
            _ = m.onBleConnected(identifier: id, nowMs: UInt64(Date().timeIntervalSince1970 * 1000))
            blog("peer connected: \(id)")
        }
        radio.onPeerDisconnected = { id in blog("peer disconnected: \(id)") }
        radio.onDataReceived = { [weak self] id, data in
            guard let self = self, let mesh = self.mesh else { return }
            // Opaque relay: surface the 0xAF app-layer payload to Dart. MUST use
            // the anonymous path — it's the one that recognizes the 0xAF marker
            // and returns relay_data (matches Android's onBleDataReceivedAnonymous);
            // onBleData/onBleDataReceived fall through to merge_document and drop it.
            let res = mesh.onBleDataReceivedAnonymous(identifier: id, data: data, nowMs: self.nowMs())
            if let relay = res?.relayData, !relay.isEmpty {
                DispatchQueue.main.async {
                    self.rxSink?(FlutterStandardTypedData(bytes: relay))
                }
            }
        }
        mesh = m
        radio.start()
        started = true
        blog("BLE started as \(m.deviceName())")
    }

    private func stopBle() {
        radio.stop()
        mesh = nil
        started = false
        blog("BLE stopped")
    }

    // FlutterStreamHandler (inbound relay payloads -> Dart)
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        rxSink = events
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        rxSink = nil
        return nil
    }
}
