# ADR-0007: Backup freshness is a node exporter textfile metric written by each job

Status: Proposed

## Context

A failed backup run leaves its `restic-backups-<job>` unit failed, and the
"Failed backup" rule alerts on it. A job that never runs fails nothing: a
timer stopped or removed, or a host that is down at the run time. The old
"Backup not run in 26h" rule read `node_systemd_timer_last_trigger_seconds`,
which disappears with the timer, and counts a trigger, not a success. The
owner asked whether the forgejo, cue and fyr backups run (board, 2026-11-14).

Prometheus needs to know when each job last succeeded, and which jobs the
host declares, so that a job with no success at all alerts too. Only the
host knows either. The node exporter already runs on every host
(`modules/observability-agent.nix`) and Prometheus scrapes it; its textfile
collector exports whatever `*.prom` files sit in a directory. A pushgateway
or an exporter of our own would be one more service for the same result.

## Decision

- The observability agent turns on the textfile collector on
  `homelab.observabilityAgent.textfileDirectory`
  (`/var/lib/prometheus-node-exporter/textfile`) and creates it. Other
  modules write their metrics there as `*.prom` files, each replaced
  atomically: written under a name without `.prom`, then renamed.
- Each backup job's unit gets an ExecStartPost that writes
  `homelab_backup_last_success_timestamp_seconds` and, when restic can list
  the new snapshot, `homelab_backup_last_success_size_bytes` (the snapshot
  summary's `total_bytes_processed`). systemd runs it only after the backup
  and the pruning succeeded.
- The backups module links a file into the directory with
  `homelab_backup_job_info` 1 for every declared job, Vaultwarden's
  included, from the store through tmpfiles, so it follows the config on
  every rebuild.
- The label is `backup_job`, not `job`: Prometheus sets `job` to the scrape
  job and would rename a scraped `job` label to `exported_job`.
- The rules stay in the consumer's alerting.yaml, as all rules do; the
  example has "Backup stale" (no success in 36h, for 1h) and "Backup never
  ran" (declared, no success, for 36h), both joined with the info series,
  in place of the timer rule.

## Consequences

- A job that stops running alerts within 37 hours of its last success,
  whatever stopped it, as long as the host is up; a host that is down
  alerts as "Host down" instead.
- Removing a job leaves its timestamp file behind, but without its info
  series it no longer alerts. Removing the backups module leaves a dangling
  link once the store path is collected, which the collector reports as
  `node_textfile_scrape_error`.
- A new job, and every job on the first rebuild with this change, has no
  timestamp until its first run; "Backup never ran" waits 36 hours so the
  scheduled run comes first.
- The size lookup is one more restic call per run, against the snapshot
  files restic has just cached, limited to 5 minutes and allowed to fail.
- Thresholds are fixed at 36 hours. A job on a longer schedule needs its own
  rule in the consumer's copy.
- Other host-side facts the Nix side knows (declared jobs, certificates)
  can use the same directory.
