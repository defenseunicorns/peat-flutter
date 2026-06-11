package com.defenseunicorns.peat

/**
 * Kotlin bindings for peat-ffi's JNI surface — copied verbatim (minus the
 * androidx.annotation import) from peat-ffi/android/.../PeatJni.kt so it stays
 * in lockstep with the .so built from the same peat workspace.
 *
 * Why the Flutter (FFI/UniFFI) app needs this at all: peat-ffi's Android build
 * exposes TWO surfaces from the same libpeat_ffi.so — the UniFFI ffibuffer
 * surface that Dart drives, and this JNI surface. The Android Context can only
 * be handed to native code as a jobject, which UniFFI can't carry — so the
 * Context must be plumbed through this JNI entry point. iroh's DNS-based
 * discovery (relay/pkarr → hickory-resolver's ConnectivityManager probe), which
 * runs during create_node, reads that Context and otherwise panics with
 * "android context was not initialized" (UniFFI surfaces it as call status 2).
 *
 * EVERY method must be declared and @JvmStatic: nativeInit() registers a fixed
 * RegisterNatives table for the whole surface; a missing or non-static method
 * makes registration abort (NoSuchMethodError / "jclass has wrong type"
 * SIGABRT). We only call setAndroidContextJni here, but the full set must be
 * present for registration to succeed.
 */
/**
 * Listener peat-ffi's per-transport fan-out invokes (via JNI `onFrame`) for
 * every encoded outbound frame the mesh produces for a transport. The bridge
 * forwards these to peat-btle's radio. `transportId` is e.g. "ble" / "ble-lite".
 * Not in the RegisterNatives table — `subscribeOutboundFramesJni` resolves by
 * name, and the Rust side calls `onFrame` reflectively by name+signature.
 */
interface OutboundFrameListener {
    fun onFrame(transportId: String, collection: String, bytes: ByteArray)
}

object PeatJni {
    init {
        System.loadLibrary("peat_ffi")
        // Re-register natives against the live classloader. Matters when
        // Android classloader isolation prevents JNI_OnLoad from finding
        // PeatJni at .so load time.
        nativeInit()
    }

    // -- Lifecycle ---------------------------------------------------------

    @JvmStatic external fun nativeInit()

    @JvmStatic external fun peatVersion(): String

    @JvmStatic external fun testJni(): String

    /**
     * Plumb the Android [context] (the Application Context) into peat-ffi's
     * ndk-context global cell. Call before the first node creation.
     */
    @JvmStatic external fun setAndroidContextJni(context: Any)

    @JvmStatic external fun verifyAndroidContextJni(): Boolean

    @JvmStatic external fun createNodeJni(
        appId: String,
        sharedKey: String,
        storagePath: String,
    ): Long

    @JvmStatic external fun createNodeWithConfigJni(
        appId: String,
        sharedKey: String,
        storagePath: String,
        enableBle: Boolean,
        blePowerProfile: String?,
    ): Long

    @JvmStatic external fun getGlobalNodeHandleJni(): Long

    // Releases the owning reference create_node stored in the native global.
    // Call on node teardown (NOT on BLE stop — the node outlives BLE
    // start/stop) so the node can actually be freed. See peat#978.
    @JvmStatic external fun clearGlobalNodeHandleJni()

    @JvmStatic external fun freeNodeJni(handle: Long)

    // -- Node identity / peer state ----------------------------------------

    @JvmStatic external fun nodeIdJni(handle: Long): String

    @JvmStatic external fun peerCountJni(handle: Long): Int

    @JvmStatic external fun connectedPeersJni(handle: Long): String

    @JvmStatic external fun endpointSocketAddrJni(handle: Long): String?

    @JvmStatic external fun connectPeerJni(
        handle: Long,
        nodeId: String,
        address: String,
    ): Boolean

    // -- Sync coordination -------------------------------------------------

    @JvmStatic external fun startSyncJni(handle: Long): Boolean

