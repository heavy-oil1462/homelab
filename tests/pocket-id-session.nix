# How long a sign-in to nixpkgs' Pocket ID lasts, with the settings a host's
# unit gets, homelab.pocketId.sessionDuration among them. Each of `hosts`
# (a name, its unit's settings and the option's value) runs Pocket ID on a
# temporary state directory with SQLite, a unix socket, the static API key
# and an encryption key. A user is made through the admin API and signs in
# with a one-time access token, as `pocket-id one-time-access-token` does
# (a passkey needs a browser); the sign-in is checked to:
#
# - set the access token cookie with a Max-Age of the option, in seconds;
# - carry an access token that expires that long after it was issued;
# - be a session Pocket ID takes, for /api/users/me.
#
# Pocket ID is killed after each host, and every request has a deadline.
{ lib, runCommand, python3, jq, curl, package, hosts }:

let
  # The unit's settings as nixpkgs' module writes them to its environment
  # file; the test's own socket and actor port replace the host's.
  environment = settings: lib.concatStringsSep " " (lib.mapAttrsToList
    (name: value: lib.escapeShellArg "${name}=${if lib.isBool value then lib.boolToString value else toString value}")
    (removeAttrs settings [ "UNIX_SOCKET" "ACTORS_PORT" ]));

  check = { name, settings, minutes }: ''
    echo "${name}: SESSION_DURATION=${toString settings.SESSION_DURATION or "unset"}, expecting ${toString minutes} minutes"
    [ ${lib.escapeShellArg (toString settings.SESSION_DURATION or "")} = ${toString minutes} ] \
      || fail "${name}: the unit's SESSION_DURATION is not homelab.pocketId.sessionDuration"
    host=${lib.escapeShellArg name}
    rm -rf state pocket-id.sock && mkdir state
    actors=$(python3 -c 'import socket; s = socket.socket(type=socket.SOCK_DGRAM); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
    (
      cd state
      exec env ${environment settings} \
        UNIX_SOCKET="$sock" ACTORS_PORT="$actors" \
        STATIC_API_KEY="$key" ENCRYPTION_KEY=encryption-key-0123456789abcdef \
        ${lib.getExe package}
    ) > pocket-id.log 2>&1 &
    pid=$!
    for _ in $(seq 300); do
      [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' --unix-socket "$sock" http://pocket-id/healthz || true)" = 204 ] && break
      kill -0 "$pid" 2> /dev/null || fail "$host: Pocket ID exited"
      sleep 0.1
    done
    [ -S "$sock" ] || fail "$host: Pocket ID did not answer in 30 seconds"
    grep -q "version=${package.version}" pocket-id.log || fail "$host: not Pocket ID ${package.version}"

    [ "$(api POST /api/users '{"username": "alice", "email": "alice@example.com", "firstName": "Alice", "emailVerified": true}')" = 201 ] \
      || fail "$host: no user: $(cat api.json)"
    user=$(jq -r .id api.json)
    [ "$(api POST "/api/users/$user/one-time-access-token" '{}')" = 201 ] \
      || fail "$host: no one-time access token: $(cat api.json)"
    token=$(jq -r .token api.json)

    # The sign-in, as the browser makes it with the token's link.
    status=$(curl -s -m 10 -o /dev/null -D headers -w '%{http_code}' --unix-socket "$sock" \
      -X POST "http://pocket-id/api/one-time-access-token/$token")
    [ "$status" = 200 ] || fail "$host: sign-in answered $status"
    cookie=$(tr -d '\r' < headers | grep -i '^set-cookie: __Host-access_token=' || true)
    [ -n "$cookie" ] || fail "$host: no access token cookie: $(cat headers)"
    maxAge=$(printf '%s\n' "$cookie" | grep -o 'Max-Age=[0-9]*' | cut -d= -f2)
    [ "$maxAge" = $((${toString minutes} * 60)) ] \
      || fail "$host: the cookie lasts $maxAge seconds, not ${toString minutes} minutes"

    jwt=$(printf '%s\n' "$cookie" | sed 's/^[^=]*=\([^;]*\).*/\1/')
    lifetime=$(printf '%s' "$jwt" | python3 -c '
    import base64, json, sys
    claims = sys.stdin.read().split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(claims + "=" * (-len(claims) % 4)))
    print(claims["exp"] - claims["iat"])')
    [ "$lifetime" = $((${toString minutes} * 60)) ] \
      || fail "$host: the access token lasts $lifetime seconds, not ${toString minutes} minutes"

    status=$(curl -s -m 10 -o me.json -w '%{http_code}' --unix-socket "$sock" \
      -H "Cookie: __Host-access_token=$jwt" http://pocket-id/api/users/me)
    [ "$status" = 200 ] && [ "$(jq -r .username me.json)" = alice ] \
      || fail "$host: Pocket ID does not take its own session: $status"

    kill "$pid" && wait "$pid" || true
    pid=
    echo "$host: a sign-in lasts ${toString minutes} minutes"
  '';
in
runCommand "pocket-id-session-test" { nativeBuildInputs = [ python3 jq curl ]; } ''
  set -euo pipefail
  pid=
  fail() {
    echo "FAIL: $*" >&2
    tail -n 20 pocket-id.log >&2 || true
    [ -z "$pid" ] || kill "$pid" 2> /dev/null || true
    exit 1
  }
  sock=$PWD/pocket-id.sock
  key=api-key-0123456789abcdef # public-check: fake

  # api <method> <path> [<JSON body>]: Pocket ID's admin API. Prints the
  # status; the body goes to api.json.
  api() {
    local args=(-s -m 10 -o api.json -w '%{http_code}' --unix-socket "$sock" -X "$1" -H "X-API-Key: $key")
    if [ "$#" -gt 2 ]; then args+=(-H 'Content-Type: application/json' --data-binary "$3"); fi
    curl "''${args[@]}" "http://pocket-id$2"
  }

  ${lib.concatMapStrings check hosts}
  touch $out
''
