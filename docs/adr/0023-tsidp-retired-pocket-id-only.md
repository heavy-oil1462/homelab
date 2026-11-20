# ADR-0023: tsidp is retired; Pocket ID is the only OIDC provider

Status: Accepted

## Context

[ADR-0006](0006-tsidp-for-oidc-sign-in.md) signed Forgejo and Grafana in
through tsidp, Tailscale's OIDC provider, and
[ADR-0010](0010-tsidp-clients-declared-in-nix.md) declared its clients in
Nix. [ADR-0018](0018-pocket-id-is-the-oidc-provider.md) made Pocket ID the
site's OIDC provider, and
[ADR-0019](0019-forgejo-and-grafana-on-pocket-id.md) let each service
choose between the two, tsidp by default, so the site could move one
service at a time.

The site has moved. Forgejo and Grafana sign in through Pocket ID, and
cue, fyr, podium and vaka do too, through dev/oidc. The owner asked for
tsidp to go: "Cue also runing on pocket id now. Can remove tsidp" (board,
2026-11-20). Keeping it costs a module, a client script, its options, a
second code path in Forgejo's and Grafana's modules, and tests for all of
them, for a provider nothing uses.

## Decision

- The library has no tsidp. `modules/tsidp.nix`, its client script and
  its `tsidp` export from the flake are removed, and Forgejo
  (`homelab.forgejo.oidc`) and Grafana
  (`homelab.observability.grafanaOidc`) sign in through Pocket ID only.
- The removed options, `homelab.tsidp` and the services' `issuer`, are
  declared with `lib.mkRemovedOptionModule`: a host that still sets one
  fails to build with a message naming this record and the steps in
  `docs/pocket-id.md`. The issuer is always `homelab.pocketId.url`.
- `provider` stays, with `pocket-id` its only value and the default, so a
  host that switched under ADR-0019 builds unchanged. This replaces
  ADR-0019's choice of provider; the rest of ADR-0019, how existing users
  are kept on a switch and own-account editing, stands.
- Forgejo's `forgejo-oidc` still renames a sign in source named
  `tailscale`, tsidp's, to `pocket-id` in place, so a host that moves from
  tsidp straight to this version keeps its accounts' links.
- What stays: [ADR-0003](0003-tailscale-identity-for-sign-in.md)'s
  Tailscale identity through Caddy (WhoIs) is a different mechanism, not
  an OIDC provider, and is not touched here. Its sites move to
  [ADR-0020](0020-oidc-login-gate-at-the-proxy.md)'s login gate later.
  Pocket ID's first-admin setup gate (`homelab.pocketId.setupLogins`) and
  proxy authentication (ADR-0005) stay as they are.

## Consequences

- One provider and one code path: Forgejo's and Grafana's modules, their
  options and the `oidc-providers` check cover Pocket ID only. The
  `tsidp-clients` check goes with its script; the `oidc-providers` check
  also holds the removed options' errors and a host that still names the
  provider. `examples/server.nix` signs in through Pocket ID, and the
  separate Pocket ID example host goes.
- A host still on tsidp must make the provider switch in the same
  rebuild as this update (`docs/pocket-id.md`, "Moving off tsidp"). There
  is no way back to tsidp short of an older library.
- A consumer that imports `nixosModules.tsidp` fails on the missing
  attribute; it drops the import.
- tsidp's state, its auth key file, its node and the tailnet policy's
  grant are left on a site; a rebuild removes none of them, and the
  owner deletes them by hand.

Supersedes [ADR-0006](0006-tsidp-for-oidc-sign-in.md) and
[ADR-0010](0010-tsidp-clients-declared-in-nix.md). Related:
[ADR-0003](0003-tailscale-identity-for-sign-in.md),
[ADR-0018](0018-pocket-id-is-the-oidc-provider.md),
[ADR-0019](0019-forgejo-and-grafana-on-pocket-id.md),
[ADR-0020](0020-oidc-login-gate-at-the-proxy.md).
