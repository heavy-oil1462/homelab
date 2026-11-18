# ADR-0018: Pocket ID is the site's OIDC provider

Status: Accepted

## Context

Sign-in rests on Tailscale's identity today. Caddy looks the tailnet user
up through WhoIs for podium, cue, fyr and the camera sites
([ADR-0003](0003-tailscale-identity-for-sign-in.md)), and Forgejo and
Grafana sign in through tsidp, Tailscale's OIDC provider, whose users are
the tailnet's ([ADR-0006](0006-tsidp-for-oidc-sign-in.md), with its
clients declared in Nix by [ADR-0010](0010-tsidp-clients-declared-in-nix.md)).

The owner wants sign-in off Tailscale's identity ("I may want to look at
open source altneratives to tailscale later", board 01a1f005-32ef) and
chose to move every site now, the WhoIs sites included (question
01a1f005-df03, 2026-11-18). After a comparison with Authentik the choice
of Pocket ID stands (board 01a1f08c-244d, 2026-11-18).

Pocket ID is an open source OIDC provider that signs users in with
passkeys only, so the owner's YubiKey becomes the login. It keeps its
state in one SQLite database. nixpkgs has it as a package and a NixOS
module, `services.pocket-id`, at our pin (Pocket ID 2.7.0).

What Pocket ID 2.7.0 offers for declaring clients from Nix, read in its
source:

- Its admin API creates a client with an id of our choosing
  (`POST /api/oidc/clients`, `OidcClientCreateDto.ID`), updates it
  (`PUT /api/oidc/clients/<id>`), deletes it, and makes a new secret for
  it (`POST /api/oidc/clients/<id>/secret`). The secret is made by Pocket
  ID, returned once and stored only as a bcrypt hash; no call sets it.
- `STATIC_API_KEY` (or `STATIC_API_KEY_FILE`) gives the API an admin key
  from the environment, with no user to create first, and it does not
  count as a user for the first-run setup.
- Introspection (`POST /api/oidc/introspect`) checks the client's id and
  secret before it looks at the token: a wrong secret is 401, a token
  that is no JWT is 200 and inactive.
- It has no file of clients read at start, as tsidp has, and no seeding
  mechanism; the clients are rows in the database.

Three ways were considered.

1. The admin API with the static key, once Pocket ID answers.
2. Writing the clients into the SQLite database before Pocket ID starts,
   as ADR-0010 does with tsidp's file. That ties us to the schema, which
   Pocket ID migrates on its own, and would have to make bcrypt hashes
   and Pocket ID's other columns (creator, timestamps) right ourselves.
3. Registering the clients by hand in the admin UI, which DIRECTION.md
   counts as a gap to close.

## Decision

- **Pocket ID is the site's OIDC provider.** Services that speak OIDC
  sign in through it; sites that do not go through the proxy's login
  gate (issue 01a1f008-7816), which signs in through Pocket ID too. It
  supersedes ADR-0006 and ADR-0010 for new work: no new service signs in
  through tsidp. They stay in force for what still runs on tsidp until the
  migration is complete, and are marked superseded by this record then.
- **WhoIs is retired site by site.** Each site that imports
  `tailnet_identity` (ADR-0003) moves to the login gate, and ADR-0003 is
  superseded when the last one has.
- **The module.** `modules/pocket-id.nix` (`homelab.pocketId`) sets
  nixpkgs' `services.pocket-id`, as a NixOS service rather than a
  container: the module and package move with `flake.lock`, with no image
  to pin. It runs as nixpkgs' `pocket-id` system user with no
  capabilities and nixpkgs' sandboxing, so it holds to ADR-0014's aim
  without a container.
- **Behind Caddy, on a socket.** Pocket ID serves HTTP only on
  `/run/pocket-id-http/pocket-id.sock`. The directory is mode 0750, owned
  by `pocket-id` with the group `caddy`, and only the caddy container
  mounts it, so nothing listens on a port and only Caddy reaches it, as
  with Forgejo's socket (ADR-0005). Caddy serves it as
  `https://id.<domain>` (`homelab.pocketId.hostName`), tailnet-only like
  every site; that URL is the issuer. Pocket ID trusts Caddy's
  `X-Forwarded-For`. Its analytics and version check are off.
- **Its keys.** Pocket ID needs an encryption key for the signing keys it
  keeps in the database, and the clients unit needs the static API key.
  A oneshot before Pocket ID, `pocket-id-keys`, writes each to
  `/var/lib/secrets` (`pocket-id-encryption-key`, `pocket-id-api-key`,
  root, 0400) when missing. The encryption key is made only while there
  is no database: with a database and no key, it fails rather than make a
  key that cannot read the database. systemd hands both to Pocket ID as
  credentials.
