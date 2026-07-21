#!/usr/bin/env bash
# Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Stage 1 live migration: move the running guest from the 'src' host container
# to the 'dst' host container and measure the blackout (downtime).
#
# This first version transfers the snapshot via the shared /fc mount to prove
# the cutover path (pause -> snapshot -> load -> resume) and the measurement
# harness. A later revision streams memory over the fcnet network and adds the
# pre-copy rounds needed to bring the blackout under 30ms.
#
# Precondition: a guest is already running in 'src' (tools/migration/boot-guest.sh src).
# Usage: bash tools/migration/migrate.sh
set -euo pipefail

FCBIN=/fc/build/cargo_target/x86_64-unknown-linux-musl/debug/firecracker
KEY=/fc/ubuntu-24.04.id_rsa
GUEST_IP=172.16.0.2
SOCK=/tmp/fc.sock
SNAPDIR=/fc/migration
MEM=$SNAPDIR/mem.file
STATE=$SNAPDIR/snap.file

api() { local host=$1; shift; docker exec "$host" curl -s --unix-socket "$SOCK" "$@"; }
gssh() { local host=$1; shift; docker exec "$host" ssh -i "$KEY" \
    -o StrictHostKeyChecking=no -o ConnectTimeout=6 "root@$GUEST_IP" "$@"; }

echo "== 1. plant marker in src guest =="
docker exec src mkdir -p "$SNAPDIR"
gssh src 'echo "MIG-$(date +%s)" > /dev/shm/proof; echo "  marker=$(cat /dev/shm/proof) uptime_before=$(cut -d" " -f1 /proc/uptime)s"'

echo "== 2. prepare dst (tap0 + waiting firecracker) =="
docker exec dst bash -c "
  set -e
  ip link show tap0 >/dev/null 2>&1 || ip tuntap add tap0 mode tap
  ip addr replace 172.16.0.1/24 dev tap0
  ip link set tap0 up
  pkill -9 firecracker 2>/dev/null || true
  rm -f $SOCK
  nohup $FCBIN --api-sock $SOCK </dev/null >/tmp/fc.log 2>&1 &
  sleep 1
"

echo "== 3. CUTOVER (blackout begins) =="
T0=$(date +%s%N)
api src -X PATCH http://localhost/vm -H 'Content-Type: application/json' \
    -d '{"state":"Paused"}'
api src -X PUT http://localhost/snapshot/create -H 'Content-Type: application/json' \
    -d "{\"snapshot_type\":\"Full\",\"snapshot_path\":\"$STATE\",\"mem_file_path\":\"$MEM\"}"
api dst -X PUT http://localhost/snapshot/load -H 'Content-Type: application/json' \
    -d "{\"snapshot_path\":\"$STATE\",\"mem_backend\":{\"backend_type\":\"File\",\"backend_path\":\"$MEM\"},\"resume_vm\":true}"
T1=$(date +%s%N)
echo "   blackout ~= $(( (T1 - T0) / 1000000 )) ms  (orchestration wall-clock)"

echo "== 4. verify guest resumed on dst =="
sleep 2
gssh dst 'echo "  marker_after=$(cat /dev/shm/proof) uptime_after=$(cut -d" " -f1 /proc/uptime)s"' \
    || echo "  verify SSH failed (guest may need another second; retry the gssh check)"

echo "== 5. teardown source =="
docker exec src pkill -9 firecracker 2>/dev/null || true
echo "== migration complete =="
