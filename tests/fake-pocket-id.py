"""A stand-in for Pocket ID's admin API, for tests/pocket-id-clients.nix.

    python3 fake-pocket-id.py <socket> <API key> <directory>

Listens on the unix socket <socket>, as Pocket ID does with UNIX_SOCKET,
and answers what modules/pocket-id-clients.sh calls, as Pocket ID 2.7.0
does:

- GET /healthz: 204.
- GET, PUT and DELETE /api/oidc/clients/<id>, POST /api/oidc/clients and
  POST /api/oidc/clients/<id>/secret, for requests with X-API-Key <API
  key>; 401 without it, 404 for a client that does not exist. A new secret
  is 32 random letters and digits; only it is kept, never shown again.
- POST /api/oidc/introspect with HTTP basic auth of a client id and
  secret: 401 for a wrong secret, 404 for an unknown client, else 200 with
  an inactive token.

Keeps its state in files in <directory>, which the test reads and
changes:

- clients.json: an object of the clients by id, each as Pocket ID returns
  it, with its secret under "secret".
- requests: one "METHOD path" line per request.
- down: while it exists, /healthz answers 503.
"""

import base64
import json
import os
import secrets
import socketserver
import string
import sys
from http.server import BaseHTTPRequestHandler

CLIENTS = "/api/oidc/clients"

socket_path, api_key, state = sys.argv[1], sys.argv[2], sys.argv[3]


def path(name):
    return os.path.join(state, name)


def load():
    if not os.path.exists(path("clients.json")):
        return {}
    with open(path("clients.json")) as f:
        return json.load(f)


def save(clients):
    with open(path("clients.json"), "w") as f:
        json.dump(clients, f)


# The fields Pocket ID's update and create take, besides the id and logos.
FIELDS = {
    "name": "",
    "callbackURLs": [],
    "logoutCallbackURLs": [],
    "isPublic": False,
    "pkceEnabled": False,
    "requiresReauthentication": False,
    "launchURL": None,
    "isGroupRestricted": False,
    "credentials": {},
}


def shown(client):
    return {k: v for k, v in client.items() if k != "secret"}


class Handler(BaseHTTPRequestHandler):
    timeout = 10

    def address_string(self):
        return "unix"

    def log_message(self, *args):
        pass

    def answer(self, code, body=None):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        if body is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        with open(path("requests"), "a") as f:
            f.write(f"{method} {self.path}\n")
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""

        if self.path == "/healthz" and method == "GET":
            return self.answer(503 if os.path.exists(path("down")) else 204)

        clients = load()
        if self.path == "/api/oidc/introspect" and method == "POST":
            auth = self.headers.get("Authorization", "")
            if not auth.startswith("Basic "):
                return self.answer(400, {"error": "no credentials"})
            client_id, _, secret = base64.b64decode(auth[6:]).decode().partition(":")
            if client_id not in clients:
                return self.answer(404, {"error": "client not found"})
            if not secret or clients[client_id].get("secret") != secret:
                return self.answer(401, {"error": "invalid client secret"})
            return self.answer(200, {"active": False})

        if self.headers.get("X-API-Key") != api_key:
            return self.answer(401, {"error": "You are not signed in"})
        if self.path == CLIENTS and method == "POST":
            data = json.loads(body)
            if data["id"] in clients:
                return self.answer(400, {"error": "Client ID already in use"})
            client = {"id": data["id"], **{k: data.get(k, v) for k, v in FIELDS.items()}}
            clients[data["id"]] = client
            save(clients)
            return self.answer(201, shown(client))
        if not self.path.startswith(CLIENTS + "/"):
            return self.answer(404, {"error": "not found"})
        rest = self.path[len(CLIENTS) + 1 :].split("/")
        client_id = rest[0]
        if client_id not in clients:
            return self.answer(404, {"error": "Record not found"})
        client = clients[client_id]
        if len(rest) == 2 and rest[1] == "secret" and method == "POST":
            secret = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32))
            client["secret"] = secret
            save(clients)
            return self.answer(200, {"secret": secret})
        if len(rest) != 1:
            return self.answer(404, {"error": "not found"})
        if method == "GET":
            return self.answer(200, {**shown(client), "allowedUserGroups": []})
        if method == "PUT":
            data = json.loads(body)
            client.update({k: data.get(k, v) for k, v in FIELDS.items()})
            save(clients)
            return self.answer(200, shown(client))
        if method == "DELETE":
            del clients[client_id]
            save(clients)
            return self.answer(204)
        return self.answer(405, {"error": "method not allowed"})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")

    def do_DELETE(self):
        self.handle_any("DELETE")


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


if os.path.exists(socket_path):
    os.remove(socket_path)
Server(socket_path, Handler).serve_forever()
