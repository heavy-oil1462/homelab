# ADR-0009: Dashboards through Grafana Git Sync

Status: Accepted

Amended by [ADR-0012](0012-git-sync-service-account-made-by-the-host.md):
the `grafana-git-sync` unit makes the Grafana service account and its
token when `apiTokenFile` has none, instead of the owner by hand.

## Context

[ADR-0008](0008-dashboards-synced-from-git.md) had a timer on the Grafana
host fetch a Forgejo repository and copy its dashboards into the directory
Grafana's file provider reads. That is one way: dashboards cannot be saved
in Grafana, and an edit made there is exported and committed by hand.

Grafana's own Git Sync keeps a folder of dashboards in step with a
directory of a Git repository both ways: Grafana pulls the branch on an
interval, and a dashboard saved in Grafana is committed and pushed. ADR-0008
rejected it as experimental and GitHub only. Both have changed. In Grafana
13 the `provisioning` feature is on by default, and since 12.4 the Pure Git
repository type speaks plain Git over HTTPS to any server with Smart HTTP
protocol v2, through Grafana's nanogit library. The owner chose Git Sync
over the timer (question 01a1daf3-fb83, 2026-11-14), so dashboards can be
edited in Grafana's UI or in Git and each side follows the other.

What was checked before deciding:

