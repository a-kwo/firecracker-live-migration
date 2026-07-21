# Copyright 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Minimal "host" image for the live-migration demo. Each container plays the
# role of one physical host running a Firecracker microVM. The Firecracker
# binary itself is statically linked (musl) and bind-mounted in, so this image
# only needs the userspace tooling to set up networking, drive the API socket,
# and move snapshot data between hosts.
FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        iproute2 \
        iptables \
        openssh-client \
        netcat-openbsd \
        socat \
        curl \
        python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /fc
