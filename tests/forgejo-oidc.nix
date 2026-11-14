# Runs containers/forgejo-oidc.sh against a stubbed podman and systemctl: a
# first run, a run with nothing to do, Forgejo that started before the
# issuer answered, a changed secret, a missing secret and an issuer that
# does not answer.
{ runCommand, callPackage, runtimeShell }:

let
  script = callPackage ../containers/forgejo-oidc.nix { };
in
runCommand "forgejo-oidc-test" { } ''
  set -euo pipefail
  mkdir bin
  export PATH=$PWD/bin:$PATH STUB=$PWD
  export FORGEJO_OIDC_TRIES=3 FORGEJO_OIDC_WAIT=0
  issuer=https://idp.tailnet.invalid

  # podman answers like the forgejo container. The source exists once added
  # (the file source), and Forgejo has set it up once restarted after that
  # (the file registered). Commands go to podman.log, stdin to stdin.
  cat > bin/podman <<'STUB'
  #!${runtimeShell}
  echo "$*" >> "$STUB/podman.log"
  case "$*" in
    *"exec -i forgejo sh -c"*)
      cat > "$STUB/stdin"
      case "$*" in *add-oauth*) touch "$STUB/source" ;; esac
      ;;
    *healthz*) [ -z "''${STUB_DOWN:-}" ] ;;
    *openid-configuration*) [ -z "''${STUB_NO_ISSUER:-}" ] ;;
    *"admin auth list"*)
      printf 'ID\tName\tType\tEnabled\n'
      [ ! -e "$STUB/source" ] || printf '1\ttailscale\tOAuth2\ttrue\n'
      ;;
    *redirect_url*)
      [ ! -e "$STUB/registered" ] || printf 'https://idp.tailnet.invalid/authorize?client_id=x'
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
  run() {
    : > podman.log; : > systemctl.log
    ${script}/bin/forgejo-oidc tailscale "$issuer" id secret state > out 2> err
  }

  # First run: adds the source with the id and secret on stdin, records it
  # and restarts Forgejo.
  run || { cat out err; fail "first: failed"; }
  grep -q -- "add-oauth --name tailscale --provider openidConnect --auto-discover-url $issuer/.well-known/openid-configuration --scopes email --scopes profile" podman.log \
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
  grep -q -- "update-oauth --id 1 --name tailscale" podman.log \
    || fail "new secret: update-oauth not called: $(cat podman.log)"
  [ "$(sed -n 2p stdin)" = s3cret-2 ] || fail "new secret: stdin was: $(cat stdin)"
  grep -q "restart podman-forgejo.service" systemctl.log || fail "new secret: Forgejo not restarted"

  # An empty secret: fails before touching Forgejo.
  : > secret
  if run; then fail "empty secret: succeeded"; fi
  [ ! -s podman.log ] || fail "empty secret: went on: $(cat podman.log)"
  grep -q "secret file secret is missing or empty" err || fail "empty secret: no clear error: $(cat err)"
  echo s3cret-2 > secret # public-check: fake

  # The issuer does not answer: tries FORGEJO_OIDC_TRIES times, then fails.
  if STUB_NO_ISSUER=1 run; then fail "no issuer: succeeded"; fi
  [ "$(grep -c openid-configuration podman.log)" -eq 3 ] || fail "no issuer: expected 3 tries: $(cat podman.log)"
  if grep -q "admin auth" podman.log; then fail "no issuer: went on"; fi
  grep -q "could not fetch" err || fail "no issuer: no clear error: $(cat err)"

  echo ok > $out
''
