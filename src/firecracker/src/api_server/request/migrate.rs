// Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

use vmm::rpc_interface::VmmAction;

use super::super::parsed_request::{ParsedRequest, RequestError};

/// Parses `GET /migrate`, returning migration-relevant status for the running
/// microVM (guest memory size and whether dirty-page tracking is enabled).
pub(crate) fn parse_get_migrate() -> Result<ParsedRequest, RequestError> {
    Ok(ParsedRequest::new_sync(VmmAction::GetMigrationStatus))
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
}
