# ADR-0010: tsidp's OIDC clients are declared in Nix and written into its clients file before it starts

Status: Superseded by ADR-0023

## Context

[ADR-0006](0006-tsidp-for-oidc-sign-in.md) signs Forgejo and Grafana in
through tsidp. Their side of OIDC is configured from Nix, but each client
is registered once by hand in tsidp's admin UI, and the owner copies the id
and secret tsidp makes into files under `/var/lib/secrets`. The owner asked
for that step to be declarative too ("can forgejo and grafana OIDC be
configured from the nix config instead of manually in the UI?", board,
2026-11-14).

tsidp 0.0.12, at our nixpkgs pin, keeps its clients in
`oidc-funnel-clients.json` in its state directory: a JSON object keyed by
client id, each with the secret, a name, the redirect URIs and a creation
time (`FunnelClient` in `server/clients.go`). It reads the file once, when
it starts (`LoadFunnelClients`), and rewrites it whole whenever a client is
added, edited or deleted. A client id is any string; the admin UI makes
random hex ones.

Two ways were considered.

1. Before tsidp starts, merge the declared clients into that file.
2. After tsidp starts, create them through its API. The admin UI's
   `/clients/new` and dynamic registration (`/register`) need a tailnet
   caller with the `tailscale.com/cap/tsidp` capability, which the host
   is not unless the tailnet policy grants it; both make the id and secret
   themselves, so the secret could not come from a file; and nothing
   updates a client's redirect URIs or secret.

## Decision

- **Merge before start** (option 1), with no change to tsidp.
  `homelab.tsidp.clients.<id>` declares a client by its id, with
  `redirectUris`, `idFile` and `secretFile`
  (`/var/lib/secrets/<id>-oidc-client-id` and `-client-secret` by default)
  and `owner` (root by default).
- The tsidp unit gets an `ExecStartPre=+` running
  `modules/tsidp-clients.sh` as root, after systemd has made the state
  directory. For each declared client it:
  - writes the id to `idFile` when the file does not hold it, and a random
    secret, 64 hex digits as tsidp makes them, to `secretFile` when that is
    missing or empty. Both are mode 0400, owned by `owner` and its group,
    and written by a rename. A secret already there is kept.
  - sets the client in tsidp's clients file to the id, the name (the id),
    the redirect URIs and the secret from `secretFile`, keeping its
    creation time and any other fields.
- Clients with other ids, registered in the admin UI, are left as they
  are. The ids declared last time are kept in `homelab-clients.json` in
  the state directory, so a client removed from the config is removed from
  tsidp; its files stay.
- The clients file is rewritten only when it changes, mode 0600 and owned
  like the state directory. A clients file that is not JSON fails the
  start and is left alone.
- tsidp restarts when the declared clients change (`restartTriggers`), as
  it reads them only at start. `forgejo-oidc` and the grafana container
  start after tsidp, so on a host running both they find the files.
- Turning on a service's OIDC does not declare its client inside the
  library: tsidp may run on another host, and modules only read options.
  The example derives the clients from `homelab.forgejo.oidc` and
  `homelab.observability.grafanaOidc`, with the redirect URIs from
  `homelab.domain`, and a host copies that.

This replaces ADR-0006's bullet on registering clients by hand in the admin
UI for the clients a host declares; the rest of ADR-0006 stands.

## Consequences

- A host with tsidp and the services on it provisions only tsidp's auth
  key. The id and secret files are made on the first start.
- The secret file is the source of truth. A secret regenerated in the admin
  UI is replaced by the file's on tsidp's next start; to rotate one, empty
  the file and restart tsidp, then the service.
- A declared client's redirect URIs and name edited in the admin UI are
  likewise reset on the next start.
- The script relies on the file name and format of tsidp 0.0.12. A tsidp
  that moves its clients elsewhere starts without them; the
  `tsidp-clients` check pins the format we write, not tsidp's reading of
  it, which is tested by hand.
- A hand-registered client whose id is the same as a declared one is taken
  over. The admin UI's ids are random hex, so this only happens on purpose.
- A host that had registered its clients by hand keeps its secret files;
  the id files are rewritten to the declared ids, and the old clients stay
  in tsidp until deleted in the admin UI. Forgejo picks up the new id
  through `forgejo-oidc`; Grafana on its next restart, signing in with the
  old client until then.
- When tsidp runs on another host than the service, that host's files are
  still copied by hand.
- The `tsidp-clients` check runs the script against a fake state
  directory: a first start, a hand-made client kept, a run with nothing to
  do, a changed redirect URI, a secret set by hand, a client no longer
  declared, and a clients file that is not JSON.

Related: [ADR-0006](0006-tsidp-for-oidc-sign-in.md) (Forgejo and Grafana
sign in through tsidp).
