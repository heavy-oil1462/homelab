# ADR-0003: Sign-in uses the Tailscale identity, looked up by Caddy through WhoIs

Status: Accepted

## Context

The owner wants to sign in to podium, cue, fyr, Forgejo and Grafana once,
with their Tailscale identity, and chose that over Authelia and a full
identity provider (question 01a1d1ae-9454, 2026-11-12). Every site is
already reachable only over the tailnet, through Caddy, so the tailnet
already knows who is on the other end of each connection. A login service
would add a second account, passwords or passkeys to manage, and one more
stateful service to back up, for no gain inside the tailnet.

podium, cue and fyr already trust a `Remote-User` header from Caddy's
address (podium ADR-013). Grafana (`auth.proxy`) and Forgejo (reverse proxy
authentication) can do the same. What was open is how Caddy learns the
tailnet user. Agents and scripts call the same services from tagged nodes
with bearer tokens, and a tagged node has no user, so that has to keep
working.

Caddy runs in a podman container with 443 published on the host's tailnet
address. The old comment in `containers/reverse-proxy.nix` said podman
source-NATs inbound connections to the bridge gateway, which would rule out
any lookup by client address. The source shows otherwise, at our nixpkgs
pin (tailscale 1.98.2, netavark from the same pin):

- netavark marks for masquerade only hairpin traffic, from the container
  subnet or 127.0.0.1, to a published port (`src/firewall/nft.rs`,
  `NETAVARK-HOSTPORT-SETMARK`). A connection from a tailnet peer is DNATed
  to the container and keeps its source.
- tailscale marks every packet forwarded in from `tailscale0` in its
  `ts-forward` chain and masquerades marked packets in `ts-postrouting`
  (`util/linuxfw/iptables_runner.go` and `nftables_runner.go`). This is its
  subnet-route SNAT, applied whenever the `NoSNAT` pref is off, which is the
  default, whether or not the node advertises routes. Traffic DNATed to a
  container is forwarded, so it leaves on the podman bridge with the
  bridge's address as source. That is the gateway address Caddy saw.

`tailscale set --snat-subnet-routes=false` removes that rule and Caddy sees
the tailnet peer, without changing how the container is published or
networked.

Three ways were considered.

1. tailscale's nginx-auth (`services.tailscaleAuth` in nixpkgs), a WhoIs
   helper on a unix socket, called by Caddy's `forward_auth` with the
   client address. Needs the real client address, which the setting above
   provides. The container stays on the podman network, so upstreams by
   container name (`forgejo:3000`) keep resolving, and 443 stays bound to
   the tailnet address only.
2. The caddy-tailscale plugin (`tailscale_auth`). Needs a Caddy image built
   with xcaddy, pushed to our registry and pinned there, where every other
   image is an upstream image pinned by digest. Caddy becomes its own
   tailnet node through tsnet, with an auth key in `/var/lib/secrets` and
   its node state in a volume. Sites would listen on that node's address,
   so the DNS records for `*.<domain>` would have to move from the host's
   tailnet address to the new node's, and the node needs its own ACLs and
   tags.
3. `tailscale serve` on the host in front of Caddy, which adds
   `Tailscale-User-*` headers. Serve takes over 443 on the tailnet address,
   so Caddy would move to a loopback port behind it. Serve terminates TLS
   only for the node's own `ts.net` name; the sites under `homelab.domain`
   with certificates from ACME DNS-01 cannot be served in HTTP mode, and in
   TCP passthrough mode serve adds no headers.

## Decision

Caddy looks up the tailnet user with tailscale's nginx-auth over a unix
socket (option 1). `homelab.reverseProxy.tailscaleIdentity.enable` turns it
on:

- `services.tailscaleAuth` listens on `/run/tailnet-identity/whois.sock`,
  which is mounted into the caddy container. The directory is not
  nginx-auth's RuntimeDirectory, which systemd recreates on every restart
  and would leave the container's mount pointing at a deleted directory.
- `services.tailscale.extraSetFlags` gets `--snat-subnet-routes=false`.

Sites opt in with `import tailnet_identity`, a snippet in the example
Caddyfile. A host whose Caddyfile imports it but leaves the option off
fails an assertion. The snippet runs, in this order:

- It deletes `Remote-User` and every `Tailscale-*` header the client sent,
  on every request. A forged identity never reaches a service.
- A request with an `Authorization` header skips the lookup and reaches
  the service with no identity. Agents on tagged nodes and scripts keep
  using their tokens, which the services check as before.
- Otherwise nginx-auth looks up the client address. For a tailnet user it
  answers with the login name (`alice@github`), which Caddy passes as
  `Remote-User`. For a tagged node (403) or an address that is no tailnet
  peer (401) the request goes on without an identity, so the browser gets
  the service's own token sign-in rather than an error.

Mapping a login name to each service's user is left to the services' own
configuration.

The caddy-tailscale plugin is rejected because it needs a custom image and
a new secret and moves every site to another address, while option 1 needs
neither. `tailscale serve` is rejected because it cannot serve our domain's
certificates and adds headers only where it terminates TLS. Authelia and a
full identity provider were the owner's rejected alternatives.

## Consequences

- Sign-in is only as strong as the tailnet account and the device. Anyone
  using an enrolled, unlocked device of the owner, or holding the identity
  provider account behind the tailnet, is signed in everywhere. Device
  approval, key expiry and the account's second factor are now the login
  security.
- Users from other tailnets who are shared into this node also get their
  login name passed on. Services must only accept the names they map.
- Services must trust `Remote-User` only from Caddy's address. Other
  containers on the podman network can reach a service directly and send
  any header; Caddy's stripping protects only what passes through Caddy.
- Turning off tailscale's SNAT also affects subnet routing and exit-node
  traffic through the host: LAN and internet hosts then see tailnet source
  addresses and need a route back. A host that is a subnet router or exit
  node should not enable the option unless its LAN routes the tailnet
  range back to it. Other ports published on the tailnet address (Forgejo
  SSH, Nextcloud) now see the real tailnet client too.
- Requests from the host itself or from a container through the tailnet
  address are hairpinned by podman, look like the bridge, and get no
  identity.
- If nginx-auth is down, browser requests through the snippet fail with
  502; requests with a token are unaffected. It is socket-activated, so
  systemd starts it again on the next request.
- No new secret file, image or port. nginx-auth is a NixOS service from
  nixpkgs and moves with `flake.lock`.
- The `tailnet-identity` check runs the example's snippet in Caddy against
  a stand-in for nginx-auth: identity set, forged headers stripped, tokens
  passed through, tagged and unknown clients passed through without
  identity. It cannot prove the WhoIs lookup on a real tailnet; that is
  tested by hand.
