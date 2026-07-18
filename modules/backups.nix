{ config, pkgs, ... }:

{
  imports = [ ./options.nix ];

  environment.systemPackages = with pkgs; [
    restic
    rclone
    sqlite
  ];

  # Staging dir for the consistent database snapshot taken before each run.
  systemd.tmpfiles.rules = [
    "d /var/backup 0700 root root -"
  ];

  # Vaultwarden holds the household password vault, so it is the one service
  # we cannot afford to lose. restic pushes an encrypted copy to the remote
  # repository through rclone once a day.
  #
  # A failed run is visible without any extra plumbing: the node exporter
  # systemd collector (modules/observability-agent.nix) exports
  #   node_systemd_unit_state{name="restic-backups-vaultwarden.service",state="failed"}
  # so Prometheus/Grafana can alert on it.
  #
  # Secrets are provisioned out of band at runtime (never committed):
  #   /var/lib/secrets/restic-password  the restic repository password
  #   /var/lib/secrets/rclone.env       the rclone remote credentials
  services.restic.backups.vaultwarden = {
    repository = config.homelab.backups.resticRepo;
    passwordFile = "/var/lib/secrets/restic-password";
    environmentFile = "/var/lib/secrets/rclone.env";

    # Create the repository on the first run if it does not exist yet.
    initialize = true;

    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };

    paths = [
      "/var/backup/vaultwarden.sqlite3.bak"
      "/var/lib/vaultwarden"
    ];

    # The live SQLite files are inconsistent while Vaultwarden is running, so we
    # back up the snapshot taken in backupPrepareCommand and skip the originals
    # and their WAL sidecars. icon_cache and tmp are regenerated and not worth
    # storing.
    extraBackupArgs = [
      "--exclude=/var/lib/vaultwarden/db.sqlite3"
      "--exclude=/var/lib/vaultwarden/db.sqlite3-journal"
      "--exclude=/var/lib/vaultwarden/db.sqlite3-wal"
      "--exclude=/var/lib/vaultwarden/db.sqlite3-shm"
      "--exclude=/var/lib/vaultwarden/icon_cache"
      "--exclude=/var/lib/vaultwarden/tmp"
    ];

    # Online backup of the live database into the staging dir. The sqlite .backup
    # command is safe to run while Vaultwarden has the database open.
    backupPrepareCommand = ''
      ${pkgs.sqlite}/bin/sqlite3 /var/lib/vaultwarden/db.sqlite3 ".backup '/var/backup/vaultwarden.sqlite3.bak'"
    '';

    # Always runs after the backup, including on failure.
    backupCleanupCommand = ''
      rm -f /var/backup/vaultwarden.sqlite3.bak
    '';

    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 6"
      "--keep-yearly 1"
    ];
  };
}
