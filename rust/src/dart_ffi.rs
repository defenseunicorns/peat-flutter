// FFIBuffer scaffolding for peat_ffi.dart Dart FFI bindings.
//
// The Dart bindings use an "ffibuffer" transport: each call passes all
// arguments through a flat array of 8-byte union elements and receives
// results through a second flat array of the same type. This module
// exports the entry points the Dart side looks up by name.
//
// Buffer layouts (matching peat_ffi.dart):
//   Void return:          [0]=status(i8)  [1..3]=error_buf(u64,u64,ptr)
//   u32 return:           [0]=value(u32)  [1]=status(i8)  [2..4]=error_buf
//   i8/bool return:       [0]=value(i8)   [1]=status(i8)  [2..4]=error_buf
//   u64 handle return:    [0]=handle(u64) [1]=status(i8)  [2..4]=error_buf
//   RustBuffer return:    [0..2]=buf(u64,u64,ptr) [3]=status(i8)
// [4..6]=error_buf
//
// Arg buffer elements per type:
//   u64 handle / u64 callback:  1 element (.u64)
//   f64 primitive:              1 element (.f64)
//   u32 primitive:              1 element (.u32)
//   RustBuffer (any complex):   3 elements (.u64 cap, .u64 len, .ptr data)

#![allow(non_snake_case, clippy::missing_safety_doc)]

use std::ffi::c_void;

// 8-byte union matching Dart's _UniFfiFfiBufferElement
#[repr(C)]
pub union Elem {
    pub u8: u8,
    pub i8: i8,
    pub u16: u16,
    pub i16: i16,
    pub u32: u32,
    pub i32: i32,
    pub u64: u64,
    pub i64: i64,
    pub f32: f32,
    pub f64: f64,
    pub ptr: *mut c_void,
}

// Mirrors uniffi_core::RustBuffer (must match C layout)
#[repr(C)]
#[derive(Clone, Copy)]
pub struct RustBuf {
    pub capacity: u64,
    pub len: u64,
    pub data: *mut u8,
}

impl RustBuf {
    pub fn empty() -> Self {
        RustBuf {
            capacity: 0,
            len: 0,
            data: std::ptr::null_mut(),
        }
    }
}

// Mirrors uniffi_core::RustCallStatus
#[repr(C)]
pub struct CallStatus {
    pub code: i8,
    pub error_buf: RustBuf,
}

impl CallStatus {
    pub fn new() -> Self {
        CallStatus {
            code: 0,
            error_buf: RustBuf::empty(),
        }
    }
}

impl Default for CallStatus {
    fn default() -> Self {
        Self::new()
    }
}

// Mirrors uniffi_core::ForeignBytes
#[repr(C)]
pub struct ForeignBytes {
    pub len: i32,
    pub data: *const u8,
}

// --- Helpers ----------------------------------------------------------------

unsafe fn read_buf(e: *const Elem, i: usize) -> RustBuf {
    RustBuf {
        capacity: (*e.add(i)).u64,
        len: (*e.add(i + 1)).u64,
        data: (*e.add(i + 2)).ptr as *mut u8,
    }
}

unsafe fn write_buf(e: *mut Elem, i: usize, b: RustBuf) {
    (*e.add(i)).u64 = b.capacity;
    (*e.add(i + 1)).u64 = b.len;
    (*e.add(i + 2)).ptr = b.data as *mut c_void;
}

unsafe fn write_err(e: *mut Elem, i: usize, s: &CallStatus) {
    (*e.add(i)).i8 = s.code;
    write_buf(e, i + 1, s.error_buf);
}

// void return:      ret[0]=status, ret[1..3]=error
unsafe fn ret_void(e: *mut Elem, s: &CallStatus) {
    write_err(e, 0, s);
}

// u64 handle/primitive return: ret[0]=value, ret[1]=status, ret[2..4]=error
unsafe fn ret_u64(e: *mut Elem, v: u64, s: &CallStatus) {
    (*e.add(0)).u64 = v;
    write_err(e, 1, s);
}

// u32 return: ret[0]=value(u32), ret[1]=status, ret[2..4]=error
unsafe fn ret_u32(e: *mut Elem, v: u32, s: &CallStatus) {
    (*e.add(0)).u32 = v;
    write_err(e, 1, s);
}

