# Live VM Migration — Design

## Goal

Move a **running** Firecracker microVM from a source host to a destination host
while the guest keeps executing, such that the observable **blackout (downtime)
is ≤ 30 ms** and in-flight user activity (e.g. an open SSH session, a `ping`, an
HTTP request against a server in the guest) is not interrupted.

"Two hosts" = two Docker containers, each with `/dev/kvm`, on one KVM-capable
Linux machine. "Two VMs" = the **source** instance and the **destination**
instance of the *same* guest (see [`CLAUDE.md`](../CLAUDE.md)). Migration is
one-directional: source → destination; the source is torn down after cutover.

## Strategy: pre-copy migration on top of diff snapshots

Firecracker has snapshot/restore but **no migration**. The insight is that its
existing **diff-snapshot + dirty-page-tracking** machinery is exactly the
primitive pre-copy live migration needs: send memory while the guest runs,
re-send only what changed, then freeze briefly for the last delta.

```
 t │ SOURCE (running)                         DESTINATION
 ──┼────────────────────────────────────────────────────────────────
 0 │ full memory dump ─────────────────────►  write mem file
 1 │ diff round 1 (dirty since t0) ────────►  apply to mem file     ┐ guest
 2 │ diff round 2 (dirty since t1) ────────►  apply                 │ keeps
 . │ … converge until dirty set is small …                         ┘ running
 ──┼────────────────────────────────────────────────────────────── PAUSE ─┐
 N │ PAUSE vCPUs                                                           │ ≤30ms
   │ final diff + vCPU regs + device state ─►  apply + build microVM       │ blackout
   │                                           RESUME vCPUs + grat. ARP ◄──┘
 ──┼──────────────────────────────────────────────────────────────────────
   │ (teardown)                                serving traffic
```

Steps 0–2 carry the bulk of the cost with **zero downtime**. Only the final
round (a small dirty delta plus the tiny CPU/device state) sits on the critical
path, which is what keeps the freeze in the millisecond range.

## What already exists (reused, not rebuilt)

| Primitive | Where | Role in migration |
|---|---|---|
| `create_snapshot()` | `src/vmm/src/persist.rs:169` | Serialize microVM state + dump memory (full or diff). |
| `snapshot_memory_to_file()` | `src/vmm/src/vstate/vm.rs:572` | `Diff` path: `get_dirty_bitmap()` + `dump_dirty()` writes only dirty pages. |
| `get_dirty_bitmap()` / `reset_dirty_bitmap()` | `src/vmm/src/vstate/vm.rs:546` / `:536` | KVM `KVM_GET_DIRTY_LOG`. Requires `track_dirty_pages` at boot. The engine of each pre-copy round. |
| `GuestMemory::dump()` / `dump_dirty()` / `reset_dirty()` | `src/vmm/src/vstate/memory.rs:996`+ | Write full / dirty-only pages; reset the tracker between rounds. |
| `restore_from_snapshot()` | `src/vmm/src/persist.rs:365` | Rebuild a microVM from a state file + memory backend. |
| `build_microvm_from_snapshot(..., uffd: Option<Uffd>)` | `src/vmm/src/builder.rs:424` | Reconstruct devices/vCPUs and resume; accepts a UFFD handle. |
| `MemBackendType::{File, Uffd}` | `src/vmm/src/vmm_config/snapshot.rs` | **Uffd** backend = lazy, on-demand page loading → fast resume. |
| `network_overrides` / `vsock_override` | `src/vmm/src/persist.rs:371`+ | Rebind the guest NIC to a **different host TAP** on the destination — essential: the guest keeps its MAC/IP, only the host device changes. |
| API: `PUT /snapshot/create`, `PUT /snapshot/load`, `PATCH /vm {state}` | `src/firecracker/src/api_server/parsed_request.rs:111,126` | Existing control verbs we mirror/extend. |

The two features that make ≤30 ms feasible are **diff snapshots** (small final
payload) and the **UFFD backend** (destination resumes before all pages are
resident; the rest fault in from the already-transferred memory file).

## Architecture

