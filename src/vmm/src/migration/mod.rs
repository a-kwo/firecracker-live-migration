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

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::Vmm;
use crate::persist::CreateSnapshotError;
use crate::vmm_config::snapshot::SnapshotType;

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
}

/// Errors that can occur during a migration operation.
#[derive(Debug, thiserror::Error, displaydoc::Display)]
pub enum MigrationError {
    /// Migration requires a KVM-backed VM.
    NotKvmVm,
    /// Failed to dump guest memory: {0}
    DumpMemory(#[from] CreateSnapshotError),
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
    kvm_vm.snapshot_memory_to_file(&params.memory_path, params.snapshot_type)?;
    Ok(())
}
