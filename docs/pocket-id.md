# Pocket ID

Pocket ID is the site's OpenID Connect provider
([ADR-0018](adr/0018-pocket-id-is-the-oidc-provider.md)). The `pocket-id`
module runs it on the server host, behind Caddy at
`https://id.<domain>` (`homelab.pocketId.hostName`). Users sign in with
passkeys only; there are no passwords.

## Deploying it

1. Import `modules/pocket-id.nix` on the host that runs the reverse proxy
   and set `homelab.pocketId.enable = true`.
2. Add its site to the Caddyfile, as the example does:

   ```
   id.__DOMAIN__:443 {
   	import site_tls
   	reverse_proxy unix//run/pocket-id-http/pocket-id.sock
   }
   ```

   The name must resolve on the tailnet like the other sites. Passkeys
   are bound to it, so pick it once.
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

Pocket ID has no users at first, and its setup page makes whoever opens it
first the admin. Do this right after the first deploy; until then anyone
on the tailnet who reaches the site could take the admin account.

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

Other users are added in the admin UI (Users, then a signup link or a new
user), and register their own passkeys.

## Clients

Each service that signs in through Pocket ID is declared in
`homelab.pocketId.clients.<id>`: its redirect URIs, where its id and
secret go, who owns those files and which units read them. After Pocket
ID starts, the `pocket-id-clients` unit creates or updates each client
through Pocket ID's admin API, with the static API key, and writes the
files. Pocket ID makes the secrets; the unit checks the one in the file
on every run and asks for a new one when the file is empty or Pocket ID
no longer accepts it, then restarts the client's units.

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

The apps match the owner's existing account like this:

- Forgejo, through the `forgejo-oidc` sign in source: new accounts are
  named after the claim its `USERNAME` setting names, and an existing
  account of that name or email is linked once its password is given
  (`ACCOUNT_LINKING=login`). Today `USERNAME` is `email`, the local part
  of tsidp's email claim; Forgejo's move to Pocket ID makes it the
  username, so the Pocket ID username is the Forgejo user name.
- Grafana: the `email` claim is the user's login and email, and the
  addresses in `homelab.observability.grafanaOidc.admins` get Admin. The
  owner's Pocket ID email goes in that list; an existing Grafana user with
  that login keeps its dashboards and preferences.
- cue, fyr, podium and vaka sign in through dev/oidc; which claim each
  matches on is set when it moves to Pocket ID.

## Restoring

Restore `/var/lib/pocket-id` from the `pocket-id` job, with the database
from its SQLite copy under `/var/backup/pocket-id/`, and put the
encryption key back in `/var/lib/secrets/pocket-id-encryption-key` before
Pocket ID starts: with a database and no key, `pocket-id-keys` refuses to
start it rather than make a new key. The client secret files need not be
restored; `pocket-id-clients` makes new ones for secrets Pocket ID does
not accept, and restarts their services. Passkeys keep working as long as
the site's name is the same.
