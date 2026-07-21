// Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

use vmm::migration::MigrateMemoryParams;
use vmm::rpc_interface::VmmAction;

use super::super::parsed_request::{ParsedRequest, RequestError};
use super::super::request::Body;

/// Parses `GET /migrate`, returning migration-relevant status for the running
/// microVM (guest memory size and whether dirty-page tracking is enabled).
pub(crate) fn parse_get_migrate() -> Result<ParsedRequest, RequestError> {
    Ok(ParsedRequest::new_sync(VmmAction::GetMigrationStatus))
}

/// Parses `PUT /migrate`, dumping guest memory for a pre-copy migration round
/// (full or dirty-only) to the requested path without pausing the vCPUs.
pub(crate) fn parse_put_migrate(body: &Body) -> Result<ParsedRequest, RequestError> {
    let params = serde_json::from_slice::<MigrateMemoryParams>(body.raw())?;
    Ok(ParsedRequest::new_sync(VmmAction::MigrateMemory(params)))
}

#[cfg(test)]
mod tests {
    use super::super::super::parsed_request::RequestAction;
    use super::*;

    #[test]
    fn test_parse_get_migrate_request() {
        match parse_get_migrate().unwrap().into_parts() {
            (RequestAction::Sync(action), _) if *action == VmmAction::GetMigrationStatus => {}
            _ => panic!("Test failed."),
        }
    }

    #[test]
    fn test_parse_put_migrate_request() {
        let body = r#"{ "memory_path": "/tmp/mem.file", "snapshot_type": "Full" }"#;
        assert!(parse_put_migrate(&Body::new(body)).is_ok());
        // Missing required `memory_path` must be rejected.
        assert!(parse_put_migrate(&Body::new(r#"{ "snapshot_type": "Diff" }"#)).is_err());
    }
}
