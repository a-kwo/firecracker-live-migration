# CLAUDE.md

Guidance for working in this repository.

## Project Outline

**Task.** Using Firecracker microVM, implement a Live VM Migration API and
demonstrate a successful live VM migration. The total amount of blackout time
that the VMs experience must be less than or equal to 30ms.

**Objective.** Clone Firecracker, run two concurrent hosts (e.g. Docker
instances), spawn two VMs from Firecracker on the hosts, and show that you can
successfully perform a live VM migration in under 30ms without interrupting the
user experience.

**Environment.** Part of this challenge is to find suitable software or hardware
in order to virtualize correctly.

**Submission.** Record a video (≤120 seconds, unlisted YouTube) walking through
what was built, and share the source in a private GitHub repo with user
`dedalus-ai`. Coding style and professional software-engineering etiquette are a
large part of the evaluation — only submit complete, high-quality work. Submit
via the provided Google Form.

**AI Policy.** AI use is allowed and encouraged; document exactly how AI was
used.

## Working Notes for This Challenge

- The 30ms budget is **blackout (downtime) time**, not total migration time.
  This points at a **pre-copy / diff-snapshot** live-migration design: transfer
  the bulk of guest memory while the source VM keeps running, then pause, ship
  only the final dirty delta + device state, and resume on the destination.
- Firecracker has **no built-in live migration**. It has snapshot/restore, which
  is the foundation to build on. The core primitives already exist:
  - `src/vmm/src/persist.rs` — `create_snapshot`, `restore_from_snapshot`,
    `snapshot_state_sanity_check`. Supports **full and diff snapshots**
    (dirty-page tracking via KVM), which is the key to keeping blackout low.
  - `src/vmm/src/snapshot/` — snapshot serialization/versioning format.
  - `src/vmm/src/vstate/memory.rs` — guest memory, dirty bitmap.
  - `docs/snapshotting/snapshot-support.md` — snapshot/restore user + design doc.
  - `docs/snapshotting/network-for-clones.md`,
    `docs/snapshotting/random-for-clones.md`,
    `docs/snapshotting/handling-page-faults-on-snapshot-resume.md` — the gotchas
    when resuming a clone (network/TCP state, RNG, lazy page faulting via
    userfaultfd). Relevant because a migrated VM is effectively a clone.
- The API surface to extend lives in `src/firecracker/src/api_server/request/`
  (see `snapshot.rs`) and is wired through `src/vmm/src/rpc_interface.rs`.
- Running "two concurrent hosts" → two Docker containers, each running a
  Firecracker process, with a memory/state channel between source and dest.

## What Firecracker Is

An AWS open-source **VMM written in Rust** that uses Linux **KVM** to run
lightweight "microVMs" (VM isolation + container speed/density). Each
Firecracker **process runs exactly one microVM**. Threads per process:

- **API thread** — in-process HTTP control plane (never in the VM fast path).
- **VMM thread** — machine model, legacy + VirtIO devices, MMDS, I/O rate limit.
- **vCPU thread(s)** — one per guest core, running the `KVM_RUN` loop. Treated as
  untrusted/malicious from the moment they start; contained via seccomp + jailer.

## Repository Map

Rust workspace; members are `src/*` (see `Cargo.toml`). LOC is concentrated in
`vmm`.

| Crate | Role |
|-------|------|
| **`src/vmm`** | The core — VM state, devices, snapshotting, MMDS. ~100k LOC. |
| `src/firecracker` | Main binary: CLI + HTTP API server, wraps `vmm`. |
| `src/jailer` | Production launcher; sandboxes FC (cgroups, namespaces, chroot). Excluded from default build members (needs static musl link). |
| `src/acpi-tables` | ACPI table generation. |
| `src/cpu-template-helper` | CPU template tooling. |
| `src/seccompiler` | Compiles seccomp JSON filters → BPF. |
| `src/snapshot-editor`, `src/rebase-snap` | Snapshot manipulation tools. |
| `src/utils`, `src/log-instrument*`, `src/clippy-tracing` | Support/tooling. |

### Inside `src/vmm/src/`

- `builder.rs` — assembles a microVM from config; the boot flow.
- `vstate/` — `kvm.rs`, `vm.rs`, `vcpu.rs`, `memory.rs`, `bus.rs`, `interrupts.rs`.
- `devices/` — `virtio/` (block, net, vsock, balloon, rng, mem, pmem, vhost-user),
  `legacy/` (serial, i8042), `pci/`, `acpi/`, `pseudo/`.
- `device_manager/` — MMIO/PCI bus wiring + device persistence.
- `persist.rs` + `snapshot/` — snapshot/restore.
- `mmds/` + `dumbo/` — metadata service + its minimal TCP/IP stack.
- `rpc_interface.rs` + `resources.rs` — API request ↔ VM config glue.
- `cpu_config/` + `arch/` — per-arch (x86_64 / aarch64) CPU templates, boot setup.
- `rate_limiter/`, `io_uring/`, `seccomp.rs`, `gdb/` — supporting subsystems.

### Binary & API — `src/firecracker/src/`

`main.rs` parses args, sets up logging/metrics/seccomp, runs with or without the
API server. `api_server/request/` has one file per API resource (drive, net,
vsock, balloon, snapshot, boot_source, machine_configuration, mmds, hotplug/…) —
the REST surface used to configure a microVM before `InstanceStart`.

## Build, Test, Run

Development happens **inside a Docker dev container** driven by `tools/devtool`.
Toolchain is pinned (`rust-toolchain.toml`, currently `1.97.0`); target is
**musl static** (`<arch>-unknown-linux-musl`).

```bash
tools/devtool build            # build in dev container
# binary → build/cargo_target/<arch>-unknown-linux-musl/debug/firecracker
tools/devtool test             # run integration tests
```

- Integration tests: `tests/` (pytest — `integration_tests/`, `framework/`,
  `host_tools/`).
- CI: `.buildkite/`.
- Note the host here is **Windows / PowerShell**; Firecracker itself requires a
  **Linux + KVM** host, so builds/runs go through Docker/Linux.

## Conventions & Etiquette

- Match surrounding code style; keep changes minimal and idiomatic. Workspace
  lints are strict (see `[workspace.lints]` in `Cargo.toml`: undocumented unsafe,
  cast truncation/wrap/sign-loss all `warn`). New `unsafe` needs a `// SAFETY:`
  comment.
- Every source file carries the Amazon/SPDX Apache-2.0 header — replicate it in
  new files.
- Errors use `thiserror` + `displaydoc` (see the `enum ... Error` patterns).
- Commit messages follow the repo's conventional style (`feat(...)`,
  `test(...)`, `docs(...)`; see `git log`) and are linted (`.gitlint`).
- Update `CHANGELOG.md` for user-facing changes.
- Because etiquette is graded: keep commits focused and well-described, keep the
  new migration code cohesive (ideally a clearly-scoped module + API endpoint),
  and document the design.
