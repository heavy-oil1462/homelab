# ADR-0019: Forgejo and Grafana choose their OIDC provider, and keep existing users on a switch

Status: Accepted

## Context

[ADR-0018](0018-pocket-id-is-the-oidc-provider.md) makes Pocket ID the
site's OIDC provider and moves Forgejo and Grafana to it after tsidp
([ADR-0006](0006-tsidp-for-oidc-sign-in.md)). The owner wants everything
set up without removing the Tailscale sign-in yet (board 01a1f2b9-eab7,
2026-11-19), so each service needs both providers until homelab-config
switches.

Each provider gives its users its own `sub`: tsidp a tailnet node's user,
Pocket ID a UUID. Neither service can match an existing user by it after
a switch. What each does instead, read in their sources at the pinned
images:

- Forgejo 17.0.2 (`routers/web/auth/oauth.go`) looks a user up by `sub`
  and the sign in source's id, as the user's own login or as a link in
  `external_login_user`. With no match and auto registration on, it
  creates a user named by `[oauth2_client] USERNAME`. If that name or the
  email is taken, `ACCOUNT_LINKING` decides: `login` shows the link page,
  where the user signs in to the existing account with its password (and
  second factor) once; `auto` links to the account with that name, or
  failing that that email, with no password.
- Grafana 13.3.1 (`pkg/services/authn/authnimpl/sync/user_sync.go`) looks
  a generic OAuth user up by `sub` in `user_auth`, then by email only with
  `oauth_allow_insecure_email_lookup`; it never looks up by login. With no
  match it creates a user, and fails if the login or email is taken.
- Pocket ID 2.7.0 keeps usernames (case-insensitive) and emails unique,
  makes users only through its admin (sign ups are off by default), and
  by default lets each user change their own username and email
  (`allowOwnAccountEdit`, `PUT /api/users/me`). A username may contain
  `@`. Its application settings live in the database and are edited in
  the admin UI; with `UI_CONFIG_DISABLED` they come from the environment
  instead (`ALLOW_OWN_ACCOUNT_EDIT` and so on, defaults for the rest), and
  the UI shows them read-only. The admin still edits every user, its own
  account included, through `PUT /api/users/<id>`.

A user who edits their own account cannot take an email another account
holds, but can take one no account holds: an admin's old address, or one
listed by mistake. Wherever an app matches accounts or roles by email,
that is a way in.

## Decision

- `homelab.forgejo.oidc.provider` and
  `homelab.observability.grafanaOidc.provider` choose `tsidp`, the
  default, or `pocket-id`. With `pocket-id` the issuer defaults to
  `homelab.pocketId.url`, and assertions require Pocket ID on the host and
  the service's client in `homelab.pocketId.clients` with the service's
  files and its unit (`forgejo-oidc.service`, `podman-grafana.service`)
  among the client's units. With `tsidp` everything stays as it was. The
  host declares the client, as ADR-0010 and ADR-0018 have it; the example
  declares it from the options.
- **Forgejo** keeps one sign in source. Its name follows the provider,
  `tailscale` or `pocket-id`, and is in the callback URL. `forgejo-oidc`
  finds the source by its name or another provider's and updates and
  renames it in place, so the source keeps its id. With Pocket ID new
  users are named after `preferred_username`, the Pocket ID username.
  `ACCOUNT_LINKING` stays `login` on both providers: `auto` would link an
  account by a name or email that Pocket ID users can set themselves, so
  any of them could take over an account, the admin's included, whose
  name or email no Pocket ID user holds. Every existing user links once
  with their password after a switch; `docs/pocket-id.md` gives the
  owner's steps, and how the admin sets a password for an account that
  has none.
- **Pocket ID's users do not edit their own accounts.** The pocket-id
  module sets `UI_CONFIG_DISABLED` and `ALLOW_OWN_ACCOUNT_EDIT=false`, so
  only the admin changes a username or email.
  `homelab.pocketId.allowOwnAccountEdit` turns editing back on. Pocket ID's
  other application settings keep their defaults, sign ups disabled
  among them, unless the host sets them in `services.pocket-id.settings`.
- **Grafana** looks existing users up by email with Pocket ID
  (`oauth_allow_insecure_email_lookup`), so the owner's user, with its
  preferences, is kept when its email is their Pocket ID email. Users stay
  keyed by the email claim, and the admins are listed by their Pocket ID
  emails, matched as they are; everyone else is still refused
  (`role_attribute_strict`). Both rest on users not editing their own
  email, so a host with Grafana on Pocket ID does not build while Pocket
  ID's settings allow it. The endpoints are Pocket ID's (`/authorize`,
  `/api/oidc/token`, `/api/oidc/userinfo`).

## Consequences

- Without a change to the options nothing changes for a site. On a
  switch, `forgejo-oidc` renames the source and restarts Forgejo, and
  `pocket-id-clients` writes the new id and secret and restarts the
  units that read them.
- The owner's first Pocket ID sign in to Forgejo ends on Forgejo's link
  page, once. An account without a password needs one set by the admin
  first.
- With own-account editing off, an email reaches Grafana only as the
  admin set it, so the email lookup and the admin list are as safe as the
  admin's own care: list only emails that Pocket ID accounts hold.
- Users change their own name, username and email through the admin.
  Settings changed in Pocket ID's admin UI before this are replaced by
  the environment's, Pocket ID's defaults unless the host sets them in
  `services.pocket-id.settings`. Passkeys stay the users' own.
- Sign ups (`ALLOW_USER_SIGNUPS`) let a new user choose their email once,
  at sign up. They stay disabled unless the host turns them on; with a
  token, the admin chooses who signs up.
- Grafana's dashboards, folders, alert rules and data sources belong to
  the organisation, not a user, so a user made anew loses only its own
  preferences and stars.
- Switching back to tsidp works the same way, and finds the links made
  with tsidp again.
- The `oidc-providers` check evaluates both providers on both services
  and the assertions, own-account editing among them; the
  `pocket-id-module` check holds Pocket ID's settings; the `forgejo-oidc` check runs the switch against
  its stub. Sign in against a real Pocket ID is tested by hand.

Related: [ADR-0006](0006-tsidp-for-oidc-sign-in.md),
[ADR-0010](0010-tsidp-clients-declared-in-nix.md),
[ADR-0018](0018-pocket-id-is-the-oidc-provider.md).
