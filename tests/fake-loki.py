"""A stand-in for Loki's push API, for tests/logging-labels.nix.

    python3 fake-loki.py <port file> <pushes file>

Listens on a free port of 127.0.0.1 and writes its number to <port file>
once it accepts connections, so a test never clashes with another
listener. Takes POSTs to /loki/api/v1/push, gzipped or not, and appends
each body, one JSON document per line, to <pushes file>.
"""
import gzip
import http.server
import os
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        if self.path != "/loki/api/v1/push":
            self.send_response(404)
            self.end_headers()
            return
        with open(sys.argv[2], "ab") as f:
            f.write(body.replace(b"\n", b" ") + b"\n")
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1] + ".tmp", "w") as f:
    f.write(str(server.server_address[1]))
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
server.serve_forever()
