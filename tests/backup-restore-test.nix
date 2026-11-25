# The restic-restore-test script against a real local restic repository
# with real sqlite3 and git: two jobs, one with a SQLite database and one
# with git repositories, pass; a new snapshot with the database truncated
# fails that job only, and one with an object deleted from a repository
# fails the other. Then a job with no snapshot, a snapshot too old and a
# scratch directory that is not the test's. Then how the example server
# runs it: the unit's command and config, its restic that waits for the
# lock, its credentials, the monthly timer, and the test off.
{ lib, runCommand, callPackage, restic, sqlite, git, jq, prometheus, config, off }:

let
  script = callPackage ../modules/backup-restore-test-script.nix { };
  unit = config.systemd.services.restic-restore-test;
  timer = config.systemd.timers.restic-restore-test.timerConfig;
  textfileDir = config.homelab.observabilityAgent.textfileDirectory;
  forgejo = config.services.restic.backups.forgejo;
  command = lib.splitString " " unit.serviceConfig.ExecStart;
  expect = what: cond: if cond then "" else throw "backup-restore-test: ${what}";
  wiring = lib.concatStrings [
    (expect "the unit does not run the script with one config file"
      (lib.length command == 2 && lib.head command == "${script}/bin/restic-restore-test"))
    (expect "the unit's restic is not the jobs' lock-waiting wrapper"
      (lib.any (p: p == forgejo.package) unit.path))
    (expect "the unit's repository is not homelab.backups.resticRepo"
      (unit.environment.RESTIC_REPOSITORY == config.homelab.backups.resticRepo))
    (expect "the unit's credentials differ from the jobs'"
      (unit.environment.RESTIC_PASSWORD_FILE == forgejo.passwordFile
        && unit.serviceConfig.EnvironmentFile == forgejo.environmentFile))
    (expect "the unit has no private /var/tmp or does not follow the check"
      (unit.serviceConfig.PrivateTmp && lib.elem "restic-check.service" unit.after))
    (expect "the timer is not on the first Sunday at 05:00, Persistent, with a delay"
      (timer.OnCalendar == "Sun *-*-01..07 05:00:00" && timer.Persistent && timer.RandomizedDelaySec == "1h"))
    (expect "the restore test off still has a unit or keeps its metrics"
      (!(off.systemd.services ? restic-restore-test) && !(off.systemd.timers ? restic-restore-test)
        && lib.elem "r ${textfileDir}/homelab_restore_test.prom" off.systemd.tmpfiles.rules))
  ];
  unitConfig = lib.last command;