Each host runs a Firecracker process plus a small **migration helper** that owns
the network transfer and the UFFD page-fault handling. Firecracker's threads
must not block on the network (see the API/VMM/vCPU thread split in
`docs/design.md`), so the transfer runs outside the VMM fast path.

```
   SOURCE CONTAINER                         DESTINATION CONTAINER
 ┌──────────────────────┐                 ┌──────────────────────────┐
 │ Firecracker (source) │                 │ Firecracker (destination)│
 │  API │ VMM │ vCPUs    │                 │   (pre-spawned, waiting) │
 │        │              │                 │            │  UFFD handle │
 │  migrate-send  ───────┼── TCP stream ──►┼─ migrate-recv → mem file │
 │  (reads diff bitmap)  │  (mem + state)  │  (UFFD page handler)     │
 └──────────────────────┘                 └──────────────────────────┘
          both TAPs attached to the same host bridge (br0)
```

- **Destination is pre-spawned** and parked before boot, waiting on
  `PUT /snapshot/load`. Paying boot cost at cutover would blow the budget.
- **UFFD handler** on the destination is seeded with all memory received during
  warm-up; at resume it serves faults instantly from local RAM/file, and the
  final dirty pages are applied just before `Resume`.

## Migration API

New verbs on Firecracker's existing API server (`src/firecracker/src/
api_server/request/`), wired through `rpc_interface.rs`. Kept symmetric with the
snapshot API so the code reuses `persist.rs`.

**Destination — arm the receiver** (before boot):
```
PUT /migrate
{ "role": "destination",
  "listen": "0.0.0.0:9899",
  "mem_backend": { "backend_type": "Uffd", "backend_path": "/run/mig.sock" } }
```
Reserves guest memory, starts `migrate-recv`, and blocks in the loader until the
source signals cutover.

**Source — start migrating** (VM running, booted with `track_dirty_pages`):
```
PATCH /migrate
{ "role": "source",
  "destination": "10.0.0.2:9899",
  "max_rounds": 8,
  "target_dirty_bytes": 1048576 }   // converge until final dirty set ≤ this
```
Drives the pre-copy loop, performs the freeze, ships the final delta, and (on
ack) exits `FcExitCode::Ok`.

**Status** (for the demo overlay / metrics):
```
GET /migrate  →  { "phase": "precopy|blackout|cutover|done",
                   "round": 3, "dirty_bytes": 812000, "blackout_ms": 11.4 }
