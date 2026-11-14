# ADR-0012: Grafana's Git Sync service account and token are created by the host

Status: Accepted

## Context

[ADR-0009](0009-dashboards-through-grafana-git-sync.md) has the
`grafana-git-sync` unit call Grafana's API with the token of a service
account with the Admin role, in `/var/lib/secrets/grafana-git-sync-api-token`.
The owner makes that account once by hand in Grafana's UI, a step
DIRECTION.md counts as a gap to close (ADR-0010), and one the owner had to
ask about (board, 2026-11-14). ADR-0009 suggested a bootstrap admin password
from a file, with basic auth allowed for requests from the host only.
[ADR-0011](0011-git-sync-seeds-an-empty-repository.md) already took the
other manual step, the first commit, off the owner's hands.

Making a service account takes a signed in Org Admin. With
`grafanaOidc` or `grafanaProxyAuth` Grafana has no login form and no basic
auth (ADR-0005, ADR-0006), so the built-in admin cannot sign in with a
password at all. What was checked, against nixpkgs' Grafana 13.3.0 run on
its own (the pinned image is 13.3.1):

- Grafana provisions access control (Enterprise roles), alerting,
  dashboards, data sources, plugins and app manifests from files; not
  service accounts.
- `grafana cli admin` resets the admin's password and migrates data and
  secrets; it has no command for service accounts or tokens.
- Basic auth is one switch, `[auth.basic] enabled`, for every client.
  Grafana cannot limit it to some addresses.
- Proxy authentication checks the peer address against its `whitelist`
  and ignores `X-Forwarded-For`. With the whitelist `127.0.0.1` and sign
  up off, a request from 127.0.0.1 with `X-Grafana-Git-Sync-User: admin`
  is the built-in admin; the same headers from 127.0.0.2 get 401
  (`auth-proxy.invalid-ip`), and an unknown user from 127.0.0.1 gets 401
  (sign up disabled). Login form and basic auth stay off, and a password
  sign in still fails. The whitelist takes several addresses separated by
  commas.
- As that admin, `POST /api/serviceaccounts` with the role Admin makes the
  account, `POST /api/serviceaccounts/<id>/tokens` returns a `glsa_` token
  once, and the token reads the provisioning API. Deleting a token makes
  it fail at once.

Inside the grafana container's network namespace, 127.0.0.1 is Grafana
itself. Nothing on the tailnet, behind Caddy or in another container can
send from it; root on the host can, with `nsenter --net`.

Five ways were weighed.

1. **A bootstrap admin password and basic auth**, as ADR-0009 suggested.
   Grafana's basic auth cannot be limited to the host: on, it is on for
   every request through Caddy and from every container, guarded only by
   the password. That grows the sign in surface, which the issue rules out.
2. **Grafana's provisioning** of service accounts: 13.3 has none.
3. **The CLI in the container**: no command makes accounts or tokens. It
   could reset the admin's password, which then needs option 1.
4. **Writing the account and token into Grafana's database**: the token's
   hash and the tables are Grafana's internals, which change between
   releases, behind Grafana's caches.
5. **A second Grafana on the same volume**, with no network and basic auth
   on, while the real one is stopped: SQLite takes one server, so Grafana
   would go down, and the second one would start alert evaluation and Git
   Sync jobs without a network.

## Decision

- **Proxy authentication from 127.0.0.1 in the container.** With
  `grafanaGitSync`, Grafana takes the headers `X-Grafana-Git-Sync-User`
  (the login) and `X-Grafana-Git-Sync-Role` from `127.0.0.1` only, with
  sign up off, so only existing users. No password is involved, and the
  login form and basic auth stay as they are. With `grafanaProxyAuth`,
  Grafana has one user header: the whitelist becomes Caddy's address and
  `127.0.0.1`, and the unit sends `Remote-User` and `Remote-Role`.
