"""A Git server over Smart HTTP, for tests/grafana-git-sync.nix.

    python3 fake-git-http.py <port file> <user> <token file> <project root> <log>

Listens on a free port of 127.0.0.1 and writes its number to <port file>
once it accepts connections. Serves the bare repositories under
<project root> through `git http-backend`, as CGI, to requests that carry
<user> and the token in <token file> as basic auth, as Forgejo takes an
access token; others get 401 with a challenge, so git asks for
credentials. The token comes from a file so that it is in no process's
command line, which the test looks for. Each request waits
half a second, which gives the test time to look at the processes git
runs, and is logged to <log> as "METHOD path status".
"""

import base64
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

port_file, user, token_file, root, log = sys.argv[1:6]
with open(token_file) as f:
    token = f.read().strip()
expected = "Basic " + base64.b64encode(f"{user}:{token}".encode()).decode()


class Handler(BaseHTTPRequestHandler):
    # A client that stops sending does not keep its thread for good.
    timeout = 10

    def log_message(self, *args):
        pass

    def logged(self, status):
        with open(log, "a") as f:
            f.write(f"{self.command} {self.path} {status}\n")

    def handle_any(self):
        time.sleep(0.5)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if self.headers.get("Authorization") != expected:
            self.logged(401)
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="git"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        url = urlsplit(self.path)
        env = {
            "PATH": os.environ["PATH"],
            "GIT_PROJECT_ROOT": root,
            "GIT_HTTP_EXPORT_ALL": "1",
            "REMOTE_USER": user,
            "REMOTE_ADDR": "127.0.0.1",
            "REQUEST_METHOD": self.command,
            "PATH_INFO": url.path,
            "QUERY_STRING": url.query,
            "CONTENT_TYPE": self.headers.get("Content-Type") or "",
            "CONTENT_LENGTH": str(len(body)),
        }
        if self.headers.get("Git-Protocol"):
            env["GIT_PROTOCOL"] = self.headers["Git-Protocol"]
        result = subprocess.run(
            ["git", "http-backend"], input=body, env=env, capture_output=True, timeout=30
        )
        head, _, payload = result.stdout.partition(b"\r\n\r\n")
        status = 200
        headers = []
        for line in head.decode().split("\r\n"):
            name, _, value = line.partition(":")
            if name.lower() == "status":
                status = int(value.split()[0])
            elif name:
                headers.append((name, value.strip()))
        self.logged(status)
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self.handle_any()

    def do_POST(self):
        self.handle_any()


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file + ".tmp", "w") as f:
    f.write(str(server.server_address[1]))
os.rename(port_file + ".tmp", port_file)
server.serve_forever()
