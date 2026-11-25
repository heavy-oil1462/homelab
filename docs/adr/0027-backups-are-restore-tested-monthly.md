# ADR-0027: Backups are restore-tested monthly, automatically

Status: Accepted

## Context

The owner asked whether any script restores the data in the snapshots
and confirms it is correct (board, 2026-11-25). None did. docs/backups.md
listed manual restore commands, and the restore drill of the backups
initiative was still to do.

The weekly `restic check` (homelab.backups.check) proves the repository is
sound: its structure, every index, and a share of its data packs read back
against their hashes. It says nothing about whether a job's data is usable.
A snapshot can be sound and still hold:

- a SQLite copy that is damaged, or empty because a path was wrong;
- a git repository copied halfway through a push (ADR-0002 says only the
  databases are consistent), with objects its refs need missing;
- nothing recent at all, when a job stopped saving snapshots that the
  freshness metric of ADR-0007 would miss, such as a job whose paths moved.

Only a restore and the applications' own checks show that. DIRECTION.md
asks for hands-free setup and alerts on failure, so a test the owner has
to remember to run by hand would not be done.

## Decision

- `modules/backups.nix` gets a `restic-restore-test` unit beside the
  check, with a timer on the first Sunday of the month at 05:00 (randomised
  by an hour, Persistent), ordered after `restic-check`. The owner can run
  it at any time with `systemctl start restic-restore-test`. It uses the
  jobs' credentials and their restic, which waits for the repository lock.
  Options are under `homelab.backups.restoreTest`: `enable` (on by
  default), `schedule`, `gitFsckTimeout` and `scratchDir`.
- For every job, Vaultwarden's included, one at a time, it takes the
  latest snapshot of this host tagged with the job's name and counts the
  job **correct** when:
  1. that snapshot is at most 2 days old;
  2. `restic restore --verify` restores it into `<scratchDir>/<job>` and
     reads every file back against the snapshot's content hashes;
  3. the restored regular files and their total size equal the counts
     restic kept in the snapshot's summary (snapshots from restic 0.17 on);
  4. each of the job's SQLite copies under `/var/backup/<job>/` passes
     `PRAGMA integrity_check` and has at least one table;
  5. every git repository restored (a directory with `HEAD` and
     `objects/`, bare or not) passes `git fsck --no-dangling`, all within
     `gitFsckTimeout`.
- The scratch directory is removed after each job, also on failure. By
  default it is under `/var/tmp`, which the unit has private
  (`PrivateTmp`), so systemd removes it even if the script is killed. An
  assertion keeps it apart from every job's paths, and the script never
  restores into or removes a directory there it did not make.
- Per job it writes, through the textfile collector as ADR-0007 has it,
  `homelab_backup_restore_test_ok`, `..._last_run_timestamp_seconds`,
  `..._last_success_timestamp_seconds` and `..._restored_bytes`, with the
  label `backup_job`, after each job and on failure too, and logs one
  summary line per job, so the unit's journal reads as a report.
- The example alert "Backup restore test failed" fires for a declared job
  whose last test failed or that has not passed in 40 days. The generic
  failed-unit rule leaves the unit out, as it does the check.

A restore test is kept apart from `restic check`: the check reads the
repository's packs, whichever job they belong to, weekly and cheaply; the
test reads one snapshot per job in full and runs the applications' checks,
which costs a full download of every job and is monthly for that reason.
Each catches what the other cannot.

## Consequences

- A backup that cannot be restored, or whose database or repositories are
  broken, alerts within a month, without the owner doing anything; a
  restore drill is one command.
- Every month the whole of each job's latest snapshot is downloaded from
  the remote, and the host needs free space for the largest job in
  `scratchDir`. A remote that bills for egress bills for it.
- The test's checks are generic: SQLite and git. Other formats (a
  Postgres dump, say) are only checked by `--verify`, which proves the
  bytes, not that the application can read them.
- A job on a schedule longer than 2 days fails the test; like the
  freshness rules of ADR-0007, that needs a change of its own.
- A git repository in the middle of a push when it was backed up fails
  git fsck. If it happens, the test reports it, and the next month's
  snapshot is likely sound; a repeated failure is a real problem.
- Turning the test off removes its metrics file on the next rebuild, so
  nothing alerts as overdue.

Related: [ADR-0002](0002-generic-backup-jobs.md),
[ADR-0007](0007-backup-freshness-textfile-metric.md).