    @JvmStatic external fun requestSyncJni(handle: Long): Boolean

    // -- Generic document I/O ----------------------------------------------

    @JvmStatic external fun publishDocumentJni(
        handle: Long,
        collection: String,
        json: String,
    ): String

    @JvmStatic external fun publishDocumentWithOriginJni(
        handle: Long,
        collection: String,
        json: String,
        origin: String,
    ): String

    @JvmStatic external fun getDocumentJni(
        handle: Long,
        collection: String,
        docId: String,
    ): String?

    // -- Typed collection accessors (CoT-style schema; ADR-049) ------------

    @JvmStatic external fun getCellsJni(handle: Long): String

    @JvmStatic external fun getTracksJni(handle: Long): String

    @JvmStatic external fun getNodesJni(handle: Long): String

    @JvmStatic external fun getCommandsJni(handle: Long): String

    @JvmStatic external fun getMarkersJni(handle: Long): String

    @JvmStatic external fun publishNodeJni(handle: Long, nodeJson: String): Boolean

    @JvmStatic external fun publishMarkerJni(handle: Long, markerJson: String): Boolean

    @JvmStatic external fun ingestPositionJni(handle: Long, positionJson: String): String

    // -- Blob transfer -----------------------------------------------------

    @JvmStatic external fun enableBlobTransferJni(handle: Long, blobDir: String): Boolean

    @JvmStatic external fun blobAddPeerJni(
        handle: Long,
        peerId: String,
        address: String,
    ): Boolean

    @JvmStatic external fun blobPutJni(
        handle: Long,
        data: ByteArray,
        contentType: String,
    ): String

    @JvmStatic external fun blobGetJni(handle: Long, hash: String): ByteArray

    @JvmStatic external fun blobExistsLocallyJni(handle: Long, hash: String): Boolean

    @JvmStatic external fun blobEndpointIdJni(handle: Long): String

    // -- BLE transport bridge (pipe peat-btle radio <-> peat-ffi mesh) -----

    /**
     * Subscribe a [OutboundFrameListener] to the mesh's per-transport fan-out.
     * peat-ffi pushes every outbound "ble"/"ble-lite" frame to the listener,
     * which the bridge transmits over peat-btle. By-name JNI (not in the
     * RegisterNatives table — it references this consumer-supplied interface).
     */
    @JvmStatic external fun subscribeOutboundFramesJni(
        handle: Long,
        listener: OutboundFrameListener,
    ): Boolean

    /**
     * Ingest a decrypted frame received over BLE into the mesh. peat-ffi
     * publishes it with "ble" origin so the mesh re-fans it to other
     * transports (iroh/Wi-Fi) without looping. Returns the doc id or null.
     */
    @JvmStatic external fun ingestInboundFrameJni(
        handle: Long,
        collection: String,
        postcardBytes: ByteArray,
    ): String?

    /**
     * Inbound counterpart for the universal-Document (peat-lite / ble-lite)
     * codec — used for raw collections (e.g. the 'demo' counter) that the typed
     * translator declines. Decodes via the lite-bridge, publishes with
     * "ble-lite" origin.
     */
    @JvmStatic external fun ingestInboundLiteFrameJni(
        handle: Long,
        collection: String,
        envelopeBytes: ByteArray,
    ): String?

    // -- BLE transport state (ADR-039) -------------------------------------

    @JvmStatic external fun bleSetStartedJni(handle: Long, started: Boolean)

    @JvmStatic external fun bleAddPeerJni(handle: Long, peerId: String)

    @JvmStatic external fun bleRemovePeerJni(handle: Long, peerId: String)

    @JvmStatic external fun bleIsAvailableJni(handle: Long): Boolean

    @JvmStatic external fun blePeerCountJni(handle: Long): Int

    // -- Test-only fault injection -----------------------------------------

    @JvmStatic external fun forceStoreErrorForTestingJni(handle: Long): Boolean
}
