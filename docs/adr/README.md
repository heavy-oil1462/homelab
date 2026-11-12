# Architecture decision records

One file per decision, named `NNNN-title.md` with the next free number.
It starts with the title as an H1 and a plain status line directly under
it, then the sections Context, Decision and Consequences:

```markdown
# ADR-NNNN: Title
Status: Proposed

## Context
```

The podium runner only passes records in this form on to its workers.

Status is one of:

- Proposed: suggested in a pull request, not yet agreed.
- Accepted: in force; follow it.
- Superseded by NNNN: replaced by a later record. An accepted record's
  content is not edited; a change of course is a new record that
  supersedes it.

## Index

- [ADR-0001](0001-disko-input-for-checks.md): disko is a flake input for
  the checks only (Accepted)
- [ADR-0002](0002-generic-backup-jobs.md): Backups are declared per host as
  homelab.backups.jobs (Accepted)
- [ADR-0003](0003-tailscale-identity-for-sign-in.md): Sign-in uses the
  Tailscale identity, looked up by Caddy through WhoIs (Accepted)
- [ADR-0005](0005-proxy-auth-only-from-caddy.md): Services trust
  Remote-User only from Caddy, by its fixed address or a socket only Caddy
  mounts (Accepted)
