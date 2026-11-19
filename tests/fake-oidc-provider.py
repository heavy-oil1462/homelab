# A stand-in for Pocket ID as an OpenID Connect provider, for the OIDC
# gate's flow test. It signs in whoever the user file names, without asking:
# /authorize redirects straight back with a code, /token trades it for an ID
# token signed with a key made at start, and checks the PKCE verifier;
# /userinfo answers for the access token, as oauth2-proxy asks it for
# claims the ID token lacks.
# Every authorization is logged with its query.
#
#   python3 -I fake-oidc-provider.py <port> <client id> <secret file> <user file> <log file>
import base64, hashlib, http.server, json, secrets, sys, time, urllib.parse

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa

port, client_id, secret_file, user_file, log_file = sys.argv[1:6]
issuer = "http://127.0.0.1:%s" % port
client_secret = open(secret_file).read().strip()
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
codes = {}
tokens = {}


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def number(n):
    return b64(n.to_bytes((n.bit_length() + 7) // 8, "big"))


def id_token(user, nonce):
    now = int(time.time())
    header = {"alg": "RS256", "kid": "k", "typ": "JWT"}
    claims = {"iss": issuer, "sub": "id-" + user, "aud": client_id, "iat": now,
              "exp": now + 3600, "preferred_username": user, "name": user}
    if nonce:
        claims["nonce"] = nonce
    signing = b64(json.dumps(header).encode()) + "." + b64(json.dumps(claims).encode())
    signature = key.sign(signing.encode(), padding.PKCS1v15(), hashes.SHA256())
    return signing + "." + b64(signature)


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, status, body=None, headers=()):
        self.send_response(status)
        for h in headers:
            self.send_header(*h)
        data = json.dumps(body).encode() if body is not None else b""
        if body is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        if url.path == "/.well-known/openid-configuration":
            self.reply(200, {
                "issuer": issuer,
                "authorization_endpoint": issuer + "/authorize",
                "token_endpoint": issuer + "/token",
                "jwks_uri": issuer + "/jwks",
                "userinfo_endpoint": issuer + "/userinfo",
                "response_types_supported": ["code"],
                "subject_types_supported": ["public"],
                "id_token_signing_alg_values_supported": ["RS256"],
                "code_challenge_methods_supported": ["S256"],
            })
        elif url.path == "/jwks":
            pub = key.public_key().public_numbers()
            self.reply(200, {"keys": [{"kty": "RSA", "alg": "RS256", "use": "sig", "kid": "k",
                                       "n": number(pub.n), "e": number(pub.e)}]})
        elif url.path == "/userinfo":
            user = tokens.get(self.headers.get("Authorization", "")[len("Bearer "):])
            if user is None:
                return self.reply(401, {"error": "invalid_token"})
            self.reply(200, {"sub": "id-" + user, "preferred_username": user, "name": user})
        elif url.path == "/authorize":
            with open(log_file, "a") as f:
                f.write(url.query + "\n")
            q = urllib.parse.parse_qs(url.query)
            if q.get("client_id") != [client_id] or q.get("code_challenge_method") != ["S256"]:
                return self.reply(400, {"error": "invalid_request"})
            code = secrets.token_hex(8)
            codes[code] = (open(user_file).read().strip(), q.get("nonce", [""])[0],
                           q["code_challenge"][0], q["redirect_uri"][0])
            target = q["redirect_uri"][0] + "?" + urllib.parse.urlencode(
                {"code": code, "state": q["state"][0]})
            self.reply(302, headers=[("Location", target)])
        else:
            self.reply(404, {"error": "not_found"})

    def do_POST(self):
        form = urllib.parse.parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
        auth = self.headers.get("Authorization", "")
        sent = form.get("client_secret", [""])[0]
        if auth.startswith("Basic "):
            sent = urllib.parse.unquote(base64.b64decode(auth[6:]).decode().split(":", 1)[1])
        if self.path != "/token" or sent != client_secret:
            return self.reply(401, {"error": "invalid_client"})
        user, nonce, challenge, redirect = codes.pop(form.get("code", [""])[0], (None,) * 4)
        verifier = form.get("code_verifier", [""])[0]
        if user is None or form.get("redirect_uri") != [redirect] \
                or b64(hashlib.sha256(verifier.encode()).digest()) != challenge:
            return self.reply(400, {"error": "invalid_grant"})
        access = secrets.token_hex(16)
        tokens[access] = user
        self.reply(200, {"access_token": access, "token_type": "Bearer",
                         "expires_in": 3600, "refresh_token": secrets.token_hex(16),
                         "id_token": id_token(user, nonce)})

    def log_message(self, fmt, *args):
        sys.stderr.write("provider: " + fmt % args + "\n")


http.server.ThreadingHTTPServer(("127.0.0.1", int(port)), Handler).serve_forever()
