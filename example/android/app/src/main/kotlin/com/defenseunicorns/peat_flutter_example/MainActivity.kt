package com.defenseunicorns.peat_flutter_example

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.defenseunicorns.peat.PeatJni
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // iroh local discovery (peat_mesh::discovery::MdnsDiscovery → swarm-discovery)
    // finds peers via raw UDP multicast on 224.0.0.251 / ff02::fb. Android's
    // Wi-Fi driver filters inbound multicast to save power unless an app holds a
    // WifiManager.MulticastLock (requires CHANGE_WIFI_MULTICAST_STATE). We hold
    // it for the app's lifetime so iroh mDNS works over any LAN — including the
    // Wi-Fi Direct group interface.
    private var multicastLock: WifiManager.MulticastLock? = null

    // BLE transport bridge: pipes peat-ffi mesh frames over peat-btle.
    private var bleBridge: BleBridge? = null

    // Wi-Fi Direct (P2P) link: forms an infra-free LAN.
    private var wifiDirect: WifiDirectManager? = null

    // P2PWiFi carrier: tunnels the same fan-out frames as BLE over a TCP
    // socket on the Wi-Fi Direct link (a second transport alongside BLE).
    private var wifiDirectBridge: WifiDirectBridge? = null

    companion object {
        private const val BLE_CHANNEL = "peat/ble"
        private const val WIFI_CHANNEL = "peat/wifidirect"
        private const val REQ_PERMS = 4242

        // BLE (12+) + Wi-Fi Direct (NEARBY_WIFI_DEVICES on 13+, else FINE_LOCATION).
        private val RUNTIME_PERMS: Array<String> = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.BLUETOOTH_CONNECT)
                add(Manifest.permission.BLUETOOTH_ADVERTISE)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.NEARBY_WIFI_DEVICES)
            } else {
                add(Manifest.permission.ACCESS_FINE_LOCATION)
            }
        }.distinct().toTypedArray()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Plumb the Android Context into peat-ffi BEFORE Dart creates a node
        // (else iroh's DNS-discovery path panics "android context was not
        // initialized" → UniFFI status 2). Touching PeatJni runs its init {}.
        try {
            PeatJni.setAndroidContextJni(applicationContext)
            Log.i("PeatExample", "setAndroidContextJni ok; ctx=${PeatJni.verifyAndroidContextJni()}")
        } catch (t: Throwable) {
            Log.e("PeatExample", "setAndroidContextJni failed", t)
        }

        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("peat-mdns").apply {
            setReferenceCounted(true)
            acquire()
        }

        if (!hasPermissions()) {
            ActivityCompat.requestPermissions(this, RUNTIME_PERMS, REQ_PERMS)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, BLE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startBle" -> {
                    if (!hasPermissions()) {
                        ActivityCompat.requestPermissions(this, RUNTIME_PERMS, REQ_PERMS)
                        result.error("PERMISSION", "Permissions not granted yet; tap again after granting.", null)
                        return@setMethodCallHandler
                    }
                    val bridge = bleBridge ?: BleBridge(applicationContext).also { bleBridge = it }
                    // Mirror outbound frames to the Wi-Fi Direct tunnel when it
                    // exists (checked at call time, so order of start vs.
                    // startWifiDirect doesn't matter).
                    bridge.outboundForward = { t, c, b -> wifiDirectBridge?.send(t, c, b) }
                    val ok = bridge.start()
                    // Node (re)start: re-point the Wi-Fi Direct tunnel at the
                    // new node too (the TCP link, like BLE, stays up across it).
                    wifiDirectBridge?.rebind()
                    result.success(ok)
                }
                "stopBle" -> { bleBridge?.stop(); result.success(true) }
                "unbindBle" -> {
                    // Node teardown: drop both carriers' node handles but keep
                    // the links up, so restart re-binds without a flap.
                    bleBridge?.unbind()
                    wifiDirectBridge?.unbind()
                    result.success(true)
                }
                "clearGlobalNodeHandle" -> {
                    // Release the native global's owning node reference on node
                    // teardown (see peat#978). Safe no-op if nothing is stored.
                    try { PeatJni.clearGlobalNodeHandleJni(); result.success(true) }
                    catch (t: Throwable) { result.error("CLEAR", t.message, null) }
                }
                "isBleRunning" -> result.success(bleBridge?.isRunning() ?: false)
                "blePeerCount" -> result.success(bleBridge?.peerCount() ?: 0)
                "publishDoc" -> {
                    // Publish a raw doc through the node layer (NOT put_document /
                    // storage_backend) so it reaches the ADR-059 fan-out and
                    // syncs over BLE — like capabilities do. JNI, so no UniFFI
                    // checksum drift. The json must carry its "id" field.
                    val collection = call.argument<String>("collection")
                    val json = call.argument<String>("json")
                    if (collection == null || json == null) {
                        result.error("ARG", "collection/json required", null); return@setMethodCallHandler
                    }
                    val handle = try { PeatJni.getGlobalNodeHandleJni() } catch (_: Throwable) { 0L }
                    if (handle == 0L) { result.error("NODE", "node not started", null); return@setMethodCallHandler }
                    try {
                        val id = PeatJni.publishDocumentJni(handle, collection, json)
                        result.success(id)
                    } catch (t: Throwable) {
                        result.error("PUBLISH", t.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, WIFI_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startWifiDirect" -> {
                    if (!hasPermissions()) {
                        ActivityCompat.requestPermissions(this, RUNTIME_PERMS, REQ_PERMS)
                        result.error("PERMISSION", "Permissions not granted yet; tap again after granting.", null)
                        return@setMethodCallHandler
                    }
                    val wd = wifiDirect ?: WifiDirectManager(applicationContext).also { wifiDirect = it }
                    // Stand up the P2PWiFi frame tunnel and wire it to the group
                    // lifecycle + the shared outbound dispatch (BleBridge owns
                    // the single JNI subscription and mirrors frames to us).
                    val tunnel = wifiDirectBridge ?: WifiDirectBridge().also { wifiDirectBridge = it }
                    wd.onGroupFormed = { isGroupOwner, goAddress ->
                        tunnel.start(isGroupOwner, goAddress)
                    }
                    wd.onGroupLost = { tunnel.stop() }
                    result.success(wd.start())
                }
                "stopWifiDirect" -> {
                    wifiDirectBridge?.stop()
                    wifiDirect?.stop()
                    result.success(true)
                }
                "wifiDirectStatus" -> result.success(wifiDirect?.statusInfo() ?: mapOf("status" to "idle"))
                "wifiTunnelPeers" -> result.success(if (wifiDirectBridge?.isConnected() == true) 1 else 0)
                else -> result.notImplemented()
            }
        }
    }

    private fun hasPermissions(): Boolean =
        RUNTIME_PERMS.all { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }

    override fun onDestroy() {
        bleBridge?.stop()
        bleBridge = null
        wifiDirectBridge?.stop()
        wifiDirectBridge = null
        wifiDirect?.stop()
        wifiDirect = null
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        super.onDestroy()
    }
}