- **The unit makes the token only when the file has none.** When
  `apiTokenFile` is missing or empty, `grafana-git-sync`, once Grafana
  answers, finds Grafana's process with `podman inspect`, and from its
  network namespace (`nsenter --net`) signs in as the built-in admin
  `admin`, with the role Admin:
  - finds the service account `grafana-git-sync`, or makes it with the
    role Admin;
  - adds a token named after the time, and writes it to `apiTokenFile`,
    through a temporary file in the same directory, mode 0400, owned by
    root, the unit's user;
  - then deletes the account's other tokens, so emptying the file
    rotates the token.
  A file with a token in it is used as it is, and nothing is made: hosts
  with a hand-made token keep it.
- **The token stays off command lines, the store and the logs.** It comes
  from Grafana in a file in the unit's private temporary directory and
  goes from there to `apiTokenFile`; the headers carry the admin's login,
  not a secret. If Grafana refuses the admin, the unit fails, saying what
  Grafana answered and that the file was not written, and nothing reaches
  Git Sync.

This replaces ADR-0009's making of the service account by hand, and adds
`127.0.0.1` in Grafana's own container to the address ADR-0005 has Grafana
trust `Remote-User` from, for hosts with `grafanaProxyAuth` and Git Sync.
The rest of both stands.

## Consequences

- Turning Git Sync on needs the Forgejo token only. Nothing new to
  provision; `grafana-git-sync-api-token` is written on the first run, and
  a site that loses it gets a new one at the next run.
- Grafana is itself at 127.0.0.1, so whoever can make Grafana send a
  request with headers of their choosing to its own port signs in as any
  existing user, the built-in admin included: a data source with custom
  headers, or a webhook contact point with extra headers. Setting those up
  takes the Admin role, or the Editor role for contact points. With
  `grafanaOidc` and `grafanaProxyAuth` only admins sign in, and
  anonymous users are Admins without them, so this lifts an Org Admin to
  the server admin, not a stranger in. With `grafanaProxyAuth` such a
  request may also sign up a user, since sign up is on for Caddy's users.
- Anything else that sends the headers gets 401 on that request, or with
  anonymous access goes on as anonymous. Browsers do not send them.
- The unit relies on the built-in admin, `admin`, being an Org Admin of
  the main organisation. A site that renamed or demoted it gets the unit's
  failure, and can still put a token in the file by hand.
- Grafana takes the headers only once restarted with the new settings,
  which the rebuild that turns this on does. Existing hosts with Git Sync
  restart Grafana once for the new environment, keep their token and get
  no new account; a hand-made account (ADR-0009's docs named it
  `git-sync`) stays until deleted in Grafana.
- The token is in Grafana's database, hashed, and in the file. The file is
  the source of truth: a token deleted in Grafana fails the unit until the
  file is emptied. A token whose old siblings could not be deleted is
  named in the journal; they stay valid until deleted by hand.
- The unit runs `nsenter` from util-linux and needs root, as it has.
  Grafana's API for service accounts is `/api/serviceaccounts`, stable
  since Grafana 9; a change there fails the unit, saying what Grafana
  answered.
- The `grafana-git-sync` check runs the script with a stubbed `nsenter`
  against the stand-in for Grafana: with no file the account and token are
  made once, mode 0400, never in the output; a file with a token is left
  alone; an empty one gets a new token for the same account and the old
  one deleted; and a Grafana refusing the admin fails clearly with no file
  written. Grafana's proxy authentication from 127.0.0.1 and from another
  address, and the service account API, were tested by hand as above.

Related: [ADR-0009](0009-dashboards-through-grafana-git-sync.md)
(dashboards through Grafana Git Sync),
[ADR-0011](0011-git-sync-seeds-an-empty-repository.md) (Git Sync seeds an
empty repository), [ADR-0005](0005-proxy-auth-only-from-caddy.md) (proxy
authentication only from Caddy), [ADR-0010](0010-tsidp-clients-declared-in-nix.md)
(services configured from Nix).
