#![cfg(feature = "sync")]

use peat_ffi::dart_ffi::{
    uniffi_ffibuffer_peat_ffi_fn_method_peatnode_on_peer_observed,
    uniffi_ffibuffer_peat_ffi_fn_method_peatnode_reconnect_known_peers,
    uniffi_ffibuffer_peat_ffi_fn_method_peatnode_roster_remember,
    uniffi_ffibuffer_peat_ffi_fn_method_peatnode_wake_reconnect, Elem, RustBuf,
};
use peat_ffi_upstream::{create_node, NodeConfig, PeatNode, PeerInfo};
use std::sync::Arc;
use uniffi::Lower;

type VoidShim = unsafe extern "C" fn(*const Elem, *mut Elem);

/// Transfer a UniFFI-owned allocation into the layout expected by the Dart
/// shim. `uniffi::RustBuffer` intentionally has no `Drop` implementation; the
/// called shim reconstructs it and consumes the allocation exactly once.
fn mirror_buffer(buffer: uniffi::RustBuffer) -> RustBuf {
    RustBuf {
        capacity: buffer.capacity() as u64,
        len: buffer.len() as u64,
        data: buffer.data_pointer().cast_mut(),
    }
}

fn lower_string(value: String) -> RustBuf {
    mirror_buffer(<String as Lower<peat_ffi_upstream::UniFfiTag>>::lower(
        value,
    ))
}

fn lower_peer_info(value: PeerInfo) -> RustBuf {
    mirror_buffer(<PeerInfo as Lower<peat_ffi_upstream::UniFfiTag>>::lower(
        value,
    ))
}

fn fresh_handle(node: &Arc<PeatNode>) -> u64 {
    Arc::into_raw(Arc::clone(node)) as u64
}

fn call_void_shim(shim: VoidShim, args: &[Elem]) {
    let mut ret: [Elem; 4] = std::array::from_fn(|_| Elem { u64: 0 });

    // SAFETY: `args` and `ret` remain live and correctly sized for the entire
    // call. Every complex argument owns a UniFFI-created RustBuffer, and every
    // receiver handle owns one fresh Arc strong reference for the shim to
    // consume. The called shims return a four-element void-result buffer.
    unsafe {
        shim(args.as_ptr(), ret.as_mut_ptr());
        assert_eq!(ret[0].i8, 0, "Dart FFI shim returned an error status");
        assert_eq!(ret[1].u64, 0, "successful call returned an error buffer");
        assert_eq!(ret[2].u64, 0, "successful call returned an error buffer");
        assert!(
            ret[3].ptr.is_null(),
            "successful call returned an error buffer"
        );
    }
}

fn assert_handle_consumed(node: &Arc<PeatNode>) {
    assert_eq!(
        Arc::strong_count(node),
        1,
        "the shim must consume exactly one fresh Arc ownership slot"
    );
}

#[test]
fn reconnect_shims_consume_fresh_arc_handles() {
    let storage = tempfile::tempdir().expect("create temporary node storage");
    let node = create_node(NodeConfig {
        app_id: "dart-ffi-shim-smoke".to_string(),
        shared_key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".to_string(),
        bind_address: Some("127.0.0.1:0".to_string()),
        storage_path: storage.path().to_string_lossy().into_owned(),
        transport: None,
    })
    .expect("create node");

    let reconnect_args = [Elem {
        u64: fresh_handle(&node),
    }];
    call_void_shim(
        uniffi_ffibuffer_peat_ffi_fn_method_peatnode_reconnect_known_peers,
        &reconnect_args,
    );
    assert_handle_consumed(&node);

    let wake_args = [Elem {
        u64: fresh_handle(&node),
    }];
    call_void_shim(
        uniffi_ffibuffer_peat_ffi_fn_method_peatnode_wake_reconnect,
        &wake_args,
    );
    assert_handle_consumed(&node);

    let observed_id = lower_string("unknown-peer".to_string());
    let observed_args = [
        Elem {
            u64: fresh_handle(&node),
        },
        Elem {
            u64: observed_id.capacity,
        },
        Elem {
            u64: observed_id.len,
        },
        Elem {
            ptr: observed_id.data.cast(),
        },
    ];
    call_void_shim(
        uniffi_ffibuffer_peat_ffi_fn_method_peatnode_on_peer_observed,
        &observed_args,
    );
    assert_handle_consumed(&node);

    let group_id = lower_string("test-group".to_string());
    let peer = lower_peer_info(PeerInfo {
        name: "offline-peer".to_string(),
        node_id: "unknown-peer".to_string(),
        addresses: Vec::new(),
        relay_url: None,
    });
    let remember_args = [
        Elem {
            u64: fresh_handle(&node),
        },
        Elem {
            u64: group_id.capacity,
        },
        Elem { u64: group_id.len },
        Elem {
            ptr: group_id.data.cast(),
        },
        Elem { u64: peer.capacity },
        Elem { u64: peer.len },
        Elem {
            ptr: peer.data.cast(),
        },
    ];
    call_void_shim(
        uniffi_ffibuffer_peat_ffi_fn_method_peatnode_roster_remember,
        &remember_args,
    );
    assert_handle_consumed(&node);
    assert!(
        node.roster_get("unknown-peer".to_string()).is_some(),
        "roster_remember must decode and persist the supplied record"
    );

    drop(node);
}
