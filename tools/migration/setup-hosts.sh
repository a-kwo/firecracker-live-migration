#!/usr/bin/env bash
# Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Stand up the two "hosts" for the live-migration demo plus the shared L2 fabric
# a live client rides across the move.
#
# A bridge (br-mig, 172.16.0.1/24) lives in the host network namespace with two
# guest taps on it (tap_src, tap_dst). The two containers (src, dst) run with
# --network host so their Firecracker processes attach to those taps, putting
# both guests on the same L2 segment as the client. At cutover the bridge simply
# relearns which port the guest's MAC is on, so a client pinging 172.16.0.2 keeps
# working across the migration. Idempotent: safe to re-run.
set -euo pipefail

NET_BRIDGE=br-mig
IMAGE=fc-host
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Repo root (this script lives in tools/migration/); override with FC_DIR.
FC_DIR="${FC_DIR:-$(cd "$HERE/../.." && pwd)}"
MIGTMP=/dev/shm/fcmig

echo "== building $IMAGE image =="
docker build -q -t "$IMAGE" "$HERE" >/dev/null

echo "== host bridge $NET_BRIDGE + guest taps (tap_src, tap_dst) =="
# Remove the legacy single-host tap if present: it carried the same
# 172.16.0.1/24 and would steal the route from the bridge.
sudo ip link del tap0 2>/dev/null || true
sudo ip link add "$NET_BRIDGE" type bridge 2>/dev/null || true
# No STP and no forwarding delay: new ports must pass traffic immediately so
# cutover reconvergence stays in the milliseconds.
sudo ip link set "$NET_BRIDGE" type bridge forward_delay 0 stp_state 0
# Pin the bridge (guest gateway) MAC so the guest's cached gateway ARP entry
# stays valid across the move.
sudo ip link set "$NET_BRIDGE" address 06:00:ac:10:00:01
sudo ip addr replace 172.16.0.1/24 dev "$NET_BRIDGE"
sudo ip link set "$NET_BRIDGE" up
for tap in tap_src tap_dst; do
    sudo ip link show "$tap" >/dev/null 2>&1 || sudo ip tuntap add "$tap" mode tap
    sudo ip link set "$tap" master "$NET_BRIDGE"
    sudo ip link set "$tap" up
done

# RAM-backed scratch shared by both hosts for the migration image (fast fsync).
mkdir -p "$MIGTMP"
echo "== shared migration tmpfs at $MIGTMP -> /mig =="

start_host() {
    local name="$1"
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" \
        --init \
        --network host \
        --device /dev/kvm \
        --device /dev/net/tun \
        --cap-add NET_ADMIN \
        -v "$FC_DIR:/fc" \
        -v "$MIGTMP:/mig" \
        -w /fc \
        "$IMAGE" sleep infinity >/dev/null
    if docker exec "$name" test -c /dev/kvm; then
        echo "  $name  /dev/kvm=OK"
    else
        echo "  $name  /dev/kvm=MISSING" >&2
        return 1
    fi
}

echo "== starting hosts (shared host network) =="
start_host src
start_host dst

echo "== done =="
echo "Client gateway/bridge: 172.16.0.1 (br-mig).  Guest will be 172.16.0.2."
echo "Ping the guest from the VM host with:  ping 172.16.0.2"
