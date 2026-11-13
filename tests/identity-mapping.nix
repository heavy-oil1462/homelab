# Runs the forgejo_identity and grafana_identity snippets that
# containers/reverse-proxy.nix generates for the example server, with the
# example's tailnet_identity, in Caddy against the stand-in for nginx-auth.
# Checks that a listed login reaches the service as its user (and, for
# Grafana, as Admin), that anyone else and forged headers reach it with no
# identity, and that tokens pass without one.
{ runCommand, caddy, curl, python3, caddyfile }:

let
  fakeAuth = ./fake-nginx-auth.py;
in
runCommand "identity-mapping-test" { nativeBuildInputs = [ caddy curl python3 ]; } ''
  set -euo pipefail
  export HOME=$PWD XDG_DATA_HOME=$PWD XDG_CONFIG_HOME=$PWD
  fail() { echo "FAIL: $*" >&2; cat caddy.log >&2 || true; exit 1; }

  # The snippets as the example server's Caddyfile has them, dialing a
  # socket in the build dir.
  for s in tailnet_identity forgejo_identity grafana_identity; do
    sed -n "/^($s) {\$/,/^}\$/p" ${caddyfile} > "$s"
    grep -q . "$s" || fail "no $s snippet in the generated Caddyfile"
  done
  {
    printf '{\n\tauto_https off\n\tadmin off\n}\n\n'
    sed "s|unix//run/tailnet-identity/whois.sock|unix/$PWD/whois.sock|" tailnet_identity
    cat forgejo_identity grafana_identity
    printf '\nhttp://127.0.0.1:8080 {\n\timport forgejo_identity\n'
    printf '\trespond "user=[{header.Remote-User}]"\n}\n'
    printf '\nhttp://127.0.0.1:8081 {\n\timport grafana_identity\n'
    printf '\trespond "user=[{header.Remote-User}] role=[{header.Remote-Role}]"\n}\n'
  } > Caddyfile

  echo user alice@example > mode
  : > lookups
  python3 -I ${fakeAuth} "$PWD/whois.sock" mode lookups &
  caddy run --config Caddyfile --adapter caddyfile > caddy.log 2>&1 &
  for _ in $(seq 50); do
    curl -s -o /dev/null http://127.0.0.1:8080/ && [ -S whois.sock ] && break
    sleep 0.2
  done

  check() {
    port=$1; want=$2; shift 2
    got=$(curl -s -w ' %{http_code}' "$@" "http://127.0.0.1:$port/")
    [ "$got" = "$want" ] || fail "curl :$port $*: got '$got', want '$want'"
  }

  # A listed login: Forgejo gets the mapped user, Grafana the login as Admin.
  # Forged headers are replaced.
  check 8080 'user=[alice] 200'
  check 8080 'user=[alice] 200' -H 'Remote-User: mallory'
  check 8081 'user=[alice@example] role=[Admin] 200'
  check 8081 'user=[alice@example] role=[Admin] 200' -H 'Remote-User: mallory@example' -H 'Remote-Role: Viewer'

  # A login that is not listed gets no identity, whatever it sends.
  echo user bob@example > mode
  check 8080 'user=[] 200' -H 'Remote-User: alice'
  check 8081 'user=[] role=[] 200' -H 'Remote-User: alice@example' -H 'Remote-Role: Admin'

  # Tagged nodes and unknown addresses get none either.
  for m in tagged unknown; do
    echo $m > mode
    check 8080 'user=[] 200' -H 'Remote-User: alice'
    check 8081 'user=[] role=[] 200' -H 'Remote-User: alice@example' -H 'Remote-Role: Admin'
  done

  # A token skips the lookup and carries no identity, forged or not.
  echo user alice@example > mode
  : > lookups
  check 8080 'user=[] 200' -H 'Authorization: token x' -H 'Remote-User: alice'
  check 8081 'user=[] role=[] 200' -H 'Authorization: Bearer x' -H 'Remote-User: alice@example' -H 'Remote-Role: Admin'
  [ ! -s lookups ] || fail "lookup despite Authorization header"

  kill %1 %2
  echo ok > $out
''
