package com.defenseunicorns.peat_flutter_example

import android.content.Context
import android.util.Log
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
        // Both devices must share this so their advertisements match.
        // MUST be <= 8 bytes: peat-btle truncates the advertised mesh id to 8
        // bytes (service data) but matchesMesh() compares it for exact equality
        // against the full local id, so a 9-char "peatwater" advertises as
        // "peatwate" and never matches. Keep it <= 8 chars.
        private const val MESH_ID = "peatwtr"
    }

    private var peatBtle: PeatBtle? = null
    @Volatile private var handle: Long = 0L
    // Distinct BLE peers currently connected (deduped; onPeerConnected can fire
    // twice for the central+peripheral roles). Surfaced to the Flutter UI so the
    // BLE link is visible even though the app's iroh peer-count stays 0.
    private val connectedPeers = java.util.Collections.synchronizedSet(HashSet<String>())

    fun isRunning(): Boolean = peatBtle != null

    fun peerCount(): Int = connectedPeers.size

    fun start(): Boolean {
        if (peatBtle != null) {
            Log.w(TAG, "already running")
            return true
        }
        handle = try {
            PeatJni.getGlobalNodeHandleJni()
        } catch (t: Throwable) {
            Log.e(TAG, "getGlobalNodeHandleJni failed", t); 0L
        }
        if (handle == 0L) {
            Log.e(TAG, "no peat-ffi node handle yet — start the node first")
            return false
        }

        // Outbound: every frame the mesh fans out for a BLE transport gets
        // wrapped and broadcast over the radio.
        try {
            PeatJni.subscribeOutboundFramesJni(handle, object : OutboundFrameListener {
                override fun onFrame(transportId: String, collection: String, bytes: ByteArray) {
                    val btle = peatBtle ?: return
                    try {
                        btle.broadcastBytes(wrap(transportId, collection, bytes))
                        Log.d(TAG, "outbound [$transportId/$collection] ${bytes.size}B")
                    } catch (t: Throwable) {
                        Log.e(TAG, "broadcastBytes failed", t)
                    }
                }
            })
        } catch (t: Throwable) {
            Log.e(TAG, "subscribeOutboundFramesJni failed", t)
        }

        try { PeatJni.bleSetStartedJni(handle, true) } catch (t: Throwable) { Log.e(TAG, "bleSetStarted failed", t) }

        return try {
            val btle = PeatBtle(context = context, meshId = MESH_ID)
            btle.init()
            btle.startMesh(this)
            peatBtle = btle
            Log.i(TAG, "BLE bridge started (meshId=$MESH_ID, nodeId=${btle.nodeId})")
            true
        } catch (t: Throwable) {
            Log.e(TAG, "PeatBtle start failed", t)
            try { PeatJni.bleSetStartedJni(handle, false) } catch (_: Throwable) {}
            false
        }
    }

    fun stop() {
        peatBtle?.let { try { it.stopMesh() } catch (t: Throwable) { Log.e(TAG, "stopMesh failed", t) } }
        peatBtle = null
        connectedPeers.clear()
        if (handle != 0L) try { PeatJni.bleSetStartedJni(handle, false) } catch (_: Throwable) {}
        Log.i(TAG, "BLE bridge stopped")
    }

    // ---------- PeatMeshListener ----------

    override fun onMeshUpdated(peers: List<PeatPeer>) {
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
            val id = if (transport == TRANSPORT_LITE) {
                PeatJni.ingestInboundLiteFrameJni(handle, collection, frame)
            } else {
                PeatJni.ingestInboundFrameJni(handle, collection, frame)
            }
            Log.d(TAG, "inbound [t=$transport/$collection] ${frame.size}B -> ${id ?: "no-op"}")
        } catch (t: Throwable) {
            Log.e(TAG, "ingest failed (transport=$transport)", t)
        }
    }

    // ---------- helpers ----------

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
