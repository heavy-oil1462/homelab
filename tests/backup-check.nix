# The restic-check script against a real local restic repository: a check
# of a sound repository says ok, one with a data pack deleted says not ok
# and keeps the last success. Then how the example server runs it: the
# unit's command, its restic that waits for the lock, its credentials and
# the weekly timer, and the check off.
{ lib, runCommand, callPackage, restic, prometheus, config, off }:

let
  script = callPackage ../modules/backup-check-script.nix { };
  unit = config.systemd.services.restic-check;
  timer = config.systemd.timers.restic-check.timerConfig;
  textfileDir = config.homelab.observabilityAgent.textfileDirectory;
  expect = what: cond: if cond then "" else throw "backup-check: ${what}";
  wiring = lib.concatStrings [
    (expect "the unit does not run the script with 5% and the textfile directory"
      (unit.serviceConfig.ExecStart == "${script}/bin/restic-check 5% ${textfileDir}"))
    (expect "the unit's restic is not the jobs' lock-waiting wrapper"
      (lib.any (p: p == config.services.restic.backups.forgejo.package) unit.path))
    (expect "the unit's repository is not homelab.backups.resticRepo"
      (unit.environment.RESTIC_REPOSITORY == config.homelab.backups.resticRepo))
    (expect "the unit's credentials differ from the jobs'"
      (unit.environment.RESTIC_PASSWORD_FILE == config.services.restic.backups.forgejo.passwordFile
        && unit.serviceConfig.EnvironmentFile == config.services.restic.backups.forgejo.environmentFile))
    (expect "the timer is not weekly on Sunday at 04:00, Persistent, with a delay"
      (timer.OnCalendar == "Sun *-*-* 04:00:00" && timer.Persistent && timer.RandomizedDelaySec == "1h"))
    (expect "the check off still has a unit or keeps its metrics"
      (!(off.systemd.services ? restic-check) && !(off.systemd.timers ? restic-check)
        && lib.elem "r ${textfileDir}/homelab_restic_check.prom" off.systemd.tmpfiles.rules))
  ];
in
runCommand "backup-check-test" { nativeBuildInputs = [ restic prometheus.cli ]; } ''
  set -euo pipefail
  : ${lib.escapeShellArg wiring}
  fail() { echo "FAIL: $*" >&2; exit 1; }
  export HOME=$PWD RESTIC_REPOSITORY=$PWD/repo RESTIC_PASSWORD_FILE=$PWD/password
  export RESTIC_CACHE_DIR=$PWD/cache
  echo 'not a secret' > password  # public-check: fake
  mkdir data textfile
  for i in 1 2 3; do head -c 2000000 /dev/urandom > data/file$i; done
  restic init --quiet
  restic backup --quiet data
  prom=textfile/homelab_restic_check.prom
  value() { awk -v series="$1" '$1 == series { print $2 }' "$prom"; }

  # A sound repository: ok, and both timestamps set to the run.
  ${script}/bin/restic-check 100% textfile || fail "sound: the check failed"
  echo "--- after the first check:"; cat "$prom"
  [ "$(value homelab_backup_check_ok)" = 1 ] || fail "sound: not ok"
  success=$(value homelab_backup_check_last_success_timestamp_seconds)
  [ -n "$success" ] && [ "$success" = "$(value homelab_backup_check_last_run_timestamp_seconds)" ] \
    || fail "sound: last success is not the last run"
  promtool check metrics < "$prom" || fail "sound: not valid exposition format"
  [ -z "$(ls textfile | grep -v '\.prom$')" ] || fail "sound: temporary file left"

  # A data pack deleted: the check fails, ok is 0, the run's time moves
  # and the last success stays.
  sleep 1
  pack=$(find repo/data -type f | head -n 1)
  rm "$pack"
  if ${script}/bin/restic-check 5% textfile 2> check.err; then fail "damaged: the check passed"; fi
  echo "--- restic, after deleting $pack:"; cat check.err
  echo "--- metrics:"; cat "$prom"
  grep -q "needs a repair" check.err || fail "damaged: no word of the repair: $(cat check.err)"
  [ "$(value homelab_backup_check_ok)" = 0 ] || fail "damaged: still ok"
  [ "$(value homelab_backup_check_last_success_timestamp_seconds)" = "$success" ] || fail "damaged: last success moved"
  [ "$(value homelab_backup_check_last_run_timestamp_seconds)" -gt "$success" ] || fail "damaged: last run did not move"
  promtool check metrics < "$prom" || fail "damaged: not valid exposition format"

  # A check that never passed writes no last success.
  rm "$prom"
  if ${script}/bin/restic-check 5% textfile 2> /dev/null; then fail "never: the check passed"; fi
  [ "$(value homelab_backup_check_ok)" = 0 ] || fail "never: ok"
  if grep -q last_success "$prom"; then fail "never: a last success written"; fi
  promtool check metrics < "$prom" || fail "never: not valid exposition format"

  touch $out
''
