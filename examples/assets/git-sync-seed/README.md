# Git Sync seed

A starting point for `homelab.observability.grafanaGitSync.seed`. The
grafana-git-sync unit commits the dashboard JSON files in this directory,
and its subdirectories, once to a Git Sync repository that has no commits
yet; after that the repository is the source and this directory is not
read again (docs/dashboards.md,
docs/adr/0011-git-sync-seeds-an-empty-repository.md). Files that do not
end in `.json`, like this one, are left out.

Each file is a dashboard as Grafana's Export, Export as JSON gives it with
"Export for sharing externally" off: it needs its `uid`, which names the
dashboard in Grafana. Don't put a dashboard here that is also in
`homelab.observability.dashboardsDir`.

- `overview.json`: which scrape targets are up, from Prometheus's `up`.