in
runCommand "backup-restore-test-test" { nativeBuildInputs = [ restic sqlite git jq prometheus.cli ]; } ''
  set -euo pipefail
  : ${lib.escapeShellArg wiring}
  fail() { echo "FAIL: $*" >&2; exit 1; }

  # The example server's config: every job, Vaultwarden's too, with its
  # databases, and the paths the module uses.
  jq -e '
    .textfileDir == "${textfileDir}"
    and .scratchDir == "/var/tmp/restic-restore-test"
    and .stagingDir == "/var/backup"
    and .gitFsckTimeoutSeconds == 3600
    and .maxAgeSeconds == 172800
    and ([.jobs[].name] | sort) == ["forgejo", "pocket-id", "vaultwarden"]
    and (.jobs[] | select(.name == "forgejo") | .sqliteDatabases) == ["/var/lib/forgejo/data/gitea.db"]
    and (.jobs[] | select(.name == "vaultwarden") | .sqliteDatabases) == ["/var/lib/vaultwarden/db.sqlite3"]
  ' ${unitConfig} > /dev/null || fail "the unit's config is not the example server's: $(cat ${unitConfig})"

  export HOME=$PWD RESTIC_REPOSITORY=$PWD/repo RESTIC_PASSWORD_FILE=$PWD/password
  export RESTIC_CACHE_DIR=$PWD/cache
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
  echo 'not a secret' > password  # public-check: fake
  restic init --quiet
  mkdir textfile

  # The app job: a live WAL database, copied into the staging dir as the
  # module does, and a plain file.
  live=$PWD/app/data/app.db
  mkdir -p app/data
  head -c 100000 /dev/urandom > app/data/upload.bin
  sqlite3 "$live" 'PRAGMA journal_mode = wal;
    CREATE TABLE items (id INTEGER PRIMARY KEY, body TEXT);
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
    INSERT INTO items (body) SELECT hex(randomblob(64)) FROM n;' > /dev/null
  backup_app() {
    rm -rf staging
    mkdir -p "$(dirname "staging/app$live")"
    sqlite3 "$live" ".backup 'staging/app$live'"
    "$@"
    restic backup --quiet --tag app "$PWD/app" "$PWD/staging/app" \
      --exclude "$live" --exclude "$live-wal" --exclude "$live-shm"
  }
  backup_app true

  # The git job: a work tree and a bare repository it pushed to, the way
  # Forgejo keeps them.
  mkdir -p forge
  git init --quiet forge/work
  for i in 1 2 3; do
    echo "change $i" > forge/work/file$i
    git -C forge/work add file$i
    git -C forge/work commit --quiet -m "change $i"
  done
  git init --quiet --bare forge/owner/repo.git
  git -C forge/work push --quiet ../owner/repo.git HEAD:refs/heads/main
  restic backup --quiet --tag forge "$PWD/forge"

  cat > config.json <<EOF
  { "textfileDir": "$PWD/textfile", "scratchDir": "$PWD/scratch",
    "stagingDir": "$PWD/staging", "gitFsckTimeoutSeconds": 60,
    "maxAgeSeconds": 172800,
    "jobs": [ { "name": "app", "sqliteDatabases": ["$live"] },
              { "name": "forge", "sqliteDatabases": [] } ] }
  EOF
  prom=textfile/homelab_restore_test.prom
  value() { awk -v series="$1{backup_job=\"$2\"}" '$1 == series { print $2 }' "$prom"; }
  run() {
    local status=0
    ${script}/bin/restic-restore-test "''${1:-config.json}" > run.out 2> run.err || status=$?
    echo "--- the journal of the run:"; cat run.out run.err
    echo "--- metrics:"; cat "$prom"
    promtool check metrics < "$prom" || fail "not valid exposition format"
    [ -z "$(ls textfile | grep -v '\.prom$')" ] || fail "temporary file left"
    [ -z "$(ls -A scratch)" ] || fail "scratch not emptied: $(ls -A scratch)"
    return "$status"
  }

  # Both sound: ok, with their summaries.
  run || fail "sound: the test failed"
  grep -Eq '^app: snapshot [0-9a-f]{8} of [0-9TZ:-]+, 2 files, [0-9.]+ MiB restored and verified, 1 databases ok, 0 git repositories ok$' run.out \
    || fail "sound: no summary of app"
  grep -Eq '^forge: snapshot [0-9a-f]{8} of [0-9TZ:-]+, [0-9]+ files, [0-9.]+ MiB restored and verified, 0 databases ok, 2 git repositories ok$' run.out \
    || fail "sound: no summary of forge"
  for job in app forge; do
    [ "$(value homelab_backup_restore_test_ok $job)" = 1 ] || fail "sound: $job not ok"
    [ "$(value homelab_backup_restore_test_last_success_timestamp_seconds $job)" \
      = "$(value homelab_backup_restore_test_last_run_timestamp_seconds $job)" ] || fail "sound: $job's last success is not its last run"
    [ "$(value homelab_backup_restore_test_restored_bytes $job)" -gt 0 ] || fail "sound: $job restored nothing"
  done
  app_success=$(value homelab_backup_restore_test_last_success_timestamp_seconds app)

  # The database copy truncated to half in a new snapshot: app fails, forge
  # stays ok, and app keeps its last success.
  sleep 1
  backup_app sh -c "truncate -s \$((\$(stat -c %s 'staging/app$live') / 2)) 'staging/app$live'"
  if run; then fail "truncated database: the test passed"; fi
  grep -q "^app: FAILED: database $live fails its integrity check" run.err || fail "truncated database: app did not fail on it"
  grep -q '^forge: snapshot' run.out || fail "truncated database: forge did not pass"
  grep -q '1 of 2 backup jobs failed' run.err || fail "truncated database: no count of the failed jobs"
  [ "$(value homelab_backup_restore_test_ok app)" = 0 ] || fail "truncated database: app still ok"
  [ "$(value homelab_backup_restore_test_ok forge)" = 1 ] || fail "truncated database: forge not ok"
  [ "$(value homelab_backup_restore_test_last_success_timestamp_seconds app)" = "$app_success" ] || fail "truncated database: app's last success moved"
  [ "$(value homelab_backup_restore_test_last_run_timestamp_seconds app)" -gt "$app_success" ] || fail "truncated database: app's last run did not move"
  forge_success=$(value homelab_backup_restore_test_last_success_timestamp_seconds forge)
  backup_app true

  # An object deleted from the bare repository in a new snapshot: forge
  # fails, app is ok again.
  object=$(find forge/owner/repo.git/objects -type f -path '*/objects/??/*' | head -n 1)
  [ -n "$object" ] || fail "the bare repository has no loose object"
  rm -f "$object"
  restic backup --quiet --tag forge "$PWD/forge"
  if run; then fail "missing object: the test passed"; fi
  grep -q '^forge: FAILED: git fsck of .*/forge/owner/repo.git failed' run.err || fail "missing object: forge did not fail on it"
  grep -q '^app: snapshot' run.out || fail "missing object: app did not pass"
  [ "$(value homelab_backup_restore_test_ok forge)" = 0 ] || fail "missing object: forge still ok"
  [ "$(value homelab_backup_restore_test_ok app)" = 1 ] || fail "missing object: app not ok"
  [ "$(value homelab_backup_restore_test_last_success_timestamp_seconds forge)" = "$forge_success" ] || fail "missing object: forge's last success moved"

  # A job without a snapshot, and every snapshot too old.
  jq '.jobs += [{name: "never", sqliteDatabases: []}]' config.json > never.json
  if run never.json; then fail "no snapshot: the test passed"; fi
  grep -q '^never: FAILED: no snapshot tagged never' run.err || fail "no snapshot: never did not fail on it"
  [ "$(value homelab_backup_restore_test_ok never)" = 0 ] || fail "no snapshot: never ok"
  sleep 2
  jq '.maxAgeSeconds = 1' config.json > old.json
  if run old.json; then fail "too old: the test passed"; fi
  grep -q '^app: FAILED: the latest snapshot, .* is older than' run.err || fail "too old: app did not fail on it"

  # A scratch directory of a job that is not the test's is left alone.
  mkdir scratch/app; echo keep > scratch/app/data
  if ${script}/bin/restic-restore-test config.json 2> run.err; then fail "foreign scratch: the test passed"; fi
  grep -q '^app: FAILED: .*/scratch/app exists and is not a restore test' run.err || fail "foreign scratch: app did not fail on it"
  [ "$(cat scratch/app/data)" = keep ] || fail "foreign scratch: its data was touched"

  touch $out
''
