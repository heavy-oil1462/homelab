# ADR-0031: One prune a night for the shared repository

Status: Accepted

## Context

All backup jobs share one restic repository (ADR-0002), on the site's
Google Drive through rclone. Every job ran the NixOS module's
`forget --prune` after its backup, over the whole repository: forget groups
by host and paths, so the cue job's run listed and pruned vaultwarden's and
fyr's snapshots too (Loki, 2026-11-23 01:10). That was five prunes a
night, each rewriting and deleting packs on Drive.

The repository now has a pack, `b31c244ab1`, that is listed but cannot be
read. Prunes have failed on it since 2026-11-24, and the restore test
(ADR-0027) shows Forgejo's newest snapshot needs it. The logs do not name
the cause. The `--retry-lock` wrapper keeps the prunes from running at
once, but an interrupted or retried upload or delete on Drive can leave
duplicates or holes, and every prune is one more chance of that. Stale
locks were removed most nights ("successfully removed 1 locks"), so runs
did get cut off.

The NixOS module (`services.restic.backups.<name>.pruneOpts`) has no way to
forget without pruning: a non-empty `pruneOpts` always runs `restic unlock`
and `restic forget --prune`.

## Decision

- Each job forgets only its own snapshots and prunes nothing. Its
  `pruneOpts` stay empty, so the module runs neither unlock nor
  forget --prune, and `modules/backups.nix` appends its own
  `restic forget --tag <job> --keep-…` to the unit's ExecStart, after the
  backup. Retention is unchanged: 7 daily, 4 weekly, 6 monthly, 1 yearly.
- A `restic-prune` unit and timer prune the repository once a night,
  `homelab.backups.prune.schedule`, 02:00 by default, after the jobs'
  default midnight run, with `Persistent`. It runs `restic unlock` (stale
  locks only) and `restic prune`, with the jobs' credentials and
  lock-waiting restic, and restic's default `--max-unused 5%`.
- The prune writes `homelab_backup_prune_last_run_timestamp_seconds`,
  `homelab_backup_prune_last_success_timestamp_seconds` and
  `homelab_backup_prune_ok` through the textfile collector, as the
  repository check does. The example's "Backup prune failed or stale" rule
  alerts on a failure or on no success in 2 days; the generic failed-unit
  rule leaves the unit out.
- `homelab_backup_last_success_timestamp_seconds` of a job means its
  backup and its own forget succeeded, not the prune.

This amends ADR-0002, where retention applied through each job's run, and
ADR-0007, where the job's success meant "the backup and the pruning".

## Consequences

- One prune a night touches the remote's packs instead of one per job. A
  job's forget only deletes snapshot files and takes the exclusive lock
  briefly.
- A job no longer forgets another job's snapshots; a snapshot without a
  job's tag (none are made) would never be forgotten.
- Data of forgotten snapshots stays in the repository until the next
  prune, up to a day longer than before.
- A failing prune no longer fails the jobs or their freshness: the backups
  keep running, and the prune alert says the repository needs attention.
  Before, a damaged pack turned every job's unit failed.
- The prune does not fix the damaged pack. That still needs the repair in
  docs/backups.md, "Repository check".
- The `backup-prune` check runs the example server's forget commands and
  the prune script against a local repository: each job forgets only its
  own tag, nothing is deleted until the prune, the prune writes ok, and a
  repository with a needed pack missing writes not ok.
