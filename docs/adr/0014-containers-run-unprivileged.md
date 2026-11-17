# ADR-0014: Library containers run unprivileged, with dropped capabilities

Status: Accepted

## Context

Every container in `containers/` runs under rootful podman, as
`virtualisation.oci-containers` sets it up. Root inside such a container is
root on the host, held back only by the capabilities podman leaves it and by
its namespaces. A break out of Caddy, which every request from the tailnet
reaches, or of any other service, would land as root on the server.

Some containers already ran as a dedicated host user, `user = "<uid>:<gid>"`
with a static id: Forgejo, the registry, Vaultwarden and UniFi's MongoDB.
Others did not:

- Caddy and homepage ran as root.
- Prometheus, Loki and Grafana had a host user each, but no static uid, so
  the option read `":"` at evaluation. podman takes an empty user as uid 0,
  and they ran as root too.
- Home Assistant, Frigate, the Nextcloud AIO mastercontainer and the UniFi
  controller run as root by their images' design.

No container had `no-new-privileges`, and all had podman's default
capabilities (CHOWN, DAC_OVERRIDE, FOWNER, FSETID, KILL, NET_BIND_SERVICE,
SETFCAP, SETGID, SETPCAP, SETUID, SYS_CHROOT), Home Assistant NET_RAW too.

Two ways were open (question 01a1ea3d-c147, 2026-11-17):

1. Close the gaps in today's rootful setup: every container that can runs as
   a host user, all of them with `no-new-privileges` and only the
   capabilities they need, held by a check.
2. Move the servers to rootless podman, so that even root in a container is
   an unprivileged user on the host. Its costs: every container moves to
   systemd user units of a lingering user, with its storage, images and
   volumes migrated; container uids map through subordinate id ranges, so
   files on the host belong to shifted ids that backups, restores and the
   secret files under `/var/lib/secrets/` have to follow; rootless
   networking (pasta) shows connections to a published port as coming from
   the host, which takes away the client address that Caddy's WhoIs lookup
   (ADR-0003) and Grafana's trust in Caddy's fixed address (ADR-0005) rest
   on; binding 443 needs a sysctl; and host networking and device access
   for Home Assistant, Frigate's GPU and UniFi get harder or do not work.

The owner chose option 1: "Close the gaps in today's setup".

## Decision

- Every library container runs as a dedicated host user, set as
  `user = "<uid>:<gid>"` with numbers. The user gets a static uid and gid
  from the block 600 to 699 (README, "Static user ids"), with
  `lib.mkDefault` so a host that already has the user keeps its ids. New
  here: prometheus 603, loki 604, grafana 605, caddy 606, homepage 607.
- Data a container writes is that user's. Named volumes carry `:U`, so podman
  hands them to the container's user on every start; bind-mounted
  directories get a tmpfiles rule with the owner, as before. This re-owns
  data written while a container ran as root, so a deploy needs no step for
  it.
- Where a container shares files with the host by the user's name (secret
  files from tmpfiles or tsidp, the acme certificate's group, the WhoIs
  socket's group), its unit runs `host-user-check` first, which refuses to
  start it when the host's user has other ids than the container's numbers
  and names the setting to add.
- Explicit uids rather than `--userns=auto`. With it podman maps each
  container to a range of its own, so files on the host belong to ids no
  host user has, which change when a container is created again unless the
  range is pinned; backups, restores, the secret files and the sockets
  shared with the host would all have to follow them. A named host user
  keeps file ownership predictable and readable in `ls`.
- Every container gets `--security-opt=no-new-privileges` and
  `--cap-drop=ALL`, then `--cap-add` for each capability it needs, each with
  a comment saying why. Containers that run as a user need none, except
  Caddy: NET_BIND_SERVICE, to listen on 443 in its network namespace.
  podman gives a non-root user the capabilities it adds as ambient ones.
- Caddy reads the certificate through the acme cert's group, `caddy`, and
  the WhoIs socket through its group, now `caddy` instead of nginx-auth's
  own; the socket stays mode 0660. With Forgejo's proxy authentication on,
  Caddy gets Forgejo's group to reach its socket directory (ADR-0005).
- Root stays only where the image supports nothing else, on an allowlist in
  `tests/container-hardening.nix`, each entry with its reason there and in
  its module. Today: Home Assistant, Frigate, the Nextcloud AIO
  mastercontainer and the UniFi controller (which drops to the unifi user
  itself). Their capabilities are cut to those podman's defaults that they
  use. A container joins the list only when its image cannot run as a user,
  with the reason in the module, and leaves it when it can.
- The `container-hardening` check evaluates the example servers, which
  enable every container module, and fails on any container that runs as
  root or as no declared user without being on the allowlist, lacks
  `no-new-privileges` or `--cap-drop=ALL`, is privileged, or adds every
  capability back.

Rootless podman is not pursued for the library's services for now. The
exceptions stay as they are: podium's rootless podman setup in
homelab-config, and this library's `agent-sandbox`, which starts its
sandboxes with the workstation user's rootless podman and is not an
`oci-containers` service. homelab-config's own containers (cue, fyr, vaka,
vaka-detect, podium) get the same treatment as the library's in a later
change.

## Consequences

- A break out of Caddy, homepage, the observability stack, Forgejo, the
  registry, Vaultwarden or MongoDB lands as an unprivileged user with no
  capabilities. A break out of the allowlisted four still lands as root,
  with fewer capabilities than before.
- On the first start after the deploy, `:U` re-owns the volumes of Caddy,
  Prometheus, Loki and Grafana, and on every start after that; a large
  Prometheus volume takes a moment longer to start. homepage gets two new
  volumes, of files it writes itself, which need no backup.
- A host that already had the prometheus, loki, grafana or caddy user keeps
  its ids, and that container does not start until the host's config sets
  them (`users.users.<name>.uid` and `users.groups.<name>.gid`, which the
  check's message gives). homepage shares no files with the host, so a host
  with an older homepage user only sees NixOS's warning that it keeps its
  uid.
- The certificate files become the caddy group's. Another service on the
  host that read them through the acme group needs the cert's group set
  for it, or the caddy group.
- The capabilities of the root containers come from reading their images'
  start scripts, not from a test on a host; a start that fails for one is
  fixed by adding the capability it names, with its reason.
- The containers the Nextcloud AIO mastercontainer starts through podman's
  socket are not `oci-containers`, so neither this record nor the check
  covers them.
- A new container module must pass the check in the example server: as a
  user, or on the allowlist with its reason.

Related: [ADR-0003](0003-tailscale-identity-for-sign-in.md) (the WhoIs
socket), [ADR-0005](0005-proxy-auth-only-from-caddy.md) (Forgejo's socket).
