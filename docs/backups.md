# Backups and restore

`modules/backups.nix` backs up Vaultwarden and every job in
`homelab.backups.jobs` with restic, all into the one repository in
`homelab.backups.resticRepo`. Each job runs daily (or on its `schedule`) as
the `restic-backups-<job>` unit, and a failed run stays a failed unit, which
the node exporter's systemd collector reports.

A job declares its files and its live SQLite databases:

```nix
homelab.backups.jobs.forgejo = {
  paths = [ "/var/lib/forgejo" ];
  sqliteDatabases = [ "/var/lib/forgejo/data/forgejo.db" ];
};
```

Before each run every database is copied with sqlite3's `.backup` to the
same path under `/var/backup/<job>/`, so the snapshot holds a consistent copy
at `/var/backup/forgejo/var/lib/forgejo/data/forgejo.db` and no live database
file. Everything else in `paths` is copied as it is at that moment. A git
push during a run can therefore leave a repository half copied; check
repositories with `git fsck` after a restore, as below.

Retention is 7 daily, 4 weekly, 6 monthly and 1 yearly snapshot per job.

## Commands

Every job installs a wrapper, `restic-<job>`, that runs restic with the
job's repository, password file and rclone credentials, as root:

```sh
sudo restic-forgejo snapshots
```

All jobs share the repository, so any wrapper sees every snapshot. Without
the wrappers, for example from another machine with the same secrets:

```sh
set -a; . /var/lib/secrets/rclone.env; set +a
export RESTIC_PASSWORD_FILE=/var/lib/secrets/restic-password
export RESTIC_REPOSITORY=rclone:remote:homelab-backup   # homelab.backups.resticRepo
restic snapshots
```

The wrappers wait up to 12 hours for the repository lock (`--retry-lock`), so
a command started while a job prunes waits for it instead of failing.

## Restore one job

The example restores Forgejo; for another job, use its name, paths, unit and
user. Commands run as root on the host.

1. Pick a snapshot. Each job tags its snapshots with its name:

   ```sh
   restic-forgejo snapshots --tag forgejo
   restic-forgejo snapshots --path /var/lib/forgejo
   ```

   Note the ID, or use `latest`.

2. Restore it to a scratch directory, not over the live data:

   ```sh
   restic-forgejo restore <id> --target /root/restore-forgejo
   ```

   For the newest snapshot, `latest --tag forgejo` in place of the ID.

   The scratch directory holds the files at their full paths:
   `/root/restore-forgejo/var/lib/forgejo` and the database copy at
   `/root/restore-forgejo/var/backup/forgejo/var/lib/forgejo/data/forgejo.db`.
   Check the copy before going on:

   ```sh
   sqlite3 /root/restore-forgejo/var/backup/forgejo/var/lib/forgejo/data/forgejo.db 'PRAGMA integrity_check'
   ```

3. Stop the container, and its backup so it does not run halfway:

   ```sh
   systemctl stop restic-backups-forgejo.timer podman-forgejo
   ```

4. Put the files back, keeping the current state aside until the restore is
   verified:

   ```sh
   mv /var/lib/forgejo /var/lib/forgejo.before-restore
   cp -a /root/restore-forgejo/var/lib/forgejo /var/lib/forgejo
   ```

5. Put the database copy in place of the live database. The snapshot has no
   live database file and no `-wal`, `-shm` or `-journal` sidecars; make sure
   none are left over:

   ```sh
   cp /root/restore-forgejo/var/backup/forgejo/var/lib/forgejo/data/forgejo.db \
     /var/lib/forgejo/data/forgejo.db
   rm -f /var/lib/forgejo/data/forgejo.db-wal /var/lib/forgejo/data/forgejo.db-shm \
     /var/lib/forgejo/data/forgejo.db-journal
   ```

6. Fix ownership. Container users have static ids (see "Static user ids" in
   the README: 600 vaultwarden, 602 forgejo), unless the host overrides them:

   ```sh
   chown -R forgejo:forgejo /var/lib/forgejo
   ```

7. Start the container and the timer again:

   ```sh
   systemctl start podman-forgejo restic-backups-forgejo.timer
   ```

8. Verify. The unit is active and the log is clean:

   ```sh
   systemctl status podman-forgejo
   journalctl -u podman-forgejo -n 100
   ```

   Sign in to the web UI and open a few repositories. Then check every
   repository, since a push during the backup can leave one incomplete:

   ```sh
   podman exec forgejo sh -c \
     'for r in /var/lib/gitea/git/repositories/*/*.git; do echo "$r"; git -C "$r" fsck --no-progress; done'
   ```

   A broken repository is pushed again from a clone, or restored from an
   older snapshot by itself (`restic-forgejo restore <id> --include
   /var/lib/forgejo/git/repositories/<owner>/<repo>.git --target ...`).

9. Once everything works, remove `/var/lib/forgejo.before-restore` and
   `/root/restore-forgejo`.

## Checking a backup works

After deploying a new job, run it once and look for its snapshot:

```sh
systemctl start restic-backups-forgejo
journalctl -u restic-backups-forgejo -n 50
restic-forgejo snapshots --tag forgejo
```
