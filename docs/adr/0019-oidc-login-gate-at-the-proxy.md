# ADR-0019: Sites that can't sign in themselves get an OIDC login gate at the proxy

Status: Accepted

## Context

Some sites have no sign-in worth the name: the cameras' own admin pages,
and other pages only the owner should open. Today Caddy guards them with
Tailscale's identity, looked up through WhoIs
([ADR-0003](0003-tailscale-identity-for-sign-in.md)), through snippets
the site configuration builds on `tailnet_identity`, such as
`owner_only`. The owner wants sign-in that does not depend on Tailscale:
"for the cam- things. I am thinking to make a generic login page through
the proxy before it allows the connection" (board, 2026-11-18). Pocket ID
is the site's OIDC provider ([ADR-0018](0018-pocket-id-is-the-oidc-provider.md)),
and every WhoIs site is to move to the gate (question 01a1f005-df03).

The supervisor settled the shape (issue 01a1f008-7816): Caddy asks an
OIDC-aware auth service before it proxies, with `forward_auth`, and sends
a browser without a session to sign in; the provider is a setting;
the gate restricts by user; sites import a snippet.

Two auth services were weighed:

1. oauth2-proxy, in nixpkgs as a package and a NixOS module
   (`services.oauth2-proxy`, 7.15.2 at our pin). It answers
   `/oauth2/auth` for forward-auth, runs the sign-in under `/oauth2/`,
   keeps the session in an encrypted cookie, and serves on a unix socket.
2. caddy-security, a Caddy plugin. It needs a Caddy image built with
   xcaddy and pinned in our registry, which ADR-0003 already refused for
   caddy-tailscale.

What oauth2-proxy 7.15.2 and Pocket ID 2.7.0 do, read in their source:

- `/oauth2/auth` answers 202 for a session, 401 for none and 403 for a
  session that fails the request's own constraints, the query parameters
  `allowed_emails`, `allowed_groups` and `allowed_email_domains`. Each
  must hold; they are ANDed.
- With `--set-xauthrequest` the 202 carries `X-Auth-Request-Email`,
  `-User`, `-Preferred-Username` and `-Groups`.
- oauth2-proxy needs the claim it takes as the email, and refuses an
  `email` claim whose `email_verified` is false. Pocket ID makes email
  optional and marks emails unverified unless its admin says otherwise.
  It always sends `preferred_username`, the user's unique name.
- Pocket ID issues a refresh token with every code, good for 30 days,
  and refuses it once the user is disabled or deleted. Its redirect URIs
  take `*` within a host name.

## Decision

- **oauth2-proxy behind Caddy's `forward_auth`** (option 1).
  caddy-security is rejected for its custom image. Running oauth2-proxy
  as the reverse proxy in front of each site is rejected too: Caddy stays
  the one place that routes and terminates TLS, each site keeps its own
  `reverse_proxy`, and one oauth2-proxy serves every gated site.
- **On the reverse-proxy host, as a NixOS service.**
  `homelab.reverseProxy.oidcGate.enable` turns it on in
  `containers/reverse-proxy.nix`, as `tailscaleIdentity` does for
  nginx-auth. nixpkgs' module and package move with `flake.lock`, with no
  image to pin. It runs as nixpkgs' `oauth2-proxy` system user, with no
  capabilities, `NoNewPrivileges` and a read-only system, which holds to
  [ADR-0014](0014-containers-run-unprivileged.md)'s aim without a
  container.
- **Only Caddy reaches it.** It serves HTTP only on
  `/run/oidc-gate/oauth2-proxy.sock`, in a directory of mode 0750 owned by
  `oauth2-proxy` with the group `caddy`, made by tmpfiles and mounted
  into the caddy container only, as Pocket ID's is. Nothing listens on a
  port.
- **The provider is a setting.** `issuer` defaults to
  `homelab.pocketId.url`. The client, `clientId` (`oidc-gate`), is
  declared by the host in `homelab.pocketId.clients`, with PKCE, the
  redirect URI `https://*.<domain>/oauth2/callback` and
  `oauth2-proxy.service` among its units, so `pocket-id-clients` writes
  its secret before oauth2-proxy starts and restarts it with a new one.
  With Pocket ID on the same host and as the issuer, the host does not
  build without that client. Another provider needs its client
  registered there and the secret in `clientSecretFile`.
- **Users are told apart by name.** oauth2-proxy takes
  `preferred_username` as the email (`--oidc-email-claim`), asks only for
  `openid profile`, and gives any user of the provider a session. Who
  passes is up to the snippet.
