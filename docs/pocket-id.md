# Pocket ID

Pocket ID is the site's OpenID Connect provider
([ADR-0018](adr/0018-pocket-id-is-the-oidc-provider.md)). The `pocket-id`
module runs it on the server host, behind Caddy at
`https://id.<domain>` (`homelab.pocketId.hostName`). Users sign in with
passkeys only; there are no passwords.

## Deploying it

1. Import `modules/pocket-id.nix` on the host that runs the reverse proxy
   and set `homelab.pocketId.enable = true`, with the owner's tailnet
   login in `homelab.pocketId.setupLogins` and
   `homelab.reverseProxy.tailscaleIdentity.enable` on:

   ```nix
   homelab.pocketId = {
     enable = true;
     setupLogins = [ "alice@github" ];
   };
   ```

2. Add its site to the Caddyfile, as the example does:

   ```
   id.__DOMAIN__:443 {
   	import site_tls
   	import pocket_id_setup
   	reverse_proxy unix//run/pocket-id-http/pocket-id.sock
   }
   ```

   `pocket_id_setup` is generated from `setupLogins`. It keeps Pocket ID's
   first-admin setup, the pages `/setup` and `/signup/setup` and the call
   `/api/signup/setup` that makes the admin, to those tailnet logins,
   looked up through WhoIs; anyone else, and any request with a token,
   gets 403 there. The host does not build without the import. The name
   must resolve on the tailnet like the other sites. Passkeys are bound to
   it, so pick it once.
3. Back up its state with a job that copies the database through SQLite:

   ```nix
   homelab.backups.jobs.pocket-id = {
     paths = [ config.homelab.pocketId.dataDir ];
     sqliteDatabases = [ config.homelab.pocketId.databaseFile ];
   };
   ```

4. Rebuild. On the first start `pocket-id-keys` writes
   `/var/lib/secrets/pocket-id-encryption-key` and
   `/var/lib/secrets/pocket-id-api-key`. Keep a copy of the encryption key
   where the restic password is kept: the database encrypts Pocket ID's
   signing keys with it, and a restored database is useless without it.

## The owner's account and passkey

Pocket ID has no users at first, and its setup page makes whoever finishes
it first the admin. Only the logins in `homelab.pocketId.setupLogins`
reach it, so the owner can do this whenever convenient; other users,
agents and tagged nodes on the tailnet get 403. Once the admin exists,
Pocket ID refuses the setup itself.

1. Open `https://id.<domain>/setup`.
2. Enter first and last name, a username and an email. These become the
   claims the apps match the account on (below), so use the same username
   as the Forgejo account and the email Grafana knows you by.
3. Pocket ID asks for a passkey. Insert the YubiKey, choose it as a
   security key in the browser's dialog, enter its PIN if the browser asks
   for one, and touch it.
