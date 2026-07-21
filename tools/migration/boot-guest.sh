#!/usr/bin/env bash
# Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Boot the demo microVM inside one of the host containers (default: src).
# Sets up the guest TAP in the container's network namespace, launches
# Firecracker from the shared /fc mount, and verifies the guest is reachable
# over SSH. Run from the VM host:  bash tools/migration/boot-guest.sh src
set -euo pipefail

HOST="${1:-src}"
FCBIN=/fc/build/cargo_target/x86_64-unknown-linux-musl/debug/firecracker
KEY=/fc/ubuntu-24.04.id_rsa
GUEST_IP=172.16.0.2

echo "== booting guest in container '$HOST' =="
docker exec "$HOST" bash -c "
  set -e
  # Kill any stale VMM first and let it release tap0 before we reopen it.
  pkill -9 firecracker 2>/dev/null || true
  sleep 1
  ip link show tap0 >/dev/null 2>&1 || ip tuntap add tap0 mode tap
  ip addr replace 172.16.0.1/24 dev tap0
  ip link set tap0 up
  rm -f /tmp/fc.sock
  # stdin from /dev/null so the backgrounded VMM is not stopped by SIGTTIN.
  nohup $FCBIN --api-sock /tmp/fc.sock --config-file /fc/vm_config.json \
      </dev/null >/tmp/fc.log 2>&1 &
  sleep 4
  echo '--- fc log tail ---'; tail -n 5 /tmp/fc.log
"

echo "== ssh check =="
docker exec "$HOST" ssh -i "$KEY" \
    -o StrictHostKeyChecking=no -o ConnectTimeout=6 "root@$GUEST_IP" \
    'echo "GUEST-OK host=$(hostname) kernel=$(uname -r)"' \
    || echo "SSH FAILED (check /tmp/fc.log inside the container)"
