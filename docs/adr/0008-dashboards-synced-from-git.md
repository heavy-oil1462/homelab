# ADR-0008: Grafana's dashboards are synced from a Git repository by a timer on the host

Status: Superseded by ADR-0009

## Context

Grafana's dashboards were files in the site's config,
`homelab.observability.dashboardsDir`, copied into the Nix store and
mounted into the grafana container. Changing one meant a rebuild and a
deploy of the host. The owner wants to edit dashboards in Forgejo and have
a merged change reach Grafana within minutes, with no deploy (board issue
01a1dae9-7972, 2026-11-14).

Dashboards are data Grafana reads, not configuration of the host: the
module, the container and its settings stay as built. DIRECTION.md has
servers change only when deliberately rebuilt; this keeps to it for
everything but the dashboards' JSON, which the owner moves to Git on
purpose.

Three ways were considered.

1. A pull: a timer on the Grafana host fetches the repository and copies
   the dashboards into a directory Grafana's file provider reads.
2. A push: a Forgejo Actions workflow calls Grafana's HTTP API on merge.
   It needs a Grafana service account token stored in CI, and a runner that
   reaches Grafana; a runner able to write to Grafana is one more thing to
   protect, and a failed push leaves nothing on the host to alert on.
3. Grafana's own Git Sync. Experimental in Grafana 12 and 13, behind a
   feature flag, and it speaks to GitHub only.

## Decision

- **A pull.** `homelab.observability.dashboardsGit` (`enable`, `url`,
  `branch` "main", `path` "dashboards", `keyFile`, `interval` "2min") adds
  the `grafana-dashboards-sync` service and a timer running it every
  interval. It fetches the branch's head, depth 1, into a bare repository
  under `/var/lib/grafana-dashboards/state` and extracts `path` into a
  staging directory there.
- **Validation, then the swap.** Every `*.json` in the staging directory
  must parse as a JSON object with a non-empty string `title`. Only then is
  the staging directory copied into `/var/lib/grafana-dashboards/live` with
  `rsync --delete`. rsync writes each file under a temporary name and
  renames it into place, so Grafana reads whole files, and dashboards
  deleted in the repository go. Symbolic links are left out. A fetch that
  fails or a commit that does not check out leaves `live` as it was, logs
  the reason and fails the unit, until a later run succeeds. The existing
  "Failed systemd unit" rule alerts on it.
- The directory is not swapped by renaming a symlink: podman resolves a
  bind mount's source when the container starts, and Grafana's file
  provider keys provisioned dashboards by file path, so a path that changes
  on every commit would make it delete and recreate them.
- **Grafana.** The container mounts `live` read-only where it mounted
  `dashboardsDir`, at `/etc/grafana/dashboards`. The file provider checks it
  every 30 seconds and keeps `allowUiUpdates: false`: the repository is the
  source of truth, and a change made in the UI is exported and committed.
- **Credentials.** A read-only deploy key for that one repository, as an
  SSH private key in `/var/lib/secrets/grafana-dashboards-deploy-key`
  (root, 0400), passed to ssh with `-i`. Never in the store or the URL. The
  server's host key is trusted on first use and kept in the state
  directory.
- `dashboardsDir` and `dashboardsGit` are mutually exclusive on a host; an
  assertion requires exactly one. `dashboardsGit` is off by default.

## Consequences

- A merged change reaches Grafana within the interval plus 30 seconds, with
  no rebuild. Changing the repository, branch, path or interval is still a
  rebuild.
- Whoever can merge to the branch changes what Grafana shows, including
  queries against Prometheus and Loki. The branch should be protected in
  Forgejo the way the config repository is.
- Dashboards cannot be saved in Grafana. An edit made in the UI is lost
  unless exported and committed.
- The host needs the repository's SSH server on the network, and one new
  secret file. Without the key file the unit fails and Grafana shows the
  last synced set, or none on a new host.
- A Forgejo host key that changes (a rebuild of Forgejo with a new key)
  fails the unit until the old entry is removed from
  `/var/lib/grafana-dashboards/state/known_hosts`. Trusting on first use
  means the first fetch does not authenticate the server; it usually runs
  over the tailnet.
- Validation catches broken JSON and files that are not dashboards, not
  queries that are wrong or panels that do not render.
- The `grafana-dashboards-sync` check runs the script against a local bare
  repository: a good commit syncs, bad JSON and a missing title keep the old
  set and fail, a deleted dashboard is removed, and a missing branch or
  directory fails. The fetch over SSH and Grafana's reload are tested by
  hand.
