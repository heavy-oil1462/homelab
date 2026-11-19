# Runs modules/pocket-id-clients.sh against nixpkgs' Pocket ID, started on
# a temporary state directory with SQLite, its unit's settings, a unix
# socket, the static API key and an encryption key, and a stubbed
# systemctl (docs/adr/0018-pocket-id-is-the-oidc-provider.md):
#
# - a first run takes over the forgejo client a failed run left with a
#   secret nobody kept, creates grafana's, writes both clients' files and
#   leaves one secret on each, the one in the file; a client made in the
#   admin UI stays as it is;
# - a run with nothing to do changes nothing in Pocket ID and restarts
#   nothing;
# - a changed redirect URI updates the client and keeps what the admin UI
#   set;
# - an emptied secret file and a secret deleted in the admin UI each get a
#   new secret, the old one stops working, and only their client's units
#   restart;
# - a client no longer declared is deleted, its files left;
# - a wrong API key and a Pocket ID that never answers fail.
#
# Pocket ID logs every request, which shows what a run wrote. No secret is
# in the output. Pocket ID is killed at the end, so nothing holds the
# build's output open, and every run has a deadline.
{ lib, runCommand, callPackage, runtimeShell, python3, jq, curl, package, settings }:

let
  script = callPackage ../modules/pocket-id-clients.nix { };
  # The unit's settings as nixpkgs' module writes them to its environment
  # file; the test's own socket and actor port replace the host's.
  environment = lib.concatStringsSep " " (lib.mapAttrsToList
    (name: value: lib.escapeShellArg "${name}=${if lib.isBool value then lib.boolToString value else toString value}")
    (removeAttrs settings [ "UNIX_SOCKET" "ACTORS_PORT" ]));
