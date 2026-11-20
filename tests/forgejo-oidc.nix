# Runs containers/forgejo-oidc.sh against a stubbed podman and systemctl: a
# first run, a run with nothing to do, Forgejo that started before the
# issuer answered, a changed secret, a source left from tsidp (before
# docs/adr/0023-tsidp-retired-pocket-id-only.md) that is updated and renamed
# in place, a missing secret and an issuer that does not answer.
{ runCommand, callPackage, runtimeShell }:

let
  script = callPackage ../containers/forgejo-oidc.nix { };
in
runCommand "forgejo-oidc-test" { } ''
  set -euo pipefail
  mkdir bin
  export PATH=$PWD/bin:$PATH STUB=$PWD
  export FORGEJO_OIDC_TRIES=3 FORGEJO_OIDC_WAIT=0
  issuer=https://id.home.example.com
  export STUB_ISSUER=$issuer

  # podman answers like the forgejo container. The source exists once added,
  # under the name in the file source, and Forgejo has set it up for the
  # issuer in STUB_ISSUER once restarted after that (the file registered).
  # Commands go to podman.log, stdin to stdin.
  cat > bin/podman <<'STUB'
  #!${runtimeShell}
  echo "$*" >> "$STUB/podman.log"
  case "$*" in
    *"exec -i forgejo sh -c"*)
      cat > "$STUB/stdin"
      # The value after --name.
      name=$(printf '%s\n' "$@" | sed -n '/^--name$/{n;p;q}')
      printf '%s\n' "$name" > "$STUB/source"
      ;;
    *healthz*) [ -z "''${STUB_DOWN:-}" ] ;;
    *openid-configuration*) [ -z "''${STUB_NO_ISSUER:-}" ] ;;
    *"admin auth list"*)
      printf 'ID\tName\tType\tEnabled\n'
      [ ! -e "$STUB/source" ] || printf '1\t%s\tOAuth2\ttrue\n' "$(cat "$STUB/source")"
      ;;
    *redirect_url*)
      [ ! -e "$STUB/registered" ] || printf '%s/authorize?client_id=x' "$STUB_ISSUER"
      ;;
    *) exit 64 ;;
  esac
  STUB
  cat > bin/systemctl <<'STUB'
  #!${runtimeShell}
  echo "$*" >> "$STUB/systemctl.log"
  [ ! -e "$STUB/source" ] || touch "$STUB/registered"
  STUB
  chmod +x bin/podman bin/systemctl

  fail() { echo "FAIL: $*" >&2; exit 1; }
  echo client-1 > id
  echo s3cret-1 > secret # public-check: fake
  # The source's name, and tsidp's former one, as containers/forgejo.nix
  # passes them.
  name=pocket-id former=tailscale
  run() {
    : > podman.log; : > systemctl.log
    ${script}/bin/forgejo-oidc "$name" "$issuer" id secret state "$former" > out 2> err
  }

  # First run: adds the source with the id and secret on stdin, records it
  # and restarts Forgejo.
  run || { cat out err; fail "first: failed"; }
  grep -q -- "add-oauth --name pocket-id --provider openidConnect --auto-discover-url $issuer/.well-known/openid-configuration --scopes email --scopes profile" podman.log \
    || fail "first: add-oauth not called as expected: $(cat podman.log)"
  if grep -q "s3cret-1\|client-1" podman.log; then fail "first: id or secret on the command line"; fi
  [ "$(cat stdin)" = "$(printf 'client-1\ns3cret-1')" ] || fail "first: stdin was: $(cat stdin)"
  grep -q "restart podman-forgejo.service" systemctl.log || fail "first: Forgejo not restarted"
  [ -s state ] || fail "first: no state"
  if grep -q "s3cret-1" state; then fail "first: secret in the state file"; fi

  # Again: nothing changed and Forgejo has the source.
  run || { cat out err; fail "again: failed"; }
  if grep -q -- "-oauth" podman.log; then fail "again: source changed: $(cat podman.log)"; fi
  [ ! -s systemctl.log ] || fail "again: Forgejo restarted"
  grep -q "nothing to do" out || fail "again: no log line: $(cat out)"

  # Forgejo started before the issuer answered: restarted, source unchanged.
  rm registered
  run || { cat out err; fail "unregistered: failed"; }
  if grep -q -- "-oauth" podman.log; then fail "unregistered: source changed"; fi
  grep -q "restart podman-forgejo.service" systemctl.log || fail "unregistered: Forgejo not restarted"

  # A new secret: updates the source by its id and restarts.
  echo s3cret-2 > secret # public-check: fake
  run || { cat out err; fail "new secret: failed"; }
  grep -q -- "update-oauth --id 1 --name pocket-id" podman.log \
    || fail "new secret: update-oauth not called: $(cat podman.log)"
  [ "$(sed -n 2p stdin)" = s3cret-2 ] || fail "new secret: stdin was: $(cat stdin)"
  grep -q "restart podman-forgejo.service" systemctl.log || fail "new secret: Forgejo not restarted"

  # A host still on tsidp's source "tailscale", set up for its issuer: the
  # source is updated by its id and renamed, not added again.
  echo tailscale > source
  echo tsidp-hash > state
  echo pocket-client > id
  echo pocket-s3cret > secret # public-check: fake
  run || { cat out err; fail "switch: failed"; }
  if grep -q -- "add-oauth" podman.log; then fail "switch: added a second source: $(cat podman.log)"; fi
  grep -q -- "update-oauth --id 1 --name pocket-id --provider openidConnect --auto-discover-url $issuer/.well-known/openid-configuration" podman.log \
    || fail "switch: source not updated in place: $(cat podman.log)"
  [ "$(cat stdin)" = "$(printf 'pocket-client\npocket-s3cret')" ] || fail "switch: stdin was: $(cat stdin)"
  [ "$(cat source)" = pocket-id ] || fail "switch: source named $(cat source)"
  grep -q "restart podman-forgejo.service" systemctl.log || fail "switch: Forgejo not restarted"
  grep -q "renamed it pocket-id" out || fail "switch: no log line: $(cat out)"

  # Again on Pocket ID: nothing to do.
  run || { cat out err; fail "switched again: failed"; }
  if grep -q -- "-oauth" podman.log; then fail "switched again: source changed: $(cat podman.log)"; fi
  [ ! -s systemctl.log ] || fail "switched again: Forgejo restarted"

  # An empty secret: fails before touching Forgejo.
  : > secret
  if run; then fail "empty secret: succeeded"; fi
  [ ! -s podman.log ] || fail "empty secret: went on: $(cat podman.log)"
  grep -q "secret file secret is missing or empty" err || fail "empty secret: no clear error: $(cat err)"
  echo pocket-s3cret > secret # public-check: fake

  # The issuer does not answer: tries FORGEJO_OIDC_TRIES times, then fails.
  if STUB_NO_ISSUER=1 run; then fail "no issuer: succeeded"; fi
  [ "$(grep -c openid-configuration podman.log)" -eq 3 ] || fail "no issuer: expected 3 tries: $(cat podman.log)"
  if grep -q "admin auth" podman.log; then fail "no issuer: went on"; fi
  grep -q "could not fetch" err || fail "no issuer: no clear error: $(cat err)"

  echo ok > $out
''
