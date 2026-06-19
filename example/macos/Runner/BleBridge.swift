// macOS BLE bridge: pipes the peat-btle radio (CoreBluetooth) <-> peat mesh.
//
// Port of ios/Runner/BleBridge.swift. macOS differences:
//   - import FlutterMacOS (not Flutter)
//   - the mesh type is `PeatMesh` (peat_btle bindings), 3-arg init, no
//     peripheralType; the advertise name is constructed here (the bindings
//     expose no deviceName()).
// CoreBluetooth itself is identical on macOS, so PeatBLEManager is unchanged.
//
// Wire UUIDs must match the Android/iOS peat-btle radio:
//   - advertise + scan: 16-bit alias 0xF47A
//   - GATT service / characteristic: 128-bit f47ac10b / f47a0003.
import Foundation
import CoreBluetooth
import FlutterMacOS

private let PEAT_SERVICE_UUID_16 = CBUUID(string: "F47A")
private let PEAT_SERVICE_UUID_128 = CBUUID(string: "F47AC10B-58CC-4372-A567-0E02B2C3D479")
private let PEAT_DOC_CHAR_UUID = CBUUID(string: "F47A0003-58CC-4372-A567-0E02B2C3D479")

private func blog(_ msg: String) { NSLog("[PeatBLE] %@", msg) }

// MARK: - CoreBluetooth radio (identical to iOS)

final class PeatBLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, CBPeripheralManagerDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheralManager!
    private var discovered: [String: CBPeripheral] = [:]
    private var connected: [String: CBPeripheral] = [:]      // we are Central
    private var subscribedCentrals: [CBCentral] = []          // we are Peripheral
    private var docCharacteristic: CBMutableCharacteristic?
    private var serviceAdded = false
    private var notifyQueue: [Data] = []
    private static let maxNotifyQueue = 256

    var localDeviceName = "PEAT_peatwtr-00000000"

    var onDataReceived: ((String, Data) -> Void)?
    var onPeerConnected: ((String) -> Void)?
    var onPeerDisconnected: ((String) -> Void)?

    var peerCount: Int { connected.count + subscribedCentrals.count }

    // Dedicated SERIAL queue for all CoreBluetooth callbacks + mesh work. macOS
    // Flutter merges the UI and platform thread, so running the radio on
    // `queue: nil` (the main queue) starves/beachballs the UI under BLE load.
    // Serial also serializes mesh access (callbacks + outbound bleTx).
    let queue = DispatchQueue(label: "peat.ble", qos: .userInitiated)

    func start() {
        central = CBCentralManager(delegate: self, queue: queue)
        peripheral = CBPeripheralManager(delegate: self, queue: queue)
    }

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
        cm.connect(p, options: nil)
    }

    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) {
        let id = p.identifier.uuidString
        p.delegate = self
        connected[id] = p
        discovered.removeValue(forKey: id)
        p.discoverServices([PEAT_SERVICE_UUID_128])
        onPeerConnected?(id)
    }

    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        let id = p.identifier.uuidString
        connected.removeValue(forKey: id)
        onPeerDisconnected?(id)
    }

    func centralManager(_ cm: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        discovered.removeValue(forKey: p.identifier.uuidString)
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
        if docCharacteristic != nil, !subscribedCentrals.isEmpty {
            notifyQueue.append(data)
            if notifyQueue.count > PeatBLEManager.maxNotifyQueue {
                notifyQueue.removeFirst(notifyQueue.count - PeatBLEManager.maxNotifyQueue)
            }
            drainNotifyQueue()
        }
        for (_, p) in connected {
            guard let s = p.services?.first(where: { $0.uuid == PEAT_SERVICE_UUID_128 }),
                  let c = s.characteristics?.first(where: { $0.uuid == PEAT_DOC_CHAR_UUID }) else { continue }
            let kind: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
            p.writeValue(data, for: c, type: kind)
        }
    }

    private func drainNotifyQueue() {
        guard let char = docCharacteristic else { notifyQueue.removeAll(); return }
        while let next = notifyQueue.first {
            if peripheral.updateValue(next, for: char, onSubscribedCentrals: nil) {
                notifyQueue.removeFirst()
            } else {
                break
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
    private var mesh: PeatMesh?
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
            let callsign = (args?["callsign"] as? String) ?? "mac"
            startBle(nodeId: nodeId, callsign: callsign)
            result(true)
        case "stopBle", "unbindBle":
            stopBle()
            result(true)
        case "bleResume":
            if started { radio.resume() }
            result(true)
        case "bleTx":
            guard let m = mesh else { result(false); return }
            if let payload = (call.arguments as? FlutterStandardTypedData)?.data {
                // Mesh encode + radio writes off the (merged) main thread.
                let r = radio
                r.queue.async { r.sendData(m.broadcastBytes(payload: payload)) }
            }
            result(true)
        case "blePeerCount":
            // peerCount reads dicts mutated on the BLE queue — read there too.
            result(radio.queue.sync { radio.peerCount })
        case "blePeerIds":
            result((mesh?.getConnectedPeers() ?? []).map { Int($0.nodeId) })
        case "isBleRunning":
            result(started)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startBle(nodeId: UInt32, callsign: String) {
        if started { return }
        let m = PeatMesh(nodeId: nodeId, callsign: callsign, meshId: "peatwtr")
        // peat_btle exposes no deviceName(); replicate the PEAT_<meshId>-<8hex>
        // convention the Android/iOS radios advertise + mesh-match on.
        radio.localDeviceName = String(format: "PEAT_peatwtr-%08x", nodeId)
        radio.onPeerConnected = { id in
            m.onBleConnected(identifier: id, nowMs: UInt64(Date().timeIntervalSince1970 * 1000))
            blog("peer connected: \(id)")
        }
        radio.onPeerDisconnected = { id in blog("peer disconnected: \(id)") }
        radio.onDataReceived = { [weak self] id, data in
            guard let self = self, let mesh = self.mesh else { return }
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
        blog("BLE started as \(radio.localDeviceName)")
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
