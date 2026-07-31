#!/usr/bin/env python3
"""Serve a test directory on an ephemeral loopback port."""

from __future__ import annotations

import http.server
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: CDNFixtureServer.py ROOT PORT_FILE")
    root = Path(sys.argv[1]).resolve()
    port_file = Path(sys.argv[2]).resolve()
    handler = lambda *args, **kwargs: http.server.SimpleHTTPRequestHandler(  # noqa: E731
        *args, directory=str(root), **kwargs
    )
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    port_file.write_text(str(server.server_address[1]), encoding="utf-8")
    server.serve_forever()


if __name__ == "__main__":
    main()
