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
  through tsidp, the tailnet's OIDC provider (Superseded by ADR-0023)
- [ADR-0007](0007-backup-freshness-textfile-metric.md): Backup freshness is
  a node exporter textfile metric written by each job (Accepted)
- [ADR-0008](0008-dashboards-synced-from-git.md): Grafana's dashboards are
  synced from a Git repository by a timer on the host (Superseded by
  ADR-0009)
- [ADR-0009](0009-dashboards-through-grafana-git-sync.md): Dashboards
  through Grafana Git Sync (Accepted)
- [ADR-0010](0010-tsidp-clients-declared-in-nix.md): tsidp's OIDC clients
  are declared in Nix and written into its clients file before it starts
  (Superseded by ADR-0023)
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
- [ADR-0016](0016-image-updates-as-reviewed-bumps.md): Container image
  updates are found by a tool and land as reviewed bumps (Accepted)
- [ADR-0017](0017-running-images-are-scanned.md): Running images are
  scanned for known vulnerabilities (Accepted)
- [ADR-0018](0018-pocket-id-is-the-oidc-provider.md): Pocket ID is the
  site's OIDC provider (Accepted)
- [ADR-0019](0019-forgejo-and-grafana-on-pocket-id.md): Forgejo and
  Grafana choose their OIDC provider, and keep existing users on a switch
  (Accepted)
- [ADR-0020](0020-oidc-login-gate-at-the-proxy.md): Sites that can't sign
  in themselves get an OIDC login gate at the proxy (Accepted)
- [ADR-0021](0021-pocket-id-clients-on-the-secrets-api.md):
  pocket-id-clients follows Pocket ID's secrets API and is checked
  against Pocket ID itself (Accepted)
- [ADR-0022](0022-home-assistant-http-settings-after-the-yaml.md): Home
  Assistant's HTTP settings after the YAML (Accepted)
- [ADR-0023](0023-tsidp-retired-pocket-id-only.md): tsidp is retired;
  Pocket ID is the only OIDC provider (Accepted)
- [ADR-0024](0024-break-glass-ssh-from-the-lan.md): Break-glass SSH from
  the LAN, keys only (Accepted)
- [ADR-0025](0025-yubikey-prompts-once-per-session.md): YubiKey prompts
  on workstations: once per session, PIN where it matters (Accepted)
- [ADR-0026](0026-servers-ssh-through-sshd-only.md): Servers take SSH
  through sshd only, not Tailscale SSH (Accepted)
- [ADR-0027](0027-backups-are-restore-tested-monthly.md): Backups are
  restore-tested monthly, automatically (Accepted)
- [ADR-0028](0028-tailnet-lock-decides-which-nodes-join.md): Tailnet Lock
  decides which nodes join (Accepted)
- [ADR-0029](0029-network-gear-scraped-through-exporters.md): Network
  gear is scraped through exporters on the observability host (Accepted)
- [ADR-0030](0030-proxmox-pushes-opentelemetry-into-prometheus.md):
  Proxmox pushes OpenTelemetry into Prometheus (Accepted)
