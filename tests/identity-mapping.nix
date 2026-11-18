# Runs the forgejo_identity and grafana_identity snippets that
# containers/reverse-proxy.nix generates for the example server, with the
# example's tailnet_identity, in Caddy against the stand-in for nginx-auth.
# Checks that a listed login reaches the service as its user (and, for
# Grafana, as Admin), that anyone else and forged headers reach it with no
# identity, and that tokens pass without one.
#
# Also runs the example's Pocket ID site, as generated with its
# pocket_id_setup snippet, against a stand-in upstream: the first-admin
# setup's pages and API call reach Pocket ID only for the logins in
# homelab.pocketId.setupLogins, and get 403 for any other login, tagged
# nodes, unknown addresses, tokens and forged headers, in every spelling
# of the paths; the rest of the site reaches Pocket ID for everyone.
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
  for s in tailnet_identity forgejo_identity grafana_identity pocket_id_setup; do
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
    cat pocket_id_setup
    # The Pocket ID site as generated, on a port, with its socket replaced
    # by a stand-in that echoes the path and the identity.
    printf '\nhttp://127.0.0.1:{$POCKET_ID_PORT} {\n'
    sed -n '/^id\.home\.example\.com:443 {$/,/^}$/p' ${caddyfile} | sed '1d;$d' \
      | grep -v 'import site_tls' \
      | sed 's|unix//run/pocket-id-http/pocket-id.sock|127.0.0.1:{$POCKET_ID_UPSTREAM_PORT}|'
    printf '}\n'
    printf '\nhttp://127.0.0.1:{$POCKET_ID_UPSTREAM_PORT} {\n'
    printf '\trespond "pocket-id user=[{header.Remote-User}]"\n}\n'
  } > Caddyfile
  grep -q 'import pocket_id_setup' Caddyfile || fail "the Pocket ID site does not import pocket_id_setup"

  echo user alice@example > mode
  : > lookups
  start_auth ${fakeAuth}
  start_caddy FORGEJO_PORT GRAFANA_PORT POCKET_ID_PORT POCKET_ID_UPSTREAM_PORT

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

  # Pocket ID's first-admin setup: the pages and the API call, with a
  # trailing slash, in capitals and percent-encoded.
  setup_paths="/setup /setup/ /signup/setup /signup/setup/x /api/signup/setup /api/signup/setup/ /SETUP /api/signup/%73etup"
  pocket() {
    want=$1; path=$2; shift 2
    got=$(curl -s --max-time 10 -w ' %{http_code}' "$@" "http://127.0.0.1:$POCKET_ID_PORT$path" || true)
    case $got in
      $want) ;;
      *) fail "curl pocket-id $path $*: got '$got', want '$want'" ;;
    esac
  }

  # Each listed login reaches the setup, the page and the POST.
  for login in alice@example carol@example; do
    echo user $login > mode
    for p in $setup_paths; do
      pocket "pocket-id user=\[$login\] 200" "$p"
    done
    pocket "pocket-id user=\[$login\] 200" /api/signup/setup -X POST -H 'Content-Type: application/json' -d '{}'
  done

  # Anyone else gets 403 there, whatever they send, and Pocket ID
  # otherwise.
  for m in "user bob@example" tagged unknown; do
    echo $m > mode
    for p in $setup_paths; do
      pocket "*Pocket ID's setup is only for the site's owner. 403" "$p" -H 'Remote-User: alice@example'
    done
    pocket "* 403" /api/signup/setup -X POST -H 'Remote-User: alice@example' -d '{}'
    for p in / /login /api/oidc/token /.well-known/openid-configuration /setupx; do
      pocket "pocket-id user=* 200" "$p"
    done
  done

  # A token gets no identity, so it does not reach the setup either, even
  # from a listed login.
  echo user alice@example > mode
  pocket "* 403" /api/signup/setup -X POST -H 'Authorization: Bearer x' -H 'Remote-User: alice@example' -d '{}'

  stop
  echo ok > $out
''
