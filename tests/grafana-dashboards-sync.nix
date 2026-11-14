# Runs containers/grafana-dashboards-sync.sh against a local bare Git
# repository: a good commit syncs, a run with nothing new stays quiet, a
# commit with bad JSON or a dashboard without a title keeps the last good
# set and fails, a deleted dashboard is removed, and a missing branch or
# directory fails.
{ runCommand, callPackage, git }:

let
  script = callPackage ../containers/grafana-dashboards-sync.nix { };
in
runCommand "grafana-dashboards-sync-test" { nativeBuildInputs = [ git ]; } ''
  set -euo pipefail
  export HOME=$PWD GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

  fail() { echo "FAIL: $*" >&2; exit 1; }
  git init --quiet --bare --initial-branch=main origin.git
  git clone --quiet origin.git work 2>/dev/null
  git -C work checkout --quiet -b main
  commit() {
    git -C work add -A
    git -C work commit --quiet -m "$1"
    git -C work push --quiet origin main
  }
  echo key > key # public-check: fake
  run() {
    ${script}/bin/grafana-dashboards-sync "file://$PWD/origin.git" main "''${1:-dashboards}" key state live > out 2> err
  }

  # A good commit: the dashboards in the directory, nothing else.
  mkdir -p work/dashboards/nested
  echo '{"title": "GPU", "panels": []}' > work/dashboards/gpu.json
  echo '{"title": "Disks"}' > work/dashboards/nested/disks.json
  echo '{"title": "Outside"}' > work/outside.json
  commit good
  run || { cat out err; fail "good: failed"; }
  [ -f live/gpu.json ] && [ -f live/nested/disks.json ] || fail "good: not synced: $(find live)"
  [ ! -e live/outside.json ] || fail "good: synced a file outside the directory"
  grep -q "synced from main at" out || fail "good: no log line: $(cat out)"

  # Nothing new: quiet, nothing changed.
  run || { cat out err; fail "again: failed"; }
  [ ! -s out ] || fail "again: not quiet: $(cat out)"

  # Bad JSON: fails, the last good set stays.
  echo '{"title": "GPU",' > work/dashboards/gpu.json
  echo '{"title": "New"}' > work/dashboards/new.json
  commit bad
  if run; then fail "bad JSON: succeeded"; fi
  grep -q "gpu.json in commit .* is not JSON with a title" err || fail "bad JSON: no reason: $(cat err)"
  grep -q "keeps the last good set" err || fail "bad JSON: no reason: $(cat err)"
  grep -q '"panels"' live/gpu.json || fail "bad JSON: live gpu.json changed"
  [ ! -e live/new.json ] || fail "bad JSON: new.json synced"
  # And fails again on the next run, so the unit stays failed.
  if run; then fail "bad JSON again: succeeded"; fi

  # A dashboard without a title is refused as well.
  echo '{"title": "GPU"}' > work/dashboards/gpu.json
  echo '{"panels": []}' > work/dashboards/new.json
  commit untitled
  if run; then fail "no title: succeeded"; fi
  [ ! -e live/new.json ] || fail "no title: new.json synced"

  # A deleted dashboard is removed, the fixed ones synced.
  rm work/dashboards/new.json work/dashboards/nested/disks.json
  commit delete
  run || { cat out err; fail "delete: failed"; }
  [ ! -e live/nested/disks.json ] || fail "delete: disks.json still there"
  [ ! -e live/new.json ] || fail "delete: new.json there"
  [ "$(cat live/gpu.json)" = '{"title": "GPU"}' ] || fail "delete: gpu.json not updated"

  # A directory that is not in the commit fails and leaves the set alone.
  if run missing; then fail "missing directory: succeeded"; fi
  grep -q "has no directory missing" err || fail "missing directory: no reason: $(cat err)"
  [ -f live/gpu.json ] || fail "missing directory: live changed"

  # A branch that does not exist fails.
  git -C origin.git branch -m main other
  if run; then fail "missing branch: succeeded"; fi
  grep -q "fetching branch main failed" err || fail "missing branch: no reason: $(cat err)"
  [ -f live/gpu.json ] || fail "missing branch: live changed"

  echo ok > $out
''
