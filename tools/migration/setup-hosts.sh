#!/usr/bin/env bash
# Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Stand up the two "hosts" for the live-migration demo: a user-defined bridge
# network and two containers (src, dst), each with access to /dev/kvm and the
# Firecracker build/artifacts bind-mounted at /fc. Idempotent: safe to re-run.
set -euo pipefail

NET=fcnet
IMAGE=fc-host
FC_DIR="${FC_DIR:-$HOME/firecracker}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== building $IMAGE image =="
docker build -q -t "$IMAGE" "$HERE" >/dev/null

echo "== (re)creating network $NET =="
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# RAM-backed scratch shared by both hosts for the migration image. Keeping the
# snapshot state/memory files on tmpfs makes the cutover fsync instant, which
# matters because that fsync sits inside the blackout window.
MIGTMP=/dev/shm/fcmig
mkdir -p "$MIGTMP"
echo "== shared migration tmpfs at $MIGTMP -> /mig =="

start_host() {
    local name="$1"
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" \
        --network "$NET" \
        --device /dev/kvm \
        --device /dev/net/tun \
        --cap-add NET_ADMIN \
        -v "$FC_DIR:/fc" \
        -v "$MIGTMP:/mig" \
        -w /fc \
        "$IMAGE" sleep infinity >/dev/null
    local ip
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name")
    # Verify KVM is reachable from inside the container.
    if docker exec "$name" test -c /dev/kvm; then
        echo "  $name  ip=$ip  /dev/kvm=OK"
    else
        echo "  $name  ip=$ip  /dev/kvm=MISSING" >&2
        return 1
    fi
}

echo "== starting hosts =="
start_host src
start_host dst

echo "== done =="
echo "src -> $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' src)"
echo "dst -> $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dst)"
echo
echo "Enter a host with:  docker exec -it src bash   (or dst)"
