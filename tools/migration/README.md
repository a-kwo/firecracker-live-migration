# Live VM Migration Demo

This directory contains the demo harness for the live-migration support added
to Firecracker in this fork: a running microVM is moved between two hosts with
a blackout (guest downtime) consistently around **22 ms** — within a 30 ms
budget — while an external client pings it 1,000 times per second.

```
  ---------------------------------------------------
   Live VM migration: src -> dst
  ---------------------------------------------------
   VM blackout (pause -> resume)      22.3 ms
   30 ms budget                       PASS
   Client probes answered             8646 of 8648 (99.98%)
  ---------------------------------------------------
```

See [docs/live-migration.md](../../docs/live-migration.md) for the design and
its rationale. The Firecracker-side changes live in
[`src/vmm/src/migration/`](../../src/vmm/src/migration/mod.rs).

## How it works

Firecracker upstream has snapshot/restore but no live migration. This fork adds
a **pre-copy** migration built on the existing diff-snapshot and KVM
dirty-page-tracking primitives:

1. **Pre-copy (guest running).** A new `PUT /migrate` API dumps guest memory
   *without pausing the vCPUs*. The full pass streams in 32 MiB chunks so the
   VMM thread keeps servicing virtio between chunks (a monolithic dump would
   stall guest networking); dirty-only rounds then re-send just the pages the
   guest wrote, shrinking the remaining delta each round.
2. **Cutover (the blackout).** Pause the vCPUs, take a `Diff` snapshot (final
   dirty pages + device state, a few MiB at most), load it on the destination
   Firecracker with `resume_vm=true`, retargeting the guest NIC to the
   destination's tap via `network_overrides`. Measured pause→resume:
   ~22 ms (pause ~0.3 ms, snapshot create ~16 ms, load+resume ~6 ms, from
   Firecracker's own request timings).
3. **Network continuity.** Both taps sit on one L2 bridge with a pinned
   gateway MAC; the bridge's learned entry for the guest MAC is dropped during
   the freeze, so the first post-resume frame floods and reaches the guest on
   its new tap immediately. The guest keeps its MAC, IP, and open connections.

## API additions

| Endpoint | Purpose |
|---|---|
| `GET /migrate` | Migration-relevant status: guest memory size, dirty-page tracking state. |
| `PUT /migrate` | Dump guest memory without pausing: `snapshot_type` `Full` or `Diff`, optional `offset`/`len` byte range for chunked full passes. |

The cutover itself reuses the existing `PATCH /vm` (pause),
`PUT /snapshot/create` (diff), and `PUT /snapshot/load` APIs.

## Files

| File | Role |
|---|---|
| `setup-hosts.sh` | Builds the host image and stands up the two "hosts": containers `src` and `dst` with `/dev/kvm`, a shared L2 bridge (`br-mig`) with one guest tap per host, and a shared tmpfs for the migration image. |
| `boot-guest.sh` | Boots the demo guest (1 vCPU, 1 GiB, `track_dirty_pages`) inside a host container and verifies it over SSH. |
| `migrate.py` | The migration orchestrator, run inside `src`: pre-copy rounds, then the timed cutover. A single long-lived process, so no subprocess startup lands inside the blackout window. |
| `migrate.sh` | Host-side wrapper: prepares the destination Firecracker, runs the orchestrator, surfaces Firecracker's internal timings, verifies the guest on `dst`. |
| `demo-ping.sh` | The end-to-end demo: continuous 1 ms-interval ping from the host while the migration runs, then a summary of the blackout against budget and probes answered. |
| `vm_config.json` | The demo guest configuration. |
| `Dockerfile` | Minimal image for the host containers. |

## Running it

Requirements: a Linux host with KVM (`/dev/kvm`) — e.g. a GCP instance created
with `--enable-nested-virtualization` — plus Docker, and a Firecracker build in
this repo (`tools/devtool build`). Guest kernel, rootfs, and SSH key are
fetched per [docs/getting-started.md](../../docs/getting-started.md) and
expected at the repo root (`vmlinux-*`, `ubuntu-*.ext4`, `ubuntu-*.id_rsa`).

```bash
tools/migration/setup-hosts.sh    # two hosts + bridge + shared scratch
tools/migration/boot-guest.sh src # boot the guest on host A
tools/migration/demo-ping.sh      # migrate A -> B under a live ping
```

Correctness is verified on every run: a marker written to the guest's RAM
(`/dev/shm`) before migration must read back identically on the destination,
and the guest's uptime must continue rather than reset — i.e. the same running
kernel, resumed on the other host.

## Notable correctness details

Two subtle issues surfaced while building this, both fixed in the Firecracker
changes:

- **Dirty-tracking reset ordering.** A full memory dump taken while vCPUs run
  must reset dirty tracking *before* dumping, not after — otherwise pages
  written during the dump have their dirty bits cleared without ever being
  re-sent, and the destination resumes with stale memory (observed as guest
  heap corruption and a kernel panic seconds after resume).
- **Virtio queue memory.** Queue rings are written by the VMM, not the guest,
  so KVM's dirty log never marks them; each unpaused dump must mark them dirty
  afterwards (as `create_snapshot` does) or the destination's queues fall out
  of sync with the restored device state.
