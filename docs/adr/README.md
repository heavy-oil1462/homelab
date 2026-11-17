# Architecture decision records

One file per decision, named `NNNN-title.md` with the next free number.
Its first three lines are exactly the title as an H1, an empty line and
a plain status line; the sections Context, Decision and Consequences
follow:

```markdown
# ADR-NNNN: Title

Status: Accepted

## Context
```

The podium runner passes only Accepted records in this form on to its
workers (parseADR in podium's internal/runner/worker.go).

Status is one of:

- Proposed: suggested in a pull request, not yet agreed.
- Accepted: in force; follow it.
- Superseded by NNNN: replaced by a later record. An accepted record's
  content is not edited; a change of course is a new record that
  supersedes it.

A record of a decision the issue makes, or that the change implements,
is written as Accepted and listed so in the index. Proposed is only for
a decision the issue leaves open for the owner; a record left Proposed
never reaches the workers.

## Index

- [ADR-0001](0001-disko-input-for-checks.md): disko is a flake input for
  the checks only (Accepted)
- [ADR-0002](0002-generic-backup-jobs.md): Backups are declared per host as
  homelab.backups.jobs (Accepted)
- [ADR-0003](0003-tailscale-identity-for-sign-in.md): Sign-in uses the
  Tailscale identity, looked up by Caddy through WhoIs (Accepted)
- [ADR-0004](0004-probe-targets-through-file-sd.md): Probe targets reach
  Prometheus through file_sd (Accepted)
- [ADR-0005](0005-proxy-auth-only-from-caddy.md): Services trust
  Remote-User only from Caddy, by its fixed address or a socket only Caddy
  mounts (Accepted)
- [ADR-0006](0006-tsidp-for-oidc-sign-in.md): Forgejo and Grafana sign in
  through tsidp, the tailnet's OIDC provider (Accepted)
- [ADR-0007](0007-backup-freshness-textfile-metric.md): Backup freshness is
  a node exporter textfile metric written by each job (Accepted)
- [ADR-0008](0008-dashboards-synced-from-git.md): Grafana's dashboards are
  synced from a Git repository by a timer on the host (Superseded by
  ADR-0009)
- [ADR-0009](0009-dashboards-through-grafana-git-sync.md): Dashboards
  through Grafana Git Sync (Accepted)
- [ADR-0010](0010-tsidp-clients-declared-in-nix.md): tsidp's OIDC clients
  are declared in Nix and written into its clients file before it starts
  (Accepted)
- [ADR-0011](0011-git-sync-seeds-an-empty-repository.md): Git Sync seeds an
  empty repository once from the site's dashboards (Accepted)
- [ADR-0012](0012-git-sync-service-account-made-by-the-host.md): Grafana's
  Git Sync service account and token are created by the host (Accepted)
- [ADR-0013](0013-gpu-containers-check-the-cdi-spec.md): GPU containers
  check the CDI spec before they start (Accepted)
- [ADR-0014](0014-containers-run-unprivileged.md): Library containers run
  unprivileged, with dropped capabilities (Accepted)
- [ADR-0015](0015-forgejo-trusts-the-deploy-ca.md): Forgejo's SSH server
  trusts the deploy CA (Accepted)
