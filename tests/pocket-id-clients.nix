# Runs modules/pocket-id-clients.sh against a stand-in for Pocket ID's
# admin API on a unix socket and a stubbed systemctl
# (docs/adr/0018-pocket-id-is-the-oidc-provider.md): a first run creates
# both clients and writes their files, keeping a client made in the admin
# UI; a run with nothing to do changes nothing and restarts nothing; a
# changed redirect URI updates the client and keeps what the admin UI set;
# an emptied secret file and a secret Pocket ID refuses each get a new
# secret and restart only their client's units; a client no longer
# declared is deleted with its files left; a wrong API key and a Pocket ID
# that never answers fail. No secret is in the output.
#
# The stand-in logs to a file and is killed at the end, so nothing holds
# the build's output open, and every run has a deadline.
{ runCommand, callPackage, runtimeShell, python3, jq }:

let
  script = callPackage ../modules/pocket-id-clients.nix { };
in
runCommand "pocket-id-clients-test" { nativeBuildInputs = [ python3 jq ]; } ''
  set -euo pipefail
  mkdir bin fake secrets
  export PATH=$PWD/bin:$PATH STUB=$PWD
  export POCKET_ID_CLIENTS_TRIES=3 POCKET_ID_CLIENTS_WAIT=0
  fake=
  fail() {
    echo "FAIL: $*" >&2
    [ -z "$fake" ] || kill "$fake" 2> /dev/null || true
    exit 1
  }

  cat > bin/systemctl <<'STUB'
  #!${runtimeShell}
  echo "$*" >> "$STUB/systemctl.log"
  STUB
  chmod +x bin/systemctl

  owner="$(id -u):$(id -g)"
  sock=$PWD/pocket-id.sock
  printf 'api-key-0123456789abcdef\n' > api-key # public-check: fake
  clients=fake/clients.json

  # The spec as the module writes it: Forgejo's client, and Grafana's when
  # $1 is set, with Grafana's redirect URI $2.
  spec() {
    jq -n --arg owner "$owner" --arg dir "$PWD/secrets" --arg grafana "''${1:-}" --arg uri "''${2:-https://status.example.com/login/generic_oauth}" '
      [{id: "forgejo", displayName: "Forgejo", redirectUris: ["https://git.example.com/user/oauth2/pocket-id/callback"],
        logoutRedirectUris: [], pkce: false,
        idFile: "\($dir)/forgejo-oidc-client-id", secretFile: "\($dir)/forgejo-oidc-client-secret",
        owner: $owner, units: ["forgejo-oidc.service"]}]
      + if $grafana == "" then [] else
        [{id: "grafana", displayName: "grafana", redirectUris: [$uri], logoutRedirectUris: [], pkce: true,
          idFile: "\($dir)/grafana-oidc-client-id", secretFile: "\($dir)/grafana-oidc-client-secret",
          owner: $owner, units: ["podman-grafana.service"]}]
      end' > spec.json
  }
  run() {
    : > systemctl.log
    : > fake/requests
    timeout 60 ${script}/bin/pocket-id-clients spec.json "$sock" "''${1:-api-key}" declared.json > out 2> err
  }
  field() { jq -r "$1" "$clients"; }
  # Whether a request was made, as "METHOD path".
  requested() { grep -qx "$1" fake/requests; }

  python3 -I ${./fake-pocket-id.py} "$sock" api-key-0123456789abcdef fake > fake.log 2>&1 &
  fake=$!
  for _ in $(seq 100); do
    [ -S "$sock" ] && break
    kill -0 "$fake" 2> /dev/null || { cat fake.log; fail "the stand-in for Pocket ID exited"; }
    sleep 0.1
  done
  [ -S "$sock" ] || { cat fake.log; fail "the stand-in for Pocket ID did not start in 10 seconds"; }

  # A client made by hand in the admin UI.
  echo '{"nextcloud": {"id": "nextcloud", "name": "Nextcloud", "callbackURLs": ["https://cloud.example.com/cb"],
    "logoutCallbackURLs": [], "isPublic": false, "pkceEnabled": false, "requiresReauthentication": false,
    "launchURL": null, "isGroupRestricted": false, "credentials": {}, "secret": "hand-made"}}' > "$clients" # public-check: fake
  hand=$(jq -cS .nextcloud "$clients")

  # First run: both clients made, their files written 0400 with the
  # secrets Pocket ID made, and both clients' units restarted.
  spec grafana
  : > secrets/grafana-oidc-client-secret
  run || { cat out err; fail "first: failed"; }
  [ "$(cat secrets/forgejo-oidc-client-id)" = forgejo ] || fail "first: forgejo id file"
  [ "$(cat secrets/grafana-oidc-client-id)" = grafana ] || fail "first: grafana id file"
  for f in secrets/*; do
    [ "$(stat -c %a "$f")" = 400 ] || fail "first: $f is mode $(stat -c %a "$f")"
  done
  forgejo_secret=$(cat secrets/forgejo-oidc-client-secret)
  grafana_secret=$(cat secrets/grafana-oidc-client-secret)
  [ "$(field .forgejo.secret)" = "$forgejo_secret" ] || fail "first: forgejo's file is not Pocket ID's secret"
  [ "$(field .grafana.secret)" = "$grafana_secret" ] || fail "first: grafana's file is not Pocket ID's secret"
  [ "$(field .forgejo.name)" = Forgejo ] || fail "first: forgejo's name is $(field .forgejo.name)"
  [ "$(field '.forgejo.callbackURLs | join(" ")')" = https://git.example.com/user/oauth2/pocket-id/callback ] || fail "first: forgejo's redirect URIs"
  [ "$(field .forgejo.pkceEnabled)" = false ] && [ "$(field .grafana.pkceEnabled)" = true ] || fail "first: PKCE"
  [ "$(field .grafana.isPublic)" = false ] || fail "first: grafana is public"
  [ "$(jq -cS .nextcloud "$clients")" = "$hand" ] || fail "first: hand-made client changed"
  [ "$(cat declared.json)" = '["forgejo","grafana"]' ] || fail "first: declared ids $(cat declared.json)"
  [ "$(cat systemctl.log)" = "try-restart --no-block -- forgejo-oidc.service podman-grafana.service" ] || fail "first: systemctl $(cat systemctl.log)"
  if grep -qF -e "$forgejo_secret" -e "$grafana_secret" -e api-key-0123456789abcdef out err; then fail "first: a secret in the output"; fi

  # A setting made in the admin UI that the spec does not name.
  jq '.grafana.isGroupRestricted = true | .grafana.launchURL = "https://status.example.com"' "$clients" > c.json
  mv c.json "$clients"

  # Again: nothing to do. The secrets are checked, not replaced, and
  # nothing is written or restarted.
  cp -p secrets/forgejo-oidc-client-secret forgejo-before
  run || { cat out err; fail "again: failed"; }
  [ "$(cat secrets/forgejo-oidc-client-secret)" = "$forgejo_secret" ] || fail "again: secret replaced"
  [ "$(cat secrets/grafana-oidc-client-secret)" = "$grafana_secret" ] || fail "again: secret replaced"
  [ ! -s systemctl.log ] || fail "again: restarted $(cat systemctl.log)"
  requested "POST /api/oidc/introspect" || fail "again: secrets not checked"
  if grep -q '^\(PUT\|DELETE\)\|/secret$\|^POST /api/oidc/clients$' fake/requests; then fail "again: wrote $(cat fake/requests)"; fi

  # A changed redirect URI: Grafana's client follows, the secret and the
  # admin UI's settings stay, and nothing is restarted.
  spec grafana https://grafana.example.com/login/generic_oauth
  run || { cat out err; fail "uri: failed"; }
  [ "$(field '.grafana.callbackURLs | join(" ")')" = https://grafana.example.com/login/generic_oauth ] || fail "uri: not updated"
  [ "$(field .grafana.isGroupRestricted)" = true ] || fail "uri: group restriction lost"
  [ "$(field .grafana.launchURL)" = https://status.example.com ] || fail "uri: launch URL lost"
  [ "$(field .grafana.secret)" = "$grafana_secret" ] || fail "uri: secret changed"
  [ ! -s systemctl.log ] || fail "uri: restarted $(cat systemctl.log)"

  # An emptied secret file gets a new secret; only Forgejo is restarted.
  rm -f secrets/forgejo-oidc-client-secret
  : > secrets/forgejo-oidc-client-secret
  run || { cat out err; fail "emptied: failed"; }
  new=$(cat secrets/forgejo-oidc-client-secret)
  [ -n "$new" ] && [ "$new" != "$forgejo_secret" ] || fail "emptied: no new secret"
  [ "$(field .forgejo.secret)" = "$new" ] || fail "emptied: file is not Pocket ID's secret"
  [ "$(cat systemctl.log)" = "try-restart --no-block -- forgejo-oidc.service" ] || fail "emptied: systemctl $(cat systemctl.log)"

  # A secret Pocket ID no longer takes, as after it was made again in the
  # admin UI, gets a new one too.
  jq '.grafana.secret = "made-in-the-ui"' "$clients" > c.json # public-check: fake
  mv c.json "$clients"
  run || { cat out err; fail "refused: failed"; }
  [ "$(cat secrets/grafana-oidc-client-secret)" != "$grafana_secret" ] || fail "refused: secret kept"
  [ "$(field .grafana.secret)" = "$(cat secrets/grafana-oidc-client-secret)" ] || fail "refused: file is not Pocket ID's secret"
  [ "$(cat systemctl.log)" = "try-restart --no-block -- podman-grafana.service" ] || fail "refused: systemctl $(cat systemctl.log)"

  # Grafana no longer declared: its client goes, its files and the
  # hand-made client stay.
  spec
  run || { cat out err; fail "removed: failed"; }
  [ "$(field 'has("grafana")')" = false ] || fail "removed: grafana still in Pocket ID"
  [ "$(field 'has("forgejo")')" = true ] || fail "removed: forgejo gone"
  [ "$(jq -cS .nextcloud "$clients")" = "$hand" ] || fail "removed: hand-made client changed"
  [ -s secrets/grafana-oidc-client-secret ] || fail "removed: grafana's secret file deleted"
  [ "$(cat declared.json)" = '["forgejo"]' ] || fail "removed: declared ids $(cat declared.json)"

  # A wrong API key fails and changes nothing.
  echo wrong-key-0123456789 > bad-key # public-check: fake
  cp "$clients" before.json
  if run bad-key; then fail "bad key: succeeded"; fi
  grep -q "answered 401" err || fail "bad key: no message: $(cat err)"
  cmp -s before.json "$clients" || fail "bad key: clients changed"

  # A Pocket ID that does not answer fails after its tries.
  touch fake/down
  if run; then fail "down: succeeded"; fi
  grep -q "did not answer" err || fail "down: no message: $(cat err)"
  rm fake/down

  kill "$fake"
  touch $out
''
