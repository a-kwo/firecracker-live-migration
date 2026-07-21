#!/usr/bin/env bash
# Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pre-copy live migration: move the running guest from 'src' to 'dst' with a
# blackout small enough to be imperceptible.
#
# Host-side orchestration only: prepare the destination Firecracker, run the
# in-container orchestrator (migrate.py) that does the pre-copy and the timed
# cutover, surface the firecracker-internal timings, and verify the guest.
#
# Precondition: a guest is running in 'src' (tools/migration/boot-guest.sh src).
# Usage: [ROUNDS=3] bash tools/migration/migrate.sh
set -euo pipefail

KEY=/fc/ubuntu-24.04.id_rsa
GUEST_IP=172.16.0.2
DST_SOCK=/fc/dst.sock
FCBIN=/fc/build/cargo_target/x86_64-unknown-linux-musl/debug/firecracker
ROUNDS=${ROUNDS:-3}

echo "== prepare dst (tap0 + waiting firecracker on /fc/dst.sock) =="
docker exec dst bash -c "
  pkill -9 firecracker 2>/dev/null || true; sleep 1
  ip link show tap0 >/dev/null 2>&1 || ip tuntap add tap0 mode tap
  ip addr replace 172.16.0.1/24 dev tap0
  ip link set tap0 up
  rm -f $DST_SOCK
  nohup $FCBIN --api-sock $DST_SOCK </dev/null >/tmp/fc.log 2>&1 &
  sleep 1
"

echo "== pre-copy + cutover (orchestrator inside src) =="
docker exec src python3 /fc/tools/migration/migrate.py "$ROUNDS"

echo "== firecracker-internal timings (exclude orchestration overhead) =="
docker exec src grep "API request took" /tmp/fc.log | tail -3 | sed 's/^/   src: /'
docker exec dst grep "API request took" /tmp/fc.log | tail -1 | sed 's/^/   dst: /'

echo "== verify guest resumed on dst =="
sleep 2
docker exec dst ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=6 "root@$GUEST_IP" \
    'echo "  marker_after=$(cat /dev/shm/proof) uptime_after=$(cut -d" " -f1 /proc/uptime)s"' \
    || echo "  verify SSH failed (retry after ARP settles)"

echo "== teardown source =="
docker exec src pkill -9 firecracker 2>/dev/null || true
echo "== migration complete =="