in
runCommand "pocket-id-clients-test" { nativeBuildInputs = [ python3 jq curl ]; } ''
  set -euo pipefail
  mkdir bin state secrets
  export PATH=$PWD/bin:$PATH STUB=$PWD
  export POCKET_ID_CLIENTS_TRIES=3 POCKET_ID_CLIENTS_WAIT=0
  pid=
  fail() {
    echo "FAIL: $*" >&2
    tail -n 20 pocket-id.log >&2 || true
    [ -z "$pid" ] || kill "$pid" 2> /dev/null || true
    exit 1
  }

  cat > bin/systemctl <<'STUB'
  #!${runtimeShell}
  echo "$*" >> "$STUB/systemctl.log"
  STUB
  chmod +x bin/systemctl

  owner="$(id -u):$(id -g)"
  sock=$PWD/pocket-id.sock
  key=api-key-0123456789abcdef # public-check: fake
  printf '%s\n' "$key" > api-key

  # The actor runtime needs a port of its own; the build may share the
  # network with others.
  actors=$(python3 -c 'import socket; s = socket.socket(type=socket.SOCK_DGRAM); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  (
    cd state
    exec env ${environment} \
      UNIX_SOCKET="$sock" ACTORS_PORT="$actors" \
      STATIC_API_KEY="$key" ENCRYPTION_KEY=encryption-key-0123456789abcdef \
      ${lib.getExe package}
  ) > pocket-id.log 2>&1 &
  pid=$!
  for _ in $(seq 300); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$sock" http://pocket-id/healthz || true)" = 204 ] && break
    kill -0 "$pid" 2> /dev/null || fail "Pocket ID exited"
    sleep 0.1
  done
  [ -S "$sock" ] || fail "Pocket ID did not answer in 30 seconds"
  grep -q "version=${package.version}" pocket-id.log || fail "not Pocket ID ${package.version}"

  # api <method> <path> [<JSON body>]: Pocket ID's admin API, as the admin
  # UI calls it. Prints the status; the body goes to api.json.
  api() {
    local args=(-s -o api.json -w '%{http_code}' --unix-socket "$sock" -X "$1" -H "X-API-Key: $key")
    if [ "$#" -gt 2 ]; then args+=(-H 'Content-Type: application/json' --data-binary "$3"); fi
    curl "''${args[@]}" "http://pocket-id$2"
  }
  # Whether Pocket ID takes client $1's secret $2, as a service would.
  introspect() {
    curl -s -o /dev/null -w '%{http_code}' --unix-socket "$sock" -u "$1:$2" \
      --data-urlencode token=none http://pocket-id/api/oidc/introspect
  }
  client() { [ "$(api GET "/api/oidc/clients/$1")" = 200 ] || fail "no client $1"; jq -r "$2" api.json; }
  secrets() { [ "$(api GET "/api/oidc/clients/$1/secrets")" = 200 ] || fail "no secrets of $1"; jq length api.json; }

  # The spec as the module writes it: Forgejo's client, and Grafana's when
  # $1 is set, with Grafana's redirect URI $2.
  spec() {
    jq -n --arg owner "$owner" --arg dir "$PWD/secrets" --arg grafana "''${1:-}" --arg uri "''${2:-https://status.example.com/login/generic_oauth}" '
      [{id: "forgejo", displayName: "Forgejo", redirectUris: ["https://git.example.com/user/oauth2/pocket-id/callback"],
        logoutRedirectUris: [], pkce: false,
        idFile: "\($dir)/forgejo-oidc-client-id", secretFile: "\($dir)/forgejo-oidc-client-secret",
        owner: $owner, units: ["forgejo-oidc.service"]}]
      + if $grafana == "" then [] else
        [{id: "grafana", displayName: "Grafana", redirectUris: [$uri], logoutRedirectUris: [], pkce: true,
          idFile: "\($dir)/grafana-oidc-client-id", secretFile: "\($dir)/grafana-oidc-client-secret",
          owner: $owner, units: ["podman-grafana.service"]}]
      end' > spec.json
  }
  # run [<API key file>] [<socket>]: the unit's script. The requests it
  # made, as "METHOD path" from Pocket ID's log, go to requests.
  run() {
    : > systemctl.log
    local from=$(($(wc -l < pocket-id.log) + 1))
    local status=0
    timeout 60 ${script}/bin/pocket-id-clients spec.json "''${2:-$sock}" "''${1:-api-key}" declared.json > out 2> err || status=$?
    tail -n "+$from" pocket-id.log | sed -n 's/.* method=\([A-Z]*\) path=\([^ ]*\) .*/\1 \2/p' > requests
    return "$status"
  }
  # Whether the last run wrote anything to Pocket ID.
  wrote() { grep -v '^GET \|^POST /api/oidc/introspect$' requests; }

  # A client made by hand in the admin UI.
  api POST /api/oidc/clients '{"name": "Nextcloud", "callbackURLs": ["https://cloud.example.com/cb"]}' > status
  [ "$(cat status)" = 201 ] || fail "hand-made client: $(cat status) $(cat api.json)"
  hand=$(jq -r .id api.json)
  [ "$(client "$hand" .name)" = Nextcloud ] || fail "hand-made client not made"
  client "$hand" 'del(.credentials)' > hand.json

  # The client a failed run of the old script left: created with the id
  # forgejo, and a secret Pocket ID made with it that went nowhere.
  api POST /api/oidc/clients '{"id": "forgejo", "name": "Forgejo", "callbackURLs": ["https://git.example.com/user/oauth2/pocket-id/callback"]}' > status
  [ "$(cat status)" = 201 ] || fail "leftover client: $(cat status) $(cat api.json)"
  [ "$(jq -r .id api.json)" = forgejo ] || fail "Pocket ID did not keep the id forgejo: $(jq -r .id api.json)"
  lost=$(jq -r '.createdSecret.secret // empty' api.json)
  [ -n "$lost" ] || fail "Pocket ID made no secret with the client; is AUTO_CREATE_OIDC_CLIENT_SECRET off?"

  # First run: forgejo taken over, grafana made, their files written 0400
  # with secrets Pocket ID takes, one secret each, and both clients' units
  # restarted.
  spec grafana
  : > secrets/grafana-oidc-client-secret
  run || { cat out err; fail "first: failed"; }
  grep -qx "POST /api/oidc/clients" requests || fail "first: grafana not created"
  [ "$(grep -cx "POST /api/oidc/clients" requests)" = 1 ] || fail "first: forgejo created again"
  [ "$(cat secrets/forgejo-oidc-client-id)" = forgejo ] || fail "first: forgejo id file"
  [ "$(cat secrets/grafana-oidc-client-id)" = grafana ] || fail "first: grafana id file"
  for f in secrets/*; do
    [ "$(stat -c %a "$f")" = 400 ] || fail "first: $f is mode $(stat -c %a "$f")"
  done
  forgejo_secret=$(cat secrets/forgejo-oidc-client-secret)
  grafana_secret=$(cat secrets/grafana-oidc-client-secret)
  [ "$(introspect forgejo "$forgejo_secret")" = 200 ] || fail "first: Pocket ID refuses forgejo's file"
  [ "$(introspect grafana "$grafana_secret")" = 200 ] || fail "first: Pocket ID refuses grafana's file"
  [ "$(introspect forgejo "$lost")" = 401 ] || fail "first: the leftover's secret still works"
  [ "$(secrets forgejo)" = 1 ] && [ "$(secrets grafana)" = 1 ] || fail "first: more than one secret"
  [ "$(client forgejo .name)" = Forgejo ] || fail "first: forgejo's name"
  [ "$(client forgejo '.callbackURLs | join(" ")')" = https://git.example.com/user/oauth2/pocket-id/callback ] || fail "first: forgejo's redirect URIs"
  [ "$(client forgejo .pkceEnabled)" = false ] && [ "$(client grafana .pkceEnabled)" = true ] || fail "first: PKCE"
  [ "$(client grafana .isPublic)" = false ] || fail "first: grafana is public"
  [ "$(client "$hand" 'del(.credentials)')" = "$(cat hand.json)" ] || fail "first: hand-made client changed"
  [ "$(cat declared.json)" = '["forgejo","grafana"]' ] || fail "first: declared ids $(cat declared.json)"
  [ "$(cat systemctl.log)" = "try-restart --no-block -- forgejo-oidc.service podman-grafana.service" ] || fail "first: systemctl $(cat systemctl.log)"
  if grep -qF -e "$forgejo_secret" -e "$grafana_secret" -e "$key" out err; then fail "first: a secret in the output"; fi

  # Settings made in the admin UI that the spec does not name.
  client grafana '. + {isGroupRestricted: true, launchURL: "https://status.example.com", accessTokenDurationMinutes: 30}' > change.json
  [ "$(api PUT /api/oidc/clients/grafana "$(cat change.json)")" = 200 ] || fail "admin UI: $(cat api.json)"

  # Again: nothing to do. The secrets are checked, not replaced, and
  # nothing is written or restarted.
  run || { cat out err; fail "again: failed"; }
  [ "$(cat secrets/forgejo-oidc-client-secret)" = "$forgejo_secret" ] || fail "again: secret replaced"
  [ "$(cat secrets/grafana-oidc-client-secret)" = "$grafana_secret" ] || fail "again: secret replaced"
  [ ! -s systemctl.log ] || fail "again: restarted $(cat systemctl.log)"
  grep -qx "POST /api/oidc/introspect" requests || fail "again: secrets not checked"
  if wrote; then fail "again: wrote to Pocket ID"; fi

  # A changed redirect URI: Grafana's client follows, the secret and the
  # admin UI's settings stay, and nothing is restarted.
  spec grafana https://grafana.example.com/login/generic_oauth
  run || { cat out err; fail "uri: failed"; }
  [ "$(wrote)" = "PUT /api/oidc/clients/grafana" ] || fail "uri: wrote $(wrote)"
  [ "$(client grafana '.callbackURLs | join(" ")')" = https://grafana.example.com/login/generic_oauth ] || fail "uri: not updated"
  [ "$(client grafana .isGroupRestricted)" = true ] || fail "uri: group restriction lost"
  [ "$(client grafana .launchURL)" = https://status.example.com ] || fail "uri: launch URL lost"
  [ "$(client grafana .accessTokenDurationMinutes)" = 30 ] || fail "uri: token lifetime lost"
  [ "$(introspect grafana "$grafana_secret")" = 200 ] || fail "uri: secret no longer works"
  [ ! -s systemctl.log ] || fail "uri: restarted $(cat systemctl.log)"

  # An emptied secret file gets a new secret, the old one stops working,
  # and only Forgejo is restarted.
  rm -f secrets/forgejo-oidc-client-secret
  : > secrets/forgejo-oidc-client-secret
  run || { cat out err; fail "emptied: failed"; }
  new=$(cat secrets/forgejo-oidc-client-secret)
  [ -n "$new" ] && [ "$new" != "$forgejo_secret" ] || fail "emptied: no new secret"
  [ "$(introspect forgejo "$new")" = 200 ] || fail "emptied: Pocket ID refuses the new secret"
  [ "$(introspect forgejo "$forgejo_secret")" = 401 ] || fail "emptied: the old secret still works"
  [ "$(secrets forgejo)" = 1 ] || fail "emptied: $(secrets forgejo) secrets"
  [ "$(cat systemctl.log)" = "try-restart --no-block -- forgejo-oidc.service" ] || fail "emptied: systemctl $(cat systemctl.log)"

  # A secret Pocket ID refuses, deleted in the admin UI, gets a new one.
  api GET /api/oidc/clients/grafana/secrets > /dev/null
  [ "$(api DELETE "/api/oidc/clients/grafana/secrets/$(jq -r '.[0].id' api.json)")" = 204 ] || fail "refused: $(cat api.json)"
  [ "$(introspect grafana "$grafana_secret")" = 401 ] || fail "refused: Pocket ID still takes the secret"
  run || { cat out err; fail "refused: failed"; }
  new=$(cat secrets/grafana-oidc-client-secret)
  [ "$new" != "$grafana_secret" ] || fail "refused: secret kept"
  [ "$(introspect grafana "$new")" = 200 ] || fail "refused: Pocket ID refuses the new secret"
  [ "$(cat systemctl.log)" = "try-restart --no-block -- podman-grafana.service" ] || fail "refused: systemctl $(cat systemctl.log)"

  # Grafana no longer declared: its client goes, its files and the
  # hand-made client stay.
  spec
  run || { cat out err; fail "removed: failed"; }
  [ "$(api GET /api/oidc/clients/grafana)" = 404 ] || fail "removed: grafana still in Pocket ID"
  [ "$(client forgejo .id)" = forgejo ] || fail "removed: forgejo gone"
  [ "$(client "$hand" 'del(.credentials)')" = "$(cat hand.json)" ] || fail "removed: hand-made client changed"
  [ -s secrets/grafana-oidc-client-secret ] || fail "removed: grafana's secret file deleted"
  [ "$(cat declared.json)" = '["forgejo"]' ] || fail "removed: declared ids $(cat declared.json)"

  # A wrong API key fails and changes nothing.
  echo wrong-key-0123456789 > bad-key # public-check: fake
  spec grafana
  if run bad-key; then fail "bad key: succeeded"; fi
  grep -q "answered 401" err || fail "bad key: no message: $(cat err)"
  [ "$(api GET /api/oidc/clients/grafana)" = 404 ] || fail "bad key: grafana made"
  [ "$(cat declared.json)" = '["forgejo"]' ] || fail "bad key: declared ids $(cat declared.json)"

  # A Pocket ID that does not answer fails after its tries.
  if run api-key "$PWD/nothing.sock"; then fail "down: succeeded"; fi
  grep -q "did not answer" err || fail "down: no message: $(cat err)"

  kill "$pid"
  touch $out
''