- The image moves from 13.0.2 (2026-06) to 13.3.1. Its changelog from
  13.0.3 to 13.3.1 lists as breaking: a renamed `marketplace` section, a
  removed frontend field `isDefault` on data source list items (not the
  provisioning file's `isDefault`), the `alertingSaveStateCompressed` flag,
  and Prometheus's Azure and SigV4 auth and Zipkin leaving core. None is
  something the library provisions. Nothing changed for file provisioning
  of datasources, alerting or dashboards, for `auth.generic_oauth`, the
  `__FILE` variables or `auth.proxy`; notification provisioning's HTTP
  endpoints were marked deprecated, which file provisioning does not use.
- In 13.3.1, `[provisioning] enabled` defaults to true, with no feature
  toggle. `repository_types` picks the types, and `allowed_git_urls` (from
  13.0.4) lets through a Git host that resolves to a loopback, private or
  link-local address, which Git Sync otherwise refuses against SSRF. A
  tailnet's IPv4 range (100.64.0.0/10) is not refused, its IPv6 ULA range
  is. `http://` URLs with a token are refused unless `allow_insecure`.
- Forgejo serves protocol v2 over HTTPS (`ls-refs`, `fetch` with
  `shallow` and `filter`), at Codeberg and in a local Forgejo 15.0.2 from
  our nixpkgs. Against that Forgejo, Grafana 13.0.1 from our nixpkgs, with
  `repository_types = git`, pulled the library's `gpu.json` into a folder,
  and a dashboard saved through Git Sync landed as a commit on the branch.
  Forgejo took the access token under any user name. The pinned 13.3.1 and
  Forgejo 17.0.1 images were not run here.
- The repository is a resource of Grafana's API
  (`provisioning.grafana.app/v0alpha1`, kind `Repository`), created with a
  service account token. The Git token goes in `secure.token.create`, is
  stored encrypted and cannot be read back. A PUT replaces the resource and
  takes a new token; one that carries a resourceVersion usually fails with
  409, as Grafana's controller writes the status every few seconds. Grafana
  tests a repository against the Git server on request.

## Decision

- **Grafana 13.3.1**, pinned by digest. With
  `homelab.observability.grafanaGitSync.enable` (off by default) the
  container gets `GF_PROVISIONING_REPOSITORY_TYPES=git`, Pure Git only,
  and `GF_PROVISIONING_ALLOWED_GIT_URLS` set to the host of the
  repository's URL, so it works whatever the name resolves to on the
  tailnet. The URL must be `https://`.
- **The repository is declared in Nix.** Options `url`, `branch` ("main"),
  `path` ("dashboards"), `intervalSeconds` (60), `tokenFile` and
  `apiTokenFile`. The `grafana-git-sync` oneshot unit reads both tokens
  from files under `/var/lib/secrets`, finds Grafana's address on podman's
  network and calls its API there: it creates the repository
  `homelab-dashboards`, or replaces it when its spec in Grafana differs
  from the config or the spec or token changed since the last run (a hash
  in `/var/lib/grafana-git-sync/applied`), then asks Grafana to test it.
  It runs at boot and whenever the config changes, and does nothing when
  all is in step. The tokens never reach a command line or the store.
- **Its settings:** sync target `folder`, so the dashboards are in a
  folder of their own, "Dashboards"; the `write` workflow only. Pure Git
  cannot open pull requests, so a dashboard saved in Grafana is committed
  straight to the branch, as the user who saved it. The repository Grafana
  writes to must therefore let its token push to that branch: it is **not
  one of the team's protected repositories**, and its branch has no
  protection or required reviews. It holds dashboards only.
- **Credentials.** A Forgejo access token with read and write access to
  repositories, best from a Forgejo user that can reach that one
  repository, in `/var/lib/secrets/grafana-git-sync-token`; and the token
  of a Grafana service account with the Admin role in
  `/var/lib/secrets/grafana-git-sync-api-token`. Both root, 0400. The
  service account is made once by hand in Grafana; sign in has no
  password, so nothing else could make it.
- **`dashboardsDir` stays, for the library's dashboards.** Its files are
  provisioned read-only into the Homelab folder, as before ADR-0008, and
  change with a rebuild. They follow the metrics the library's modules
  export (the GPU dashboard and the NVIDIA exporter, for example), so they
  belong with the module version, not in the owner's repository, where
  they would drift from it. The owner's own dashboards are in Git Sync's
  folder. A dashboard is in one or the other: the same uid from both
  would have two managers fighting over it, which Git Sync reports as a
  conflict, so moving a dashboard to Git means removing it from
  `dashboardsDir`. A host may set either or both.
- ADR-0008's `dashboardsGit` option, the `grafana-dashboards-sync` timer,
  its script and its check are removed.

## Consequences

- A dashboard saved in Grafana is in Git at once; a change pushed to the
  branch shows in Grafana within `intervalSeconds`. Forgejo sends Pure Git
  no webhooks, so it is polling. Changing the repository, branch, path,
  interval or a token is still a rebuild, which runs the unit.
- Anyone who can push to the branch changes what Grafana shows, including
  queries against Prometheus and Loki, and so can every Grafana user who
  may save dashboards in the folder (every user, with the Admin role, as
  sign in is set up today). Changes are not reviewed before they apply;
  Git's history is the record and the way back.
- The Forgejo token can push to every repository its user can write to.
  A Forgejo user of its own, with access to the dashboards repository
  only, keeps that to one repository.
- Grafana checks Git Sync files: a file that is not a dashboard is skipped
  with a warning on the repository's page and the rest sync. A broken
  dashboard does not keep the others from syncing, as ADR-0008's
  validation did, and no unit fails on it; a token the Git server refuses
  fails the `grafana-git-sync` unit at its next run, which the failed unit
  alert reports.
- Consumers provision two new secret files to turn the option on, and make
  a service account in Grafana by hand. That is a step in a UI, which
  DIRECTION.md counts as a gap to close (ADR-0010); closing it needs a way
  for the host to make the account, such as a bootstrap admin password
  file with basic auth on for local requests, left for later. Hosts that used `dashboardsGit`
  drop it and its deploy key, and either set `dashboardsDir` again or move
  those dashboards into the Git Sync repository.
- Grafana keeps the repository and its token in its database, in the
  `grafana-data` volume; turning the option off leaves it there until it is
  deleted in Administration, Provisioning.
- Git Sync's API is `v0alpha1`. A Grafana upgrade may change the
  Repository resource; the unit then fails, saying what Grafana answered.
- The `grafana-git-sync` check runs the unit's script against a stubbed
  podman and a stand-in for Grafana's API: create, nothing to do, a spec
  changed in Grafana, a new token, a refused Git token, a refused or
  missing API token and Grafana not answering. Git Sync against a real
  Forgejo was tested by hand as above.

Supersedes [ADR-0008](0008-dashboards-synced-from-git.md). Related:
[ADR-0006](0006-tsidp-for-oidc-sign-in.md) (Grafana's sign in).
