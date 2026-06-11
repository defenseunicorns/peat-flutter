package com.defenseunicorns.peat_flutter_example

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pDeviceList
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import com.defenseunicorns.peat.PeatJni
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

/**
 * Infrastructure-free Wi-Fi Direct (P2P) LAN between two devices.
 *
 * This forms a Wi-Fi P2P group (one device becomes Group Owner / soft-AP, the
 * other a client). Once the group is formed both devices share an IP subnet,
 * and the EXISTING iroh transport (mDNS over the p2p interface; MulticastLock
 * already held by MainActivity) discovers the peer and syncs — exactly the
 * path that works over a normal LAN. No peat-ffi / UniFFI changes: Wi-Fi Direct
 * only establishes the link; iroh does the sync.
 *
 * Caveats: Wi-Fi must be ON (radio, not connected to an AP). The first
 * `connect()` typically pops a one-time system "Invitation to connect" dialog
 * on the peer that the user accepts. 2-device demo: we connect to the first
 * discovered AVAILABLE peer.
 */
class WifiDirectManager(private val context: Context) {

    companion object {
        private const val TAG = "WifiDirect"
        // Fixed port for the (nodeId, irohPort) handshake over the P2P link.
        private const val HANDSHAKE_PORT = 47625
    }

    @Volatile private var handshakeThread: Thread? = null

    private val manager: WifiP2pManager? =
        context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    private var channel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null
    private val handler = android.os.Handler(Looper.getMainLooper())
    // Android stops P2P discovery after ~2 min; re-trigger so two phones brought
    // up minutes apart still find each other (don't rely on a single discovery).
    private val rediscover = object : Runnable {
        @SuppressLint("MissingPermission")
        override fun run() {
            val mgr = manager; val ch = channel
            if (mgr != null && ch != null && !isConnected()) {
                // Clear the per-peer connect throttle so a peer that was offline
                // on the first attempt (e.g. the other phone started minutes
                // later) gets retried — otherwise the first failed connect
                // blacklists it forever and the group never forms.
                attempted.clear()
                mgr.discoverPeers(ch, null)
                // Also re-check for an already-formed (persisted) group that no
                // discoverPeers/CONNECTION_CHANGED would surface.
                requestConnection()
            }
            if (channel != null) handler.postDelayed(this, 15_000)
        }
    }

    @Volatile var status: String = "idle"; private set
    @Volatile var groupOwner: Boolean = false; private set
    @Volatile var groupOwnerAddress: String? = null; private set
    @Volatile var peersSeen: Int = 0; private set
    // Our own P2P device address (from THIS_DEVICE_CHANGED). Used as a
    // deterministic tiebreak: only the lower-address device initiates connect;
    // the higher-address device waits for + accepts the invitation. Avoids both
    // phones initiating simultaneously (which can leave neither prompting).
    @Volatile private var myAddress: String? = null

    // Avoid hammering connect() on every PEERS_CHANGED tick.
    private val attempted = java.util.Collections.synchronizedSet(HashSet<String>())

    fun isRunning(): Boolean = channel != null

