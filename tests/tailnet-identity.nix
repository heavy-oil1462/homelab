# Runs the tailnet_identity snippet from the example Caddyfile in Caddy
# against a stand-in for tailscale's nginx-auth that answers like it does for
# a tailnet user, a tagged node and an unknown address. Checks that forged
# identity headers never reach the upstream and that requests with an
# Authorization header skip the lookup.
{ runCommand, caddy, curl, python3 }:

let
  fakeAuth = ./fake-nginx-auth.py;
in
runCommand "tailnet-identity-test" { nativeBuildInputs = [ caddy curl python3 ]; } ''
  set -euo pipefail
  export HOME=$PWD XDG_DATA_HOME=$PWD XDG_CONFIG_HOME=$PWD
  . ${./identity-harness.sh}

  # The snippet as the example ships it, dialing a socket in the build dir.
  sed -n '/^(tailnet_identity) {$/,/^}$/p' ${../examples/assets/caddy/Caddyfile} \
    | sed "s|unix//run/tailnet-identity/whois.sock|unix/$PWD/whois.sock|" > snippet
  grep -q forward_auth snippet || fail "no tailnet_identity snippet in the example Caddyfile"
  {
    printf '{\n\tauto_https off\n\tadmin off\n}\n\n'
    cat snippet
    printf '\nhttp://127.0.0.1:{$PORT} {\n\timport tailnet_identity\n'
    printf '\trespond "user=[{header.Remote-User}] ts=[{header.Tailscale-User}{header.Tailscale-User-Login}] auth=[{header.Authorization}]"\n}\n'
  } > Caddyfile

  echo user > mode
  : > lookups
  start_auth ${fakeAuth}
  start_caddy PORT

  check() {
    want=$1; shift
    got=$(get "$PORT" "$@")
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

  stop
  echo ok > $out
''
