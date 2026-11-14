# Runs modules/tsidp-clients.sh against a fake tsidp state directory: a
# first start with no clients file, a start with a client registered by
# hand, a run with nothing to do, a changed redirect URI, a secret put in
# its file by hand, a client no longer declared and a clients file that is
# not JSON.
{ runCommand, callPackage, jq }:

let
  script = callPackage ../modules/tsidp-clients.nix { };
in
runCommand "tsidp-clients-test" { nativeBuildInputs = [ jq ]; } ''
  set -euo pipefail
  fail() { echo "FAIL: $*" >&2; exit 1; }
  mkdir state secrets
  owner="$(id -u):$(id -g)"
  clients=state/oidc-funnel-clients.json

  # The spec as the module writes it: Forgejo's client, and Grafana's when
  # $1 is set, with Grafana's redirect URI $2.
  spec() {
    jq -n --arg owner "$owner" --arg dir "$PWD/secrets" --arg grafana "''${1:-}" --arg uri "''${2:-https://status.example.com/login/generic_oauth}" '
      [{id: "forgejo", redirectUris: ["https://git.example.com/user/oauth2/tailscale/callback"],
        idFile: "\($dir)/forgejo-oidc-client-id", secretFile: "\($dir)/forgejo-oidc-client-secret", owner: $owner}]
      + if $grafana == "" then [] else
        [{id: "grafana", redirectUris: [$uri],
          idFile: "\($dir)/grafana-oidc-client-id", secretFile: "\($dir)/grafana-oidc-client-secret", owner: $owner}]
      end' > spec.json
  }
  run() {
    ${script}/bin/tsidp-clients spec.json state > out 2> err
  }
  field() { jq -r "$1" "$clients"; }

  # First start: no clients file yet, Grafana's secret an empty file as
  # tmpfiles leaves it. Both files are written, 0400, and both clients.
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
  [ "''${#forgejo_secret}" = 64 ] && [ "''${#grafana_secret}" = 64 ] || fail "first: secrets not 64 hex digits"
  [ "$forgejo_secret" != "$grafana_secret" ] || fail "first: same secret twice"
  [ "$(field .forgejo.client_secret)" = "$forgejo_secret" ] || fail "first: forgejo secret not in tsidp"
  [ "$(field .grafana.client_secret)" = "$grafana_secret" ] || fail "first: grafana secret not in tsidp"
  [ "$(field '.forgejo.redirect_uris | join(" ")')" = https://git.example.com/user/oauth2/tailscale/callback ] || fail "first: redirect URIs"
  [ "$(field .forgejo.redirect_uri)" = https://git.example.com/user/oauth2/tailscale/callback ] || fail "first: redirect_uri"
  [ "$(stat -c %a "$clients")" = 600 ] || fail "first: clients file mode"
  if grep -q "$forgejo_secret" out err; then fail "first: secret logged"; fi

  # A client registered by hand in the admin UI, as tsidp writes it.
  jq '. + {"0a1b2c": {client_id: "0a1b2c", client_secret: "hand-made", client_name: "Nextcloud",
    redirect_uris: ["https://cloud.example.com/callback"], redirect_uri: "https://cloud.example.com/callback",
    created_at: "2026-11-01T00:00:00Z"}}' "$clients" > hand.json # public-check: fake
  cp hand.json "$clients"
  hand=$(jq -cS '.["0a1b2c"]' hand.json)

  # Again: nothing to do, the files and the secrets are kept.
  cp "$clients" before.json
  run || { cat out err; fail "again: failed"; }
  cmp -s before.json "$clients" || fail "again: clients file rewritten"
  [ "$(cat secrets/forgejo-oidc-client-secret)" = "$forgejo_secret" ] || fail "again: secret regenerated"
  grep -q "up to date" out || fail "again: no log line: $(cat out)"

  # A changed redirect URI: Grafana's client follows, its creation time and
  # secret stay, the hand-made client is untouched.
  created=$(field .grafana.created_at)
  spec grafana https://grafana.example.com/login/generic_oauth
  run || { cat out err; fail "uri: failed"; }
  [ "$(field '.grafana.redirect_uris[0]')" = https://grafana.example.com/login/generic_oauth ] || fail "uri: not updated"
  [ "$(field .grafana.created_at)" = "$created" ] || fail "uri: created_at changed"
  [ "$(field .grafana.client_secret)" = "$grafana_secret" ] || fail "uri: secret changed"
  [ "$(jq -cS '.["0a1b2c"]' "$clients")" = "$hand" ] || fail "uri: hand-made client changed"

  # A secret put in its file by hand, with a newline, replaces tsidp's.
  rm -f secrets/forgejo-oidc-client-secret
  echo n3w-secret > secrets/forgejo-oidc-client-secret # public-check: fake
  run || { cat out err; fail "new secret: failed"; }
  [ "$(field .forgejo.client_secret)" = n3w-secret ] || fail "new secret: tsidp has $(field .forgejo.client_secret)"

  # Grafana no longer declared: its client goes, its files and the
  # hand-made client stay.
  spec
  run || { cat out err; fail "removed: failed"; }
  [ "$(field 'has("grafana")')" = false ] || fail "removed: grafana still in tsidp"
  [ "$(field 'has("forgejo")')" = true ] || fail "removed: forgejo gone"
  [ "$(jq -cS '.["0a1b2c"]' "$clients")" = "$hand" ] || fail "removed: hand-made client changed"
  [ -s secrets/grafana-oidc-client-secret ] || fail "removed: grafana's secret file deleted"

  # A clients file that is not JSON fails the run and is left as it is.
  echo 'not json' > "$clients"
  if run; then fail "broken: succeeded"; fi
  [ "$(cat "$clients")" = "not json" ] || fail "broken: clients file changed"

  touch $out
''
