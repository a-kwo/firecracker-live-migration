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
# create/load API.
#
# Both API sockets live on the shared /fc mount, so the entire cutover runs in a
# single container process — the true blackout (pause -> resume) is timed from
# inside that process, excluding docker/orchestration overhead that is not part
# of the guest's downtime in a production control plane.
#
# Precondition: a guest is running in 'src' (tools/migration/boot-guest.sh src).
# Usage: [ROUNDS=3] bash tools/migration/migrate.sh
set -euo pipefail

KEY=/fc/ubuntu-24.04.id_rsa
GUEST_IP=172.16.0.2
SRC_SOCK=/fc/src.sock
DST_SOCK=/fc/dst.sock
FCBIN=/fc/build/cargo_target/x86_64-unknown-linux-musl/debug/firecracker
SNAPDIR=/fc/migration
MEM=$SNAPDIR/mem.file
STATE=$SNAPDIR/snap.file
ROUNDS=${ROUNDS:-3}

gssh() { local host=$1; shift; docker exec "$host" ssh -i "$KEY" \
    -o StrictHostKeyChecking=no -o ConnectTimeout=6 "root@$GUEST_IP" "$@"; }
dump() { docker exec src curl -s --unix-socket "$SRC_SOCK" -X PUT http://localhost/migrate \
    -d "{\"memory_path\":\"$MEM\",\"snapshot_type\":\"$1\"}"; }

echo "== plant marker in src guest =="
docker exec src mkdir -p "$SNAPDIR"
gssh src 'echo "MIG-$(date +%s)" > /dev/shm/proof; echo "  marker=$(cat /dev/shm/proof) uptime_before=$(cut -d" " -f1 /proc/uptime)s"'

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

echo "== pre-copy: full pass then $ROUNDS dirty rounds (guest keeps running) =="
dump Full
for i in $(seq 1 "$ROUNDS"); do dump Diff; done

echo "== CUTOVER: pause src -> final diff+state -> load+resume dst (single process) =="
# Both sockets are visible on /fc inside the src container, so the pause and the
# resume happen back-to-back with no process spawn between them. Time the freeze
# from inside the container.
docker exec src bash -c "
  t0=\$(date +%s%N)
  curl -s --unix-socket $SRC_SOCK -X PATCH http://localhost/vm -d '{\"state\":\"Paused\"}'
  curl -s --unix-socket $SRC_SOCK -X PUT http://localhost/snapshot/create \
      -d '{\"snapshot_type\":\"Diff\",\"snapshot_path\":\"$STATE\",\"mem_file_path\":\"$MEM\"}'
  curl -s --unix-socket $DST_SOCK -X PUT http://localhost/snapshot/load \
      -d '{\"snapshot_path\":\"$STATE\",\"mem_backend\":{\"backend_type\":\"File\",\"backend_path\":\"$MEM\"},\"resume_vm\":true}'
  t1=\$(date +%s%N)
  echo \"   TRUE BLACKOUT (pause -> resume): \$(( (t1 - t0) / 1000000 )) ms\"
"

echo "== verify guest resumed on dst =="
sleep 2
gssh dst 'echo "  marker_after=$(cat /dev/shm/proof) uptime_after=$(cut -d" " -f1 /proc/uptime)s"' \
    || echo "  verify SSH failed (retry after ARP settles)"

echo "== teardown source =="
docker exec src pkill -9 firecracker 2>/dev/null || true
echo "== migration complete =="
