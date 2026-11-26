{ config, lib, pkgs, ... }:

# restic backups to one remote repository (homelab.backups.resticRepo)
# through rclone. Every job becomes services.restic.backups.<name>, so it runs
# as the restic-backups-<name> unit from the restic-backups-<name> timer.
#
# Vaultwarden holds the household password vault, so its job is built in and
# needs nothing but the repository. Hosts add more jobs as
# homelab.backups.jobs; container modules do not declare their own
# (docs/adr/0002-generic-backup-jobs.md). Restoring is in docs/backups.md.
#
# A failed run is visible without any extra plumbing: the node exporter
# systemd collector (modules/observability-agent.nix) exports
#   node_systemd_unit_state{name="restic-backups-<name>.service",state="failed"}
# so Prometheus/Grafana can alert on it.
#
# A job that does not run at all (its timer gone, the host down at the run
# time) fails no unit. After every successful run the job writes
#   homelab_backup_last_success_timestamp_seconds{backup_job="<name>"}
#   homelab_backup_last_success_size_bytes{backup_job="<name>"}
# for the node exporter's textfile collector, and a static
#   homelab_backup_job_info{backup_job="<name>"} 1
# names every declared job, so a rule can tell a job that never succeeded
# from one that does not exist. The label is backup_job, not job, which
# Prometheus sets to the scrape job's name.
#
# A job forgets only its own snapshots (forget --tag <name>) and does not
# prune. The restic-prune unit prunes the shared repository once a night,
# after the jobs, and writes
#   homelab_backup_prune_last_run_timestamp_seconds
#   homelab_backup_prune_last_success_timestamp_seconds
#   homelab_backup_prune_ok
# like the check below (docs/adr/0031-one-prune-a-night-for-the-shared-repository.md).
#
# A damaged repository (a missing pack, say) does not stop the jobs: backup
# still saves snapshots, and only a prune, a restore or a check notices. So
# the restic-check unit checks the repository weekly
# (homelab.backups.check), reading a share of its data, and writes
#   homelab_backup_check_last_run_timestamp_seconds
#   homelab_backup_check_last_success_timestamp_seconds
#   homelab_backup_check_ok
# into the same directory, on success and on failure.
#
# A sound repository does not prove a job's data comes back usable. So the
# restic-restore-test unit (homelab.backups.restoreTest) restores the latest
# snapshot of every job monthly into a scratch directory, with --verify, and
# checks its SQLite databases with PRAGMA integrity_check and its git
# repositories with git fsck. It writes, per job,
#   homelab_backup_restore_test_ok{backup_job="<name>"}
#   homelab_backup_restore_test_last_run_timestamp_seconds{...}
#   homelab_backup_restore_test_last_success_timestamp_seconds{...}
#   homelab_backup_restore_test_restored_bytes{...}
# (docs/adr/0027-backups-are-restore-tested-monthly.md).
#
# Secrets are provisioned out of band at runtime (never committed) and shared
# by all jobs:
#   /var/lib/secrets/restic-password  the restic repository password
#   /var/lib/secrets/rclone.env       the rclone remote credentials

