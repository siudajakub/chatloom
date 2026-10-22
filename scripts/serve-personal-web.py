#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Serve the prepared Flutter web build locally with crypto isolation headers."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port", type=int, default=5182)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1] / "build" / "web"
if not (root / "index.html").is_file():
    parser.error("Build web first; build/web/index.html is missing")

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(root), **kw)
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()
    def log_message(self, *a):
        pass  # Avoid recording private paths or authentication callbacks.

print(f"Personal Chat: http://127.0.0.1:{args.port}", flush=True)
try:
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
except KeyboardInterrupt:
    pass
