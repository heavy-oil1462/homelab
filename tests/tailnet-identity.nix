# Runs the tailnet_identity snippet from the example Caddyfile in Caddy
# against a stand-in for tailscale's nginx-auth that answers like it does for
# a tailnet user, a tagged node and an unknown address. Checks that forged
# identity headers never reach the upstream and that requests with an
# Authorization header skip the lookup.
{ runCommand, writeText, caddy, curl, python3 }:

let
  # Answers like cmd/nginx-auth: 204 with Tailscale-User for a user, 403 for
  # a tagged node, 401 for an address WhoIs does not know. The mode comes
  # from a file so one server covers all cases; each lookup is logged.
  fakeAuth = writeText "fake-nginx-auth.py" ''
    import http.server, os, socketserver, sys

    sock, modefile, logfile = sys.argv[1:4]

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            with open(logfile, "a") as f:
                f.write("%s %s\n" % (self.headers.get("Remote-Addr"), self.headers.get("Remote-Port")))
            mode = open(modefile).read().strip()
            if mode == "user":
                self.send_response(204)
                self.send_header("Tailscale-User", "alice@github")
            else:
                self.send_response(403 if mode == "tagged" else 401)
            self.end_headers()

        def address_string(self):
            return "unix"

    class Server(socketserver.UnixStreamServer):
        def get_request(self):
            conn, _ = super().get_request()
            return conn, ("unix", 0)

    if os.path.exists(sock):
        os.remove(sock)
    Server(sock, Handler).serve_forever()
  '';
in
runCommand "tailnet-identity-test" { nativeBuildInputs = [ caddy curl python3 ]; } ''
  set -euo pipefail
  export HOME=$PWD XDG_DATA_HOME=$PWD XDG_CONFIG_HOME=$PWD
  fail() { echo "FAIL: $*" >&2; cat caddy.log >&2 || true; exit 1; }

  # The snippet as the example ships it, dialing a socket in the build dir.
  sed -n '/^(tailnet_identity) {$/,/^}$/p' ${../examples/assets/caddy/Caddyfile} \
    | sed "s|unix//run/tailnet-identity/whois.sock|unix/$PWD/whois.sock|" > snippet
  grep -q forward_auth snippet || fail "no tailnet_identity snippet in the example Caddyfile"
  {
    printf '{\n\tauto_https off\n\tadmin off\n}\n\n'
    cat snippet
    printf '\nhttp://127.0.0.1:8080 {\n\timport tailnet_identity\n'
    printf '\trespond "user=[{header.Remote-User}] ts=[{header.Tailscale-User}{header.Tailscale-User-Login}] auth=[{header.Authorization}]"\n}\n'
  } > Caddyfile

  echo user > mode
  : > lookups
  python3 -I ${fakeAuth} "$PWD/whois.sock" mode lookups &
  caddy run --config Caddyfile --adapter caddyfile > caddy.log 2>&1 &
  for _ in $(seq 50); do
    curl -s -o /dev/null http://127.0.0.1:8080/ && [ -S whois.sock ] && break
    sleep 0.2
  done

  check() {
    want=$1; shift
    got=$(curl -s -w ' %{http_code}' "$@" http://127.0.0.1:8080/)
    [ "$got" = "$want" ] || fail "curl $*: got '$got', want '$want'"
  }

  # A tailnet user gets their login name.
  check 'user=[alice@github] ts=[] auth=[] 200'

  # Forged identity headers are deleted, and the lookup uses the real client
  # address, not a forged Remote-Addr.
  : > lookups
  check 'user=[alice@github] ts=[] auth=[] 200' \
    -H 'Remote-User: mallory@github' -H 'Tailscale-User: mallory@github' \
    -H 'Tailscale-User-Login: mallory@github' -H 'Remote-Addr: 100.64.0.9'
  grep -q '^127\.0\.0\.1 [0-9]' lookups || fail "lookup not by client address: $(cat lookups)"

  # A token skips the lookup and carries no identity, forged or not.
  : > lookups
  check 'user=[] ts=[] auth=[Bearer x] 200' -H 'Authorization: Bearer x' -H 'Remote-User: mallory@github'
  [ ! -s lookups ] || fail "lookup despite Authorization header"

  # A tagged node or an unknown address goes on without an identity.
  echo tagged > mode
  check 'user=[] ts=[] auth=[] 200' -H 'Remote-User: mallory@github'
  echo unknown > mode
  check 'user=[] ts=[] auth=[] 200' -H 'Remote-User: mallory@github'

  kill %1 %2
  echo ok > $out
''