let
  cfg = config.homelab.backups;

  # All jobs share the repository, and restic refuses to start while another
  # process holds a conflicting lock: forget and prune take an exclusive
  # lock, so a job that starts while another forgets would fail. Rather than
  # spreading the schedules (Persistent catch-up after a downtime starts every
  # missed job at boot anyway), every restic command waits up to 12 hours for
  # the lock with the global --retry-lock flag (restic 0.16 and later). The
  # NixOS module only lets extraBackupArgs and pruneOpts reach two of its
  # commands, not cat/init in preStart or unlock, so the flag goes into a
  # wrapper that is the jobs' restic package. A job still waiting after 12
  # hours fails like any other run.
  resticWaiting = pkgs.writeShellScriptBin "restic" ''
    exec ${lib.getExe pkgs.restic} --retry-lock 12h "$@"
  '';

  passwordFile = "/var/lib/secrets/restic-password";
  environmentFile = "/var/lib/secrets/rclone.env";

  checkScript = pkgs.callPackage ./backup-check-script.nix { };
  checkMetrics = "${textfileDir}/homelab_restic_check.prom";

  pruneScript = pkgs.callPackage ./backup-prune-script.nix { };

  restoreTestScript = pkgs.callPackage ./backup-restore-test-script.nix { };
  restoreTestMetrics = "${textfileDir}/homelab_restore_test.prom";
  restoreTestConfig = pkgs.writeText "restic-restore-test.json" (builtins.toJSON {
    inherit textfileDir;
    inherit (cfg.restoreTest) scratchDir;
    stagingDir = "/var/backup";
    gitFsckTimeoutSeconds = cfg.restoreTest.gitFsckTimeout;
    # A job backs up daily by default; a latest snapshot over 2 days old
    # means it has stopped.
    maxAgeSeconds = 2 * 86400;
    jobs = lib.mapAttrsToList (name: job: { inherit name; inherit (job) sqliteDatabases; }) jobs;
  });

  # Whether path a is b or lies under it.
  within = a: b:
    let
      a' = lib.removeSuffix "/" a;
      b' = lib.removeSuffix "/" b;
    in
    a' == b' || lib.hasPrefix "${b'}/" a';

  staging = name: "/var/backup/${name}";

  # The live database's copy, at its own path under the job's staging dir.
  snapshotOf = name: db: "${staging name}${db}";

  textfileDir = config.homelab.observabilityAgent.textfileDirectory;

  # Label values are job names, which are attribute names and could hold
  # anything; escape what the exposition format needs escaped.
  label = name: lib.replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" "\\n" ] name;

  jobInfo = pkgs.writeText "homelab_backup_jobs.prom" (''
    # HELP homelab_backup_job_info A backup job declared on this host.
    # TYPE homelab_backup_job_info gauge
  '' + lib.concatMapStrings (name: ''
    homelab_backup_job_info{backup_job="${label name}"} 1
  '') (lib.attrNames jobs));

  # Retention, per job.
  keepOpts = [
    "--keep-daily 7"
    "--keep-weekly 4"
    "--keep-monthly 6"
    "--keep-yearly 1"
  ];

  # The job's own forget, after its backup in the unit's ExecStart. The
  # NixOS module runs its pruneOpts only as forget --prune over every
  # snapshot, so they stay empty and the job forgets here: only snapshots
  # tagged with its name, grouped by host and paths as restic does by
  # default, and without --prune. That leaves the data in the repository
  # until restic-prune removes it.
  forgetCmd = name: "${resticWaiting}/bin/restic forget --tag ${name} "
    + lib.concatStringsSep " " keepOpts;

  # ExecStartPost of the job's unit: systemd runs it only when every
  # ExecStart command (backup, its own forget) succeeded. The size is the
  # summary restic stored in the new snapshot (the bytes of the files it
  # read); looking it up reads snapshot files restic has just cached, and
  # if that fails or takes over 5 minutes the timestamp is written without
  # it. The file is written
  # under a name without .prom and renamed, so a scrape never sees half.
  recordSuccess = name: ''
    set -eu
    out=${lib.escapeShellArg "${textfileDir}/homelab_backup_${name}.prom"}
    mkdir -p ${lib.escapeShellArg textfileDir}
    now=$(date +%s)
    size=$(timeout 300 ${resticWaiting}/bin/restic snapshots --no-lock --json --latest 1 \
        --tag ${lib.escapeShellArg name} --host "$(cat /proc/sys/kernel/hostname)" \
      | ${lib.getExe pkgs.jq} -r 'max_by(.time) | .summary.total_bytes_processed // empty' \
      || true)
    case "$size" in *[!0-9]* | "") size= ;; esac
    {
      echo '# HELP homelab_backup_last_success_timestamp_seconds When the backup job last succeeded.'
      echo '# TYPE homelab_backup_last_success_timestamp_seconds gauge'
      echo ${lib.escapeShellArg ''homelab_backup_last_success_timestamp_seconds{backup_job="${label name}"}''} "$now"
      if [ -n "$size" ]; then
        echo '# HELP homelab_backup_last_success_size_bytes Size of the files the last successful run backed up.'
        echo '# TYPE homelab_backup_last_success_size_bytes gauge'
        echo ${lib.escapeShellArg ''homelab_backup_last_success_size_bytes{backup_job="${label name}"}''} "$size"
      fi
    } > "$out.tmp"
    mv "$out.tmp" "$out"
  '';

  # Vaultwarden predates homelab.backups.jobs and keeps its unit without any
  # option being set. icon_cache and tmp are regenerated and not worth
  # storing.
  vaultwarden = {
    paths = [ "/var/lib/vaultwarden" ];
    sqliteDatabases = [ "/var/lib/vaultwarden/db.sqlite3" ];
    exclude = [
      "/var/lib/vaultwarden/icon_cache"
      "/var/lib/vaultwarden/tmp"
    ];
    schedule = "daily";
  };

  jobs = cfg.jobs // { inherit vaultwarden; };

  mkJob = name: job: {
    repository = cfg.resticRepo;
    inherit passwordFile environmentFile;
    package = resticWaiting;

    # Create the repository on the first run if it does not exist yet.
    initialize = true;

    timerConfig = {
      OnCalendar = job.schedule;
      Persistent = true;
    };

    paths = job.paths ++ lib.optional (job.sqliteDatabases != [ ]) (staging name);

    # The live SQLite files are inconsistent while the service runs, so the
    # copies taken in backupPrepareCommand are backed up instead.
    exclude = job.exclude ++ lib.concatMap
      (db: map (suffix: db + suffix) [ "" "-wal" "-shm" "-journal" ])
      job.sqliteDatabases;

    # The tag lets the runbook pick one job's snapshots, and the job's
    # forget take only its own.
    extraBackupArgs = [ "--tag ${name}" ];

    # Online backup of each live database into the staging dir. The sqlite
    # .backup command is safe to run while the service has the database
    # open; .timeout waits out a writer's lock instead of failing at once.
    # sqlite3 would create a missing database as an empty one, so a wrong
    # path fails the run here instead.
    backupPrepareCommand = lib.mkIf (job.sqliteDatabases != [ ]) (''
      set -eu
      rm -rf ${staging name}
    '' + lib.concatMapStrings (db: ''
      test -f ${lib.escapeShellArg db} || { echo "${db} does not exist" >&2; exit 1; }
      mkdir -p ${lib.escapeShellArg (dirOf (snapshotOf name db))}
      ${pkgs.sqlite}/bin/sqlite3 ${lib.escapeShellArg db} ".timeout 30000" ${lib.escapeShellArg ".backup '${snapshotOf name db}'"}
    '') job.sqliteDatabases);

    # Always runs after the backup, including on failure.
    backupCleanupCommand = lib.mkIf (job.sqliteDatabases != [ ]) ''
      rm -rf ${staging name}
    '';

    # No forget --prune from the NixOS module; see forgetCmd.
    pruneOpts = [ ];
  };
