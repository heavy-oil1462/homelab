# ADR-0015: Forgejo's SSH server trusts the deploy CA

Status: Accepted

## Context

`modules/deploy-ca.nix` has every host trust the CA keys in
`homelab.deployCaKeys` for root logins over SSH. No ADR introduced it; the
module's header says why: a fleet update signs one short-lived certificate,
with one touch and PIN of the hardware key that holds the CA, and reuses it
for every host. homelab-config's `scripts/update-fleet.py` does that, with a
throwaway key and a certificate valid for an hour.

The run also fetches the config repository and updates the `homelab` flake
input, both over `ssh://git@<forge>:2222/...`, Forgejo's built in SSH
server. Forgejo takes only the owner's own security key there, which is
verify-required, so each costs another PIN and touch, sometimes more than
one. The owner asked for one touch and PIN for the whole run (board,
2026-11-17).

Forgejo's built in server, not only OpenSSH with Forgejo's
AuthorizedPrincipalsCommand, accepts user certificates. Read at v17.0.1,
the version of the pinned image (`modules/ssh/ssh.go`, `publicKeyHandler`):

- The SSH user must be `BUILTIN_SSH_SERVER_USER` (`git`); any other is
  refused before keys are looked at.
- A certificate is refused unless `[server] SSH_TRUSTED_USER_CA_KEYS` is
  set, and unless it is a user certificate.
- For each of the certificate's principals in turn, Forgejo looks up a key
  of type principal whose content is exactly that principal
  (`SearchPublicKeyByContentExact`). A principal no account lists is
  skipped. For the first one found, the certificate must be signed by one of
  the trusted CA keys and valid for that principal now (`CertChecker`); the
  connection then acts as that principal key's owner.

A principal key is added only by the user, for their own account, in the
web settings (`routers/web/user/setting/keys.go`); the API and the admin
cannot add one. `CheckPrincipalKeyString` allows content by
`SSH_AUTHORIZED_PRINCIPALS_ALLOW`: `username` lets a user add only their
own user name, `email` their activated addresses, `anything` anything. With
CA keys set and the setting empty, Forgejo defaults to `username,email`.
The setting and the CA keys are documented in Forgejo's
`custom/conf/app.example.ini`; `SSH_TRUSTED_USER_CA_KEYS_FILENAME` only
names a file Forgejo writes for OpenSSH, and the built in server does not
write it (`modules/ssh/init.go`).

## Decision

The owner agreed, question 01a1eb30-01d0, 2026-11-17 (DIRECTION.md, Ask
the owner first: SSH access).

- `homelab.forgejo.trustDeployCa`, off by default, sets
  `SSH_TRUSTED_USER_CA_KEYS` to `homelab.deployCaKeys`, joined with commas,
  and `SSH_AUTHORIZED_PRINCIPALS_ALLOW` to `username`. Off, they are set to
  empty and `off`, since the image keeps a setting in app.ini after its
  variable goes away. An assertion refuses the option without CA keys, and
  a CA key with a comma in its comment.
- It is off by default, not on whenever `deployCaKeys` is set: it widens
  SSH access to Forgejo, which DIRECTION.md asks the owner about, and a
  host that trusts the CA for root has not by that chosen to give it
  Forgejo too.
- A certificate's principal maps to the Forgejo user of the same name, and
  only once that user has added it under Settings, SSH / GPG keys, Manage
  SSH principals. `email` is left out, so that a principal is always a
  user name: an address would be one more name per user for the
  certificate to carry, and users can add addresses to their own accounts.
- A fleet run's certificate carries two principals: `root`, for the hosts,
  and the owner's Forgejo user name. git and nix connect as `git@` with
  it.
- Not taken: an OpenSSH ControlMaster connection to Forgejo, opened once at
  the start of the run and shared by the git and nix fetches. It still
  costs a second touch and PIN, for Forgejo, and the script has to manage
  the connection's lifetime.

## Consequences

- One touch and PIN for the whole run, once homelab-config's script puts
  the Forgejo user name in the certificate and uses it for git and nix.
- The reach does not grow. The certificate is already root on every host,
  Forgejo's own included, which can read and change Forgejo's data
  directly. It is valid for an hour and its key is thrown away after the
  run. What is new is that it reaches Forgejo through Forgejo's own
  permission checks, as the owner.
- The deploy CA becomes a key to the owner's Forgejo account over SSH: who
  holds it, or can make it sign, can push as the owner. That was true of
  Forgejo's host already.
- `root` maps to nothing as long as no Forgejo user is named `root`; it is
  not a reserved name. Registration is closed, but OIDC sign in creates a
  user named after the tailnet login's local part, so a login `root@...`
  would make one. Such a user would still have to add `root` as their
  principal for a host certificate to sign in as them. The assumption is
  documented in the README; it is not checked, since Forgejo's users are
  not in the config.
- `git` is the SSH user, not a principal: it names no Forgejo account, and
  a certificate is mapped by its principals alone. A Forgejo user named
  `git` could add `git` as their principal, which a fleet certificate does
  not carry.
- A principal stays with the account when the user is renamed, and
  another user cannot add the same principal while it exists.
- Turning the option off leaves the principal keys in Forgejo's database,
  unused while no CA is trusted.
- Owner steps: set `homelab.forgejo.trustDeployCa = true` on the Forgejo
  host, deploy, and add their user name as an SSH principal in Forgejo's
  settings once.
- The `forgejo-deploy-ca` check evaluates the example server with the
  option on and off and compares Forgejo's environment. A sign in with a
  real certificate needs the image running and is tested by hand.

Related: `modules/deploy-ca.nix` (the hosts' trust of the CA),
[ADR-0006](0006-tsidp-for-oidc-sign-in.md) (accounts created on OIDC sign
in), [ADR-0014](0014-containers-run-unprivileged.md) (Forgejo runs
unprivileged).
