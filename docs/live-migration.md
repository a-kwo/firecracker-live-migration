# Live VM Migration — Design

## Goal

Move a **running** Firecracker microVM from a source host to a destination host
while the guest keeps executing, such that the observable **blackout (downtime)
is ≤ 30 ms** and in-flight client activity (e.g. a continuous ping, an open SSH
session) is not interrupted.

"Two hosts" = two Docker containers, each with `/dev/kvm`, on one KVM-capable
Linux machine (a GCP instance with nested virtualization in the demo). "Two
VMs" = the **source** and **destination** Firecracker instances of the *same*
guest: migration is one-directional — the guest moves source → destination and
the source is torn down after cutover.

**Result: ~22 ms blackout, measured pause→resume, with 99.98% of a
1,000/sec client ping stream answered across the move.** See
[tools/migration/README.md](../tools/migration/README.md) for how to run it.

## Strategy: pre-copy on top of diff snapshots

Firecracker has snapshot/restore but no migration. Its existing
**diff-snapshot + dirty-page-tracking** machinery is, however, exactly the
primitive pre-copy migration needs: send memory while the guest runs, re-send
only what changed, then freeze briefly for the final delta.

```
 t │ SOURCE (running)                         DESTINATION
 ──┼────────────────────────────────────────────────────────────────
 0 │ full memory dump, in chunks ──────────►  memory image
 1 │ dirty pages since t0 ─────────────────►  merged in            ┐ guest
 2 │ dirty pages since t1 ─────────────────►  merged in            │ keeps
 . │ … repeat until the dirty set is small …                       ┘ running
 ──┼────────────────────────────────────────────────────────────── PAUSE ─┐
 N │ final dirty delta + device state ─────►  load snapshot,               │ ~22ms
   │                                          resume vCPUs                 │
 ──┼──────────────────────────────────────────────────────────────────────┘
   │ teardown                                 serving traffic
```

Everything expensive happens in rounds 0–N while the guest runs; only the final
small delta plus the (kilobytes of) device state sit inside the freeze.

## What was added vs. reused

**Added** (`src/vmm/src/migration/`, wired through `rpc_interface.rs` and the
API server):

- `GET /migrate` — migration-relevant status (memory size, whether
  `track_dirty_pages` is on).
- `PUT /migrate` — dump guest memory to a file **without pausing the vCPUs**:
  `snapshot_type: Full | Diff`, plus an optional `offset`/`len` byte range so
  the full pass can be streamed in chunks.

**Reused**: `snapshot_memory_to_file` (full/diff dump machinery),
`get_dirty_bitmap`/`reset_dirty_bitmap` (KVM dirty log), `PATCH /vm` pause,
`PUT /snapshot/create` (Diff) for the final delta + `MicrovmState`, and
`PUT /snapshot/load` with `network_overrides` + `resume_vm` on the destination.

Two correctness requirements of dumping while the guest runs (both bugs found
the hard way; see the demo README's "Notable correctness details"):

1. The Full dump must **reset dirty tracking before dumping**, so pages
   written concurrently with the dump stay marked and are re-sent later.
2. Each unpaused dump must **re-mark virtio queue memory dirty** (queues are
   VMM-written, invisible to KVM's dirty log).

## Why chunked, not a background thread

The dump runs synchronously on the VMM thread, which also services virtio; a
monolithic 1 GiB dump stalled guest networking for ~400 ms during pre-copy.
Chunking the full pass (32 MiB per `PUT /migrate` call, orchestrator yields
between calls) bounds each stall to ~10 ms — invisible to clients — while
avoiding the complexity and seccomp implications of spawning a runtime thread
that shares guest memory. Dirty rounds are naturally small and need no
chunking.

## Cutover and the 30 ms budget

The orchestrator (`tools/migration/migrate.py`) is one long-lived process, so
no subprocess startup lands inside the freeze. Measured budget on the demo
machine (Firecracker's own request timings):

| Step (inside the freeze) | Measured |
|---|---|
| `PATCH /vm` pause | ~0.3 ms |
| `PUT /snapshot/create` (Diff: final delta + state) | ~16 ms |
| `PUT /snapshot/load` + resume on destination | ~6–8 ms |
| **Total blackout (pause → resume)** | **~22 ms** |

Levers that keep it there: a converge dirty round immediately before the
freeze; the snapshot image on a shared tmpfs (fsync inside the freeze is
otherwise disk-bound); both API sockets reachable by the one orchestrator
process; a small final dirty set (idle-ish guest converges in 3–4 rounds).

## Network continuity

The guest's MAC/IP/TCP state are part of the snapshot, so the resumed guest
keeps its network identity. On the host side:

- Both hosts' taps (`tap_src`, `tap_dst`) sit on one L2 bridge with a **pinned
  bridge MAC** serving as the guest's gateway — the guest's cached gateway ARP
  entry stays valid across the move.
- The destination load retargets the guest NIC to `tap_dst` via
  `network_overrides`.
- During the freeze the bridge's learned entry for the guest MAC is deleted;
  the first post-resume frame floods to all ports and reaches the guest
  immediately, so reconvergence adds no measurable client-visible delay.
  Probes that arrive mid-freeze are buffered at the destination tap and are
  answered in a burst on resume — clients see one latency spike, not loss.

## Measurement methodology

- **Blackout** — wall-clock from issuing the pause to the load/resume call
  returning, measured inside the orchestrator; cross-checked against
  Firecracker's per-request `API request took` log lines on both sides.
- **Continuity** — an external client (the host) pings the guest at 1 ms
  intervals throughout; the demo reports probes answered. Correctness is
  checked every run: a RAM marker (`/dev/shm`) written before migration must
  read back identically on the destination, and guest uptime must continue.

## Possible future work

- Stream memory over a TCP channel between genuinely separate machines instead
  of a shared file (the API already separates the dump from its transport; the
  wire protocol is the missing piece).
- Lazy restore on the destination via the existing UFFD backend, removing the
  destination's memory-image write from the pre-copy path.
- Adaptive round control (converge on dirty-set size rather than a fixed round
  count) for write-heavy guests.
