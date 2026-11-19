# The OIDC login gate end to end (docs/adr/0019-oidc-login-gate-at-the-proxy.md):
# the example server's oauth2-proxy command line, its cookie secret
# generator, and the oidc_owner_only and oidc_gate snippets from its
# generated Caddyfile, in a real Caddy, against a stand-in for Pocket ID.
# The example's camera site imports oidc_owner_only (alice); a second site
# imports oidc_gate, which the flake's config opens to bob as well.
#
# The command line is the unit's, with the paths systemd provides and the
# issuer replaced by later flags, and with the cookie not Secure, since the
# test speaks plain HTTP. Checks:
#
# - without a session the browser is sent to the provider, with PKCE, and
#   comes back signed in to the page and query it asked for;
# - the user name reaches the site as Remote-User, and a forged one never
#   does, nor does a forged header or a token get past the gate;
# - one sign-in covers every gated site under the cookie domain;
# - /oauth2/sign_out ends it on all of them;
# - a user not allowed gets 403 on the owner-only site, also when adding
#   allowed_emails to the query, and passes oidc_gate.
#
# It cannot test Pocket ID itself or the renewal after 30 minutes.
{ runCommand, caddy, curl, python3, caddyfile, command, cookieSecret, clientId }:

let
  python = python3.withPackages (ps: [ ps.cryptography ]);
