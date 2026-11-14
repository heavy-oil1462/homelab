# Shared by tests/tailnet-identity.nix and tests/identity-mapping.nix:
# starts the stand-in for nginx-auth and Caddy, and stops both on failure.
#
# Nothing here may outlive or stall the build. Outside the build sandbox,
# as in CI, Nix waits until every process holding the build's output has
# closed it, so both log to files and are killed by fail() and stop(), and
# each start and request has a deadline. Caddy listens on free ports, which
# a fixed port is not outside the sandbox.
#
#   . identity-harness.sh
#   start_auth <fake-nginx-auth.py>    # whois.sock, reads mode, logs lookups
#   start_caddy PORT_A PORT_B ...      # exports each as a free port, which
#                                      # the Caddyfile reads as {$PORT_A}
#   get <port> <curl args>...          # body and status of one request
#   stop

pids=()

stop() {
  local p
  for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done
  pids=()
}

fail() {
  echo "FAIL: $*" >&2
  for log in auth.log caddy.log; do
    [ ! -s "$log" ] || { echo "--- $log" >&2; cat "$log" >&2; }
  done
  stop
  exit 1
}

start_auth() {
  rm -f whois.sock
  python3 -I "$1" "$PWD/whois.sock" mode lookups > auth.log 2>&1 &
  local pid=$!
  pids+=("$pid")
  for _ in $(seq 50); do
    [ -S whois.sock ] && return
    kill -0 "$pid" 2> /dev/null || fail "the stand-in for nginx-auth exited"
    sleep 0.2
  done
  fail "the stand-in for nginx-auth did not start in 10 seconds"
}

free_port() {
  python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# Another listener can take a port between free_port and Caddy binding it;
# Caddy then exits, and gets three more tries on other ports.
start_caddy() {
  local pid var up
  for _ in 1 2 3 4; do
    for var in "$@"; do export "$var=$(free_port)"; done
    caddy run --config Caddyfile --adapter caddyfile > caddy.log 2>&1 &
    pid=$!
    for _ in $(seq 50); do
      kill -0 "$pid" 2> /dev/null || break
      up=1
      for var in "$@"; do
        curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${!var}/" || { up=; break; }
      done
      if [ -n "$up" ]; then pids+=("$pid"); return; fi
      sleep 0.2
    done
    kill "$pid" 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
  done
  fail "Caddy did not start"
}

get() {
  local port=$1; shift
  curl -s --max-time 10 -w ' %{http_code}' "$@" "http://127.0.0.1:$port/" || true
}