4. Under the account's settings, add a second passkey, such as a phone or
   a second key, so losing one key does not lock you out. Without any,
   `pocket-id one-time-access-token <username>` on the host (as the
   `pocket-id` user, in `/var/lib/pocket-id`, with the unit's environment)
   prints a one-time sign in link.

Other users are added in the admin UI (Users, then a new user), and
register their own passkeys. Users cannot change their own name, username
or email: the admin does, in Users, for every account including their
own. Apps match accounts on the username and email, so this keeps a user
from taking an address no account holds
([ADR-0019](adr/0019-forgejo-and-grafana-on-pocket-id.md)).
`homelab.pocketId.allowOwnAccountEdit` allows it again, but Grafana on
Pocket ID and the proxy's login gate then do not build.

Pocket ID's application settings come from the host's config
(`UI_CONFIG_DISABLED`); its admin UI shows them read-only. How long a
sign-in lasts is `homelab.pocketId.sessionDuration`, in minutes
(`SESSION_DURATION`), an hour by default. Within it an app that sends
the browser to Pocket ID gets it back without the passkey; after it, the
passkey is asked again. Setting it to the login gate's
`homelab.reverseProxy.oidcGate.sessionLifetime`, `1440` for its default
24h, makes it one sign-in a day. Set others by their
environment name in `services.pocket-id.settings`, such as
`ALLOW_USER_SIGNUPS = "withToken";` for sign up links, which let the new
user choose their own email once.

## Clients

Each service that signs in through Pocket ID is declared in
`homelab.pocketId.clients.<id>`: its redirect URIs, where its id and
secret go, who owns those files and which units read them. After Pocket
ID starts, the `pocket-id-clients` unit creates or updates each client
through Pocket ID's admin API, with the static API key, and writes the
files. A client keeps the id it is declared with, which is the id the
service signs in with. Pocket ID makes the secrets; the unit checks the
one in the file on every run and asks for a new one when the file is
empty or Pocket ID no longer accepts it, deletes the client's other
secrets, and restarts the client's units. It needs Pocket ID 2.14 or
later, whose clients hold several secrets; the host does not build with
an older one.

```nix
homelab.pocketId.clients.grafana = {
  displayName = "Grafana";
  redirectUris = [ "https://status.${config.homelab.domain}/login/generic_oauth" ];
  owner = "grafana";
  units = [ "podman-grafana.service" ];
};
```

The service's issuer is `config.homelab.pocketId.url`. Its discovery
document is at `<issuer>/.well-known/openid-configuration`.

- To rotate a secret, empty its file and restart `pocket-id-clients`.
- A secret added in the admin UI works next to the file's until the unit
  next makes one. Deleting the file's secret there gets a new one on the
  next run.
- A client already in Pocket ID with a declared id, made by hand or left
  by a run that failed, is taken over: its settings follow the config,
  and its secrets are replaced by the one written to the file.
- Removing a client from the config deletes it from Pocket ID; its files
  stay.
- Settings the option does not cover, such as restricting a client to a
  user group, its launch URL or its logo, are set in the admin UI and
  kept. A client's name, redirect URIs and PKCE are reset to the config's
  on the next run.

## Claims and account links

Pocket ID sends, with the scopes `openid profile email`:

- `sub`: the user's id in Pocket ID, a UUID that never changes;
- `preferred_username`: the username;
- `email` and `email_verified`;
- `name`, `given_name`, `family_name`;
- `groups`, with the scope `groups`.

The apps match the owner's existing account like this
([ADR-0019](adr/0019-forgejo-and-grafana-on-pocket-id.md)):

- Forgejo, through the `forgejo-oidc` sign in source: new accounts are
  named after the Pocket ID username (`USERNAME=preferred_username`), and
  an existing account of that name or email is linked once its password
  is given (`ACCOUNT_LINKING=login`). Linking without the password
  (`auto`) is left off: Pocket ID users can change their own username and
  email, and would then be linked to someone else's account.
- Grafana: the `email` claim is the user's login and email, and the
  addresses in `homelab.observability.grafanaOidc.admins` get Admin.
  Grafana looks an existing user up by that email, so a user whose email
  is the owner's Pocket ID email is kept. Both are safe because users
  cannot change their own email in Pocket ID.
- cue, fyr, podium and vaka sign in through dev/oidc; which claim each
  matches on is set when it moves to Pocket ID.
- The proxy's login gate (`homelab.reverseProxy.oidcGate`) matches the
  username: the names in its `owners` and `users` are Pocket ID
  usernames, and the site behind it gets the username as `Remote-User`.
  Its client is declared like any other, as `examples/server.nix` does
  (docs/adr/0020-oidc-login-gate-at-the-proxy.md).

## Moving off tsidp

tsidp is removed, and Pocket ID is the only OIDC provider
(docs/adr/0023-tsidp-retired-pocket-id-only.md). A host whose Forgejo or
Grafana still signs in through tsidp no longer builds: the `tsidp` module
is gone, and `homelab.tsidp` and the services' `issuer` options fail with
a message that points here. The move is the provider switch sites made
before tsidp was removed, homelab-config among them: there, each service
set its `provider` to `pocket-id` and dropped its tsidp issuer and
client, and a later update of this library removed the rest. A host
still on tsidp makes the same switch in one rebuild, once Pocket ID runs
and the owner's account exists (above). `provider` can only be
`pocket-id` now; a host that sets it still builds.

1. Make the owner's Pocket ID account match, in Pocket ID's admin UI under
   Users: its username is the owner's Forgejo user name, and its email is
   the email of the owner's Grafana user (Grafana, Profile). If the Grafana
   email is tsidp's form, such as
   `alice@github.idp.<tailnet>.ts.net`, keep the real address in Pocket
   ID; Grafana then makes a new user, as below.
2. Know the password of the owner's Forgejo account. If it is forgotten,
   or the account was made on a tsidp sign in and has none, set one on
   the host:

   ```sh
   podman exec -it forgejo forgejo admin user change-password --username alice --password '<new password>'
   ```

   Forgejo asks for a new one at the next password sign in.
3. In the host's config, declare the clients, and remove `homelab.tsidp`,
   the import of the `tsidp` module, the backup job of tsidp's state and
   each service's `issuer` (it is `homelab.pocketId.url`). Grafana's
   admins become Pocket ID emails:

   ```nix
   homelab.pocketId.clients = {
     forgejo = {
       displayName = "Forgejo";
       redirectUris = [ "https://git.${config.homelab.domain}/user/oauth2/pocket-id/callback" ];
       idFile = config.homelab.forgejo.oidc.clientIdFile;
       secretFile = config.homelab.forgejo.oidc.clientSecretFile;
       units = [ "forgejo-oidc.service" ];
     };
     grafana = {
       displayName = "Grafana";
       redirectUris = [ "https://status.${config.homelab.domain}/login/generic_oauth" ];
       pkce = true;
       idFile = config.homelab.observability.grafanaOidc.clientIdFile;
       secretFile = config.homelab.observability.grafanaOidc.clientSecretFile;
       owner = "grafana";
       units = [ "podman-grafana.service" ];
     };
   };
   # The admins' Pocket ID emails.
   homelab.observability.grafanaOidc.admins = [ "alice@example.com" ];
   ```

   The host does not build if Pocket ID is off, a client is missing, a
   tsidp option is left, or, for Grafana, Pocket ID lets users edit their
   own accounts. `examples/server.nix` declares the clients from the
   options this way.
4. Rebuild. `pocket-id-clients` creates both clients, writes their id and
   secret files over tsidp's, and restarts `forgejo-oidc` and Grafana.
   `forgejo-oidc` updates the sign in source `tailscale` in place to
   Pocket ID's issuer, id and secret, renames it `pocket-id`, and
   restarts Forgejo.

What the owner sees on the first sign in:

- **Forgejo**: the sign in page has "Sign in with pocket-id" where
  "tailscale" was. It goes to Pocket ID, which asks for the passkey
  unless already signed in there, then once asks to allow Forgejo to see
  the email and profile. Back in Forgejo, Pocket ID's user id is new to
  it and the name is taken, so Forgejo shows its link account page: sign
  in there with the Forgejo user name and password (and the second
  factor, if the account has one). From then on Pocket ID signs straight
  in. Other users do the same once; an account Forgejo made on a tsidp
  sign in needs a password set first, as in step 2.
- **Grafana**: opening Grafana goes straight to Pocket ID (auto login),
  with the passkey and, once, the consent screen for Grafana. Back in
  Grafana, the owner is the user with that email, with the Admin role as
  before. If no user has that email, Grafana makes one, with the Admin
  role: dashboards, folders, alert rules, data sources and Git Sync
  belong to the organisation and are all still there; only the old
  user's own preferences and starred dashboards stay with it. Delete the
  old user under Administration, Users and access, Users.

Sessions already open in either service keep working until they expire.

Once both sign in through Pocket ID, what tsidp left can go: its state in
`/var/lib/private/tsidp`, `/var/lib/secrets/tsidp.env`, the `idp` node in
the tailnet's admin console, and the `tailscale.com/cap/tsidp` grant in
the tailnet policy. A rebuild removes none of them.

## Restoring

Restore `/var/lib/pocket-id` from the `pocket-id` job, with the database
from its SQLite copy under `/var/backup/pocket-id/`, and put the
encryption key back in `/var/lib/secrets/pocket-id-encryption-key` before
Pocket ID starts: with a database and no key, `pocket-id-keys` refuses to
start it rather than make a new key. The client secret files need not be
restored; `pocket-id-clients` makes new ones for secrets Pocket ID does
not accept, and restarts their services. Passkeys keep working as long as
the site's name is the same.
