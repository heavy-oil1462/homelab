# ADR-0011: Git Sync seeds an empty repository once from the site's dashboards

Status: Accepted

## Context

[ADR-0009](0009-dashboards-through-grafana-git-sync.md) keeps the owner's
dashboards in a Forgejo repository that Grafana's Git Sync pulls from and
pushes to. The owner made that repository empty and asked for it to start
with the site's current dashboards (cue issue 01a1daf1-0ea1, 2026-11-14).
By ADR-0009 it is outside the team's protected repositories, so no worker
can push to it, and pushing the first commit by hand is the kind of manual
step DIRECTION.md counts as a gap. The `grafana-git-sync` unit already
holds a Forgejo token that can push to it.

What Grafana 13 reads, from the source at v13.3.1
(`pkg/registry/apis/provisioning/resources/fileformat.go` and
`parser.go`, `jobs/export/resources.go`):

- A file is first decoded as a Kubernetes resource (`apiVersion`, `kind`,
  `metadata`, `spec`). Failing that, plain dashboard JSON is taken only if
  it has `panels`, `schemaVersion` and `tags`; it becomes a `v0alpha1`
  dashboard named after its `uid`.
- A dashboard without a name fails with "missing name": the `uid` must be
  there and is the dashboard's identity in Grafana.
- On reading, Grafana drops `spec.uid`, `spec.version` and `spec.id`
  itself; `id` belongs to its storage.
- Grafana writes and exports dashboards as `dashboard.grafana.app/v1`
  resources with `metadata` reduced to the name, one file per dashboard
  named after the title, and subdirectories as subfolders. Its export
  notes that a `v0alpha1` file cannot be loaded once synced back, and
  writes `v1` instead.

## Decision

- **`homelab.observability.grafanaGitSync.seed`**, a path to a directory
  of dashboard JSON files, null by default.
- **Once, and only into an empty repository.** With a seed, the
  `grafana-git-sync` unit first runs `git ls-remote` on the repository's
  URL. If the server lists any ref, the unit leaves the repository alone;
  if it has history but not the configured branch, it says so and goes
  on. Only a repository with no refs at all is seeded: one commit with
  every `.json` file of the seed, subdirectories kept, under the spec's
  `path`, pushed without force to its `branch`. A branch that appears
  meanwhile makes the push fail rather than be overwritten. The author is
  `grafana-git-sync <grafana-git-sync@localhost.invalid>`, the message
  names the seed's store path.
- **The form Grafana writes.** A plain dashboard becomes a
  `dashboard.grafana.app/v1` resource named after its `uid`, with the
  dashboard minus `id`, `uid` and `version` as its `spec`, so the files
  look the same as those Grafana commits later and need no `tags` to be
  read. A file without a `uid` fails the unit. A file that already has
  `apiVersion` and `kind` is committed as it is.
- **Before Grafana.** The seed runs before the repository is created in
  Grafana, which then pulls the seeded dashboards on its first sync. A
  failed `ls-remote` or push fails the unit and nothing reaches Grafana.
- **The token** goes to git through an askpass program that reads the
  token file; argv, the URL, the environment and the logs only carry the
  file's path. git runs with no system or user configuration, credential
  helper or terminal prompt, and each git command gets 60 seconds.

## Consequences

- Turning Git Sync on with a seed is a rebuild, with no step by hand
  beyond the tokens ADR-0009 already needs. The token's write access,
  which Grafana needs anyway, is what the seed pushes with.
- The seed is read once. After the first commit, editing the seed
  directory changes nothing, and the repository is the dashboards'
  source; a site that wants its seed back in force empties the repository
  by hand. The unit still asks the server for its refs at each run.
- A seed dashboard is managed by Git Sync, so ADR-0009's rule holds: it
  must not also be in `dashboardsDir`.
- The resource form follows Grafana 13's `v1` dashboard API. A later
  Grafana that changes it still reads plain JSON, but files the seed wrote
  may need converting, as ADR-0009 says of its `v0alpha1` Repository.
- The seed commit is unsigned and authored by the unit, not a person.
- The `grafana-git-sync` check seeds bare repositories behind
  `git http-backend` with basic auth: an empty repository gets exactly the
  seed in one commit, one with history is left alone, a refused push and
  a refused token fail before Grafana is called, a file without a `uid` is
  refused, and the token is in no process's command line or environment
  and in no output. Seeding a real Forgejo is tested by hand.

Related: [ADR-0009](0009-dashboards-through-grafana-git-sync.md)
(dashboards through Grafana Git Sync).
