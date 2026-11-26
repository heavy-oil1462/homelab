# The jobs' own forget and the restic-prune script against a real local
# restic repository: two jobs back up three times each, each job's forget, as
# its unit runs it, forgets only its own unneeded snapshot and deletes no data,
# and only restic-prune removes the data they left. A prune that succeeds
# says ok; one against a repository with a needed pack deleted says not ok
# and keeps the last success. Then how the example server wires it: no
# forget --prune in any job, the prune unit's command, restic, credentials
# and nightly timer.
{ lib, runCommand, callPackage, restic, jq, prometheus, config }:

let
  script = callPackage ../modules/backup-prune-script.nix { };
  unit = config.systemd.services.restic-prune;
  timer = config.systemd.timers.restic-prune.timerConfig;
  textfileDir = config.homelab.observabilityAgent.textfileDirectory;
  jobs = lib.attrNames config.services.restic.backups;
  execStart = name: config.systemd.services."restic-backups-${name}".serviceConfig.ExecStart;
  forgets = name: lib.filter (lib.hasInfix " forget ") (execStart name);
  forgetOf = name: lib.head (forgets name);
  expect = what: cond: if cond then "" else throw "backup-prune: ${what}";
  wiring = lib.concatStrings ([
    (expect "the example server has no forgejo and vaultwarden jobs"
      (lib.elem "forgejo" jobs && lib.elem "vaultwarden" jobs))
    (expect "the unit does not run the script with the textfile directory"
      (unit.serviceConfig.ExecStart == "${script}/bin/restic-prune ${textfileDir}"))
    (expect "the unit's restic is not the jobs' lock-waiting wrapper"
      (lib.any (p: p == config.services.restic.backups.forgejo.package) unit.path))
    (expect "the unit's repository is not homelab.backups.resticRepo"
      (unit.environment.RESTIC_REPOSITORY == config.homelab.backups.resticRepo))
    (expect "the unit's credentials differ from the jobs'"
      (unit.environment.RESTIC_PASSWORD_FILE == config.services.restic.backups.forgejo.passwordFile
        && unit.serviceConfig.EnvironmentFile == config.services.restic.backups.forgejo.environmentFile))
    (expect "the timer is not nightly at 02:00 and Persistent"
      (timer.OnCalendar == "*-*-* 02:00:00" && timer.Persistent))
  ] ++ map
    (name: lib.concatStrings [
      (expect "${name}'s unit has no prune options for the NixOS module"
        (config.services.restic.backups.${name}.pruneOpts == [ ]))
      (expect "${name}'s unit prunes or unlocks"
        (!lib.any (c: lib.hasInfix "--prune" c || lib.hasInfix " unlock" c || lib.hasInfix " prune" c) (execStart name)))
      (expect "${name}'s unit does not forget once, after its backup, with --tag ${name}"
        (lib.length (forgets name) == 1 && lib.last (execStart name) == forgetOf name
          && lib.hasInfix " backup " (lib.head (execStart name))
          && lib.hasInfix " forget --tag ${name} " (forgetOf name)))
    ])
    jobs);
in
runCommand "backup-prune-test" { nativeBuildInputs = [ restic jq prometheus.cli ]; } ''
  set -euo pipefail
  : ${lib.escapeShellArg wiring}
  fail() { echo "FAIL: $*" >&2; exit 1; }
  export HOME=$PWD RESTIC_REPOSITORY=$PWD/repo RESTIC_PASSWORD_FILE=$PWD/password
  export RESTIC_CACHE_DIR=$PWD/cache
  echo 'not a secret' > password  # public-check: fake
  mkdir -p forgejo vaultwarden textfile
  restic init --quiet
  prom=textfile/homelab_restic_prune.prom
  value() { awk -v series="$1" '$1 == series { print $2 }' "$prom"; }
  count() { restic snapshots --json --tag "$1" | jq length; }
  packs() { find repo/data -type f | wc -l; }

  # Three runs of each job on one day, each with new data. The job's
  # retention keeps the day's last and, as restic keeps the oldest while a
  # --keep-* count is not reached, its first; the second goes, and its
  # packs are left unused.
  for run in 1 2 3; do
    for job in forgejo vaultwarden; do
      head -c 2000000 /dev/urandom > $job/data
      restic backup --quiet --tag $job --time "2026-01-01 0$run:00:00" $job
    done
  done
  [ "$(count forgejo)" = 3 ] && [ "$(count vaultwarden)" = 3 ] || fail "setup: not three snapshots each"
  before=$(packs)

  # forgejo's forget, as its unit runs it: its second snapshot goes,
  # vaultwarden's stay, and no pack is deleted.
  ${forgetOf "forgejo"}
  [ "$(count forgejo)" = 2 ] || fail "forgejo's forget: forgejo has $(count forgejo) snapshots"
  [ "$(count vaultwarden)" = 3 ] || fail "forgejo's forget: it forgot vaultwarden's"
  [ "$(packs)" = "$before" ] || fail "forgejo's forget: it pruned"

  ${forgetOf "vaultwarden"}
  [ "$(count forgejo)" = 2 ] && [ "$(count vaultwarden)" = 2 ] || fail "vaultwarden's forget: not two snapshots each"
  [ "$(packs)" = "$before" ] || fail "vaultwarden's forget: it pruned"

  # restic-prune: removes the unused packs, ok, both timestamps the run's.
  ${script}/bin/restic-prune textfile || fail "sound: the prune failed"
  echo "--- after the prune:"; cat "$prom"
  [ "$(packs)" -lt "$before" ] || fail "sound: no pack removed"
  restic check --read-data || fail "sound: the repository does not check after the prune"
  [ "$(value homelab_backup_prune_ok)" = 1 ] || fail "sound: not ok"
  success=$(value homelab_backup_prune_last_success_timestamp_seconds)
  [ -n "$success" ] && [ "$success" = "$(value homelab_backup_prune_last_run_timestamp_seconds)" ] \
    || fail "sound: last success is not the last run"
  promtool check metrics < "$prom" || fail "sound: not valid exposition format"
  [ -z "$(ls textfile | grep -v '\.prom$')" ] || fail "sound: temporary file left"

  # A pack a snapshot needs deleted, as on the site's repository: the prune
  # fails, ok is 0, the run's time moves and the last success stays.
  sleep 1
  pack=$(find repo/data -type f | head -n 1)
  rm "$pack"
  if ${script}/bin/restic-prune textfile 2> prune.err; then fail "damaged: the prune passed"; fi
  echo "--- restic, after deleting $pack:"; cat prune.err
  echo "--- metrics:"; cat "$prom"
  [ "$(value homelab_backup_prune_ok)" = 0 ] || fail "damaged: still ok"
  [ "$(value homelab_backup_prune_last_success_timestamp_seconds)" = "$success" ] || fail "damaged: last success moved"
  [ "$(value homelab_backup_prune_last_run_timestamp_seconds)" -gt "$success" ] || fail "damaged: last run did not move"
  promtool check metrics < "$prom" || fail "damaged: not valid exposition format"

  # A prune that never succeeded writes no last success.
  rm "$prom"
  if ${script}/bin/restic-prune textfile 2> /dev/null; then fail "never: the prune passed"; fi
  [ "$(value homelab_backup_prune_ok)" = 0 ] || fail "never: ok"
  if grep -q last_success "$prom"; then fail "never: a last success written"; fi
  promtool check metrics < "$prom" || fail "never: not valid exposition format"

  touch $out
''
