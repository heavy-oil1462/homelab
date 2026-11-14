# Runs containers/grafana-git-sync.sh against a stubbed podman and a
# stand-in for Grafana's provisioning API: a first run creates the
# repository, a run with nothing to do changes nothing, a spec changed in
# Grafana and a new token each replace it, and a refused Git token, a
# refused or missing API token, a Grafana that does not answer and one that
# never finishes answering fail.
#
# Nothing here may outlive or stall the build. Outside the build sandbox,
# as in CI, Nix waits until every process holding the build's output has
# closed it, so the stand-in logs to a file and is killed at the end; it
# listens on a free port, and its start and every run of the script have
# a deadline.
{ runCommand, callPackage, runtimeShell, python3, jq }:

let
  script = callPackage ../containers/grafana-git-sync.nix { };
in
runCommand "grafana-git-sync-test" { nativeBuildInputs = [ python3 jq ]; } ''
  set -euo pipefail
  mkdir bin fake
  export PATH=$PWD/bin:$PATH STUB=$PWD
  export GRAFANA_GIT_SYNC_TRIES=3 GRAFANA_GIT_SYNC_WAIT=0
  fake=
  fail() {
    echo "FAIL: $*" >&2
    [ -z "$fake" ] || kill "$fake" 2> /dev/null || true
    exit 1
  }

  # podman gives the grafana container's address, 127.0.0.1, where the
  # stand-in listens.
  cat > bin/podman <<'STUB'
  #!${runtimeShell}
  echo "$*" >> "$STUB/podman.log"
  case "$*" in
    "inspect -f "*" grafana") echo "127.0.0.1 " ;;
    *) exit 64 ;;
  esac
  STUB
  chmod +x bin/podman

  echo api-token-1 > api-token # public-check: fake
  echo git-token-1 > token # public-check: fake
  cat > repository.json <<'EOF'
  {"apiVersion":"provisioning.grafana.app/v0alpha1","kind":"Repository",
   "metadata":{"name":"homelab-dashboards","namespace":"default"},
   "spec":{"title":"Dashboards","type":"git",
     "git":{"url":"https://git.example.com/org/dashboards.git","branch":"main","path":"dashboards","tokenUser":"git"},
     "sync":{"enabled":true,"target":"folder","intervalSeconds":60},
     "workflows":["write"]}}
  EOF

  python3 -I ${./fake-grafana.py} port api-token-1 fake > fake.log 2>&1 &
  fake=$!
  for _ in $(seq 50); do
    [ -s port ] && break
    kill -0 "$fake" 2> /dev/null || { cat fake.log; fail "the stand-in for Grafana exited"; }
    sleep 0.2
  done
  [ -s port ] || { cat fake.log; fail "the stand-in for Grafana did not start in 10 seconds"; }
  export GRAFANA_GIT_SYNC_PORT=$(cat port)

  # Each run gets 60 seconds.
  run() {
    : > fake/requests
    local status=0
    timeout 60 ${script}/bin/grafana-git-sync grafana repository.json token api-token state > out 2> err || status=$?
    [ "$status" -ne 124 ] || { cat out err; fail "the script did not finish in 60 seconds"; }
    return "$status"
  }
  writes() { grep -c '^\(POST\|PUT\) .*/repositories\(/homelab-dashboards\)\?$' fake/requests || true; }

  # First run: creates the repository with the Git token, records it and
  # tests it.
  run || { cat out err; fail "first: failed"; }
  grep -q '^POST /apis/provisioning.grafana.app/v0alpha1/namespaces/default/repositories$' fake/requests \
    || fail "first: not created: $(cat fake/requests)"
  [ "$(cat fake/token)" = git-token-1 ] || fail "first: Grafana got the token '$(cat fake/token)'"
  jq -e '.spec.git.url == "https://git.example.com/org/dashboards.git" and .spec.workflows == ["write"]' \
    fake/repository.json > /dev/null || fail "first: spec: $(cat fake/repository.json)"
  grep -q '/homelab-dashboards/test$' fake/requests || fail "first: not tested"
  grep -q "Created" out || fail "first: no log line: $(cat out)"
  [ -s state ] || fail "first: no state"
  if grep -q "git-token-1" state; then fail "first: token in the state file"; fi

  # Again: in step, only read and tested, though Grafana added fields.
  run || { cat out err; fail "again: failed"; }
  [ "$(writes)" -eq 0 ] || fail "again: written: $(cat fake/requests)"
  grep -q "in step" out || fail "again: no log line: $(cat out)"

  # Someone changed the branch in Grafana: put back.
  jq '.spec.git.branch = "other"' fake/repository.json > r && mv r fake/repository.json
  run || { cat out err; fail "drift: failed"; }
  grep -q '^PUT .*/repositories/homelab-dashboards$' fake/requests || fail "drift: not replaced: $(cat fake/requests)"
  jq -e '.spec.git.branch == "main"' fake/repository.json > /dev/null || fail "drift: branch still $(jq .spec.git.branch fake/repository.json)"

  # A new Git token: replaced with it.
  echo git-token-2 > token # public-check: fake
  run || { cat out err; fail "new token: failed"; }
  grep -q '^PUT ' fake/requests || fail "new token: not replaced"
  [ "$(cat fake/token)" = git-token-2 ] || fail "new token: Grafana got '$(cat fake/token)'"

  # A Git token the server refuses: Grafana's test fails, so does the unit.
  touch fake/bad-token
  if run; then fail "bad token: succeeded"; fi
  grep -q "not authorized" err || fail "bad token: no clear error: $(cat err)"
  rm fake/bad-token

  # An API token Grafana refuses: fails without writing.
  echo api-token-2 > api-token # public-check: fake
  if run; then fail "refused API token: succeeded"; fi
  [ "$(writes)" -eq 0 ] || fail "refused API token: written"
  grep -q "refused the API token" err || fail "refused API token: no clear error: $(cat err)"
  echo api-token-1 > api-token # public-check: fake

  # An empty Git token file: fails before calling Grafana.
  : > token
  if run; then fail "empty token: succeeded"; fi
  [ ! -s fake/requests ] || fail "empty token: went on: $(cat fake/requests)"
  grep -q "token file token is missing or empty" err || fail "empty token: no clear error: $(cat err)"
  echo git-token-2 > token # public-check: fake

  # Grafana does not answer: tries GRAFANA_GIT_SYNC_TRIES times, then fails.
  touch fake/down
  if run; then fail "down: succeeded"; fi
  [ "$(grep -c '^GET /api/health' fake/requests)" -eq 3 ] || fail "down: expected 3 tries: $(cat fake/requests)"
  grep -q "did not answer" err || fail "down: no clear error: $(cat err)"
  rm fake/down

  # Grafana takes the connection but does not answer: each try gives up
  # after 5 seconds, and the run fails well within its 60.
  touch fake/stall
  if run; then fail "stall: succeeded"; fi
  grep -q "did not answer" err || fail "stall: no clear error: $(cat err)"
  rm fake/stall

  # A new host, where Grafana has no repository yet but the state file is
  # left from before: created again.
  rm fake/repository.json
  run || { cat out err; fail "recreate: failed"; }
  grep -q '^POST ' fake/requests || fail "recreate: not created"

  kill "$fake"
  echo ok > $out
''
