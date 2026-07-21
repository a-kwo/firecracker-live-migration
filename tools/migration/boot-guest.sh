#!/usr/bin/env bash
# Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Boot the demo microVM inside one of the host containers (default: src).
# Sets up the guest TAP in the container's network namespace, launches
# Firecracker from the shared /fc mount, and verifies the guest is reachable
# over SSH. Run from the VM host:  bash tools/migration/boot-guest.sh src
#
# The API socket is placed on the shared /fc mount (/fc/<host>.sock) so the
# cutover can drive both source and destination from a single process, keeping
# orchestration overhead out of the blackout window.
set -euo pipefail

HOST="${1:-src}"
FCBIN=/fc/build/cargo_target/x86_64-unknown-linux-musl/debug/firecracker
KEY=/fc/ubuntu-24.04.id_rsa
GUEST_IP=172.16.0.2
SOCK="/fc/$HOST.sock"

echo "== booting guest in container '$HOST' =="
docker exec "$HOST" bash -c "
  set -e
  pkill -9 firecracker 2>/dev/null || true
  sleep 1
  ip link show tap0 >/dev/null 2>&1 || ip tuntap add tap0 mode tap
  # Pin a fixed TAP (gateway) MAC identical on both hosts, so the guest's cached
  # gateway ARP entry stays valid across the migration.
  ip link set tap0 address 06:00:ac:10:00:01
  ip addr replace 172.16.0.1/24 dev tap0
  ip link set tap0 up
  rm -f $SOCK
  # stdin from /dev/null so the backgrounded VMM is not stopped by SIGTTIN.
  nohup $FCBIN --api-sock $SOCK --config-file /fc/tools/migration/vm_config.json \
      </dev/null >/tmp/fc.log 2>&1 &
  sleep 4
  echo '--- fc log tail ---'; tail -n 5 /tmp/fc.log
"

echo "== ssh check =="
docker exec "$HOST" ssh -i "$KEY" \
    -o StrictHostKeyChecking=no -o ConnectTimeout=6 "root@$GUEST_IP" \
    'echo "GUEST-OK host=$(hostname) kernel=$(uname -r)"' \
    || echo "SSH FAILED (check /tmp/fc.log inside the container)"
