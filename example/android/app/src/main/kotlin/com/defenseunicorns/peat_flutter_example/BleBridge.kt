package com.defenseunicorns.peat_flutter_example

import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.util.Log
import androidx.core.content.ContextCompat
import com.defenseunicorns.peat.OutboundFrameListener
import com.defenseunicorns.peat.PeatBtle
import com.defenseunicorns.peat.PeatEventType
import com.defenseunicorns.peat.PeatJni
import com.defenseunicorns.peat.PeatMeshListener
import com.defenseunicorns.peat.PeatPeer

/**
 * Bridges peat-btle (BLE radio) <-> peat-ffi (mesh/CRDT) as an OPAQUE encrypted
 * pipe. peat-ffi stays the mesh owner; peat-btle is just the carrier.
 *
 *   outbound: mesh fan-out (subscribeOutboundFramesJni) -> wrap -> PeatBtle.broadcastBytes
 *   inbound : PeatBtle.onDecryptedData -> unwrap -> ingestInboundFrameJni (origin "ble")
 *   peers   : onPeerConnected/Disconnected -> bleAddPeerJni / bleRemovePeerJni
 *
 * Wire envelope carried inside peat-btle's app-layer (0xAF) payload:
 *   [0]        0xAF            (so the peer's peat-btle delivers it to onDecryptedData
 *                              instead of merging it into its own document store)
 *   [1]        collLen : u8
 *   [2..2+L]   collection UTF-8
 *   [2+L..]    peat-ffi frame (postcard bytes)
 *
 * The peat-ffi node is created on the Dart/UniFFI side; we recover its handle
 * via PeatJni.getGlobalNodeHandleJni() (create_node publishes it to the global).
 */
class BleBridge(private val context: Context) : PeatMeshListener {

    companion object {
        private const val TAG = "BleBridge"
        private const val APP_LAYER: Byte = 0xAF.toByte()
        // Envelope transport flag: which peat-ffi inbound decoder to use.
        private const val TRANSPORT_TYPED = 0 // typed 0xB6 BleTranslator ("ble")
        private const val TRANSPORT_LITE = 1  // universal peat-lite ("ble-lite")
        private const val TRANSPORT_CRDT = 2  // Automerge CRDT doc bytes (hex)
        // transport=2 payload framing: [msgId:u32 BE][fragIdx:u8][fragCount:u8][chunk].
        // A large hex doc exceeds the ~512B BLE wire ceiling, so the sender splits
        // it; we reassemble before ingest. See main.dart _broadcastCrdt.
        private const val CRDT_HDR = 6
        // Both devices must share this so their advertisements match.
        // MUST be <= 8 bytes: peat-btle truncates the advertised mesh id to 8
        // bytes (service data) but matchesMesh() compares it for exact equality
        // against the full local id, so a 9-char "peatwater" advertises as
        // "peatwate" and never matches. Keep it <= 8 chars.
        private const val MESH_ID = "peatwtr"
    }

    private var peatBtle: PeatBtle? = null
    @Volatile private var handle: Long = 0L
    private var btStateReceiver: BroadcastReceiver? = null

    // Optional secondary carrier (the Wi-Fi Direct TCP tunnel). The single
    // subscribeOutboundFramesJni listener lives here, so we forward each frame
    // to this sink too — same frame over both radios, idempotent on the peer.
    @Volatile var outboundForward: ((String, String, ByteArray) -> Unit)? = null
    // Distinct BLE peers currently connected (deduped; onPeerConnected can fire
    // twice for the central+peripheral roles). Surfaced to the Flutter UI so the
    // BLE link is visible even though the app's iroh peer-count stays 0.
    private val connectedPeers = java.util.Collections.synchronizedSet(HashSet<String>())

    fun isRunning(): Boolean = peatBtle != null

    fun peerCount(): Int = connectedPeers.size

    // Node-ids (32-bit, as Long) of DIRECTLY-connected BLE peers. Surfaced to
    // Dart so the Connections view can mark a peer "direct" vs "relayed" (a node
    // reachable only via the CRDT relay won't appear here). connectedPeers holds
    // peer.nodeId.toString() (decimal), so parse back to Long.
    fun peerIds(): List<Long> =
        synchronized(connectedPeers) { connectedPeers.mapNotNull { it.toLongOrNull() } }

