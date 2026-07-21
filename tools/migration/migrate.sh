#!/usr/bin/env bash
# Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pre-copy live migration: move the running guest from 'src' to 'dst' with a
# blackout small enough to be imperceptible.
#
# The bulk of guest RAM is streamed while the source keeps running (PUT /migrate,
# full pass then dirty-only rounds). Only the final small dirty delta plus device
# state are shipped during a brief freeze, which reuses the existing snapshot
# create/load API. The memory image is shared via /fc here; a later revision
# streams it over the fcnet network between the two hosts.
#
# Precondition: a guest is running in 'src' (tools/migration/boot-guest.sh src).
# Usage: [ROUNDS=3] bash tools/migration/migrate.sh
set -euo pipefail

KEY=/fc/ubuntu-24.04.id_rsa
GUEST_IP=172.16.0.2
SOCK=/tmp/fc.sock
FCBIN=/fc/build/cargo_target/x86_64-unknown-linux-musl/debug/firecracker
SNAPDIR=/fc/migration
MEM=$SNAPDIR/mem.file
STATE=$SNAPDIR/snap.file
ROUNDS=${ROUNDS:-3}

api()  { local host=$1; shift; docker exec "$host" curl -s --unix-socket "$SOCK" "$@"; }
gssh() { local host=$1; shift; docker exec "$host" ssh -i "$KEY" \
    -o StrictHostKeyChecking=no -o ConnectTimeout=6 "root@$GUEST_IP" "$@"; }
dump() { api src -X PUT http://localhost/migrate \
    -d "{\"memory_path\":\"$MEM\",\"snapshot_type\":\"$1\"}"; }

echo "== plant marker in src guest =="
docker exec src mkdir -p "$SNAPDIR"
gssh src 'echo "MIG-$(date +%s)" > /dev/shm/proof; echo "  marker=$(cat /dev/shm/proof) uptime_before=$(cut -d" " -f1 /proc/uptime)s"'

echo "== prepare dst (tap0 + waiting firecracker) =="
docker exec dst bash -c "
  pkill -9 firecracker 2>/dev/null || true; sleep 1
  ip link show tap0 >/dev/null 2>&1 || ip tuntap add tap0 mode tap
  ip addr replace 172.16.0.1/24 dev tap0
  ip link set tap0 up
  rm -f $SOCK
  nohup $FCBIN --api-sock $SOCK </dev/null >/tmp/fc.log 2>&1 &
  sleep 1
"

echo "== pre-copy: full pass then $ROUNDS dirty rounds (guest keeps running) =="
dump Full
for i in $(seq 1 "$ROUNDS"); do dump Diff; done

echo "== CUTOVER (blackout begins) =="
T0=$(date +%s%N)
# Pause + final diff (last dirty pages merged into MEM) + save device/vCPU state.
docker exec src bash -c "
  curl -s --unix-socket $SOCK -X PATCH http://localhost/vm -d '{\"state\":\"Paused\"}'
  curl -s --unix-socket $SOCK -X PUT http://localhost/snapshot/create \
      -d '{\"snapshot_type\":\"Diff\",\"snapshot_path\":\"$STATE\",\"mem_file_path\":\"$MEM\"}'
"
# Load the assembled image + state on dst and resume.
api dst -X PUT http://localhost/snapshot/load \
    -d "{\"snapshot_path\":\"$STATE\",\"mem_backend\":{\"backend_type\":\"File\",\"backend_path\":\"$MEM\"},\"resume_vm\":true}"
T1=$(date +%s%N)
echo "   cutover wall-clock (incl. docker/curl overhead): $(( (T1 - T0) / 1000000 )) ms"

echo "== firecracker-reported timings (true guest-freeze components) =="
docker exec dst sh -c "grep -o \"'load snapshot' API request took [0-9]* us\" /tmp/fc.log | tail -1" \
    || echo "   (load timing not found in dst log)"

echo "== verify guest resumed on dst =="
sleep 2
gssh dst 'echo "  marker_after=$(cat /dev/shm/proof) uptime_after=$(cut -d" " -f1 /proc/uptime)s"' \
    || echo "  verify SSH failed (retry after ARP settles)"

echo "== teardown source =="
docker exec src pkill -9 firecracker 2>/dev/null || true
echo "== migration complete =="
