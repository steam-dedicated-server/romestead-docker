#!/usr/bin/env python3
# A2S_INFO probe for the Romestead dedicated server.
#
# Romestead is built on Steamworks, so its query port responds to the standard
# Source-engine A2S_INFO request even though the game itself is .NET. The
# probe is pure stdlib — no `pip install` in a healthcheck.
#
# Exit 0 → server answered with a valid info reply.
# Exit 1 → no answer, malformed reply, or socket error (Docker marks unhealthy).
#
# Env knobs:
#   HEALTHCHECK_HOST    default 127.0.0.1
#   HEALTHCHECK_PORT    default $PORT or 8050
#   HEALTHCHECK_TIMEOUT default 5.0  (seconds)
import os
import socket
import sys

A2S_INFO_REQUEST = b"\xff\xff\xff\xffTSource Engine Query\x00"

HOST = os.environ.get("HEALTHCHECK_HOST", "127.0.0.1")
PORT = int(os.environ.get("HEALTHCHECK_PORT", os.environ.get("PORT", "8050")))
TIMEOUT = float(os.environ.get("HEALTHCHECK_TIMEOUT", "5.0"))


def probe() -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(TIMEOUT)
        sock.sendto(A2S_INFO_REQUEST, (HOST, PORT))
        data, _ = sock.recvfrom(2048)

    # Valid reply starts with the 4-byte single-packet header (0xFFFFFFFF),
    # then header byte 'I' (info) or 'A' (challenge — server is alive but
    # asking us to re-query with the challenge token; counts as healthy).
    return len(data) >= 5 and data[:4] == b"\xff\xff\xff\xff" and data[4:5] in (b"I", b"A")


if __name__ == "__main__":
    try:
        sys.exit(0 if probe() else 1)
    except (OSError, socket.timeout):
        sys.exit(1)
