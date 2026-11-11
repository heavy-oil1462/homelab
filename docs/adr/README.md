# Architecture decision records

One file per decision, named `NNNN-title.md` with the next free number.
Each has the sections Status, Context, Decision and Consequences.

Status is one of:

- Proposed: suggested in a pull request, not yet agreed.
- Accepted: in force; follow it.
- Superseded by NNNN: replaced by a later record. An accepted record's
  content is not edited; a change of course is a new record that
  supersedes it.

## Index

- [0001](0001-disko-input-for-checks.md) disko is a flake input for the
  checks only (Accepted)
- [0002](0002-generic-backup-jobs.md) backups are declared per host as
  homelab.backups.jobs (Accepted)