    // Outbound: every frame the mesh fans out for a BLE transport gets wrapped
    // and broadcast over the radio. Held as a field so start() can re-subscribe
    // it to a NEW node (on node restart) without recreating it — the JNI
    // subscribe is replaceable (swaps the global listener slot).
    private val outboundListener = object : OutboundFrameListener {
        override fun onFrame(transportId: String, collection: String, bytes: ByteArray) {
            peatBtle?.let { btle ->
                try {
                    btle.broadcastBytes(wrap(transportId, collection, bytes))
                    if (Log.isLoggable(TAG, Log.DEBUG))
                        Log.d(TAG, "outbound [$transportId/$collection] ${bytes.size}B")
                } catch (t: Throwable) {
                    Log.e(TAG, "broadcastBytes failed", t)
                }
            }
            // Mirror onto the secondary carrier (Wi-Fi Direct), if wired.
            try { outboundForward?.invoke(transportId, collection, bytes) } catch (t: Throwable) {
                Log.e(TAG, "outboundForward failed", t)
            }
        }
    }

    /// Start the radio, or — if it's already up (node restart) — just RE-BIND
    /// to the current node. Tearing the radio down + re-initializing PeatBtle
    /// on a node restart did not reconnect cleanly ("no connection after
    /// restart"); keeping it up and only re-pointing the outbound subscription
    /// + handle at the new node makes stop/restart converge while the BLE link
    /// stays connected.
    fun start(): Boolean {
        val h = try {
            PeatJni.getGlobalNodeHandleJni()
        } catch (t: Throwable) {
            Log.e(TAG, "getGlobalNodeHandleJni failed", t); 0L
        }
        if (h == 0L) {
            Log.e(TAG, "no peat-ffi node handle yet — start the node first")
            return false
        }
        handle = h

        // (Re)bind the current node's fan-out to the radio.
        try {
            PeatJni.subscribeOutboundFramesJni(handle, outboundListener)
        } catch (t: Throwable) {
            Log.e(TAG, "subscribeOutboundFramesJni failed", t)
        }
        try { PeatJni.bleSetStartedJni(handle, true) } catch (t: Throwable) { Log.e(TAG, "bleSetStarted failed", t) }

        // Listen for OS Bluetooth adapter on/off so the mesh recovers when the
        // user toggles Bluetooth (the comms-denied / recovery demo). Without
        // this, peat-btle's radio dies silently on OFF and never comes back.
        registerBtStateReceiver()

        if (peatBtle != null) {
            // Radio already up (node restart): we just re-bound to the new node.
            Log.i(TAG, "BLE bridge re-bound to handle=$handle (radio kept up)")
            return true
        }
        return bringUpRadio()
    }

    /// Create + start the peat-btle radio. No-op if already up. Used by start()
    /// and by the Bluetooth-ON adapter event to re-establish the mesh.
    private fun bringUpRadio(): Boolean {
        if (peatBtle != null) return true
        return try {
            val btle = PeatBtle(context = context, meshId = MESH_ID)
            btle.init()
            btle.startMesh(this)
            peatBtle = btle
            Log.i(TAG, "BLE radio up (meshId=$MESH_ID, nodeId=${btle.nodeId})")
            true
        } catch (t: Throwable) {
            Log.e(TAG, "PeatBtle start failed", t)
            if (handle != 0L) try { PeatJni.bleSetStartedJni(handle, false) } catch (_: Throwable) {}
            false
        }
    }

