#!/usr/bin/env python3
# Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Pre-copy live migration orchestrator, run inside the 'src' host container.

The bulk of guest RAM is streamed to the destination while the source keeps
running: the full pass goes out in fixed-size chunks (PUT /migrate with a byte
range) so the VMM thread services device I/O between chunks and the guest's
network never stalls, then dirty-only rounds re-send what changed. The cutover
freezes the guest only long enough to ship the final small dirty delta plus
device state (reusing the snapshot create/load API) and resume on the
destination, retargeted to its own tap.

This is a single long-lived process, so the cutover API calls are plain
in-process socket I/O with no subprocess startup inside the freeze window —
the blackout reflects Firecracker's work, not orchestration overhead.
"""
import json
import socket
import subprocess
import sys
import time

SRC_SOCK = "/fc/src.sock"
DST_SOCK = "/fc/dst.sock"
MEM = "/mig/mem.file"
STATE = "/mig/snap.file"
KEY = "/fc/ubuntu-24.04.id_rsa"
GUEST_IP = "172.16.0.2"
GUEST_MAC = "06:00:ac:10:00:02"
SRC_TAP = "tap_src"
DST_TAP = "tap_dst"
ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else 3
CHUNK = 32 * 1024 * 1024  # full-pass chunk size; ~10ms of VMM time per chunk


def api(sock_path, method, path, body=""):
    """Issue one HTTP request to a Firecracker API unix socket; return the body."""
    data = body.encode()
    request = (
        f"{method} {path} HTTP/1.1\r\n"
        f"Host: localhost\r\n"
        f"Content-Type: application/json\r\n"
        f"Content-Length: {len(data)}\r\n"
        f"Connection: close\r\n\r\n"
    ).encode() + data

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(15)
    sock.connect(sock_path)
    sock.sendall(request)
    buf = b""
    while b"\r\n\r\n" not in buf:  # read through the response headers
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    headers = head.decode(errors="replace")
    status_line = headers.split("\r\n", 1)[0]
    parts = status_line.split()
    code = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
    length = 0
    for line in headers.split("\r\n")[1:]:
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1])
    while len(rest) < length:
        chunk = sock.recv(4096)
        if not chunk:
            break
        rest += chunk
    sock.close()

    if code not in (200, 204):
        raise RuntimeError(f"{method} {path} -> {status_line!r} {rest[:200]!r}")
    return rest.decode(errors="replace")


def dump(kind, extra=""):
    """Stream guest memory to the destination image (Full or Diff), no pause."""
    api(SRC_SOCK, "PUT", "/migrate",
        f'{{"memory_path":"{MEM}","snapshot_type":"{kind}"{extra}}}')


def guest(cmd):
    """Run a command in the source guest over SSH; return stdout."""
    out = subprocess.run(
        ["ssh", "-i", KEY, "-o", "StrictHostKeyChecking=no",
         "-o", "ConnectTimeout=6", f"root@{GUEST_IP}", cmd],
        capture_output=True, text=True,
    )
    return out.stdout.strip()


def main():
    marker = f"MIG-{int(time.time())}"
    guest(f"echo {marker} > /dev/shm/proof")
    print(f"  marker={marker} uptime_before={guest('cut -d\" \" -f1 /proc/uptime')}s")

    # Pre-copy, all while the guest keeps running. The full pass streams in
    # chunks, yielding between them so virtio-net keeps being serviced.
    status = json.loads(api(SRC_SOCK, "GET", "/migrate"))
    total = status["mem_size_mib"] * 1024 * 1024
    t_pre = time.monotonic()
    for off in range(0, total, CHUNK):
        dump("Full", f',"offset":{off},"len":{CHUNK}')
        time.sleep(0.003)  # let the VMM thread drain device queues
    for _ in range(ROUNDS):
        dump("Diff")
    dump("Diff")  # converge one last round right before the freeze
    print(f"  pre-copy: {total >> 20} MiB in {time.monotonic() - t_pre:.2f}s "
          f"({(total + CHUNK - 1) // CHUNK} chunks + {ROUNDS + 1} dirty rounds)")

    # Cutover freeze: pause -> final diff + device state -> load + resume on dst.
    t0 = time.monotonic_ns()
    api(SRC_SOCK, "PATCH", "/vm", '{"state":"Paused"}')
    api(SRC_SOCK, "PUT", "/snapshot/create",
        f'{{"snapshot_type":"Diff","snapshot_path":"{STATE}","mem_file_path":"{MEM}"}}')
    # Drop the bridge's learned location for the guest MAC while the guest is
    # frozen: the first frame after resume floods to every port and reaches the
    # guest on its new tap immediately, instead of blackholing to the source tap
    # until the guest happens to transmit.
    subprocess.run(
        ["bridge", "fdb", "del", GUEST_MAC, "dev", SRC_TAP, "master"],
        capture_output=True,
    )
    api(DST_SOCK, "PUT", "/snapshot/load",
        f'{{"snapshot_path":"{STATE}",'
        f'"mem_backend":{{"backend_type":"File","backend_path":"{MEM}"}},'
        f'"network_overrides":[{{"iface_id":"eth0","host_dev_name":"{DST_TAP}"}}],'
        f'"resume_vm":true}}')
    t1 = time.monotonic_ns()

    print(f"   TRUE BLACKOUT (pause -> resume): {(t1 - t0) / 1e6:.1f} ms")


if __name__ == "__main__":
    main()
