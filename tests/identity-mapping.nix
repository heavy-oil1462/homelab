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
  . ${./identity-harness.sh}

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
    printf '\nhttp://127.0.0.1:{$FORGEJO_PORT} {\n\timport forgejo_identity\n'
    printf '\trespond "user=[{header.Remote-User}]"\n}\n'
    printf '\nhttp://127.0.0.1:{$GRAFANA_PORT} {\n\timport grafana_identity\n'
    printf '\trespond "user=[{header.Remote-User}] role=[{header.Remote-Role}]"\n}\n'
  } > Caddyfile

  echo user alice@example > mode
  : > lookups
  start_auth ${fakeAuth}
  start_caddy FORGEJO_PORT GRAFANA_PORT

  check() {
    site=$1; want=$2; shift 2
    if [ "$site" = forgejo ]; then port=$FORGEJO_PORT; else port=$GRAFANA_PORT; fi
    got=$(get "$port" "$@")
    [ "$got" = "$want" ] || fail "curl $site $*: got '$got', want '$want'"
  }

  # A listed login: Forgejo gets the mapped user, Grafana the login as Admin.
  # Forged headers are replaced.
  check forgejo 'user=[alice] 200'
  check forgejo 'user=[alice] 200' -H 'Remote-User: mallory'
  check grafana 'user=[alice@example] role=[Admin] 200'
  check grafana 'user=[alice@example] role=[Admin] 200' -H 'Remote-User: mallory@example' -H 'Remote-Role: Viewer'

  # A login that is not listed gets no identity, whatever it sends.
  echo user bob@example > mode
  check forgejo 'user=[] 200' -H 'Remote-User: alice'
  check grafana 'user=[] role=[] 200' -H 'Remote-User: alice@example' -H 'Remote-Role: Admin'

  # Tagged nodes and unknown addresses get none either.
  for m in tagged unknown; do
    echo $m > mode
    check forgejo 'user=[] 200' -H 'Remote-User: alice'
    check grafana 'user=[] role=[] 200' -H 'Remote-User: alice@example' -H 'Remote-Role: Admin'
  done

  # A token skips the lookup and carries no identity, forged or not.
  echo user alice@example > mode
  : > lookups
  check forgejo 'user=[] 200' -H 'Authorization: token x' -H 'Remote-User: alice'
  check grafana 'user=[] role=[] 200' -H 'Authorization: Bearer x' -H 'Remote-User: alice@example' -H 'Remote-Role: Admin'
  [ ! -s lookups ] || fail "lookup despite Authorization header"

  stop
  echo ok > $out
''
