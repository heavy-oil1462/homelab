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
  sqliteDatabases = [ "/var/lib/forgejo/data/gitea.db" ];
};
```

Before each run every database is copied with sqlite3's `.backup` to the
same path under `/var/backup/<job>/`, so the snapshot holds a consistent copy
at `/var/backup/forgejo/var/lib/forgejo/data/gitea.db` and no live database
file. Everything else in `paths` is copied as it is at that moment. A git
push during a run can therefore leave a repository half copied; check
repositories with `git fsck` after a restore, as below. The monthly
restore test (below) does both checks on every job's latest snapshot.

Retention is 7 daily, 4 weekly, 6 monthly and 1 yearly snapshot per job.

## Freshness metric

A failed run leaves a failed unit, but a job that does not run at all (its
timer stopped or removed, the host down at the run time) fails nothing. So
after every successful run, that is when the backup and the pruning both
succeeded, the job writes two metrics for the node exporter's textfile
collector (`modules/observability-agent.nix`), into
`homelab.observabilityAgent.textfileDirectory`
(`/var/lib/prometheus-node-exporter/textfile`):

- `homelab_backup_last_success_timestamp_seconds{backup_job="<job>"}`: the
  Unix time the run finished.
- `homelab_backup_last_success_size_bytes{backup_job="<job>"}`: the size of
  the files the run backed up, from the summary restic keeps in the
  snapshot. It is left out when restic cannot list the snapshot right after
  the run.

The host also exports `homelab_backup_job_info{backup_job="<job>"} 1` for
every job it declares, Vaultwarden's included, whether or not it has run.
The label is `backup_job` because Prometheus sets `job` to the scrape job,
`node-exporter`. A job that never succeeded has an info series and no
timestamp; a job removed from the config keeps its last timestamp file but
loses its info series.

`examples/assets/grafana-alerting.yaml` alerts on both: "Backup stale" when a
declared job's last success is more than 36 hours old, held for an hour, and
"Backup never ran" when a declared job has had no success for 36 hours. A
job on a schedule longer than daily needs a higher threshold in your copy.

To check on the host:

```sh
cat /var/lib/prometheus-node-exporter/textfile/homelab_backup_*.prom
curl -s localhost:9100/metrics | grep '^homelab_backup_'
```

and in Prometheus, the hours since each job last succeeded:

```promql
(time() - homelab_backup_last_success_timestamp_seconds) / 3600
```

## Repository check

A damaged repository does not stop the jobs: with a data pack missing,
`restic backup` still saves snapshots, and the damage shows only when a
prune, a restore or a check reads that pack. So the `restic-check` unit runs
`restic check --read-data-subset=5%` against `homelab.backups.resticRepo`
every Sunday at 04:00, started at a random point in the hour after, and at
the next boot when the host was down then. It checks the repository's
structure and every index, and downloads and verifies a random 5% of the
data packs, so weekly checks reach most of the data within a year.

It uses the jobs' password, rclone credentials and restic, which waits for
the repository lock: the check locks the repository exclusively, so it
waits for a running job, and a job started meanwhile waits for it. It is on
wherever the backups module is; change it with
`homelab.backups.check.schedule` (an OnCalendar value, best kept apart from
the jobs' schedules), `homelab.backups.check.readDataSubset` (`10%`, `1/4`
or `500M`) or turn it off with `homelab.backups.check.enable = false`, which
removes its last result too.

Each run writes `homelab_restic_check.prom` into the textfile directory,
also when the check fails:

- `homelab_backup_check_last_run_timestamp_seconds`: when it last ran.
- `homelab_backup_check_last_success_timestamp_seconds`: when it last
  passed. A failed check keeps the earlier value; it is missing until the
  first check passes.
- `homelab_backup_check_ok`: 1 when the last check passed, 0 when it failed.

A failed check also leaves the `restic-check` unit failed. The example's
"Backup repository check failed" rule alerts, as critical, when the last
check failed or when none has passed in 9 days; the generic "Failed systemd
unit" rule leaves the unit out. A host whose check has never run has no
metrics and does not alert.

To run it by hand and read the result:

```sh
systemctl start restic-check
journalctl -u restic-check -n 50
cat /var/lib/prometheus-node-exporter/textfile/homelab_restic_check.prom
```

When it fails, restic names what it found, for example
`pack b31c244ab1...: does not exist`. Repair the repository before the next
prune, as restic's troubleshooting guide describes: `restic repair index`,
then `restic repair snapshots --forget` for the snapshots that referred to
the lost data, then `restic check` again. The jobs' wrappers run these
against the repository (`sudo restic-vaultwarden repair index`). A site's
own config may wrap the steps in one script, such as homelab-config's
`scripts/setup/restic-repair.sh`, which the example rule's summary names.
After the repair, run `systemctl start restic-check` so the alert clears.

## Restore test

The repository check proves the repository is sound, not that a job's data
comes back usable. So the `restic-restore-test` unit restores every job,
Vaultwarden's included, and checks it, on the first Sunday of the month at
05:00, started at a random point in the hour after, and at the next boot
when the host was down then (ADR-0027). For each job, one at a time, it:

1. takes the job's latest snapshot of this host (`--tag <job>`), and fails
   the job when there is none or it is over 2 days old;
2. restores it with `restic restore --verify` into
   `/var/tmp/restic-restore-test/<job>`, reading every restored file back
   against the snapshot's content hashes, and compares the number of files
   and their total size with the summary restic kept in the snapshot;
3. runs `PRAGMA integrity_check` on each of the job's database copies
   (under `/var/backup/<job>/` in the snapshot), which must say `ok` and
   have at least one table;
4. runs `git fsck --no-dangling` on every git repository restored, bare or
   not, such as Forgejo's, all within an hour per job;
5. removes the scratch directory, also when a step failed.

The scratch directory is in the unit's own `/var/tmp`, which systemd
removes when the unit stops, and is never one of the jobs' paths. It needs
room for the largest job, and the test downloads each job's latest
snapshot in full from the remote once a month. It uses the jobs' password,
rclone credentials and lock-waiting restic. It is on wherever the backups
module is; change it with `homelab.backups.restoreTest.schedule`,
`homelab.backups.restoreTest.gitFsckTimeout` (seconds),
`homelab.backups.restoreTest.scratchDir` (somewhere with more room), or
turn it off with `homelab.backups.restoreTest.enable = false`, which
removes its last results too.

To run it now and read the result:

```sh
systemctl start restic-restore-test
journalctl -u restic-restore-test -n 50
cat /var/lib/prometheus-node-exporter/textfile/homelab_restore_test.prom
```

`systemctl start` returns when every job is done. The journal has one line
per job, its summary:

```
forgejo: snapshot 3f2a91c0 of 2026-11-29T03:12:44Z, 5121 files, 812.4 MiB restored and verified, 1 databases ok, 37 git repositories ok
```

or why it failed:

```
pocket-id: FAILED: database /var/lib/pocket-id/data/pocket-id.db fails its integrity check: ...
```

and the unit fails when any job did. The metrics file has, per job
(`backup_job="<job>"`), also after a failure:

- `homelab_backup_restore_test_ok`: 1 when the last test passed, 0 when it
  failed.
- `homelab_backup_restore_test_last_run_timestamp_seconds`: when it last
  ran.
- `homelab_backup_restore_test_last_success_timestamp_seconds`: when it
  last passed; a failure keeps the earlier value.
- `homelab_backup_restore_test_restored_bytes`: the bytes it restored,
  when the restore got that far.

The example's "Backup restore test failed" rule alerts, as critical, for a
declared job whose last test failed or that has not passed in 40 days; the
generic "Failed systemd unit" rule leaves the unit out.

What a failure means:

- *no snapshot* or *older than 48 hours*: the job has stopped backing up;
  see its unit, `journalctl -u restic-backups-<job>`.
- *restic restore --verify ... failed*: restic names the file or blob it
  could not restore; run `systemctl start restic-check`, and repair the
  repository as under "Repository check".
- *restored N files, the snapshot has M*: the restore is incomplete; as
  above.
- *database ... fails its integrity check* or *has no tables*: the job's
  copy of the database is broken. Check the live database with
  `sqlite3 <path> 'PRAGMA integrity_check'`; once it is sound, run the
  job (`systemctl start restic-backups-<job>`) and the test again.
- *git fsck of ... failed*: the repository was copied mid-push, or is
  broken on the host too. Run `git fsck` on the live repository; if that
  passes, run the job and the test again.

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
   `/root/restore-forgejo/var/backup/forgejo/var/lib/forgejo/data/gitea.db`.
   Check the copy before going on:

   ```sh
   sqlite3 /root/restore-forgejo/var/backup/forgejo/var/lib/forgejo/data/gitea.db 'PRAGMA integrity_check'
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
   cp /root/restore-forgejo/var/backup/forgejo/var/lib/forgejo/data/gitea.db \
     /var/lib/forgejo/data/gitea.db
   rm -f /var/lib/forgejo/data/gitea.db-wal /var/lib/forgejo/data/gitea.db-shm \
     /var/lib/forgejo/data/gitea.db-journal
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

The run updates the job's metric file, so
`/var/lib/prometheus-node-exporter/textfile/homelab_backup_forgejo.prom`
has a new timestamp and "Backup never ran" will not fire for it.