    fun statusInfo(): Map<String, Any?> = mapOf(
        "status" to status,
        "groupOwner" to groupOwner,
        "goAddress" to groupOwnerAddress,
        "peersSeen" to peersSeen,
    )

    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        val mgr = manager ?: run { Log.e(TAG, "WifiP2pManager unavailable"); return false }
        if (channel != null) return true
        val ch = mgr.initialize(context, Looper.getMainLooper()) {
            Log.w(TAG, "P2P channel disconnected")
        }
        channel = ch

        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }
        val rx = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: Intent?) {
                when (intent?.action) {
                    WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION ->
                        requestPeers()
                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION ->
                        requestConnection()
                    WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION -> {
                        @Suppress("DEPRECATION")
                        val me = intent.getParcelableExtra<WifiP2pDevice>(
                            WifiP2pManager.EXTRA_WIFI_P2P_DEVICE
                        )
                        if (me?.deviceAddress != null) {
                            myAddress = me.deviceAddress
                            Log.i(TAG, "this device address=$myAddress")
                        }
                    }
                }
            }
        }
        receiver = rx
        // Protected system broadcasts; NOT_EXPORTED is correct + required on API 34+.
        ContextCompat.registerReceiver(context, rx, filter, ContextCompat.RECEIVER_NOT_EXPORTED)

        status = "discovering"
        mgr.discoverPeers(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { Log.i(TAG, "discoverPeers started") }
            override fun onFailure(reason: Int) {
                Log.e(TAG, "discoverPeers failed: $reason")
                status = "discover_failed:$reason"
            }
        })
        handler.postDelayed(rediscover, 20_000)
        // A group may ALREADY exist (persisted from a prior run); devices in a
        // group don't show up in discoverPeers, so the CONNECTION_CHANGED event
        // may never re-fire. Proactively check current connection state.
        requestConnection()
        Log.i(TAG, "Wi-Fi Direct started")
        return true
    }

    @SuppressLint("MissingPermission")
    private fun requestPeers() {
        val mgr = manager ?: return
        val ch = channel ?: return
        mgr.requestPeers(ch) { peers: WifiP2pDeviceList ->
            peersSeen = peers.deviceList.size
            if (isConnected()) return@requestPeers
            val available = peers.deviceList.filter { it.status == WifiP2pDevice.AVAILABLE }
            for (p in available) {
                Log.i(TAG, "peer: ${p.deviceName} type=${p.primaryDeviceType} addr=${p.deviceAddress}")
            }
            // Connect ONLY to phones (Wi-Fi Direct category 10 = Telephone).
            // Avoids pairing with stray printers (cat 3), TVs, etc. that also
            // advertise Wi-Fi Direct nearby.
            val device: WifiP2pDevice =
                available.firstOrNull { it.primaryDeviceType?.startsWith("10-") == true }
                    ?: run {
                        if (available.isNotEmpty()) {
                            Log.i(TAG, "no phone (cat 10) peer yet among ${available.size} device(s)")
                        }
                        return@requestPeers
                    }
            // Deterministic tiebreak: only the lower-address device initiates;
            // the higher-address device waits for the invitation (system prompt)
            // and accepts. Avoids both phones initiating at once.
            val mine = myAddress
            if (mine != null && mine >= device.deviceAddress) {
                Log.i(TAG, "waiting for invite from ${device.deviceName} (we are higher-address: $mine >= ${device.deviceAddress})")
                return@requestPeers
            }
            if (!attempted.add(device.deviceAddress)) return@requestPeers
            Log.i(TAG, "connecting to ${device.deviceName} (${device.deviceAddress})")
            val config = WifiP2pConfig().apply { deviceAddress = device.deviceAddress }
            mgr.connect(ch, config, object : WifiP2pManager.ActionListener {
                override fun onSuccess() { Log.i(TAG, "connect initiated"); status = "connecting" }
                override fun onFailure(reason: Int) {
                    Log.e(TAG, "connect failed: $reason")
                    attempted.remove(device.deviceAddress)
                }
            })
        }
    }

    private fun requestConnection() {
        val mgr = manager ?: return
        val ch = channel ?: return
        mgr.requestConnectionInfo(ch) { info: WifiP2pInfo ->
            if (info.groupFormed) {
                groupOwner = info.isGroupOwner
                groupOwnerAddress = info.groupOwnerAddress?.hostAddress
                status = if (info.isGroupOwner) "group_owner" else "client"
                Log.i(TAG, "GROUP FORMED owner=${info.isGroupOwner} go=$groupOwnerAddress")
                startHandshake()
            } else {
                status = "discovering"
                groupOwner = false
                groupOwnerAddress = null
            }
        }
    }

    // ---- (nodeId, irohPort) handshake over the P2P link, then connectPeerJni ----
    // iroh can't announce its own address on Android (mDNS dead), so we exchange
    // identities out-of-band over a TCP socket on the formed P2P LAN and dial
    // explicitly. The GO runs a tiny server on 192.168.49.1:HANDSHAKE_PORT; the
    // client connects. Each sends "nodeId:irohPort"; both then connectPeerJni.

    private fun startHandshake() {
        if (handshakeThread?.isAlive == true) return
        val t = Thread({ runHandshake() }, "peat-wd-handshake").apply { isDaemon = true }
        handshakeThread = t
        t.start()
    }

    private fun runHandshake() {
        var handle = 0L; var myPort = -1; var myNodeId = ""
        // Wait for the peat-ffi node to be up (handle + bound iroh port).
        for (i in 0 until 60) {
            if (Thread.currentThread().isInterrupted) return
            try {
                handle = PeatJni.getGlobalNodeHandleJni()
                if (handle != 0L) {
                    myNodeId = PeatJni.nodeIdJni(handle)
                    myPort = parsePort(PeatJni.endpointSocketAddrJni(handle))
                }
            } catch (t: Throwable) { Log.e(TAG, "handshake: JNI not ready", t) }
            if (handle != 0L && myPort > 0 && myNodeId.isNotEmpty()) break
            try { Thread.sleep(500) } catch (_: InterruptedException) { return }
        }
        if (handle == 0L || myPort <= 0 || myNodeId.isEmpty()) {
            Log.e(TAG, "handshake: node not ready (handle=$handle port=$myPort)"); return
        }
        Log.i(TAG, "handshake ready: nodeId=${myNodeId.take(16)} irohPort=$myPort owner=$groupOwner")
        try {
            if (groupOwner) runHandshakeServer(handle, myNodeId, myPort)
            else runHandshakeClient(handle, myNodeId, myPort)
        } catch (t: Throwable) { Log.e(TAG, "handshake failed", t) }
    }

    private fun parsePort(sockAddr: String?): Int {
        if (sockAddr == null) return -1
        val idx = sockAddr.lastIndexOf(':')
        return if (idx < 0) -1 else sockAddr.substring(idx + 1).toIntOrNull() ?: -1
    }

    private fun runHandshakeServer(handle: Long, myNodeId: String, myPort: Int) {
        ServerSocket().use { server ->
            server.reuseAddress = true
            server.bind(InetSocketAddress(HANDSHAKE_PORT))
            Log.i(TAG, "handshake server on :$HANDSHAKE_PORT")
            while (status == "group_owner" && !Thread.currentThread().isInterrupted) {
                val sock = try { server.accept() } catch (e: Exception) { break }
                sock.use { s ->
                    val line = BufferedReader(InputStreamReader(s.getInputStream())).readLine()
                        ?: return@use
                    val parts = line.trim().split(":")
                    if (parts.size < 2) return@use
                    val peerNodeId = parts[0]
                    val peerPort = parts[1].toIntOrNull() ?: return@use
                    val peerIp = s.inetAddress?.hostAddress ?: return@use
                    s.getOutputStream().apply { write("$myNodeId:$myPort\n".toByteArray()); flush() }
                    Log.i(TAG, "handshake(server): peer ${peerNodeId.take(16)} @ $peerIp:$peerPort")
                    val ok = PeatJni.connectPeerJni(handle, peerNodeId, "$peerIp:$peerPort")
                    Log.i(TAG, "connectPeerJni(server) -> $ok")
                }
            }
        }
    }

    private fun runHandshakeClient(handle: Long, myNodeId: String, myPort: Int) {
        val go = groupOwnerAddress ?: run { Log.e(TAG, "handshake(client): no GO addr"); return }
        for (attempt in 0 until 30) {
            if (Thread.currentThread().isInterrupted || isConnected().not()) {
                if (isConnected().not()) return
            }
            try {
                Socket().use { s ->
                    s.connect(InetSocketAddress(go, HANDSHAKE_PORT), 3000)
                    s.getOutputStream().apply { write("$myNodeId:$myPort\n".toByteArray()); flush() }
                    val line = BufferedReader(InputStreamReader(s.getInputStream())).readLine()
                        ?: return
                    val parts = line.trim().split(":")
                    if (parts.size < 2) return
                    val goNodeId = parts[0]
                    val goPort = parts[1].toIntOrNull() ?: return
                    Log.i(TAG, "handshake(client): GO ${goNodeId.take(16)} @ $go:$goPort")
                    val ok = PeatJni.connectPeerJni(handle, goNodeId, "$go:$goPort")
                    Log.i(TAG, "connectPeerJni(client) -> $ok")
                }
                return
            } catch (e: Exception) {
                Log.i(TAG, "handshake(client) attempt $attempt: ${e.message}; retry")
                try { Thread.sleep(1500) } catch (_: InterruptedException) { return }
            }
        }
    }

    private fun isConnected(): Boolean = status == "group_owner" || status == "client"

    fun stop() {
        handler.removeCallbacks(rediscover)
        handshakeThread?.interrupt()
        handshakeThread = null
        val mgr = manager
        val ch = channel
        receiver?.let { try { context.unregisterReceiver(it) } catch (_: Exception) {} }
        receiver = null
        if (mgr != null && ch != null) {
            try { mgr.removeGroup(ch, null) } catch (_: Exception) {}
            try { mgr.stopPeerDiscovery(ch, null) } catch (_: Exception) {}
        }
        channel = null
        attempted.clear()
        status = "idle"; groupOwner = false; groupOwnerAddress = null; peersSeen = 0
        Log.i(TAG, "Wi-Fi Direct stopped")
    }
}
