# ADR-0006: Forgejo and Grafana sign in through tsidp, the tailnet's OIDC provider

Status: Accepted

Amended by [ADR-0010](0010-tsidp-clients-declared-in-nix.md): clients a
host declares in `homelab.tsidp.clients` are no longer registered by hand
in the admin UI; tsidp writes their id and secret files before it starts.

## Context

[ADR-0003](0003-tailscale-identity-for-sign-in.md) signs tailnet users in
with their Tailscale identity, looked up by Caddy through WhoIs and passed
on as `Remote-User`. [ADR-0005](0005-proxy-auth-only-from-caddy.md) has Forgejo and
Grafana trust that header from Caddy only (`proxyAuth`, `grafanaProxyAuth`).
That works only for requests that pass through Caddy, and it gives the
services no session of their own: every request is signed in again from the
header, and Forgejo had to move its HTTP to a socket that only Caddy mounts,
since it trusts the header from anyone.

Forgejo and Grafana both speak OpenID Connect. tsidp
(github.com/tailscale/tsidp) is Tailscale's OIDC provider: it joins the
tailnet as a node of its own and signs in whoever connects to it, by WhoIs,
so its users are the tailnet's users and there is still no second account.
The owner chose to keep WhoIs for podium, cue, fyr and the cameras, which do
not speak OIDC, and to add tsidp for Forgejo and Grafana (question
01a1d585-fe3d, 2026-11-13), and approved this plan (2026-11-14).

nixpkgs has tsidp 0.0.12 as a package and a NixOS module, `services.tsidp`,
at our pin. Its developers publish a container image as well.

## Decision

- Services that speak OIDC sign in through tsidp: Forgejo with
  `homelab.forgejo.oidc` and Grafana with `homelab.observability.grafanaOidc`.
  Services that do not keep ADR-0003's WhoIs. `proxyAuth` and
  `grafanaProxyAuth` stay available; a service uses one or the other, never
  both, and an assertion refuses both on.
- One tsidp per site, on the server host, as `modules/tsidp.nix`
  (`homelab.tsidp`), which sets nixpkgs' `services.tsidp`. A NixOS service
  rather than a container: the module and package come from nixpkgs and move
  with `flake.lock`, with no image to pin, and nixpkgs runs it under a
  DynamicUser with its own sandboxing. tsidp joins the tailnet through tsnet
  as `homelab.tsidp.hostName` (`idp`) and serves on port 443 of that node,
  with the node's ts.net certificate; the issuer is
  `https://<hostName>.<tailnet>.ts.net`. It does not use the host's
  tailscaled, where it would need 443 on the host's tailnet address, which
  Caddy holds. Funnel and token exchange (STS) stay off.
- Its secret is the Tailscale auth key, in an environment file under
  `/var/lib/secrets/` (`/var/lib/secrets/tsidp.env`, `TS_AUTHKEY=...`),
  never in the store. A one-off key with a tag, so the node key does not
  expire. tsidp reads it only until it has node state.
- Its state, under nixpkgs' StateDirectory `/var/lib/private/tsidp`, holds
  the node key, the signing keys and the registered clients. It must
  persist. `homelab.tsidp.stateDir` names it, and a host backs it up with a
  `homelab.backups.jobs` entry, as ADR-0002 has hosts do for every service.
- Clients are registered once by hand in tsidp's admin UI, reached at the
  issuer URL by a user the tailnet policy grants the
  `tailscale.com/cap/tsidp` capability with `allow_admin_ui`. tsidp makes
  the client id and secret; the owner puts them in files under
  `/var/lib/secrets` (`forgejo-oidc-client-id`, `forgejo-oidc-client-secret`,
  `grafana-oidc-client-id`, `grafana-oidc-client-secret`), each owned by root
  and mode 0400 (Grafana's by grafana, which reads them in its container).
  The options take their paths, never their contents.
- Forgejo: a oneshot unit, `forgejo-oidc`, adds tsidp as the sign in source
  `tailscale` with `forgejo admin auth add-oauth`, or updates it when the
  issuer, id or secret changed, and gets the id and secret to the container
  on stdin. Forgejo sets up sign in sources only at start, fetching the
  discovery document then, so the unit restarts Forgejo after a change and
  whenever the start of a sign in does not redirect to tsidp. Users are
  created on first sign in, named after the local part of the login; an
  existing account with that name or email is linked only with its
  password (`ACCOUNT_LINKING=login`), since users can add email addresses
  to their own accounts.
- Grafana: `auth.generic_oauth` against tsidp's endpoints, with the client
  id and secret read from files (`__FILE`). tsidp passes the tailnet login
  as the email claim, with its own host name appended to GitHub and passkey
  logins. Grafana's users are that email; the logins in
  `grafanaOidc.admins`, in either form, get the Admin role on every sign in
  and everyone else is refused (`role_attribute_strict`), as with
  `grafanaProxyAuth`. Anonymous access, the login form and basic auth are
  off.

## Consequences

- Forgejo and Grafana have sessions of their own and work for clients that
  do not pass through Caddy. With `oidc`, Forgejo serves HTTP on
  `forgejo:3000` again and the git site needs no snippet; the status site
  needs none either.
- Sign in rests on the same thing as ADR-0003's: the tailnet account and the
  device. tsidp only answers on the tailnet, and anyone who can reach its
  node can sign in to it. Forgejo creates an account for every tailnet user
  who signs in, so the tailnet policy decides who reaches the idp node;
  users shared in from other tailnets reach it only if the node is shared.
  Grafana admits only its listed admins.
- Consumers provision new files: the auth key and each client's id and
  secret. A missing client file fails the `forgejo-oidc` unit, and Grafana
  runs but cannot sign anyone in; tsidp does not start without its auth key
  file.
- The containers reach tsidp over the host's tailnet, so the host must
  resolve ts.net names (MagicDNS). If tsidp is down, new sign ins fail;
  existing sessions keep working until they expire.
- Matching GitHub and passkey logins follows tsidp's `realishEmail` (0.0.12);
  a tsidp that changes its email claim needs the module changed. tsidp is
  pre-1.0 and its grant schema may change.
- Turning `oidc` off leaves the source in Forgejo, and accounts it created
  stay, until the admin deletes them. Losing tsidp's state means registering
  the clients again and new secret files.
- The `forgejo-oidc` check runs the unit's script against a stubbed podman
  and systemctl. Sign in against a real tsidp is tested by hand.
- `examples/server.nix` uses tsidp; `examples/server-proxy-auth.nix` switches
  it back to proxy authentication, so the checks evaluate both and the
  identity snippets keep their test.

Related: [ADR-0003](0003-tailscale-identity-for-sign-in.md) (WhoIs through
Caddy), [ADR-0005](0005-proxy-auth-only-from-caddy.md) (proxy
authentication only from Caddy), [ADR-0002](0002-generic-backup-jobs.md)
(backup jobs).
