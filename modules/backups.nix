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
# Secrets are provisioned out of band at runtime (never committed) and shared
# by all jobs:
#   /var/lib/secrets/restic-password  the restic repository password
#   /var/lib/secrets/rclone.env       the rclone remote credentials

let
  cfg = config.homelab.backups;

  # All jobs share the repository, and restic refuses to start while another
  # process holds a conflicting lock: forget --prune takes an exclusive lock,
  # so a job that starts while another prunes would fail. Rather than
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

  # ExecStartPost of the job's unit: systemd runs it only when every
  # ExecStart command (backup, forget --prune) succeeded. The size is the
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
    passwordFile = "/var/lib/secrets/restic-password";
    environmentFile = "/var/lib/secrets/rclone.env";
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

    # The tag lets the runbook pick one job's snapshots. forget groups by
    # host and paths, so jobs never prune each other's snapshots.
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

    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 6"
      "--keep-yearly 1"
    ];
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
  ];

  environment.systemPackages = with pkgs; [
    restic
    rclone
    sqlite
  ];

  # Staging dir for the consistent database copies taken before each run,
  # and the list of declared jobs for the textfile collector. The link
  # follows the jobs on every rebuild.
  systemd.tmpfiles.rules = [
    "d /var/backup 0700 root root -"
    "L+ ${textfileDir}/homelab_backup_jobs.prom - - - - ${jobInfo}"
  ];

  services.restic.backups = lib.mapAttrs mkJob jobs;

  systemd.services = lib.mapAttrs'
    (name: _: lib.nameValuePair "restic-backups-${name}" { postStart = recordSuccess name; })
    jobs;
}
