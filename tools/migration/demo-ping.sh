#!/usr/bin/env bash
# Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# The "no interruption" demo: hold a continuous high-rate ping to the guest
# from the VM host (an external client on the bridge) while the guest live-
# migrates from src to dst, then report the largest inter-reply gap the client
# observed. That gap is the user-visible blackout.
#
# Precondition: a guest is running in 'src' (tools/migration/boot-guest.sh src).
# Usage: bash tools/migration/demo-ping.sh
set -euo pipefail

GUEST_IP=172.16.0.2
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PINGLOG=$(mktemp /tmp/mig-ping.XXXXXX)

echo "== starting continuous ping (5ms interval, timestamped) =="
sudo ping -D -i 0.005 "$GUEST_IP" > "$PINGLOG" 2>&1 &
PING_PID=$!
sleep 2   # steady-state before the migration

echo "== migrating while the ping runs =="
bash "$HERE/migrate.sh"

sleep 2   # steady-state after the migration
sudo kill "$PING_PID" 2>/dev/null || true
sleep 0.5

echo "== client-observed continuity =="
awk '
    /bytes from/ {
        ts = substr($1, 2, length($1) - 2) + 0
        if (prev > 0) {
            gap = (ts - prev) * 1000
            if (gap > max) max = gap
        }
        prev = ts
        n++
    }
    END {
        if (n < 2) { print "   not enough replies captured"; exit 1 }
        printf "   replies: %d   largest inter-reply gap: %.1f ms\n", n, max
    }
' "$PINGLOG"
echo "   (steady-state interval is 5 ms; the gap above includes one interval)"
echo "   ping log: $PINGLOG"
