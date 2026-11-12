# ADR-0005: Services trust Remote-User only from Caddy, by its fixed address or a socket only Caddy mounts

Status: Accepted

## Context

ADR-0003 has Caddy pass the tailnet login (`alice@github`) as `Remote-User`
to sites that import `tailnet_identity`, and notes that a service must
trust the header only from Caddy: every container on the podman network,
and every host-networked container (Home Assistant, Frigate, UniFi), can
reach a service directly and send any header. It leaves mapping the login
to each service's user to the services.

Two services need it next, Grafana and Forgejo, and they differ.

- Grafana's `auth.proxy` checks the peer address against its `whitelist`
  on every request with the header (`pkg/services/authn/clients/proxy.go`,
  read at nixpkgs' Grafana 13.0.1). It needs Caddy at an address that does
  not change. Nothing in the library fixed one; homelab-config assumed
  10.88.255.2.
- Forgejo's reverse proxy authentication does not look at the peer at all
  (`services/auth/method/reverseproxy.go` at 17.0.1, the pinned image).
  `REVERSE_PROXY_TRUSTED_PROXIES` and `REVERSE_PROXY_LIMIT` only decide
  whose `X-Forwarded-For` it believes (`routers/common/middleware.go`). With
  Forgejo on port 3000 of the podman network, anything on it signs in as
  any user, the admin included, by sending the header. Run by hand with
  nixpkgs' Forgejo 15.0.2: a request from 127.0.0.2 with `Remote-User:
  alice` and the trusted proxies set to 127.0.0.1/32 is signed in as alice.
- Forgejo looks the header up as a user name, and a tailnet login is not
  one. It can also match a user by email (`ENABLE_REVERSE_PROXY_EMAIL`),
  but users can add email addresses to their own accounts, so a user could
  claim another person's login as an address.
- Grafana takes the login as its user name and a role from a second header
  (`headers = Role:...`), and syncs the role on each sign in.

## Decision

- The caddy container gets a fixed address on podman's default network,
  `homelab.reverseProxy.address`, default 10.88.255.2, set with `--ip`.
  podman's IPAM (netavark backend, podman 5.8.2 at our pin) takes a static
  address in the network's subnet, refuses it if another container holds
  it, and hands out the others in order, going on from the last one it
  gave.
- Grafana trusts `Remote-User` from that address only
  (`homelab.observability.grafanaProxyAuth`).
- Forgejo, with `homelab.forgejo.proxyAuth.enable`, serves HTTP only on the
  unix socket `/run/forgejo-http/http.sock` (`PROTOCOL=http+unix`). The host
  directory is mode 0750 and owned by forgejo, and only the caddy container
  mounts it, so only Caddy (and root on the host) can reach Forgejo's HTTP.
  Forgejo's own hooks reach its internal API through the same socket.
- The reverse proxy generates a snippet per service from the service's
  options and puts it ahead of the Caddyfile: `forgejo_identity` maps the
  login to a Forgejo user name through `homelab.forgejo.proxyAuth.users`,
  and `grafana_identity` passes the logins in
  `homelab.observability.grafanaProxyAuth.admins` with the role Admin. A
  login not listed reaches the service with an empty `Remote-User`, which
  both treat as no identity. Each snippet imports `tailnet_identity` itself,
  so a site cannot map a header it has not cleaned. Forgejo does not
  create users on sign in; Grafana does, for the listed logins only.

## Consequences

- Without the options nothing changes for consumers, except that Caddy
  always has the fixed address, and Forgejo's environment states the
  defaults it had (`PROTOCOL=http`, `HTTP_ADDR=0.0.0.0`, reverse proxy
  authentication off). The image keeps settings in app.ini after their
  variable goes away, so turning the option off must set them back.
- With Forgejo's proxy authentication on, `forgejo:3000` no longer answers;
  the git site proxies to the socket, and anything else that called
  Forgejo over the podman network must go through
  `https://git.<domain>` instead. Git over SSH is unchanged.
- Forgejo counts a unix socket client as 127.0.0.1, so its trusted proxies
  become 127.0.0.1/32 to keep the client address from Caddy's
  `X-Forwarded-For` in its logs.
- Grafana's trust rests on no other container holding 10.88.255.2. podman
  refuses a second container that address, but while Caddy is stopped a
  container started then could get it once the allocator has worked
  through the range, and Caddy would then fail to start. An address check
  is weaker than the socket: a container with `NET_ADMIN` could take the
  address, and one with `NET_RAW` on the host network (Home Assistant has
  it) could in principle forge packets from it. Moving Grafana to a socket
  as well would close that; it is left for later.
- Admins of Grafana and the users of Forgejo are lists in the host's
  config; adding someone is a rebuild. Grafana users whose login is removed
  can no longer sign in, but keep their account until deleted.
- With proxy authentication Grafana also turns off basic auth: its built in
  admin still has the password `admin` unless changed, and with anonymous
  access gone that would be the way in for anyone on the tailnet. Service
  account tokens keep working.
