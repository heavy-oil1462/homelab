"""A stand-in for Grafana's provisioning API, for tests/grafana-git-sync.nix.

    python3 fake-grafana.py <port file> <API token> <directory>

Listens on a free port of 127.0.0.1 and writes its number to <port file>
once it accepts connections, so a test never clashes with another
listener, which a fixed port can outside the build sandbox. Answers
/api/health, and GET, POST and PUT of one Repository resource and its
/test under /apis/provisioning.grafana.app/v0alpha1/namespaces/default/
repositories, for requests with the API token. Keeps its state in files
in <directory>, which the test reads and changes:

- repository.json: the resource as Grafana keeps it, without the secure
  part; absent until created. Its resourceVersion goes up on every write,
  and a PUT with another one gets 409, as in Grafana.
- token: the Git token last written.
- requests: one "METHOD path" line per request.
- bad-token: while it exists, /test fails as Grafana does for a token the
  Git server refuses.
- down: while it exists, /api/health answers 503.
- stall: while it exists, /api/health answers only after 30 seconds.
"""

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PREFIX = "/apis/provisioning.grafana.app/v0alpha1/namespaces/default/repositories"

port_file, api_token, state = sys.argv[1], sys.argv[2], sys.argv[3]


def path(name):
    return os.path.join(state, name)


class Handler(BaseHTTPRequestHandler):
    # A client that stops sending does not keep its thread for good.
    timeout = 10

    def log_message(self, *args):
        pass

    def answer(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        with open(path("requests"), "a") as f:
            f.write(f"{method} {self.path}\n")
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if self.path == "/api/health":
            if os.path.exists(path("stall")):
                time.sleep(30)
            if os.path.exists(path("down")):
                return self.answer(503, {"database": "failing"})
            return self.answer(200, {"database": "ok"})
        if self.headers.get("Authorization") != f"Bearer {api_token}":
            return self.answer(401, {"message": "invalid API key"})
        if not self.path.startswith(PREFIX + "/") and self.path != PREFIX:
            return self.answer(404, {"message": "not found"})
        rest = self.path[len(PREFIX) :].strip("/").split("/")
        stored = None
        if os.path.exists(path("repository.json")):
            with open(path("repository.json")) as f:
                stored = json.load(f)

        if len(rest) == 2 and rest[1] == "test" and method == "POST":
            if stored is None:
                return self.answer(404, {"message": "not found"})
            if os.path.exists(path("bad-token")):
                return self.answer(
                    200,
                    {
                        "kind": "TestResults",
                        "code": 400,
                        "success": False,
                        "errors": [{"field": "secure.token", "detail": "not authorized"}],
                    },
                )
            return self.answer(200, {"kind": "TestResults", "code": 200, "success": True})

        if method == "GET" and len(rest) == 1:
            if stored is None or stored["metadata"]["name"] != rest[0]:
                return self.answer(404, {"message": "not found"})
            return self.answer(200, stored)

        if method in ("POST", "PUT"):
            new = json.loads(body)
            if method == "POST" and stored is not None:
                return self.answer(409, {"message": "already exists"})
            if method == "PUT":
                if stored is None:
                    return self.answer(404, {"message": "not found"})
                sent = new["metadata"].get("resourceVersion")
                if sent and sent != stored["metadata"]["resourceVersion"]:
                    return self.answer(409, {"message": "conflict"})
            version = int(stored["metadata"]["resourceVersion"]) + 1 if stored else 1
            secure = new.pop("secure", {})
            token = secure.get("token", {}).get("create")
            if token is not None:
                with open(path("token"), "w") as f:
                    f.write(token)
            new["metadata"]["resourceVersion"] = str(version)
            # Grafana adds fields of its own to the spec.
            new["spec"].setdefault("git", {})["encryptedTokenSet"] = True
            new["status"] = {"health": {"healthy": True}}
            with open(path("repository.json"), "w") as f:
                json.dump(new, f)
            return self.answer(201 if method == "POST" else 200, new)

        return self.answer(405, {"message": "method not allowed"})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")


# A thread per request, so a stalled answer holds up no other request.
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file + ".new", "w") as f:
    f.write(f"{server.server_port}\n")
os.rename(port_file + ".new", port_file)
server.serve_forever()
