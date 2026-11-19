# ADR-0021: pocket-id-clients follows Pocket ID's secrets API and is checked against Pocket ID itself

Status: Accepted

## Context

[ADR-0018](0018-pocket-id-is-the-oidc-provider.md) declares Pocket ID's
clients through its admin API, as Pocket ID 2.7.0 had it: one secret per
client, replaced with `POST /api/oidc/clients/<id>/secret`. The
`pocket-id-clients` check ran the script against a stand-in written to
that API, and the real API was to be tested by hand.

The first deploy on nixserver1 (2026-11-19) failed: the client was
created, and making its secret answered 404. homelab-config's fleet
deploy updates every input to its newest revision, so the host ran
Pocket ID 2.19.1 from nixos-26.05, while this flake's lock still had
nixpkgs of 2026-05-23 with 2.7.0. Pocket ID's log of the run names the
request with no route.

What Pocket ID does, read in its source and run:

- Every version since 1.8 keeps the id a client is created with
  (`OidcClientCreateDto.ID`), 2.19 included. The id was never the
  problem; the leftover client from the failed run is `forgejo`.
- Since 2.14 a client holds up to 20 secrets. They are made with
  `POST /api/oidc/clients/<id>/secrets` (201, the value shown once, or
  one the caller supplies), listed with `GET` on the same path and
  deleted one by one. `POST .../secret` is gone.
- Since 2.17 a new confidential client comes with a secret, shown once
  as `createdSecret` in the create's answer, unless
  `AUTO_CREATE_OIDC_CLIENT_SECRET` is off.
- An update replaces every field it takes, and 2.19 takes more of them
  (token lifetimes, description, skip consent, back-channel logout).
- Introspection still answers 401 for a secret the client does not hold.
- 2.19 runs an actor runtime whose peers connect over
  `ACTORS_HOST:ACTORS_PORT`, `0.0.0.0:1414` by default, with mTLS keyed
  from the encryption key. Without HA it allows one host, which has no
  peers.
- The nixpkgs pocket-id binary runs in the build sandbox, on SQLite and a
  unix socket, with nothing from the network.

## Decision

- **Secrets through `/secrets`.** For a new client the script takes the
  secret Pocket ID made with it, or asks `/secrets` for one. When it
  writes a new secret to the file, it deletes the client's other
  secrets, so only the file's works, as with 2.7's single secret. A
  secret the file holds and Pocket ID accepts is left as it is, and so
  are secrets added beside it in the admin UI.
- **A client with a declared id is taken over.** It is updated to the
  config, its id is written to the id file, and, with no usable secret in
  the file, it gets a new one and loses the others. That is how the
  client of the failed run is adopted. Clients keep being keyed by their
  declared id; the state file keeps the declared ids, as before.
- **An update sends back the whole client** with the config's fields over
  it, so settings Pocket ID adds keep their values.
- **Pocket ID 2.14 or later.** The module refuses an older package, and
  the script fails with the status it got if a later Pocket ID moves the
  API again.
- **The check runs the real Pocket ID.** `pocket-id-clients` starts
  nixpkgs' `pocket-id` with the example host's settings, on a temporary
  state directory, a unix socket, the static API key and an encryption
  key, and runs the script: first run with a leftover client, nothing to
  do, a changed redirect URI, an emptied and a refused secret, a removed
  client, a wrong key and no answer. Pocket ID's request log shows what
  each run wrote. `tests/fake-pocket-id.py` is gone. The `oidc-gate`
  check keeps its stand-in provider: it signs a user in, which the real
  Pocket ID does only with a passkey.
- **nixpkgs moves with the deployed Pocket ID.** The lock follows
  nixos-unstable to a revision whose Pocket ID has the API the fleet
  deploys (2.19.2 today, against nixos-26.05's 2.19.1).
- **The actor runtime stays on loopback** (`ACTORS_HOST=127.0.0.1`), as
  nothing new may listen on LAN interfaces.

## Consequences

- The check fails when nixpkgs brings a Pocket ID whose admin API differs
  from what the script calls, as long as the lock is updated. A lock that
  stays behind the consumers' channel again hides such a change until a
  deploy; homelab-config's fleet deploy and this lock are not tied.
- A secret made again in the admin UI no longer replaces the file's: the
  two work side by side until the file's is refused or emptied. Deleting
  the file's secret in the admin UI gets a new one on the next run, and
  its units restarted.
- A client made by hand in the admin UI with an id the config later
  declares is taken over, and its secrets replaced.
- Port 1414 is taken on the host's loopback. Another service on it keeps
  Pocket ID from starting.
- ADR-0018's statements on 2.7.0's API, its "no call sets" a secret and
  its stand-in check are superseded by this record.

Related: [ADR-0018](0018-pocket-id-is-the-oidc-provider.md),
[ADR-0020](0020-oidc-login-gate-at-the-proxy.md).
