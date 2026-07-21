#!/usr/bin/env bash
# Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Boot the demo microVM in the 'src' host container. The guest taps live on the
# host bridge (created by setup-hosts.sh), so there is no per-container network
# setup here: Firecracker just attaches to tap_src via the config. The API
# socket goes on the shared /fc mount so the cutover can drive both hosts from a
# single process. Run from the VM host:  bash tools/migration/boot-guest.sh src
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