// i64 return: ret[0]=value(i64), ret[1]=status, ret[2..4]=error
unsafe fn ret_i64(e: *mut Elem, v: i64, s: &CallStatus) {
    (*e.add(0)).i64 = v;
    write_err(e, 1, s);
}

// i8/bool return: ret[0]=value(i8), ret[1]=status, ret[2..4]=error
unsafe fn ret_i8(e: *mut Elem, v: i8, s: &CallStatus) {
    (*e.add(0)).i8 = v;
    write_err(e, 1, s);
}

// RustBuffer return: ret[0..2]=buf, ret[3]=status, ret[4..6]=error
unsafe fn ret_rbuf(e: *mut Elem, b: RustBuf, s: &CallStatus) {
    write_buf(e, 0, b);
    write_err(e, 3, s);
}

// --- Standard UniFFI function declarations ----------------------------------

extern "C" {
    fn ffi_peat_ffi_rustbuffer_from_bytes(b: ForeignBytes, s: *mut CallStatus) -> RustBuf;
    fn ffi_peat_ffi_rustbuffer_free(b: RustBuf, s: *mut CallStatus);

    // top-level functions
    fn uniffi_peat_ffi_fn_func_create_node(config: RustBuf, s: *mut CallStatus) -> u64;
    fn uniffi_peat_ffi_fn_func_create_position(
        lat: f64,
        lon: f64,
        hae: RustBuf,
        s: *mut CallStatus,
    ) -> RustBuf;
    fn uniffi_peat_ffi_fn_func_create_velocity(
        bearing: f64,
        speed: f64,
        s: *mut CallStatus,
    ) -> RustBuf;
    fn uniffi_peat_ffi_fn_func_encode_track_to_cot(track: RustBuf, s: *mut CallStatus) -> RustBuf;
    fn uniffi_peat_ffi_fn_func_peat_version(s: *mut CallStatus) -> RustBuf;

    // PeatNode methods
    fn uniffi_peat_ffi_fn_method_peatnode_all_peer_transport_states(
        h: u64,
        s: *mut CallStatus,
    ) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_connect_peer(h: u64, addr: RustBuf, s: *mut CallStatus);
    fn uniffi_peat_ffi_fn_method_peatnode_connect_peer_nowait(
        h: u64,
        addr: RustBuf,
        s: *mut CallStatus,
    );
    fn uniffi_peat_ffi_fn_method_peatnode_connected_peers(h: u64, s: *mut CallStatus) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_delete_document(
        h: u64,
        col: RustBuf,
        id: RustBuf,
        s: *mut CallStatus,
    );
    fn uniffi_peat_ffi_fn_method_peatnode_disconnect_peer(
        h: u64,
        node_id: RustBuf,
        s: *mut CallStatus,
    );
    fn uniffi_peat_ffi_fn_method_peatnode_endpoint_addr(h: u64, s: *mut CallStatus) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_endpoint_socket_addr(
        h: u64,
        s: *mut CallStatus,
    ) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_get_cell(
        h: u64,
        col: RustBuf,
        s: *mut CallStatus,
    ) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_get_cells(h: u64, s: *mut CallStatus) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_get_document(
        h: u64,
        col: RustBuf,
        id: RustBuf,
        s: *mut CallStatus,
    ) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_get_nodes(h: u64, s: *mut CallStatus) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_get_track(
        h: u64,
        id: RustBuf,
        s: *mut CallStatus,
    ) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_get_tracks(h: u64, s: *mut CallStatus) -> RustBuf;
    // BLE-bridge methods: gated to match the `#[uniffi::export]` definitions
    // (cfg(all(sync, bluetooth)), + lite-bridge for the lite variant). Without
    // these gates, the declarations reference scaffolding fns that don't exist
    // under the default `sync`-only feature set → dangling symbols on strict
    // (macOS/iOS) cdylib links. See peat#986.
    #[cfg(all(feature = "sync", feature = "bluetooth"))]
    fn uniffi_peat_ffi_fn_method_peatnode_ingest_inbound_frame(
        h: u64,
        col: RustBuf,
        data: RustBuf,
        s: *mut CallStatus,
    ) -> RustBuf;
    #[cfg(all(feature = "sync", feature = "bluetooth", feature = "lite-bridge"))]
    fn uniffi_peat_ffi_fn_method_peatnode_ingest_inbound_lite_frame(
        h: u64,
        col: RustBuf,
        data: RustBuf,
        s: *mut CallStatus,
    ) -> RustBuf;
    #[cfg(all(feature = "sync", feature = "bluetooth"))]
    fn uniffi_peat_ffi_fn_method_peatnode_publish_document(
        h: u64,
        col: RustBuf,
        json: RustBuf,
        s: *mut CallStatus,
    ) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_list_documents(
        h: u64,
        col: RustBuf,
        s: *mut CallStatus,
    ) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_node_id(h: u64, s: *mut CallStatus) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_peer_count(h: u64, s: *mut CallStatus) -> u32;
    fn uniffi_peat_ffi_fn_method_peatnode_peer_transport_state(
        h: u64,
        id: RustBuf,
        s: *mut CallStatus,
    ) -> RustBuf;
    #[cfg(all(feature = "sync", feature = "bluetooth"))]
    fn uniffi_peat_ffi_fn_method_peatnode_poll_outbound_frames(
        h: u64,
        s: *mut CallStatus,
    ) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_put_cell(h: u64, cell: RustBuf, s: *mut CallStatus);
    fn uniffi_peat_ffi_fn_method_peatnode_put_document(
        h: u64,
        col: RustBuf,
        id: RustBuf,
        data: RustBuf,
        s: *mut CallStatus,
    );
    fn uniffi_peat_ffi_fn_method_peatnode_put_node(h: u64, node: RustBuf, s: *mut CallStatus);
    fn uniffi_peat_ffi_fn_method_peatnode_put_track(h: u64, t: RustBuf, s: *mut CallStatus);
    fn uniffi_peat_ffi_fn_method_peatnode_request_sync(h: u64, s: *mut CallStatus);
    // Reconnect supervisor surface (roster population + event hooks).
    fn uniffi_peat_ffi_fn_method_peatnode_roster_remember(
        h: u64,
        group_id: RustBuf,
        peer: RustBuf,
        s: *mut CallStatus,
    );
    fn uniffi_peat_ffi_fn_method_peatnode_reconnect_known_peers(h: u64, s: *mut CallStatus);
    fn uniffi_peat_ffi_fn_method_peatnode_wake_reconnect(h: u64, s: *mut CallStatus);
    fn uniffi_peat_ffi_fn_method_peatnode_on_peer_observed(
        h: u64,
        node_id: RustBuf,
        s: *mut CallStatus,
    );
    #[cfg(all(feature = "sync", feature = "bluetooth"))]
    fn uniffi_peat_ffi_fn_method_peatnode_start_outbound_frames(h: u64, s: *mut CallStatus);
    fn uniffi_peat_ffi_fn_method_peatnode_start_sync(h: u64, s: *mut CallStatus);
    #[cfg(all(feature = "sync", feature = "bluetooth"))]
    fn uniffi_peat_ffi_fn_method_peatnode_stop_outbound_frames(h: u64, s: *mut CallStatus);
    fn uniffi_peat_ffi_fn_method_peatnode_stop_sync(h: u64, s: *mut CallStatus);
    fn uniffi_peat_ffi_fn_method_peatnode_subscribe(h: u64, cb: u64, s: *mut CallStatus) -> u64;
    fn uniffi_peat_ffi_fn_method_peatnode_subscribe_poll(h: u64, s: *mut CallStatus) -> u64;
    fn uniffi_peat_ffi_fn_method_peatnode_sync_document(
        h: u64,
        col: RustBuf,
        id: RustBuf,
        s: *mut CallStatus,
    );
    fn uniffi_peat_ffi_fn_method_peatnode_sync_stats(h: u64, s: *mut CallStatus) -> RustBuf;

    // Shared water-supply Counter (CRDT-over-Automerge-over-BLE)
    fn uniffi_peat_ffi_fn_method_peatnode_crdt_counter_value(h: u64, s: *mut CallStatus) -> i64;
    fn uniffi_peat_ffi_fn_method_peatnode_crdt_counter_increment(
        h: u64,
        delta: i64,
        s: *mut CallStatus,
    ) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_crdt_counter_merge(
        h: u64,
        bytes: RustBuf,
        s: *mut CallStatus,
    ) -> i64;
    fn uniffi_peat_ffi_fn_method_peatnode_crdt_counter_snapshot(
        h: u64,
        s: *mut CallStatus,
    ) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_crdt_kv_put(
        h: u64,
        collection: RustBuf,
        key: RustBuf,
        value: RustBuf,
        s: *mut CallStatus,
    ) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_crdt_kv_all(
        h: u64,
        collection: RustBuf,
        s: *mut CallStatus,
    ) -> RustBuf;
    fn uniffi_peat_ffi_fn_method_peatnode_crdt_kv_merge(
        h: u64,
        collection: RustBuf,
        hex: RustBuf,
        s: *mut CallStatus,
    );
    fn uniffi_peat_ffi_fn_method_peatnode_crdt_kv_snapshot(
        h: u64,
        collection: RustBuf,
        s: *mut CallStatus,
    ) -> RustBuf;

    // SubscriptionHandle methods
    fn uniffi_peat_ffi_fn_method_subscriptionhandle_cancel(h: u64, s: *mut CallStatus);
    fn uniffi_peat_ffi_fn_method_subscriptionhandle_is_active(h: u64, s: *mut CallStatus) -> i8;
    fn uniffi_peat_ffi_fn_method_subscriptionhandle_poll_changes(
        h: u64,
        s: *mut CallStatus,
    ) -> RustBuf;

    // Blob transfer (ADR-060 + peat#1013)
    #[cfg(feature = "sync")]
    fn uniffi_peat_ffi_fn_method_peatnode_enable_blob_transfer(
        h: u64,
        bind_addr: RustBuf,
        s: *mut CallStatus,
    );
    #[cfg(feature = "sync")]
    fn uniffi_peat_ffi_fn_method_peatnode_blob_add_peer(
        h: u64,
        peer_id_hex: RustBuf,
        address: RustBuf,
        s: *mut CallStatus,
    );
    #[cfg(feature = "sync")]
    fn uniffi_peat_ffi_fn_method_peatnode_blob_add_peer_id(
        h: u64,
        peer_id_hex: RustBuf,
        s: *mut CallStatus,
    );
    #[cfg(feature = "sync")]
    fn uniffi_peat_ffi_fn_method_peatnode_blob_put(
        h: u64,
        data: RustBuf,
        content_type: RustBuf,
        s: *mut CallStatus,
    ) -> RustBuf;
    #[cfg(feature = "sync")]
    fn uniffi_peat_ffi_fn_method_peatnode_blob_exists_locally(
        h: u64,
        hash_hex: RustBuf,
        s: *mut CallStatus,
    ) -> i8;
    #[cfg(feature = "sync")]
    fn uniffi_peat_ffi_fn_method_peatnode_blob_endpoint_id(h: u64, s: *mut CallStatus) -> RustBuf;
    #[cfg(feature = "sync")]
    fn uniffi_peat_ffi_fn_method_peatnode_blob_bound_addr(h: u64, s: *mut CallStatus) -> RustBuf;
    #[cfg(feature = "sync")]
    fn uniffi_peat_ffi_fn_method_peatnode_blob_fetch_start(
        h: u64,
        hash_hex: RustBuf,
        size_bytes: u64,
        peer_id_hex: RustBuf,
        s: *mut CallStatus,
    ) -> u64;

    // BlobFetchHandle methods
    #[cfg(feature = "sync")]
    fn uniffi_peat_ffi_fn_method_blobfetchhandle_status(h: u64, s: *mut CallStatus) -> RustBuf;
    #[cfg(feature = "sync")]
    fn uniffi_peat_ffi_fn_method_blobfetchhandle_dispose(h: u64, s: *mut CallStatus);
}

