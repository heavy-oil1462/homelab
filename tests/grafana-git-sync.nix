# Runs containers/grafana-git-sync.sh against a stubbed podman and a
# stand-in for Grafana's provisioning API: a first run creates the
# repository, a run with nothing to do changes nothing, a spec changed in
# Grafana and a new token each replace it, and a refused Git token, a
# refused or missing API token, a Grafana that does not answer and one that
# never finishes answering fail.
#
# Seeding (docs/adr/0011-git-sync-seeds-an-empty-repository.md) runs
# against bare repositories behind `git http-backend` with basic auth: an
# empty repository gets one commit with exactly the seed's dashboards, in
# Git Sync's resource form; one with history is left alone; a refused push
# fails before Grafana is called; and the token is in no process's command
# line or environment and in no output.
#
# Nothing here may outlive or stall the build. Outside the build sandbox,
# as in CI, Nix waits until every process holding the build's output has
# closed it, so the stand-in logs to a file and is killed at the end; it
# listens on a free port, and its start and every run of the script have
# a deadline.
{ runCommand, callPackage, runtimeShell, python3, jq, git }:

let
  script = callPackage ../containers/grafana-git-sync.nix { };
in
runCommand "grafana-git-sync-test" { nativeBuildInputs = [ python3 jq git ]; } ''
  set -euo pipefail
  mkdir bin fake
  export PATH=$PWD/bin:$PATH STUB=$PWD
  export GRAFANA_GIT_SYNC_TRIES=3 GRAFANA_GIT_SYNC_WAIT=0
  fake= fakegit=
  fail() {
    echo "FAIL: $*" >&2
    [ -z "$fake" ] || kill "$fake" 2> /dev/null || true
    [ -z "$fakegit" ] || kill "$fakegit" 2> /dev/null || true
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

  # Seeding. A token made here, so that it is in no file of the build's,
  # nor in the builder's environment, where a process scan would find it.
  head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > token
  cp token token.good
  mkdir git-root
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null HOME=$PWD
  for r in empty history refused; do git init -q --bare -b main git-root/$r.git; done
  git -C git-root/empty.git config http.receivepack true
  printf '#!${runtimeShell}\necho "push refused by the test" >&2\nexit 1\n' > git-root/refused.git/hooks/pre-receive
  chmod +x git-root/refused.git/hooks/pre-receive
  git init -q -b main other
  echo '{}' > other/README.json
  git -C other add -A
  git -C other -c user.name=someone -c user.email=someone@example.invalid commit -q -m "Someone's work"
  git -C other push -q "$PWD/git-root/history.git" main:other

  python3 -I ${./fake-git-http.py} git-port git token git-root git.log > fake-git.log 2>&1 &
  fakegit=$!
  for _ in $(seq 50); do
    [ -s git-port ] && break
    kill -0 "$fakegit" 2> /dev/null || { cat fake-git.log; fail "the stand-in for Forgejo exited"; }
    sleep 0.2
  done
  [ -s git-port ] || { cat fake-git.log; fail "the stand-in for Forgejo did not start in 10 seconds"; }
  gitbase=http://127.0.0.1:$(cat git-port)

  # The seed: a plain dashboard with the id, uid and version Grafana's
  # export has, one in a subdirectory already in resource form, and a file
  # that is not JSON.
  mkdir -p seed/infra
  cat > seed/home.json <<'EOF'
  {"id":7,"uid":"home","version":3,"title":"Home","tags":[],"schemaVersion":39,"panels":[{"type":"text"}]}
  EOF
  cat > seed/infra/disk.json <<'EOF'
  {"apiVersion":"dashboard.grafana.app/v1","kind":"Dashboard","metadata":{"name":"disk"},"spec":{"title":"Disk","panels":[]}}
  EOF
  echo "Not a dashboard." > seed/README.md

  for r in empty history refused; do
    jq --arg url "$gitbase/$r.git" '.spec.git.url = $url' repository.json > $r.json
  done
  seed() {
    : > fake/requests
    rm -f fake/repository.json
    local status=0
    timeout 60 ${script}/bin/grafana-git-sync grafana "$1.json" token api-token "$1.state" seed > out 2> err || status=$?
    [ "$status" -ne 124 ] || { cat out err; fail "seed $1: did not finish in 60 seconds"; }
    return "$status"
  }

  # An empty repository: seeded with one commit holding exactly the
  # seed's dashboards, then created in Grafana. Meanwhile every process's
  # command line and environment is read for the token.
  : > seen
  ( while [ ! -e stop-scan ]; do
      for p in /proc/[0-9]*; do
        tr '\0' '\n' 2> /dev/null < "$p/cmdline" || true
        tr '\0' '\n' 2> /dev/null < "$p/environ" || true
      done
    done > scan ) &
  scanner=$!
  seed empty || { cat out err; kill "$scanner"; fail "seed empty: failed"; }
  touch stop-scan
  wait "$scanner"
  grep -q 'ls-remote\|git-remote-http' scan || fail "token: the scan never saw git run"
  if grep -q -F -f token scan; then fail "token: in a command line or environment"; fi
  if grep -q -F -f token out err; then fail "token: in the output"; fi
  grep -q "Seeded $gitbase/empty.git" out || fail "seed empty: no log line: $(cat out)"
  [ "$(git -C git-root/empty.git rev-list --count main)" -eq 1 ] || fail "seed empty: not one commit"
  [ "$(git -C git-root/empty.git ls-tree -r --name-only main)" = "$(printf 'dashboards/home.json\ndashboards/infra/disk.json')" ] \
    || fail "seed empty: files: $(git -C git-root/empty.git ls-tree -r --name-only main)"
  [ "$(git -C git-root/empty.git log -1 --format='%an <%ae>' main)" = "grafana-git-sync <grafana-git-sync@localhost.invalid>" ] \
    || fail "seed empty: author $(git -C git-root/empty.git log -1 --format='%an <%ae>' main)"
  git -C git-root/empty.git log -1 --format=%s main | grep -q "from seed$" \
    || fail "seed empty: message $(git -C git-root/empty.git log -1 --format=%s main)"
  git -C git-root/empty.git show main:dashboards/home.json | jq -e '
    . == {apiVersion: "dashboard.grafana.app/v1", kind: "Dashboard", metadata: {name: "home"},
          spec: {title: "Home", tags: [], schemaVersion: 39, panels: [{type: "text"}]}}' > /dev/null \
    || fail "seed empty: home.json: $(git -C git-root/empty.git show main:dashboards/home.json)"
  git -C git-root/empty.git show main:dashboards/infra/disk.json | jq -e --slurpfile want seed/infra/disk.json '. == $want[0]' > /dev/null \
    || fail "seed empty: disk.json changed"
  grep -q '^POST /apis/.*/repositories$' fake/requests || fail "seed empty: not created in Grafana"
  jq -e --arg url "$gitbase/empty.git" '.spec.git.url == $url' fake/repository.json > /dev/null \
    || fail "seed empty: Grafana got $(jq .spec.git.url fake/repository.json)"

  # Again, with the seed changed: the repository has history, so it stays
  # as it is and nothing is pushed.
  head=$(git -C git-root/empty.git rev-parse main)
  : > git.log
  echo '{"uid":"new","title":"New","tags":[],"schemaVersion":39,"panels":[]}' > seed/new.json
  seed empty || { cat out err; fail "seed again: failed"; }
  [ "$(git -C git-root/empty.git rev-parse main)" = "$head" ] || fail "seed again: main moved"
  if grep -q receive-pack git.log; then fail "seed again: pushed: $(cat git.log)"; fi
  rm seed/new.json

  # Someone else's history, on another branch: untouched, and said so.
  seed history || { cat out err; fail "seed history: failed"; }
  [ "$(git -C git-root/history.git for-each-ref --format='%(refname)')" = refs/heads/other ] \
    || fail "seed history: refs $(git -C git-root/history.git for-each-ref)"
  grep -q "has history but no branch main" err || fail "seed history: no warning: $(cat err)"

  # A push the server refuses: the unit fails, saying so, and Grafana is
  # not called.
  if seed refused; then fail "seed refused: succeeded"; fi
  grep -q "Pushing the seed to main of $gitbase/refused.git failed" err || fail "seed refused: no clear error: $(cat err)"
  [ ! -s fake/requests ] || fail "seed refused: Grafana called: $(cat fake/requests)"
  [ -z "$(git -C git-root/refused.git for-each-ref)" ] || fail "seed refused: refs written"

  # A token the server refuses: the unit fails before Grafana, and the
  # token is in no output.
  head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > token
  if seed refused; then fail "seed bad token: succeeded"; fi
  grep -q "Asking $gitbase/refused.git for its branches failed" err || fail "seed bad token: no clear error: $(cat err)"
  [ ! -s fake/requests ] || fail "seed bad token: Grafana called"
  if grep -q -F -f token out err; then fail "seed bad token: token in the output"; fi

  # A seed file without a uid, into a repository emptied again: refused
  # before anything is pushed.
  cp token.good token
  git -C git-root/history.git update-ref -d refs/heads/other
  echo '{"title":"No uid","tags":[],"schemaVersion":39,"panels":[]}' > seed/nouid.json
  if seed history; then fail "seed no uid: succeeded"; fi
  grep -q "nouid.json has no uid" err || fail "seed no uid: no clear error: $(cat err)"
  [ -z "$(git -C git-root/history.git for-each-ref)" ] || fail "seed no uid: refs written"
  [ ! -s fake/requests ] || fail "seed no uid: Grafana called"

  kill "$fakegit"
  kill "$fake"
  echo ok > $out
''
