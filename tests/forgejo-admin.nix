# Runs containers/forgejo-admin.sh against a stubbed podman: no admin yet,
# an admin already there, and Forgejo not answering.
{ runCommand, callPackage, runtimeShell }:

let
  script = callPackage ../containers/forgejo-admin.nix { };
in
runCommand "forgejo-admin-test" { } ''
  set -euo pipefail
  mkdir bin
  export PATH=$PWD/bin:$PATH STUB_LOG=$PWD/podman.log
  export FORGEJO_ADMIN_TRIES=3 FORGEJO_ADMIN_WAIT=0
  url=https://git.example.com/user/login

  # The stub logs its arguments and answers like the forgejo container:
  # healthz fails while STUB_DOWN is set, the admin list shows STUB_ADMINS.
  cat > bin/podman <<'STUB'
  #!${runtimeShell}
  echo "$*" >> "$STUB_LOG"
  case "$*" in
    *healthz*) [ -z "''${STUB_DOWN:-}" ] ;;
    *"user list --admin"*)
      echo "ID   Username Email                IsActive IsAdmin 2FA"
      [ -z "''${STUB_ADMINS:-}" ] || echo "1    alice    alice@example.com    true     true    false"
      ;;
    *"user create"*)
      echo "generated random password is 'S3cret-pw'"
      echo "New user 'alice' has been successfully created!"
      ;;
    *) exit 64 ;;
  esac
  STUB
  chmod +x bin/podman

  fail() { echo "FAIL: $*" >&2; exit 1; }

  # No admin: creates one with a must-change password, one line out.
  : > "$STUB_LOG"
  ${script}/bin/forgejo-admin alice alice@example.com "$url" > out 2> err \
    || { cat out err; fail "no admin: failed"; }
  grep -q -- "user create --admin --username alice --email alice@example.com --random-password --must-change-password" "$STUB_LOG" \
    || fail "no admin: create not called as expected"
  [ "$(wc -l < out)" -eq 1 ] || fail "no admin: expected one line, got: $(cat out)"
  grep -q "alice" out && grep -q "S3cret-pw" out && grep -q "$url" out \
    && grep -q "first sign in" out && grep -q "passkey" out \
    || fail "no admin: line lacks name, password, URL or advice: $(cat out)"
  if grep -q "S3cret-pw" err; then fail "no admin: password on stderr"; fi
  [ "$(grep -c "user create" "$STUB_LOG")" -eq 1 ] || fail "no admin: create called more than once"

  # An admin exists: nothing created, and it says so.
  : > "$STUB_LOG"
  STUB_ADMINS=1 ${script}/bin/forgejo-admin alice alice@example.com "$url" > out 2> err \
    || { cat out err; fail "admin exists: failed"; }
  if grep -q "user create" "$STUB_LOG"; then fail "admin exists: create called"; fi
  grep -q "already has an admin" out || fail "admin exists: no log line: $(cat out)"

  # Forgejo not answering: tries FORGEJO_ADMIN_TRIES times, then fails.
  : > "$STUB_LOG"
  if STUB_DOWN=1 ${script}/bin/forgejo-admin alice alice@example.com "$url" > out 2> err; then
    fail "down: succeeded"
  fi
  [ "$(grep -c healthz "$STUB_LOG")" -eq 3 ] || fail "down: expected 3 tries: $(cat "$STUB_LOG")"
  if grep -q "user" "$STUB_LOG"; then fail "down: went on past the health check"; fi
  grep -q "did not answer" err || fail "down: no clear error: $(cat err)"

  echo ok > $out
''