// --- rustbuffer aliases the Dart bindings expect ----------------------------

#[no_mangle]
pub unsafe extern "C" fn ffi_uniffi_peat_ffi_rustbuffer_from_bytes(
    b: ForeignBytes,
    s: *mut CallStatus,
) -> RustBuf {
    ffi_peat_ffi_rustbuffer_from_bytes(b, s)
}

#[no_mangle]
pub unsafe extern "C" fn ffi_uniffi_peat_ffi_rustbuffer_free(b: RustBuf, s: *mut CallStatus) {
    ffi_peat_ffi_rustbuffer_free(b, s)
}

// --- FFIBuffer wrappers -----------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_func_create_node(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_func_create_node(read_buf(a, 0), &mut s);
    ret_u64(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_func_create_position(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let lat = (*a.add(0)).f64;
    let lon = (*a.add(1)).f64;
    let hae = read_buf(a, 2);
    let v = uniffi_peat_ffi_fn_func_create_position(lat, lon, hae, &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_func_create_velocity(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let bearing = (*a.add(0)).f64;
    let speed = (*a.add(1)).f64;
    let v = uniffi_peat_ffi_fn_func_create_velocity(bearing, speed, &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_func_encode_track_to_cot(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_func_encode_track_to_cot(read_buf(a, 0), &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_func_peat_version(
    _a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_func_peat_version(&mut s);
    ret_rbuf(r, v, &s);
}

// PeatNode methods -----------------------------------------------------------

// Shared water-supply Counter (CRDT-over-Automerge-over-BLE) -----------------

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_crdt_counter_value(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_crdt_counter_value((*a.add(0)).u64, &mut s);
    ret_i64(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_crdt_counter_increment(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let h = (*a.add(0)).u64;
    let delta = (*a.add(1)).i64;
    let v = uniffi_peat_ffi_fn_method_peatnode_crdt_counter_increment(h, delta, &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_crdt_counter_merge(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let h = (*a.add(0)).u64;
    let bytes = read_buf(a, 1);
    let v = uniffi_peat_ffi_fn_method_peatnode_crdt_counter_merge(h, bytes, &mut s);
    ret_i64(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_crdt_counter_snapshot(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_crdt_counter_snapshot((*a.add(0)).u64, &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_crdt_kv_put(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_crdt_kv_put(
        (*a.add(0)).u64,
        read_buf(a, 1),
        read_buf(a, 4),
        read_buf(a, 7),
        &mut s,
    );
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_crdt_kv_all(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_crdt_kv_all((*a.add(0)).u64, read_buf(a, 1), &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_crdt_kv_merge(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_crdt_kv_merge(
        (*a.add(0)).u64,
        read_buf(a, 1),
        read_buf(a, 4),
        &mut s,
    );
    ret_void(r, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_crdt_kv_snapshot(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_crdt_kv_snapshot(
        (*a.add(0)).u64,
        read_buf(a, 1),
        &mut s,
    );
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_all_peer_transport_states(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_all_peer_transport_states((*a.add(0)).u64, &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_connect_peer(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_connect_peer((*a.add(0)).u64, read_buf(a, 1), &mut s);
    ret_void(r, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_connect_peer_nowait(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_connect_peer_nowait((*a.add(0)).u64, read_buf(a, 1), &mut s);
    ret_void(r, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_connected_peers(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_connected_peers((*a.add(0)).u64, &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_delete_document(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_delete_document(
        (*a.add(0)).u64,
        read_buf(a, 1),
        read_buf(a, 4),
        &mut s,
    );
    ret_void(r, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_disconnect_peer(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_disconnect_peer((*a.add(0)).u64, read_buf(a, 1), &mut s);
    ret_void(r, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_endpoint_addr(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_endpoint_addr((*a.add(0)).u64, &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_endpoint_socket_addr(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_endpoint_socket_addr((*a.add(0)).u64, &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_get_cell(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_get_cell((*a.add(0)).u64, read_buf(a, 1), &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_get_cells(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_get_cells((*a.add(0)).u64, &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_get_document(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_get_document(
        (*a.add(0)).u64,
        read_buf(a, 1),
        read_buf(a, 4),
        &mut s,
    );
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_get_nodes(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_get_nodes((*a.add(0)).u64, &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_get_track(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_get_track((*a.add(0)).u64, read_buf(a, 1), &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_get_tracks(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_get_tracks((*a.add(0)).u64, &mut s);
    ret_rbuf(r, v, &s);
}

#[cfg(all(feature = "sync", feature = "bluetooth"))]
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_ingest_inbound_frame(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_ingest_inbound_frame(
        (*a.add(0)).u64,
        read_buf(a, 1),
        read_buf(a, 4),
        &mut s,
    );
    ret_rbuf(r, v, &s);
}

#[cfg(all(feature = "sync", feature = "bluetooth", feature = "lite-bridge"))]
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_ingest_inbound_lite_frame(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_ingest_inbound_lite_frame(
        (*a.add(0)).u64,
        read_buf(a, 1),
        read_buf(a, 4),
        &mut s,
    );
    ret_rbuf(r, v, &s);
}

#[cfg(all(feature = "sync", feature = "bluetooth"))]
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_publish_document(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_publish_document(
        (*a.add(0)).u64,
        read_buf(a, 1),
        read_buf(a, 4),
        &mut s,
    );
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_list_documents(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v =
        uniffi_peat_ffi_fn_method_peatnode_list_documents((*a.add(0)).u64, read_buf(a, 1), &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_node_id(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_node_id((*a.add(0)).u64, &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_peer_count(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_peer_count((*a.add(0)).u64, &mut s);
    ret_u32(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_peer_transport_state(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_peer_transport_state(
        (*a.add(0)).u64,
        read_buf(a, 1),
        &mut s,
    );
    ret_rbuf(r, v, &s);
}

#[cfg(all(feature = "sync", feature = "bluetooth"))]
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_poll_outbound_frames(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_poll_outbound_frames((*a.add(0)).u64, &mut s);
    ret_rbuf(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_put_cell(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_put_cell((*a.add(0)).u64, read_buf(a, 1), &mut s);
    ret_void(r, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_put_document(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_put_document(
        (*a.add(0)).u64,
        read_buf(a, 1),
        read_buf(a, 4),
        read_buf(a, 7),
        &mut s,
    );
    ret_void(r, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_put_node(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_put_node((*a.add(0)).u64, read_buf(a, 1), &mut s);
    ret_void(r, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_put_track(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_put_track((*a.add(0)).u64, read_buf(a, 1), &mut s);
    ret_void(r, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_request_sync(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_request_sync((*a.add(0)).u64, &mut s);
    ret_void(r, &s);
}

#[cfg(all(feature = "sync", feature = "bluetooth"))]
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_start_outbound_frames(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_start_outbound_frames((*a.add(0)).u64, &mut s);
    ret_void(r, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_start_sync(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_start_sync((*a.add(0)).u64, &mut s);
    ret_void(r, &s);
}

#[cfg(all(feature = "sync", feature = "bluetooth"))]
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_stop_outbound_frames(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_stop_outbound_frames((*a.add(0)).u64, &mut s);
    ret_void(r, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_stop_sync(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_stop_sync((*a.add(0)).u64, &mut s);
    ret_void(r, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_subscribe(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_subscribe((*a.add(0)).u64, (*a.add(1)).u64, &mut s);
    ret_u64(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_subscribe_poll(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_subscribe_poll((*a.add(0)).u64, &mut s);
    ret_u64(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_sync_document(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_sync_document(
        (*a.add(0)).u64,
        read_buf(a, 1),
        read_buf(a, 4),
        &mut s,
    );
    ret_void(r, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_sync_stats(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_sync_stats((*a.add(0)).u64, &mut s);
    ret_rbuf(r, v, &s);
}

// SubscriptionHandle methods -------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_subscriptionhandle_cancel(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_subscriptionhandle_cancel((*a.add(0)).u64, &mut s);
    ret_void(r, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_subscriptionhandle_is_active(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_subscriptionhandle_is_active((*a.add(0)).u64, &mut s);
    ret_i8(r, v, &s);
}

#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_subscriptionhandle_poll_changes(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_subscriptionhandle_poll_changes((*a.add(0)).u64, &mut s);
    ret_rbuf(r, v, &s);
}

// --- Reconnect supervisor surface -------------------------------------------
// roster_remember(handle, group_id: String, peer: PeerInfo) -> void.
// Args: [0]=handle, [1..3]=group_id buf, [4..6]=peer buf (PeerInfo Record,
// serialized by the same Dart writer connect_peer uses).
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_roster_remember(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_roster_remember(
        (*a.add(0)).u64,
        read_buf(a, 1),
        read_buf(a, 4),
        &mut s,
    );
    ret_void(r, &s);
}

// reconnect_known_peers(handle) -> void. Gentle pass (no backoff reset).
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_reconnect_known_peers(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_reconnect_known_peers((*a.add(0)).u64, &mut s);
    ret_void(r, &s);
}

// wake_reconnect(handle) -> void. Clears backoff, then a full pass.
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_wake_reconnect(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_wake_reconnect((*a.add(0)).u64, &mut s);
    ret_void(r, &s);
}

// on_peer_observed(handle, node_id: String) -> void.
// Args: [0]=handle, [1..3]=node_id buf.
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_on_peer_observed(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_on_peer_observed((*a.add(0)).u64, read_buf(a, 1), &mut s);
    ret_void(r, &s);
}

// Blob transfer wrappers (ADR-060 + peat#1013) -------------------------------

// enable_blob_transfer(handle, bind_addr: Option<String>) -> void.
// Args: [0]=handle, [1..3]=bind_addr buf (presence-tagged).
#[cfg(feature = "sync")]
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_enable_blob_transfer(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_enable_blob_transfer(
        (*a.add(0)).u64,
        read_buf(a, 1),
        &mut s,
    );
    ret_void(r, &s);
}

// blob_add_peer(handle, peer_id_hex: String, address: String) -> void.
// Args: [0]=handle, [1..3]=peer_id_hex buf, [4..6]=address buf.
#[cfg(feature = "sync")]
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_blob_add_peer(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_blob_add_peer(
        (*a.add(0)).u64,
        read_buf(a, 1),
        read_buf(a, 4),
        &mut s,
    );
    ret_void(r, &s);
}

// blob_add_peer_id(handle, peer_id_hex: String) -> void.
// Args: [0]=handle, [1..3]=peer_id_hex buf.
#[cfg(feature = "sync")]
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_blob_add_peer_id(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_peatnode_blob_add_peer_id((*a.add(0)).u64, read_buf(a, 1), &mut s);
    ret_void(r, &s);
}

// blob_put(handle, data: Vec<u8>, content_type: String) -> String (hash hex).
// Args: [0]=handle, [1..3]=data buf, [4..6]=content_type buf.
#[cfg(feature = "sync")]
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_blob_put(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_blob_put(
        (*a.add(0)).u64,
        read_buf(a, 1),
        read_buf(a, 4),
        &mut s,
    );
    ret_rbuf(r, v, &s);
}

// blob_exists_locally(handle, hash_hex: String) -> bool.
// Args: [0]=handle, [1..3]=hash_hex buf.
#[cfg(feature = "sync")]
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_blob_exists_locally(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_blob_exists_locally(
        (*a.add(0)).u64,
        read_buf(a, 1),
        &mut s,
    );
    ret_i8(r, v, &s);
}

// blob_endpoint_id(handle) -> Option<String>.
// Args: [0]=handle.
#[cfg(feature = "sync")]
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_blob_endpoint_id(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_blob_endpoint_id((*a.add(0)).u64, &mut s);
    ret_rbuf(r, v, &s);
}

// blob_bound_addr(handle) -> Option<String>.
// Args: [0]=handle.
#[cfg(feature = "sync")]
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_blob_bound_addr(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_blob_bound_addr((*a.add(0)).u64, &mut s);
    ret_rbuf(r, v, &s);
}

// blob_fetch_start(handle, hash_hex: String, size_bytes: u64, peer_id_hex: Option<String>)
// -> Arc<BlobFetchHandle> (u64 handle).
// Args: [0]=handle, [1..3]=hash_hex buf, [4]=size_bytes, [5..7]=peer_id_hex buf (presence-tagged).
#[cfg(feature = "sync")]
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_peatnode_blob_fetch_start(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_peatnode_blob_fetch_start(
        (*a.add(0)).u64,
        read_buf(a, 1),
        (*a.add(4)).u64,
        read_buf(a, 5),
        &mut s,
    );
    ret_u64(r, v, &s);
}

// BlobFetchHandle.status() -> BlobFetchStatus (RustBuf).
// Args: [0]=handle.
#[cfg(feature = "sync")]
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_blobfetchhandle_status(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    let v = uniffi_peat_ffi_fn_method_blobfetchhandle_status((*a.add(0)).u64, &mut s);
    ret_rbuf(r, v, &s);
}

// BlobFetchHandle.dispose() -> void.
// Args: [0]=handle.
#[cfg(feature = "sync")]
#[no_mangle]
pub unsafe extern "C" fn uniffi_ffibuffer_peat_ffi_fn_method_blobfetchhandle_dispose(
    a: *const Elem,
    r: *mut Elem,
) {
    let mut s = CallStatus::new();
    uniffi_peat_ffi_fn_method_blobfetchhandle_dispose((*a.add(0)).u64, &mut s);
    ret_void(r, &s);
}
