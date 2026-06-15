# CRDT Water Counter over Automerge + BLE — Implementation Plan

Status: APPROVED, in progress (2026-06-13)
Owner: Kit / Claude

## Why (what went wrong with the interim)

The demo water counter was an **interim per-node model**: each node owned a
`counter-<nodeId>` JSON doc `{inc,dec,by}` in the `demo` collection, synced as
**whole-doc LWW snapshots** over the BLE lite-bridge, and the displayed total was
**reconstructed client-side** by summing per-callsign docs (with membership
scoping, identity dedup, freshness tiebreakers, and read-race retention).

Every property of that model fought us:
- identity churn (reset/reinstall) → zombie docs → inconsistent dedup across devices → totals disagree
- snapshot-LWW → re-applying a stale frame clobbers a newer value
- single-broadcast + flaky BLE → a follower never converges (doomsday)
- adding relay → traffic amplification, snapshot re-application churn, value flicker

Root cause: **we were reconstructing a CRDT by hand on top of a non-CRDT
transport.** The fix is to use a real CRDT.

## The design

**The water supply is ONE shared Automerge document with a `Counter` field**,
replicated to every node. Automerge's merge is **commutative, associative, and
idempotent**, which dissolves every problem above:

| Problem | Why it disappears |
|---|---|
| relay loops / duplicate frames | merging the same doc twice is a no-op |
| out-of-order / missed frames | `merge` reconciles; a later full-doc broadcast catches a node up |
| concurrent edits from N nodes | `Counter` **sums all increments** — no LWW clobber |
| identity churn / zombies | no per-node docs, no callsign accounting at all |
| flicker / read races | value is a monotonic merge result, never reconstructed from a transient doc set |

No per-node docs. No client-side summing. No membership scoping for the counter.
No dedup. No freshness tiebreaker. No retain logic. **Delete all of it.**

### Transport

Carry the doc's `automerge::Automerge::save()` bytes as a BLE frame over the
**existing** bridge (`broadcastBytes`) + relay. Because merge is idempotent,
the relay needs no dedup and loops are harmless — and the existing multi-hop
relay (peat-ffi `relay_ble_frame`) gives us BLE→BLE forwarding for free.

- **On local edit:** increment the `Counter`, persist, broadcast `save()` bytes.
- **On receive:** `Automerge::load(bytes)` → `local.merge(&mut incoming)` → persist → recompute value.
- **Periodic re-broadcast** (every heartbeat, ~4s): broadcast `save()` for late
  joiners / missed frames. Idempotent, so always safe.

For a single counter the saved doc is small; history growth is negligible for
the demo (compaction is a later concern).

### Where it lives

**peat-ffi**, self-contained, using the `automerge` crate directly (add as a
dep — already in the workspace at 0.9.0). It does **NOT** go through peat-mesh's
document/sync layer, so:
- no change to the pinned `peat-mesh` (>=0.9.0-rc.31) crate,
- decoupled from the lite-bridge snapshot path.

This is the pragmatic first delivery. The eventual "right" home is peat-mesh
running Automerge sync over peat-btle for ALL docs with per-peer capability
negotiation (full-CRDT phones vs lite microcontrollers) — see Phase 6. The
counter proves the pattern end-to-end first.

## FFI surface (peat-ffi, new)

A small self-contained module holding one `Automerge` doc per node behind a
Mutex, persisted to `storage_path/water.automerge`:

- `crdt_counter_value() -> i64` — current merged `liters` value.
- `crdt_counter_increment(delta: i64) -> Vec<u8>` — apply `tx.increment`, persist, return `save()` bytes to broadcast.
- `crdt_counter_merge(bytes: Vec<u8>) -> i64` — `load` + `merge` incoming, persist, return new value.
- `crdt_counter_snapshot() -> Vec<u8>` — current `save()` bytes (periodic re-broadcast).

(JNI shims for Android; UniFFI for iOS — both call the same core.)

## Dart / app wiring

- `+`/`-` buttons → `crdtCounterIncrement(±n)` → broadcast bytes via the BLE
  bridge under a dedicated frame tag (e.g. transport `"crdt"` / collection `"supply"`).
- BLE inbound for that tag → `crdtCounterMerge(bytes)` → refresh displayed value.
- Heartbeat tick → broadcast `crdtCounterSnapshot()` for catch-up.
- Display: **total** = `crdtCounterValue()` (the shared pool). "yours" becomes a
  local-only tally of this device's own increments (cosmetic; not synced).
- **Remove** the interim counter machinery: `_myInc/_myDec/_peerContributions/
  _refreshCounter` summing, callsign dedup, membership scoping, retain logic,
  and the `relay_ble_frame` exclusion special-casing for `demo`.

## Phases

1. **peat-ffi core** — `automerge` dep + counter module (init/load/save/increment/
   merge/value) + unit tests: (a) two docs increment concurrently → merge → sum;
   (b) merging the same bytes twice is idempotent; (c) survives reload.
2. **FFI exports** — UniFFI methods + Android JNI shims + Dart bindings
   (`peat_ffi.dart`, `peat_node.dart` facades).
3. **Transport wiring** — broadcast-on-increment + periodic snapshot; merge-on-
   receive; reuse the existing bridge + relay (the `"crdt"` frame tag).
4. **Dart UI swap** — single shared CRDT counter; rip out the interim counter.
5. **Build + deploy + test** — iOS xcframework + Android jniLibs; the doomsday
   3-node scenario should converge with zero special handling (increment on any
   device → all converge; kill/relay/dupe-tolerant).
6. **(Later) Generalize** — move into peat-mesh as Automerge-sync-over-peat-btle
   for cells/mission/commands too; per-peer capability negotiation; lite snapshot
   path retained only for microcontroller peers.

## Risks / decisions

- **automerge 0.9 API specifics** (`transact`, `Counter`, `merge`, `load/save`) —
  verified against the version peat-protocol already uses; confirm exact calls in Phase 1.
- **Doc history growth** — negligible for the demo; revisit compaction later.
- **"yours" semantic** — local tally only; the shared model has one pool total.
- **Coexistence with the lite path** — the counter moves OFF the `demo`
  lite collection onto the `crdt`/`supply` tag, so the two don't interfere.
