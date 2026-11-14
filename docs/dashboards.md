# Dashboards in Git

Grafana's dashboards come from two places
(docs/adr/0009-dashboards-through-grafana-git-sync.md):

- `homelab.observability.dashboardsDir`: files in the host's config,
  read-only in Grafana's Homelab folder, changed with a rebuild. For the
  dashboards that come with the library, like
  `examples/assets/dashboards/gpu.json`.
- `homelab.observability.grafanaGitSync`: Grafana's Git Sync keeps the
  folder "Dashboards" in step with a directory of a Forgejo repository,
  both ways. Edit a dashboard in Grafana and it is committed to the
  branch; push a change to the branch and Grafana shows it within a
  minute. No rebuild either way.

Keep each dashboard in one place. To move one from `dashboardsDir` into
Git, add it to the repository and remove it from `dashboardsDir` in the
same change.

```nix
homelab.observability.grafanaGitSync = {
  enable = true;
  url = "https://git.example.com/org/dashboards.git";
  # branch = "main"; path = "dashboards"; intervalSeconds = 60;
  # tokenFile = "/var/lib/secrets/grafana-git-sync-token";
  # apiTokenFile = "/var/lib/secrets/grafana-git-sync-api-token";
  # seed = ./assets/git-sync-seed;
};
```

The URL is HTTPS: Git Sync speaks Git over HTTPS with protocol v2 only,
which Forgejo serves, and no SSH.

## The repository

Grafana pushes what you save straight to the branch; Pure Git cannot open
pull requests. So the repository must let Grafana's token push to the
branch without review:

- Make a repository for dashboards only, not one of the team's protected
  repositories.
- Leave its branch unprotected, or allow the token's user to push to it.
- The repository may start empty, or with an empty `dashboards`
  directory. Grafana adds one file per dashboard, and a `_folder.json` in
  each subfolder it makes. To start it with dashboards, see the next
  section.

## Seeding an empty repository

With `seed`, a directory of dashboard JSON files in the host's config,
the `grafana-git-sync` unit fills a repository that has no commits yet
before it sets the repository up in Grafana
(docs/adr/0011-git-sync-seeds-an-empty-repository.md):

- It asks Forgejo for the repository's branches, with the same token
  Grafana gets. If there is any, it does nothing, then or ever after: the
  seed never overwrites or adds to a repository with history, and editing
  the seed directory later changes nothing.
- Otherwise it makes one commit with every `.json` file of the seed,
  subdirectories included, under `path`, and pushes it to `branch`. The
  author is `grafana-git-sync <grafana-git-sync@localhost.invalid>`, and
  the message names the seed's store path. Grafana then pulls the
  dashboards on its first sync.
- Each plain dashboard is written in the form Grafana 13's Git Sync
  writes itself: a `dashboard.grafana.app/v1` resource named after the
  dashboard's `uid`, with the dashboard as its `spec` and its `id`, `uid`
  and `version` taken out. A file without a `uid` fails the unit, since
  Git Sync could not name the dashboard. Files already in that form are
  committed as they are.
- A failed push fails the unit before Grafana is touched; the journal
  says what Forgejo answered. Fix the cause and restart the unit.

Seed files are exported as for editing in Git, below. Start from
`examples/assets/git-sync-seed`. Keep the seed's dashboards out of
`dashboardsDir`.

## The tokens

Two files under `/var/lib/secrets`, each owned by root, mode 0400, read
only by the `grafana-git-sync` unit, which hands the first to Grafana. You
make the first; the unit makes the second.

1. **Forgejo.** Best from a Forgejo user of its own that has write access
   to this one repository: the token can push wherever its user can. Sign
   in as that user, open Settings, Applications, and generate a token with
   the scope `write:repository`. Then on the Grafana host:

   ```sh
   install -m 0400 /dev/null /var/lib/secrets/grafana-git-sync-token
   cat > /var/lib/secrets/grafana-git-sync-token   # paste, then Ctrl-D
   ```

2. **Grafana.** Nothing to do. When
   `/var/lib/secrets/grafana-git-sync-api-token` is missing or empty, the
   unit makes the service account `grafana-git-sync`, with the role Admin,
   adds a token to it and writes the token to the file
   (docs/adr/0012-git-sync-service-account-made-by-the-host.md). It signs
   in to Grafana as Grafana's built-in admin, which Grafana allows only
   from inside its own container, so no password and no new sign in for
   browsers. A token already in the file, such as one you made by hand
   before, is used as it is, and nothing is made.

Rebuild the host with the option on, then check the unit:

```sh
systemctl status grafana-git-sync
journalctl -u grafana-git-sync -n 20
```

On the first run it logs `Made the Grafana service account
grafana-git-sync, with the Admin role.` and `Wrote a new token of the
service account grafana-git-sync to ...`, then `Created the Git Sync
repository homelab-dashboards.` and `Grafana reaches the repository
homelab-dashboards.` The first pull follows; Administration, Provisioning
shows the repository, its last pull and any file it could not read.

To change the Forgejo token, replace the file and run
`systemctl restart grafana-git-sync`. To change Grafana's, empty its file
and restart the unit: it adds a new token to `grafana-git-sync` and
deletes the account's other tokens. A service account you made by hand
under another name stays, with its tokens, until you delete it under
Administration, Users and access, Service accounts. The unit also runs at
every boot and after every rebuild that changes the settings, and leaves
Grafana alone when nothing changed. A token that Forgejo refuses fails the
unit, which the "Failed systemd unit" alert reports.

## Editing a dashboard

- **In Grafana:** open a dashboard in the Dashboards folder, change it and
  Save. Grafana asks for a commit message and pushes the commit to the
  branch, authored by you. New dashboards saved into the folder, and
  dashboards deleted from it, are committed the same way.
- **In Git:** edit the dashboard's file in Forgejo's web editor or a
  clone and push to the branch. Grafana pulls every `intervalSeconds`, or
  at once with Pull on the repository's page under Administration,
  Provisioning. Deleting the file deletes the dashboard.

Each file is a whole dashboard, as Grafana writes it, or as Export, Export
as JSON gives it with "Export for sharing externally" off, so the
datasource uids (`Prometheus`, `Loki`) stay. Keep its `uid`, so links
survive edits. A file Grafana cannot read is skipped and named on the
repository's page; the other dashboards still sync.

Pull before you push from a clone: Grafana commits to the same branch, and
Forgejo refuses a push that is behind it.

## Turning it off

Turning the option off stops the unit; the repository, its folder and
dashboards stay in Grafana. Delete the repository under Administration,
Provisioning, and say whether its dashboards go with it.