```

## Migration protocol (source-driven)

1. **Handshake** — source connects to destination; exchange versions
   (`SNAPSHOT_VERSION`, `persist.rs:166`), guest config, memory size. Abort on
   mismatch (snapshots are not portable across incompatible layouts).
2. **Warm-up (full pass)** — source dumps all guest memory (`dump()`), streams
   it; destination writes the memory file and resets its dirty tracker. Guest
   still running.
3. **Iterative dirty rounds** — each round: `get_dirty_bitmap()` →
   `dump_dirty()` for only the dirtied pages → stream → `reset_dirty_bitmap()`.
   Repeat until `dirty_bytes ≤ target_dirty_bytes` or `max_rounds` reached
   (converge, or stop if the guest dirties faster than we can send).
4. **Freeze — start of blackout** — `PATCH /vm {state:"Paused"}` semantics: stop
   vCPUs. From here every microsecond counts against the 30 ms.
5. **Final delta** — one last `dump_dirty()` (now small) + serialized
   `MicrovmState` (vCPU regs, device state — kilobytes). Stream to destination.
6. **Cutover** — destination applies the final delta into the memory file,
   `build_microvm_from_snapshot(...)` with the UFFD backend, `Resume` vCPUs, and
   the guest emits a **gratuitous ARP** so the host bridge relearns the new TAP
   port. Guest is live. **End of blackout.**
7. **Ack + teardown** — destination acks; source releases the TAP and exits.

## Network cutover (why the user sees no interruption)

The guest's NIC state — MAC and IP — is part of the snapshot, so the resumed
guest believes it has the *same* network identity. Only the **host-side TAP
changes**, handled by `network_overrides` (`persist.rs:371`) which rebinds the
snapshot's NIC to the destination's TAP name.

For the demo, both containers' TAPs sit on the **same Linux bridge**, and the
guest keeps a fixed IP. At resume the guest sends a gratuitous ARP; the bridge
updates MAC → port; packets from the external `ping`/HTTP client now reach the
destination. TCP connections survive because IP/port/sequence state moved intact
with the memory snapshot — the peer just sees one slightly-delayed packet.

## Hitting the 30 ms budget

Only steps 4–6 count. Indicative budget (tune against measurements):

| Critical-path item | Target |
|---|---|
| Pause vCPUs (`KVM` exit) | < 1 ms |
| Final `dump_dirty()` (dirty set already tiny) | few ms |
| Serialize `MicrovmState` (KBs) | < 1 ms |
| Transfer final payload (local bridge/loopback) | few ms |
| `build_microvm_from_snapshot` + UFFD resume | few ms |
| Gratuitous ARP + first packet | < 1 ms |

Levers if we miss: lower `target_dirty_bytes` (more pre-copy rounds → smaller
final delta), keep the destination fully pre-built so only `Resume` is on the
path, and use UFFD so resume never waits on full memory residency. Measure
blackout as **last source packet → first destination packet**, reported via
`GET /migrate`.

## Code layout (new work)

- `src/vmm/src/migration/mod.rs` — orchestrator: pre-copy loop, freeze, cutover.
- `src/vmm/src/migration/transfer.rs` — wire protocol (framing of full/diff
  memory chunks + serialized `MicrovmState`) over a TCP stream.
- `src/vmm/src/migration/precopy.rs` — dirty-round driver over
  `get_dirty_bitmap()` / `dump_dirty()` / `reset_dirty_bitmap()`.
- Extend `rpc_interface.rs` with `MigrateSource` / `MigrateDestination` actions.
- `src/firecracker/src/api_server/request/migrate.rs` — parse `/migrate`.
- A UFFD page-fault handler (extend the pattern behind `MemBackendType::Uffd`;
  see `docs/snapshotting/handling-page-faults-on-snapshot-resume.md`).

Reuse `persist.rs` end to end — migration is "snapshot the source in diff rounds,
restore the destination lazily," with the file replaced by a socket.

## Prerequisites & gotchas

- Boot the source with **`track_dirty_pages: true`** — without it there is no
  dirty bitmap and no diff rounds (`machine_config.rs`).
- **Same CPU model / KVM / kernel** on both hosts (co-located containers satisfy
  this). Cross-CPU resume warns/fails — `validate_cpu_vendor`, `persist.rs:226`.
- Snapshot versions must match (`SNAPSHOT_VERSION`).
- Guest network/vsock may drop packets on resume; TCP recovers — see
  `docs/snapshotting/network-for-clones.md`,
  `docs/snapshotting/random-for-clones.md`. Entropy/`vsock` need the documented
  clone handling.
- Don't run transfer or UFFD work on the VMM thread; keep the fast path clean.

## Demo & measurement plan

1. `br0` bridge; two containers (`src`, `dst`) each with `/dev/kvm` and a TAP on
   `br0`. Destination Firecracker pre-spawned and armed via `PUT /migrate`.
2. Boot the guest on `src` with dirty tracking; run a workload (HTTP server or a
   counter) with a fixed guest IP.
3. External client runs `ping -i 0.01 <guest-ip>` (and/or a live `curl` loop /
   SSH counter) — this is the on-camera "not interrupted" proof.
4. `PATCH /migrate {role:"source", destination:"dst:9899"}`.
5. Show `GET /migrate` reporting `blackout_ms ≤ 30`, and the ping/HTTP stream
   surviving with at most one delayed packet as the guest jumps `src → dst`.

## Milestones

1. Bring up Docker + KVM + bridge; snapshot→restore across two containers via
   files (validate the environment end to end).
2. Replace the file hop with a socket transfer (full memory + state). Correct,
   not yet fast.
3. Add diff-round pre-copy + freeze/cutover; wire the `/migrate` API.
4. Add the UFFD lazy-resume backend on the destination.
5. Network cutover (gratuitous ARP, shared bridge); prove the client survives.
6. Optimize and instrument until blackout ≤ 30 ms; record the demo.