in
{
  imports = [ ./options.nix ];

  assertions = [
    {
      assertion = !(cfg.jobs ? vaultwarden);
      message = "homelab.backups.jobs.vaultwarden is taken by the built in Vaultwarden job in modules/backups.nix; pick another name.";
    }
    {
      assertion = lib.all (job: lib.all (db: lib.hasPrefix "/" db && !(lib.hasInfix "'" db)) job.sqliteDatabases)
        (lib.attrValues cfg.jobs);
      message = "homelab.backups.jobs.<name>.sqliteDatabases takes absolute paths without single quotes.";
    }
    {
      # The restore test empties <scratchDir>/<job> before and after it
      # restores there, so it must never be live data.
      assertion = !cfg.restoreTest.enable || (lib.hasPrefix "/" cfg.restoreTest.scratchDir
        && lib.all (path: !(within cfg.restoreTest.scratchDir path) && !(within path cfg.restoreTest.scratchDir))
          (lib.concatLists (lib.mapAttrsToList (name: job: job.paths ++ [ (staging name) ]) jobs)));
      message = "homelab.backups.restoreTest.scratchDir must be an absolute path that neither holds nor lies in a backup job's paths or /var/backup/<job>.";
    }
  ];

  environment.systemPackages = with pkgs; [
    restic
    rclone
    sqlite
  ];

  # Staging dir for the consistent database copies taken before each run,
  # and the list of declared jobs for the textfile collector. The link
  # follows the jobs on every rebuild.
  # With the check or the restore test off, its last result is removed, so
  # it does not alert as overdue.
  systemd.tmpfiles.rules = [
    "d /var/backup 0700 root root -"
    "L+ ${textfileDir}/homelab_backup_jobs.prom - - - - ${jobInfo}"
  ] ++ lib.optional (!cfg.check.enable) "r ${checkMetrics}"
  ++ lib.optional (!cfg.restoreTest.enable) "r ${restoreTestMetrics}";

  services.restic.backups = lib.mapAttrs mkJob jobs;

  systemd.services = lib.mkMerge [
    (lib.mapAttrs'
      (name: _: lib.nameValuePair "restic-backups-${name}" {
        serviceConfig.ExecStart = lib.mkAfter [ (forgetCmd name) ];
        postStart = recordSuccess name;
      })
      jobs)

    # The nightly prune of the shared repository, after the jobs have
    # forgotten their old snapshots, with their credentials and their
    # restic, which waits for the lock: prune locks the repository
    # exclusively, so it waits for a running job, and a job started
    # meanwhile waits for it. One prune a night instead of one per job
    # keeps the rewriting and deleting of packs on the remote to once
    # (docs/adr/0031-one-prune-a-night-for-the-shared-repository.md).
    {
      restic-prune = {
        description = "Prune the restic backup repository";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        path = [ resticWaiting ];
        environment = {
          RESTIC_REPOSITORY = cfg.resticRepo;
          RESTIC_PASSWORD_FILE = passwordFile;
          RESTIC_CACHE_DIR = "/var/cache/restic-prune";
        };
        # A rebuild does not start a prune, nor stop one that runs.
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = environmentFile;
          ExecStart = "${pruneScript}/bin/restic-prune ${lib.escapeShellArg textfileDir}";
          PrivateTmp = true;
          CacheDirectory = "restic-prune";
          CacheDirectoryMode = "0700";
        };
      };
    }

    # The weekly check of the repository, with the jobs' credentials and
    # their restic, which waits for the lock: restic check locks the
    # repository exclusively, so it waits for a running job, and a job
    # started meanwhile waits for it. restic check makes a temporary cache
    # under RESTIC_CACHE_DIR and removes it when done.
    (lib.mkIf cfg.check.enable {
      restic-check = {
        description = "Check the restic backup repository";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        path = [ resticWaiting ];
        environment = {
          RESTIC_REPOSITORY = cfg.resticRepo;
          RESTIC_PASSWORD_FILE = passwordFile;
          RESTIC_CACHE_DIR = "/var/cache/restic-check";
        };
        # A rebuild does not start a check, nor stop one that runs.
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = environmentFile;
          ExecStart = "${checkScript}/bin/restic-check ${lib.escapeShellArgs [ cfg.check.readDataSubset textfileDir ]}";
          PrivateTmp = true;
          CacheDirectory = "restic-check";
          CacheDirectoryMode = "0700";
        };
      };
    })

    # The monthly restore test of every job, with the same credentials and
    # restic. restic restore takes a shared lock, so it waits only for a
    # prune or a check; after the check when both start together, as at
    # boot after a missed Sunday. The scratch directory defaults into the
    # unit's private /var/tmp, which systemd removes when the unit stops,
    # whatever the script got to.
    (lib.mkIf cfg.restoreTest.enable {
      restic-restore-test = {
        description = "Restore every backup job's latest snapshot and check it";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" "restic-check.service" ];
        path = [ resticWaiting ];
        environment = {
          RESTIC_REPOSITORY = cfg.resticRepo;
          RESTIC_PASSWORD_FILE = passwordFile;
          RESTIC_CACHE_DIR = "/var/cache/restic-restore-test";
        };
        # A rebuild does not start a test, nor stop one that runs.
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = environmentFile;
          ExecStart = "${restoreTestScript}/bin/restic-restore-test ${restoreTestConfig}";
          PrivateTmp = true;
          CacheDirectory = "restic-restore-test";
          CacheDirectoryMode = "0700";
        };
      };
    })
  ];

  # Nightly, caught up at the next boot.
  systemd.timers.restic-prune = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = cfg.prune.schedule;
      Persistent = true;
    };
  };

  # Spread over an hour; Persistent runs a check missed while the host was
  # down at the next boot.
  systemd.timers.restic-check = lib.mkIf cfg.check.enable {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = cfg.check.schedule;
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  # Monthly, spread over an hour, caught up at the next boot.
  systemd.timers.restic-restore-test = lib.mkIf cfg.restoreTest.enable {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = cfg.restoreTest.schedule;
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
}
