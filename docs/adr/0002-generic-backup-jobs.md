# ADR-0002: Backups are declared per host as homelab.backups.jobs

Status: Accepted

## Context

`modules/backups.nix` had one hard-coded restic job, for Vaultwarden. Forgejo
in this repository and services kept in consumers' own config repos (cue and
fyr, for example) need backups too, and most of them keep their state in a
SQLite database next to plain files. A copy of a live SQLite file can be
inconsistent, so a backup needs a snapshot taken through SQLite.

Modules only read `homelab.*` options, so a container module cannot add its
own job to a shared option. A per-service backup option in each container
module would also not help services that live outside this repository.

## Decision

A host declares its backups as `homelab.backups.jobs.<name>`: paths, live
SQLite databases, excludes and a schedule. `modules/backups.nix` turns each
job into `services.restic.backups.<name>`, so each is a
`restic-backups-<name>` unit with its own timer.

All jobs use the one repository in `homelab.backups.resticRepo` and its
existing secrets, `/var/lib/secrets/restic-password` and
`/var/lib/secrets/rclone.env`. Snapshots are tagged with the job name, and
retention applies per job.

Each SQLite database is copied with sqlite3's `.backup` into
`/var/backup/<name>/` before the run; the copy is backed up and the live file
and its sidecars are excluded.

Container modules do not declare their own backups. The Vaultwarden job
stays built into the module under its existing unit name.

## Consequences

- Consumers back up any service, including their own, without new secret
  files or a module change here.
- Jobs share one repository and its lock, so they wait for each other
  (restic `--retry-lock`) instead of running in parallel.
- Only SQLite databases are consistent; other files are copied as they are
  during the run. A Git push during a backup can leave a repository half
  copied, which the restore runbook (docs/backups.md) checks with `git fsck`.
- Hosts must remember to add a job when they add a stateful container; the
  README says so per service.
