#!/usr/bin/env bash
# Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# The "no interruption" demo: hold a continuous high-rate ping to the guest
# from the VM host (an external client on the bridge) while the guest live-
# migrates from src to dst, then print a summary of the blackout the VM
# experienced and the outage the client observed.
#
# The 1ms probe interval matters: the client can only resolve an outage to the
# probe grid, so the largest inter-reply gap reads roughly blackout + one
# interval (plus the guest's brief wake-up tail).
#
# Precondition: a guest is running in 'src' (tools/migration/boot-guest.sh src).
# Usage: bash tools/migration/demo-ping.sh
set -euo pipefail

GUEST_IP=172.16.0.2
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PINGLOG=$(mktemp /tmp/mig-ping.XXXXXX)
MIGLOG=$(mktemp /tmp/mig-out.XXXXXX)

echo "[1/3] starting continuous ping of $GUEST_IP (1000 probes/sec)"
sudo -v
# Fully detach the ping from this terminal (its own session, I/O on the log
# file only) so backgrounding sudo cannot garble the tty line discipline.
PING_PID=$(sudo sh -c "ping -D -i 0.001 $GUEST_IP </dev/null >'$PINGLOG' 2>&1 & echo \$!")
sleep 2   # steady-state before the migration

echo "[2/3] migrating src -> dst while the ping runs"
bash "$HERE/migrate.sh" 2>&1 | tee "$MIGLOG"

sleep 2   # steady-state after the migration
sudo kill "$PING_PID" 2>/dev/null || true
sleep 0.3
stty sane 2>/dev/null || true

echo
echo "[3/3] client-observed continuity"
BLACKOUT=$(grep -oE 'TRUE BLACKOUT \(pause -> resume\): [0-9.]+' "$MIGLOG" \
    | grep -oE '[0-9.]+' | tail -1 || true)

awk -v blackout="${BLACKOUT:-0}" '
    /bytes from/ {
        ts = substr($1, 2, length($1) - 2) + 0
        if (prev > 0) {
            gap = (ts - prev) * 1000
            if (gap > max) max = gap
        }
        prev = ts
        n++
        if (match($0, /icmp_seq=[0-9]+/)) {
            seq = substr($0, RSTART + 9, RLENGTH - 9) + 0
            if (seq > maxseq) maxseq = seq
        }
    }
    END {
        if (n < 2) { print "  not enough ping replies captured"; exit 1 }
        rule = "  ------------------------------------------------------"
        print rule
        print  "   Live VM migration: src -> dst"
        print rule
        printf "   VM blackout (pause -> resume)      %7.1f ms\n", blackout
        printf "   Client: largest reply gap          %7.1f ms\n", max
        printf "   Client: implied blackout (-1ms)    %7.1f ms\n", max - 1.0
        printf "   Probes answered                    %d of %d (%d lost)\n",
               n, maxseq, maxseq - n
        printf "   30 ms budget                       %s\n",
               (blackout > 0 && blackout <= 30.0) ? "PASS" : "CHECK"
        print rule
    }
' "$PINGLOG"
echo "   ping log: $PINGLOG"