- **Two snippets, generated** from the options and put ahead of the
  Caddyfile like the identity snippets (ADR-0005): `oidc_owner_only`
  lets through `owners`; `oidc_gate` lets through `owners` and `users`.
  The names go in `allowed_emails` of the `/oauth2/auth` call, so
  oauth2-proxy compares them exactly; forward_auth's `uri` replaces the
  client's query, so a client cannot add a name. A site switches from
  `owner_only` to `oidc_owner_only` in one line. Each snippet:
  - sends `/oauth2/*` to oauth2-proxy: the sign-in, its callback and
    `/oauth2/sign_out`;
  - asks `/oauth2/auth` for everything else. On 202 it passes the user's
    name upstream as `Remote-User`; forward_auth's `copy_headers` deletes
    the client's `Remote-User` before it sets it. On 401 it hands the
    request to oauth2-proxy's `/oauth2/start` with the page asked for in
    `X-Auth-Request-Redirect`, so the browser goes to the provider and
    comes back to that page, query included. On 403 it answers 403 and
    names the sign-out.
  - uses only `handle` and `forward_auth`, which Caddy orders before a
    site's own `handle` blocks, so they cannot skip the gate.
  Groups are not offered: oauth2-proxy ANDs `allowed_groups` with
  `allowed_emails`, and a group-only snippet waits for a site that needs
  it. A Caddyfile that imports either snippet with the gate off does not
  build.
- **The cookie scope.** The session cookie is set on `cookieDomain`,
  `.<domain>` by default, Secure and HttpOnly, so one sign-in covers every
  gated site and the callback can be on whichever site the sign-in
  started from. It is encrypted with a key in `cookieSecretFile`
  (`/var/lib/secrets/oidc-gate-cookie-secret`, root, 0400), which the
  oneshot `oidc-gate-cookie-secret` makes before oauth2-proxy when it is
  missing. systemd hands both secrets to oauth2-proxy as credentials.
- **Session lifetime and sign-out.** A sign-in lasts `sessionLifetime`,
  24 hours by default. After 30 minutes the next request renews it with
  the refresh token, so a user disabled or deleted in Pocket ID is out
  within half an hour of their last renewal. `/oauth2/sign_out` on any
  gated site clears the cookie, which signs out of every gated site; it
  does not end the Pocket ID session, so the next visit signs in again
  through Pocket ID, without a passkey while that session lasts.
- **Relation to the other sign-in records.** WhoIs stays available:
  `tailnet_identity` and `homelab.reverseProxy.tailscaleIdentity` are
  unchanged (ADR-0003), and Pocket ID's setup guard still rests on them
  (ADR-0018). A site uses one or the other, not both. ADR-0006 and
  ADR-0010 do not apply to the gate: it signs in through Pocket ID, as
  ADR-0018 has new work do, and declares its client in
  `homelab.pocketId.clients` rather than `homelab.tsidp.clients`.

## Consequences

- The camera pages and the other WhoIs sites can sign in through
  Pocket ID with the owner's passkey, independent of Tailscale; moving
  them is a one-line change in the site configuration each.
- Requests with an `Authorization` header are not let through, unlike
  with `tailnet_identity`: a gated site is for browsers. Agents and
  scripts that call one need another way in.
- The wildcard redirect URI lets Pocket ID send a code to
  `/oauth2/callback` on any name under the domain. All are Caddy's sites,
  and a code is worthless without the client secret and the PKCE
  verifier.
- Every site under the cookie domain gets the cookie, gated or not, and
  so does each gated site's upstream. It is encrypted, but a compromised
  upstream could replay it to the gated sites while it lasts. A host can
  narrow `cookieDomain`, at the price of a sign-in per site.
- The names in `owners` and `users` must stay Pocket ID usernames in use.
  Pocket ID keeps usernames unique, but lets users change their own
  unless its admin turns that off; a listed name nobody holds could be
  taken.
- oauth2-proxy reads Pocket ID's discovery document at start, through
  this host's own Caddy, so the host must resolve `id.<domain>` to it.
  Until Pocket ID answers it exits and is restarted every 5 seconds;
  while it is down, gated sites answer 502.
- Replacing the cookie secret signs everyone out. Nothing else is state:
  oauth2-proxy keeps no files and needs no backup.
- No new secret the owner provisions: the client secret comes from
  `pocket-id-clients`, the cookie secret is generated.
- The `oidc-gate` check runs the example server's oauth2-proxy command
  line, cookie secret generator and generated snippets in Caddy against a
  stand-in for Pocket ID: the sign-in with PKCE back to the page asked
  for, one sign-in for two sites, sign-out from both, forged headers and
  query names refused, and a user who is not an owner kept out of the
  owner-only site. The `oidc-gate-module` check holds the evaluated
  service and the configurations the host refuses. Pocket ID itself and
  the renewal after 30 minutes are tested by hand.

Related: [ADR-0003](0003-tailscale-identity-for-sign-in.md) (WhoIs through
Caddy), [ADR-0005](0005-proxy-auth-only-from-caddy.md) (Remote-User only
from Caddy), [ADR-0006](0006-tsidp-for-oidc-sign-in.md) and
[ADR-0010](0010-tsidp-clients-declared-in-nix.md) (tsidp),
[ADR-0014](0014-containers-run-unprivileged.md) (unprivileged services),
[ADR-0018](0018-pocket-id-is-the-oidc-provider.md) (Pocket ID).
