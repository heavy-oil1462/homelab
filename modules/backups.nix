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

  # Staging dir for the consistent database copies taken before each run.
  systemd.tmpfiles.rules = [
    "d /var/backup 0700 root root -"
  ];

  services.restic.backups = lib.mapAttrs mkJob jobs;
}