    private fun registerBtStateReceiver() {
        if (btStateReceiver != null) return
        val rx = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
                when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                    BluetoothAdapter.STATE_OFF -> {
                        // Radio gone: drop the now-dead peat-btle instance + peers.
                        Log.w(TAG, "Bluetooth OFF — tearing down mesh")
                        peatBtle?.let { try { it.stopMesh() } catch (_: Throwable) {} }
                        peatBtle = null
                        connectedPeers.clear()
                        if (handle != 0L) try { PeatJni.bleSetStartedJni(handle, false) } catch (_: Throwable) {}
                    }
                    BluetoothAdapter.STATE_ON -> {
                        // Radio back: re-establish the mesh against the bound node.
                        // A fresh PeatBtle on the now-enabled adapter reconnects;
                        // the 4s heartbeat re-advertise then re-converges state.
                        Log.i(TAG, "Bluetooth ON — re-establishing mesh")
                        if (handle != 0L && bringUpRadio()) {
                            try { PeatJni.bleSetStartedJni(handle, true) } catch (_: Throwable) {}
                        }
                    }
                }
            }
        }
        ContextCompat.registerReceiver(
            context,
            rx,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        btStateReceiver = rx
        Log.i(TAG, "registered Bluetooth adapter-state receiver")
    }

    private fun unregisterBtStateReceiver() {
        btStateReceiver?.let { try { context.unregisterReceiver(it) } catch (_: Throwable) {} }
        btStateReceiver = null
    }

    /// Drop the node handle WITHOUT stopping the radio. Called on node teardown
    /// so a late inbound frame can't call ingest*FrameJni with a freed pointer
    /// (handle == 0 makes the JNI a no-op), while the BLE link stays connected
    /// so the peer doesn't see a disconnect. start() re-binds the new node.
    fun unbind() {
        if (handle != 0L) try { PeatJni.bleSetStartedJni(handle, false) } catch (_: Throwable) {}
        // Clear the global outbound fan-out while the old handle is still valid.
        // subscribeOutboundFramesJni only re-registers the fan-out when the slot
        // is empty; if we leave it bound to the now-freed node, the next start()
        // just swaps the listener and the NEW node never produces outbound
        // frames (the stop->reset->restart "no node connections" bug). The next
        // start() re-subscribes, re-registering the fan-out on the fresh node.
        if (handle != 0L) try { PeatJni.unsubscribeOutboundFramesJni(handle) } catch (_: Throwable) {}
        handle = 0L
        Log.i(TAG, "BLE bridge unbound from node (radio kept up)")
    }

    fun stop() {
        unregisterBtStateReceiver()
        peatBtle?.let { try { it.stopMesh() } catch (t: Throwable) { Log.e(TAG, "stopMesh failed", t) } }
        peatBtle = null
        connectedPeers.clear()
        if (handle != 0L) try { PeatJni.bleSetStartedJni(handle, false) } catch (_: Throwable) {}
        // Clear the global outbound fan-out (bound to this node) before the node
        // is freed, so the next start() re-registers it on the fresh node rather
        // than leaving it dead on the old one. See unbind() for the full
        // rationale (stop->reset->restart "no node connections" bug).
        if (handle != 0L) try { PeatJni.unsubscribeOutboundFramesJni(handle) } catch (_: Throwable) {}
        // Drop the node handle: it's about to be (or already) freed by node
        // teardown. A late inbound frame must NOT call ingest*FrameJni with a
        // stale/freed pointer (UAF) — handle == 0 makes the JNI layer no-op.
        // start() re-fetches the fresh handle via getGlobalNodeHandleJni.
        handle = 0L
        Log.i(TAG, "BLE bridge stopped")
    }

    // ---------- PeatMeshListener ----------

    override fun onMeshUpdated(peers: List<PeatPeer>) {
        if (Log.isLoggable(TAG, Log.DEBUG))
            Log.d(TAG, "mesh updated: ${peers.size} peer(s)")
    }

    override fun onPeerEvent(peer: PeatPeer, eventType: PeatEventType) { /* unused */ }

    override fun onPeerConnected(peer: PeatPeer) {
        if (handle == 0L) return
        val id = peerIdOf(peer)
        connectedPeers.add(id)
        Log.i(TAG, "peer connected: $id (total ${connectedPeers.size})")
        try { PeatJni.bleAddPeerJni(handle, id) } catch (t: Throwable) { Log.e(TAG, "bleAddPeer failed", t) }
        // Nudge a sync so current state flows to the freshly-connected peer.
        try { PeatJni.requestSyncJni(handle) } catch (_: Throwable) {}
    }

    override fun onPeerDisconnected(peer: PeatPeer) {
        if (handle == 0L) return
        val id = peerIdOf(peer)
        connectedPeers.remove(id)
        Log.i(TAG, "peer disconnected: $id (total ${connectedPeers.size})")
        try { PeatJni.bleRemovePeerJni(handle, id) } catch (t: Throwable) { Log.e(TAG, "bleRemovePeer failed", t) }
    }

    // CRDT-frame reassembly buffer, keyed by "collection:msgId" -> (fragIdx -> chunk).
    private val crdtReasm = HashMap<String, HashMap<Int, ByteArray>>()

    override fun onDecryptedData(peer: PeatPeer?, data: ByteArray) {
        if (handle == 0L) return
        // Envelope: [0]=0xAF [1]=transport(0=ble,1=ble-lite) [2]=collLen [3..]=coll [..]=frame
        if (data.size < 3 || data[0] != APP_LAYER) return  // not one of our wrapped frames
        val transport = data[1].toInt() and 0xFF
        val collLen = data[2].toInt() and 0xFF
        if (data.size < 3 + collLen) return
        val collection = String(data, 3, collLen, Charsets.UTF_8)
        val frame = data.copyOfRange(3 + collLen, data.size)
        try {
            if (transport == TRANSPORT_CRDT) {
                // Automerge CRDT doc (hex), fragmented: reassemble then merge by
                // collection ("supply" -> counter, else -> generic KV).
                // Idempotent/commutative. No lite-bridge.
                val full = reassembleCrdt(collection, frame) ?: return
                PeatJni.ingestCrdtFrameJni(handle, collection, full)
            } else if (transport == TRANSPORT_LITE) {
                val id = PeatJni.ingestInboundLiteFrameJni(handle, collection, frame)
                if (Log.isLoggable(TAG, Log.DEBUG))
                    Log.d(TAG, "inbound [lite/$collection] ${frame.size}B -> ${id ?: "no-op"}")
            } else {
                val id = PeatJni.ingestInboundFrameJni(handle, collection, frame)
                if (Log.isLoggable(TAG, Log.DEBUG))
                    Log.d(TAG, "inbound [typed/$collection] ${frame.size}B -> ${id ?: "no-op"}")
            }
        } catch (t: Throwable) {
            Log.e(TAG, "ingest failed (transport=$transport)", t)
        }
    }

    // Reassemble a transport=2 fragment. Returns the full payload (hex bytes)
    // once every fragment of a message has arrived, else null. Single-fragment
    // messages (fragCount<=1) pass straight through. Keyed by "collection:msgId";
    // a re-sent complete set just overwrites. Buffer is bounded defensively.
    private fun reassembleCrdt(collection: String, frame: ByteArray): ByteArray? {
        if (frame.size < CRDT_HDR) return null
        val msgId = ((frame[0].toInt() and 0xFF) shl 24) or
            ((frame[1].toInt() and 0xFF) shl 16) or
            ((frame[2].toInt() and 0xFF) shl 8) or
            (frame[3].toInt() and 0xFF)
        val fragIdx = frame[4].toInt() and 0xFF
        val fragCount = frame[5].toInt() and 0xFF
        val chunk = frame.copyOfRange(CRDT_HDR, frame.size)
        if (fragCount <= 1) return chunk
        val key = "$collection:$msgId"
        val parts = crdtReasm.getOrPut(key) { HashMap() }
        parts[fragIdx] = chunk
        if (parts.size < fragCount) {
            if (crdtReasm.size > 32) crdtReasm.clear() // drop stale partials
            return null
        }
        val out = java.io.ByteArrayOutputStream()
        for (i in 0 until fragCount) {
            val p = parts[i] ?: return null // gap — wait for the missing fragment
            out.write(p)
        }
        crdtReasm.remove(key)
        return out.toByteArray()
    }

    // ---------- helpers ----------

    /// Broadcast a pre-built CRDT frame (Dart already wrapped the
    /// [0xAF][2][collLen][coll][hex] envelope). peat-btle relays 0xAF frames.
    fun broadcastRaw(bytes: ByteArray) {
        try {
            peatBtle?.broadcastBytes(bytes)
        } catch (t: Throwable) {
            Log.e(TAG, "broadcastRaw failed", t)
        }
    }

    private fun peerIdOf(peer: PeatPeer): String = peer.nodeId.toString()

    private fun wrap(transportId: String, collection: String, frame: ByteArray): ByteArray {
        val c = collection.toByteArray(Charsets.UTF_8)
        require(c.size <= 255) { "collection name too long" }
        val transport = if (transportId == "ble-lite") TRANSPORT_LITE else TRANSPORT_TYPED
        val out = ByteArray(3 + c.size + frame.size)
        out[0] = APP_LAYER
        out[1] = transport.toByte()
        out[2] = c.size.toByte()
        System.arraycopy(c, 0, out, 3, c.size)
        System.arraycopy(frame, 0, out, 3 + c.size, frame.size)
        return out
    }
}
