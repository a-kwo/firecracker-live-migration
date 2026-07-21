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

use serde::Serialize;

use crate::Vmm;

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
