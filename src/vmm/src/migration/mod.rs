// Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

//! Live migration of a running microVM between hosts.
//!
//! Live migration moves a running guest from a source host to a destination
//! host with a blackout (downtime) small enough to be imperceptible. It builds
//! on Firecracker's snapshot and dirty-page-tracking primitives using a
//! *pre-copy* strategy: guest memory is streamed to the destination while the
//! source keeps running, dirtied pages are re-sent over successive rounds, and
//! only the final small delta plus device state are shipped during a brief
//! freeze. See `docs/live-migration.md` for the full design.
//!
//! This module is being built incrementally. It currently exposes read-only
//! status used to size a migration and to confirm that dirty-page tracking is
//! enabled; the streaming and cutover machinery lands in subsequent changes.

use std::fs::OpenOptions;
use std::io::{Seek, SeekFrom};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use vm_memory::{GuestMemoryBackend, WriteVolatile};

use crate::persist::CreateSnapshotError;
use crate::utils::u64_to_usize;
use crate::vmm_config::snapshot::SnapshotType;
use crate::vstate::memory::GuestMemoryExtension;
use crate::vstate::vm::KvmVm;
use crate::{Vmm, mem_size_mib};

/// A point-in-time view of migration-relevant VM state, returned by
/// `GET /migrate`. Used to size a migration and to confirm that dirty-page
/// tracking — required for the pre-copy rounds — is enabled.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MigrationStatus {
    /// Configured guest memory size, in MiB.
    pub mem_size_mib: usize,
    /// Whether dirty-page tracking is enabled. Pre-copy migration requires it.
    pub track_dirty_pages: bool,
}

impl MigrationStatus {
    /// Collect the current migration status from a running [`Vmm`].
    pub fn from_vmm(vmm: &Vmm) -> MigrationStatus {
        MigrationStatus {
            mem_size_mib: vmm.machine_config.mem_size_mib,
            track_dirty_pages: vmm.machine_config.track_dirty_pages,
        }
    }
}

/// Parameters for a `PUT /migrate` pre-copy round.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct MigrateMemoryParams {
    /// Destination path for the guest memory image. For the initial `Full`
    /// pass the whole image is written; for subsequent `Diff` passes only the
    /// pages dirtied since the previous pass are merged into the existing file.
    pub memory_path: PathBuf,
    /// `Full` for the initial pre-copy pass, `Diff` for the dirty rounds.
    #[serde(default)]
    pub snapshot_type: SnapshotType,
    /// Optional start of a byte range in memory-image offsets. Only valid for
    /// `Full`, together with `len`: the full pass can then be streamed in
    /// chunks so the VMM thread keeps servicing device I/O between calls.
    /// Dirty tracking is reset by the chunk starting at offset 0.
    #[serde(default)]
    pub offset: Option<u64>,
    /// Length of the byte range; ranges past the end of memory are clamped, so
    /// callers can stream fixed-size chunks without sizing the tail exactly.
    #[serde(default)]
    pub len: Option<u64>,
}

/// Errors that can occur during a migration operation.
#[derive(Debug, thiserror::Error, displaydoc::Display)]
pub enum MigrationError {
    /// Migration requires a KVM-backed VM.
    NotKvmVm,
    /// Failed to dump guest memory: {0}
    DumpMemory(#[from] CreateSnapshotError),
    /// offset and len must be provided together, and only with snapshot_type Full.
    InvalidRange,
    /// Failed to access the memory image file: {0}
    ImageFile(std::io::Error),
    /// Failed to access guest memory for the requested range: {0}
    Volatile(vm_memory::VolatileMemoryError),
}

/// Dump guest memory to `params.memory_path` **without pausing the vCPUs**.
///
/// This is the source-side primitive for pre-copy migration: the bulk of guest
/// RAM is transferred while the guest keeps running (`Full`), and pages dirtied
/// since the previous round are merged in on later passes (`Diff`). Only the
/// final small delta plus device state are shipped during the brief cutover
/// freeze, which reuses the existing snapshot API.
///
/// Reading memory concurrently with the running vCPUs may capture torn pages;
/// those pages are re-dirtied and re-sent by a subsequent `Diff` round, so the
/// destination image converges to a consistent state before cutover.
pub fn dump_memory(vmm: &Vmm, params: &MigrateMemoryParams) -> Result<(), MigrationError> {
    let kvm_vm = vmm.vm.as_kvm().ok_or(MigrationError::NotKvmVm)?;
    match (params.snapshot_type, params.offset, params.len) {
        (SnapshotType::Full, Some(offset), Some(len)) => {
            // Chunked full pass. Reset dirty tracking before the first chunk so
            // every page written while the chunks stream stays marked dirty and
            // is re-sent by a later diff round.
            if offset == 0 {
                kvm_vm.reset_dirty_bitmap();
                kvm_vm.guest_memory().reset_dirty();
            }
            dump_memory_range(kvm_vm, &params.memory_path, offset, len)?;
        }
        (_, None, None) => {
            kvm_vm.snapshot_memory_to_file(&params.memory_path, params.snapshot_type)?;
        }
        _ => return Err(MigrationError::InvalidRange),
    }
    // Virtio queue memory is written by the VMM, not the guest, so KVM's dirty
    // log never marks it. Mark it dirty here — exactly as create_snapshot does —
    // so the next pre-copy round (or the cutover snapshot) re-sends it and the
    // destination's queue memory stays consistent with the device state.
    vmm.device_manager
        .mark_virtio_queue_memory_dirty(kvm_vm.guest_memory());
    Ok(())
}

/// Dump the byte range `[offset, offset + len)` of the guest memory image to
/// `path`, without pausing the vCPUs.
///
/// The range is expressed in memory-image offsets — the same layout
/// `snapshot_memory_to_file` produces (slots concatenated in guest address
/// order, unplugged slots left as holes). Ranges past the end of memory are
/// clamped.
fn dump_memory_range(
    kvm_vm: &KvmVm,
    path: &Path,
    offset: u64,
    len: u64,
) -> Result<(), MigrationError> {
    let total = mem_size_mib(kvm_vm.guest_memory()) * 1024 * 1024;
    let range_end = offset.saturating_add(len).min(total);
    if offset >= range_end {
        return Ok(());
    }

    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .map_err(MigrationError::ImageFile)?;
    // Establish the full image size up front so chunks can land at their final
    // offsets in any order.
    file.set_len(total).map_err(MigrationError::ImageFile)?;

    let mut slot_start: u64 = 0;
    for (mem_slot, plugged) in kvm_vm
        .guest_memory()
        .iter()
        .flat_map(|region| region.slots())
    {
        let slot_len = u64::try_from(mem_slot.slice.len()).unwrap();
        let start = offset.max(slot_start);
        let end = range_end.min(slot_start + slot_len);
        if plugged && start < end {
            let sub = mem_slot
                .slice
                .subslice(u64_to_usize(start - slot_start), u64_to_usize(end - start))
                .map_err(MigrationError::Volatile)?;
            file.seek(SeekFrom::Start(start))
                .map_err(MigrationError::ImageFile)?;
            file.write_all_volatile(&sub)
                .map_err(MigrationError::Volatile)?;
        }
        slot_start += slot_len;
    }
    Ok(())
}
