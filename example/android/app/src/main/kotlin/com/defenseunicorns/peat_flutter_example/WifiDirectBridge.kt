package com.defenseunicorns.peat_flutter_example

import android.util.Log
import com.defenseunicorns.peat.PeatJni
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

/**
 * P2PWiFi carrier — a SECOND transport alongside [BleBridge]. It tunnels the
 * exact same peat-mesh fan-out frames over a plain TCP socket on the Wi-Fi
 * Direct group link (the group owner is 192.168.49.1). iroh's QUIC/UDP can't
 * survive Android's p2p interface, so we carry the universal-Document frames
 * over TCP instead.
 *
 * Wire framing on the stream: `[u32 BE length][envelope]`, where `envelope` is
 * the identical [BleBridge] layout `[0xAF][transport][collLen][coll][frame]`.
 * Inbound frames feed the same `ingestInbound*FrameJni` path as BLE; ingestion
 * is idempotent + echo-suppressed, so a frame arriving over both carriers is
 * harmless (it just converges twice).
 *
 * Role: the group owner runs a [ServerSocket] and accepts the client; the
 * client dials the GO. Either side loops and re-establishes on disconnect.
 *
 * Outbound frames are pushed in by the shared dispatch (the single
 * `subscribeOutboundFramesJni` listener that [BleBridge] owns also forwards
 * here), so there is no second JNI subscription.
 */
class WifiDirectBridge {

    companion object {
        private const val TAG = "WifiDirectBridge"
        private const val DATA_PORT = 47626 // distinct from the (now-removed) handshake port
        private const val MAX_FRAME = 1 shl 20 // 1 MiB sanity cap
        private const val APP_LAYER: Byte = 0xAF.toByte()
        private const val TRANSPORT_TYPED = 0
        private const val TRANSPORT_LITE = 1
    }

    @Volatile private var handle: Long = 0L
    @Volatile private var out: DataOutputStream? = null
    private val running = AtomicBoolean(false)
    private var ioThread: Thread? = null

    fun isConnected(): Boolean = out != null

    /// Start the tunnel for the formed group. [isGroupOwner] picks server vs
    /// client; [goAddress] is the group-owner IP (needed by the client).
    fun start(isGroupOwner: Boolean, goAddress: String?) {
        if (running.getAndSet(true)) return
        handle = fetchHandle()
        val t = Thread({
            if (isGroupOwner) serverLoop() else clientLoop(goAddress)
        }, "peat-wd-tunnel").apply { isDaemon = true }
        ioThread = t
        t.start()
        Log.i(TAG, "tunnel started (groupOwner=$isGroupOwner go=$goAddress)")
    }

    /// Re-point at the current node after a node restart (radio/link stays up).
    fun rebind() {
        handle = fetchHandle()
        Log.i(TAG, "tunnel re-bound to handle=$handle")
    }

    /// Drop the node handle without tearing down the link — a late inbound
    /// frame then no-ops (JNI guards handle 0) while the node is freed.
    fun unbind() {
        handle = 0L
    }

    fun stop() {
        running.set(false)
        out = null
        ioThread?.interrupt()
        ioThread = null
        Log.i(TAG, "tunnel stopped")
    }

    /// Send an outbound fan-out frame over the TCP tunnel. No-op if the link
    /// isn't connected yet. Called from the shared outbound dispatch.
    fun send(transportId: String, collection: String, frame: ByteArray) {
        val o = out ?: return
        val env = wrap(transportId, collection, frame)
        synchronized(o) {
            try {
                o.writeInt(env.size)
                o.write(env)
                o.flush()
            } catch (t: Throwable) {
                Log.e(TAG, "send failed; dropping link", t)
                out = null
            }
        }
    }

    private fun fetchHandle(): Long =
        try { PeatJni.getGlobalNodeHandleJni() } catch (t: Throwable) {
            Log.e(TAG, "getGlobalNodeHandleJni failed", t); 0L
        }

    private fun serverLoop() {
        while (running.get()) {
            try {
                ServerSocket().use { srv ->
                    srv.reuseAddress = true
                    srv.bind(InetSocketAddress(DATA_PORT))
                    Log.i(TAG, "server listening on :$DATA_PORT")
                    while (running.get()) {
                        val s = try { srv.accept() } catch (e: Exception) { break }
                        pump(s) // blocks until this connection drops
                    }
                }
            } catch (t: Throwable) {
                if (running.get()) {
                    Log.e(TAG, "server loop error; retrying", t)
                    sleep(1000)
                }
            }
        }
    }

    private fun clientLoop(go: String?) {
        if (go == null) { Log.e(TAG, "client: no group-owner address"); return }
        while (running.get()) {
            try {
                Socket().use { s ->
                    s.connect(InetSocketAddress(go, DATA_PORT), 3000)
                    pump(s)
                }
            } catch (t: Throwable) {
                Log.i(TAG, "client connect failed (${t.message}); retry")
            }
            if (running.get()) sleep(1500)
        }
    }

    /// Own a live connection: expose its output for send(), read framed
    /// envelopes until it closes. Blocks for the connection's lifetime.
    private fun pump(s: Socket) {
        s.tcpNoDelay = true
        val din = DataInputStream(s.getInputStream().buffered())
        val dout = DataOutputStream(s.getOutputStream())
        out = dout
        Log.i(TAG, "tunnel connected: ${s.inetAddress?.hostAddress}")
        try {
            while (running.get()) {
                val len = din.readInt() // EOFException when peer closes
                if (len <= 0 || len > MAX_FRAME) {
                    Log.w(TAG, "bad frame length $len; closing"); break
                }
                val buf = ByteArray(len)
                din.readFully(buf)
                ingest(buf)
            }
        } catch (t: Throwable) {
            Log.i(TAG, "connection closed: ${t.message}")
        } finally {
            if (out === dout) out = null
        }
    }

    private fun ingest(env: ByteArray) {
        val h = handle
        if (h == 0L) return // unbound (node stopped) — drop
        if (env.size < 3 || env[0] != APP_LAYER) return
        val transport = env[1].toInt() and 0xFF
        val collLen = env[2].toInt() and 0xFF
        if (env.size < 3 + collLen) return
        val collection = String(env, 3, collLen, Charsets.UTF_8)
        val frame = env.copyOfRange(3 + collLen, env.size)
        try {
            val id = if (transport == TRANSPORT_LITE) {
                PeatJni.ingestInboundLiteFrameJni(h, collection, frame)
            } else {
                PeatJni.ingestInboundFrameJni(h, collection, frame)
            }
            Log.d(TAG, "inbound [t=$transport/$collection] ${frame.size}B -> ${id ?: "no-op"}")
        } catch (t: Throwable) {
            Log.e(TAG, "ingest failed (transport=$transport)", t)
        }
    }

    /// Build the wire envelope — identical layout to BleBridge.wrap so both
    /// carriers speak the same frame format.
    private fun wrap(transportId: String, collection: String, frame: ByteArray): ByteArray {
        val coll = collection.toByteArray(Charsets.UTF_8)
        val transport = if (transportId == "ble-lite") TRANSPORT_LITE else TRANSPORT_TYPED
        val out = ByteArray(3 + coll.size + frame.size)
        out[0] = APP_LAYER
        out[1] = transport.toByte()
        out[2] = coll.size.toByte()
        System.arraycopy(coll, 0, out, 3, coll.size)
        System.arraycopy(frame, 0, out, 3 + coll.size, frame.size)
        return out
    }

    private fun sleep(ms: Long) = try { Thread.sleep(ms) } catch (_: InterruptedException) {}
}
