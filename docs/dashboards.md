# Dashboards from Git

With `homelab.observability.dashboardsGit`, Grafana's dashboards live in a
Git repository and a merged change reaches Grafana within a few minutes,
with no rebuild (docs/adr/0008-dashboards-synced-from-git.md). The
`grafana-dashboards-sync` timer fetches the branch every `interval`, checks
that each `*.json` is JSON with a `title`, and copies the directory into
`/var/lib/grafana-dashboards/live`, which Grafana reads every 30 seconds.

```nix
homelab.observability.dashboardsGit = {
  enable = true;
  url = "ssh://git@git.example.com:2222/org/dashboards.git";
  # branch = "main"; path = "dashboards"; interval = "2min";
  # keyFile = "/var/lib/secrets/grafana-dashboards-deploy-key";
};
```

Remove `dashboardsDir` from the host: a host uses one or the other. The
example dashboards in `examples/assets/dashboards` are a starting point for
the repository's `dashboards` directory.

## A read-only deploy key

The host signs in to Forgejo with an SSH key that can read this one
repository and nothing else.

1. On the Grafana host, as root, make the key:

   ```sh
   ssh-keygen -t ed25519 -N "" -C "grafana-dashboards@$(hostname)" \
     -f /var/lib/secrets/grafana-dashboards-deploy-key
   chmod 0400 /var/lib/secrets/grafana-dashboards-deploy-key
   cat /var/lib/secrets/grafana-dashboards-deploy-key.pub
   ```

2. In Forgejo, open the repository's Settings, then Deploy keys, and add
   the public key. Leave "Enable write access" unticked.
3. Rebuild the host with the option on, then check the first run:

   ```sh
   systemctl start grafana-dashboards-sync
   journalctl -u grafana-dashboards-sync -n 20
   ```

   It logs `dashboards synced from main at <commit>`. The first fetch
   trusts Forgejo's SSH host key and stores it in
   `/var/lib/grafana-dashboards/state/known_hosts`. If Forgejo's host key
   changes, delete that file and run the unit again.

Protect the branch in Forgejo (Settings, Branches) so changes reach it
through pull requests: whoever can push to it changes what Grafana shows.

## Editing a dashboard

Dashboards are read-only in Grafana; the repository is the source of
truth.

- **In Forgejo:** edit the JSON file in the web editor or a clone, and
  merge. Grafana has it within the interval plus 30 seconds.
- **In Grafana:** change the dashboard, then choose Save dashboard; Grafana
  says it cannot save a provisioned dashboard and offers the JSON. Copy it,
  or use Export, Export as JSON, with "Export for sharing externally" off
  so the datasource uids (`Prometheus`, `Loki`) stay. Commit it over the
  file in the repository, keeping its `uid`, and merge.

Each file needs a `title`, and should keep a fixed `uid` so links to the
dashboard survive edits. Deleting a file removes the dashboard.

## When a commit is bad

A commit with a file that is not JSON, or a dashboard without a title,
does not reach Grafana: the last good dashboards stay, the unit fails and
logs which file, and the "Failed systemd unit" alert fires. Fix the file
in the repository; the next run that syncs clears the failed unit. The same
holds when the fetch fails, for example while the key file is missing or
Forgejo is down.