- **Clients declared in Nix, through the admin API** (option 1).
  `homelab.pocketId.clients.<id>` declares a client by its id, with
  `displayName`, `redirectUris`, `logoutRedirectUris`, `pkce`, `idFile`
  and `secretFile` (`/var/lib/secrets/<id>-oidc-client-id` and
  `-client-secret` by default), `owner` (root by default) and `units`, the
  systemd units that read the files. The `pocket-id-clients` unit runs
  after Pocket ID, as root, and for each client:
  - creates it, or updates it when its name, redirect URIs, PKCE or
    confidentiality differ, sending back the settings the option does not
    name (group restriction, launch URL, logos) as they are;
  - writes the id to `idFile` when it does not hold it;
  - checks the secret in `secretFile` by introspection, and when the
    client is new, the file is missing or empty, or Pocket ID refuses it,
    has Pocket ID make a new secret and writes it to the file. Both files
    are mode 0400, owned by `owner` and its group, written by a rename;
  - when it wrote either file, restarts the client's `units`.
  The clients' units start after `pocket-id-clients` and pull it in.
  Clients created in the admin UI are left alone. The ids declared last
  time are kept in `/var/lib/pocket-id/homelab-clients.json`, so a client
  removed from the config is deleted from Pocket ID; its files stay. The
  login gate's oauth2-proxy is declared the same way, as one more client.
- As with ADR-0010, a service's OIDC option does not declare its client
  inside the library; the host declares it, as `docs/pocket-id.md` shows.
- **Backup.** Pocket ID's state is `/var/lib/pocket-id`: the SQLite
  database `data/pocket-id.db` and uploads such as profile pictures. A
  host backs it up with a `homelab.backups.jobs` entry that lists
  `homelab.pocketId.databaseFile` as a SQLite database, so it is copied
  consistently with `.backup` (ADR-0002), as cue and fyr are. The
  encryption key is not in that backup; it is kept off the host with the
  backup password.
- **The first-admin setup is guarded at the proxy.** Pocket ID makes
  whoever finishes its setup first the admin, and the tailnet holds more
  than the owner: agent hosts, and podium's workers browsing out through
  it. The reverse proxy generates the snippet `pocket_id_setup` from
  `homelab.pocketId.setupLogins`, which Pocket ID's site imports. For the
  setup's pages and API call, as Pocket ID 2.7.0 has them (`/setup`,
  `/signup/setup` and `/api/signup/setup`, each with what follows a
  slash), it looks the client up through WhoIs (`tailnet_identity`,
  ADR-0003) and answers 403 unless the login is listed. A request with a
  token gets no identity, so it is refused too. A host with Pocket ID
  does not build unless the Caddyfile imports the snippet, the list is
  not empty and the WhoIs lookup is on. The guard stays after the admin
  exists, when Pocket ID refuses the setup itself anyway.
- **The owner's account** is made once on Pocket ID's setup page, with
  the YubiKey as its passkey (`docs/pocket-id.md`). Apps match it by the
  `preferred_username` or `email` claim, each as its own move settles.

Option 2 is rejected because it writes another program's database behind
its back, against a schema it migrates itself. Option 3 is the manual step
DIRECTION.md asks to close.

## Consequences

- Sign-in no longer depends on Tailscale's identity: the tailnet decides
  who reaches the sites, Pocket ID and the passkey who is signed in. A
  stolen unlocked device is no longer signed in everywhere by itself.
- Pocket ID is one more stateful service to back up and restore. Losing
  its database means the owner's account and passkeys are made again and
  every client gets a new secret; losing the encryption key makes a
  restored database unreadable.
- Only the owner's tailnet logins reach the setup, so its race is no
  owner risk. The guard rests on WhoIs, which this record retires: the
  change that removes the last WhoIs site keeps the setup closed another
  way, such as through the login gate, or drops the guard on hosts whose
  admin exists. A setup path a later Pocket ID adds is unguarded until
  the snippet lists it; the `identity-mapping` check pins the paths of
  2.7.0.
- Pocket ID makes the secrets, so the secret file is not the source of
  truth as with tsidp: a secret written by hand is refused and replaced on
  the next run. To rotate one, empty the file and restart
  `pocket-id-clients`.
- A secret made again in the admin UI is replaced on the next run of
  `pocket-id-clients`, and the client's units restarted. Its name,
  redirect URIs and PKCE edited in the UI are reset to the config's.
- The script relies on Pocket ID's admin API of 2.7.0. A Pocket ID that
  changes it fails `pocket-id-clients` with the status it got, and the
  services keep the files they have. The `pocket-id-clients` check pins
  the calls we make against a stand-in; the real API is tested by hand.
- Passkeys are bound to the site's name, so `homelab.pocketId.hostName` is
  chosen once.
- Services reach the issuer through Caddy at `https://id.<domain>`, from
  containers through the host's tailnet address. If Pocket ID is down,
  new sign-ins fail; existing sessions keep working until they expire.
- Consumers provision nothing new: both keys and the client files are
  made on the host. The encryption key belongs on the recovery card.
- The migration follows in order, one change per repository: the gate
  takes Pocket ID as its provider; homelab-config deploys it and
  registers the owner; Forgejo and Grafana move; cue, fyr, podium and vaka
  move; the WhoIs sites move to the gate; tsidp is removed, and ADR-0006
  and ADR-0010 (and ADR-0003 with the last WhoIs site) are marked
  superseded by this record.

Related: [ADR-0002](0002-generic-backup-jobs.md) (backup jobs),
[ADR-0005](0005-proxy-auth-only-from-caddy.md) (a socket only Caddy
mounts), [ADR-0014](0014-containers-run-unprivileged.md) (unprivileged
services).