in
runCommand "oidc-gate-test" { nativeBuildInputs = [ caddy curl python ]; inherit command cookieSecret; } ''
  set -euo pipefail
  export HOME=$PWD XDG_DATA_HOME=$PWD XDG_CONFIG_HOME=$PWD
  . ${./identity-harness.sh}

  sock=unix/$PWD/gate.sock
  for s in oidc_gate oidc_owner_only; do
    sed -n "/^($s) {\$/,/^}\$/p" ${caddyfile} | sed "s|unix//run/oidc-gate/oauth2-proxy.sock|$sock|g" > "$s"
    grep -q forward_auth "$s" || fail "no $s snippet in the generated Caddyfile"
  done
  grep -q 'allowed_emails=alice$' oidc_owner_only || fail "oidc_owner_only does not allow just alice"
  {
    printf '{\n\tauto_https off\n\tadmin off\n}\n\n'
    cat oidc_gate oidc_owner_only
    # The example's camera site, on a port, with the camera replaced by a
    # stand-in that echoes what reaches it.
    printf '\nhttp://cam-door.home.example.com:{$CAM_PORT} {\n'
    sed -n '/^cam-door\.home\.example\.com:443 {$/,/^}$/p' ${caddyfile} | sed '1d;$d' \
      | grep -v 'import site_tls' \
      | sed 's|192\.0\.2\.20:80|127.0.0.1:{$UPSTREAM_PORT}|'
    printf '}\n'
    printf '\nhttp://open.home.example.com:{$OPEN_PORT} {\n\timport oidc_gate\n'
    printf '\trespond "open user=[{header.Remote-User}]"\n}\n'
    printf '\nhttp://:{$UPSTREAM_PORT} {\n'
    printf '\trespond "cam user=[{header.Remote-User}] uri=[{uri}] auth=[{header.Authorization}]"\n}\n'
  } > Caddyfile
  grep -q 'import oidc_owner_only' Caddyfile || fail "the camera site does not import oidc_owner_only"

  # The client secret as pocket-id-clients writes it, with no newline, and
  # the cookie secret from the unit's own generator, which keeps one it has.
  printf %s s3cret > client-secret  # public-check: fake
  read -r generator _ <<< "$cookieSecret"
  "''${generator//\"/}" "$PWD/cookie-secret" > /dev/null
  cp cookie-secret first
  "''${generator//\"/}" "$PWD/cookie-secret" > /dev/null
  cmp -s first cookie-secret || fail "the cookie secret was replaced"

  echo alice > user
  : > authorizations
  idp_port=$(free_port)
  python3 -I ${./fake-oidc-provider.py} "$idp_port" ${clientId} client-secret user authorizations > provider.log 2>&1 &
  pids+=("$!")

  start_caddy CAM_PORT OPEN_PORT UPSTREAM_PORT

  eval "$command" \
    "'--oidc-issuer-url=http://127.0.0.1:$idp_port'" \
    "'--http-address=unix://$PWD/gate.sock,mode=0666'" \
    "'--client-secret-file=$PWD/client-secret'" \
    "'--cookie-secret-file=$PWD/cookie-secret'" \
    "--cookie-secure=false" > gate.log 2>&1 &
  pids+=("$!")
  for _ in $(seq 50); do
    [ -S gate.sock ] && break
    sleep 0.2
  done
  [ -S gate.sock ] || fail "oauth2-proxy did not start"

  # One browser: a cookie jar, both sites resolving to Caddy.
  browse() {
    local site=$1 path=$2; shift 2
    local port=$CAM_PORT
    [ "$site" = cam-door ] || port=$OPEN_PORT
    curl -s --max-time 10 -b jar -c jar -w ' %{http_code}' \
      --resolve "cam-door.home.example.com:$CAM_PORT:127.0.0.1" \
      --resolve "open.home.example.com:$OPEN_PORT:127.0.0.1" \
      "$@" "http://$site.home.example.com:$port$path" || true
  }
  check() {
    local want=$1; shift
    got=$(browse "$@")
    case $got in
      $want) ;;
      *) fail "$*: got '$got', want '$want'" ;;
    esac
  }
  signins() { wc -l < authorizations; }

  # No session: off to the provider, whatever the client claims to be.
  check '* 302' cam-door / -H 'Remote-User: alice' -H 'Authorization: Bearer x'
  check '* 302' open / -H 'Remote-User: alice'
  location=$(curl -s -o /dev/null -w '%{redirect_url}' --resolve "cam-door.home.example.com:$CAM_PORT:127.0.0.1" \
    "http://cam-door.home.example.com:$CAM_PORT/")
  case $location in
    http://127.0.0.1:$idp_port/authorize\?*) ;;
    *) fail "no redirect to the provider: '$location'" ;;
  esac
  [ "$(signins)" = 0 ] || fail "the provider was reached without the browser"

  # Signing in comes back to the page and query asked for, as alice.
  check "cam user=\[alice\] uri=\[/admin?a=1&b=2\] auth=\[\] 200" cam-door '/admin?a=1&b=2' -L
  [ "$(signins)" = 1 ] || fail "$(signins) sign-ins, want 1"
  grep -q 'code_challenge_method=S256' authorizations || fail "no PKCE: $(cat authorizations)"
  grep -q "redirect_uri=http%3A%2F%2Fcam-door.home.example.com%3A$CAM_PORT%2Foauth2%2Fcallback" authorizations \
    || fail "not the site's callback: $(cat authorizations)"

  # The session: a forged Remote-User is replaced; a token is passed on.
  check "cam user=\[alice\] uri=\[/\] auth=\[\] 200" cam-door / -H 'Remote-User: mallory'
  check "cam user=\[alice\] uri=\[/\] auth=\[Bearer x\] 200" cam-door / -H 'Authorization: Bearer x'

  # The other site takes the same sign-in, without the provider.
  check "open user=\[alice\] 200" open / -H 'Remote-User: mallory'
  [ "$(signins)" = 1 ] || fail "the second site signed in again"

  # Signing out on one site signs out of both.
  check '* 302' cam-door /oauth2/sign_out
  check '* 302' cam-door /
  check '* 302' open /

  # bob may use oidc_gate but not the owner-only site, however he asks.
  echo bob > user
  check "open user=\[bob\] 200" open / -L
  check "This site is not open to the account you signed in with.* 403" cam-door /
  check "* 403" cam-door '/?allowed_emails=bob'
  check "* 403" cam-door '/x?allowed_emails=bob,alice' -H 'Remote-User: alice'
  check "open user=\[bob\] 200" open /

  stop
  echo ok > $out
''
