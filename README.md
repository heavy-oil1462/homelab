# homelab

Reusable NixOS modules for a container-based homelab. Services run as pinned
OCI containers under podman, sites are published tailnet-only through a Caddy
reverse proxy with ACME DNS-01 certificates, and hosts ship logs and metrics
to a Loki/Prometheus/Grafana stack. A workstation role provides a Hyprland
desktop, YubiKey login, and a sandboxed environment for AI coding agents.

Everything personal (domain, user, keys, service configs) is injected through
a typed `homelab.*` options namespace, so this repo contains no site-specific
values. You keep those in your own (typically private) config repo and
consume this one as a flake input.

## Usage

```nix
inputs.homelab.url = "github:heavy-oil1462/homelab";
```

Import the modules a host needs and set the options:

```nix
modules = [
  homelab.nixosModules.common
  homelab.nixosModules.server-role
  homelab.nixosModules.reverse-proxy
  {
    homelab = {
      username = "alice";
      domain = "home.example.com";
      adminKeys = [ "ssh-ed25519 AAAA... alice@laptop" ];
      tailnetIp = "100.64.0.1";
      reverseProxy.caddyfile = ./assets/Caddyfile;
      reverseProxy.notFoundPage = ./assets/404.html;
    };
  }
]
```

See `examples/` for a full server host, a workstation host, a VM host on a
disko layout, and a consumer flake. `examples/assets/` holds commented
starting points for every config file a module consumes (Caddyfile, Frigate,
Prometheus, homepage, Home Assistant, Hyprland). All example IPs are from
RFC 5737 documentation ranges.

## Modules

Roles:

- `server-role`: headless VM baseline (grub, DHCP, podman, tailscale,
  node exporter, fluent-bit log shipping, tailnet-only SSH).
- `workstation-role`: Hyprland desktop, greetd/tuigreet, pipewire, YubiKey
  login, libvirt, and the agent sandbox.

Services (OCI containers, pinned by digest):

- `reverse-proxy`: Caddy. With `homelab.tailnetIp` set, 443 binds to the
  tailnet address only, which makes every site tailnet-only.
  With `homelab.reverseProxy.tailscaleIdentity.enable`, sites that
  `import tailnet_identity` (example Caddyfile) pass the tailnet user's login
  name to their upstream as `Remote-User`, looked up through tailscale's
  nginx-auth. Client-sent identity headers are always deleted, and requests
  with an `Authorization` header pass without an identity. It turns off
  tailscale's subnet-route SNAT, so don't enable it on a subnet router or
  exit node (docs/adr/0003-tailscale-identity-for-sign-in.md).
  The caddy container has the fixed address `homelab.reverseProxy.address`
  (10.88.255.2) on podman's default network. With Forgejo's or Grafana's
  proxy authentication on, it also defines `forgejo_identity` and
  `grafana_identity`, which include `tailnet_identity` and map the login to
  the service's user (docs/adr/0005-proxy-auth-only-from-caddy.md).
- `observability`: Prometheus, Loki, Grafana with provisioned datasources,
  dashboards and alerting. A blackbox exporter on the host probes the HTTPS
  URLs in `homelab.observability.probeTargets` through Caddy, as clients
  reach them; it listens on the podman bridge only. The host must resolve the
  site names to Caddy's tailnet address (with Tailscale DNS, a split-DNS
  record for the domain). `examples/assets/grafana-alerting.yaml` alerts on
  failed units, failed backups, backups with no success in 36 hours or
  none at all, full disks, hosts that are down,
  certificates that expire within 14 days and sites that are down or serve
  an invalid certificate, through one placeholder contact point. The
  example dashboard `gpu.json` shows GPU load per instance from the NVIDIA
  GPU exporters listed in `homelab.observability.nvidiaGpuTargets`, which
  Prometheus reads from `/etc/prometheus/nvidia-gpu-targets.json` through
  the example's nvidia-gpu job. Grafana
  gives anyone who reaches it anonymous Admin access, unless
  `homelab.observability.grafanaProxyAuth.enable` is set: then only the
  tailnet logins in `homelab.observability.grafanaProxyAuth.admins` sign in,
  as Admin, through a status site that imports `grafana_identity`, and
  Grafana trusts `Remote-User` only from Caddy's address. With
  `homelab.observability.grafanaOidc.enable` instead, Grafana signs in
  through tsidp (the `tsidp` module): the logins in
  `homelab.observability.grafanaOidc.admins` get Admin, everyone else is
  refused. Its client in tsidp has the redirect URI
  `https://status.<domain>/login/generic_oauth`; declared in
  `homelab.tsidp.clients` with owner `grafana`, as `examples/server.nix`
  does, tsidp writes its id and secret to
  `/var/lib/secrets/grafana-oidc-client-id` and
  `/var/lib/secrets/grafana-oidc-client-secret`
  (docs/adr/0006-tsidp-for-oidc-sign-in.md,
  docs/adr/0010-tsidp-clients-declared-in-nix.md). Dashboards come from
  `homelab.observability.dashboardsDir`, which needs a rebuild to change,
  or with `homelab.observability.dashboardsGit` from a directory of a Git
  repository: the `grafana-dashboards-sync` timer fetches it every two
  minutes with a read-only deploy key, checks each file and copies it into
  place, so a merged change reaches Grafana with no deploy; a bad commit
  keeps the last good set and fails the unit. See
  [docs/dashboards.md](docs/dashboards.md)
  (docs/adr/0008-dashboards-synced-from-git.md).
- `vaultwarden`, `homepage`, `homeassistant`.
- `nextcloud`: Nextcloud All-in-One mastercontainer, pinned by digest. Its
  admin UI (8080) and the Apache container it starts (11000) bind to
  `homelab.nextcloud.bindAddress`, the tailnet address by default. To reach
  them from the LAN, set it to a LAN address (or `"0.0.0.0"`) and open the
  ports in the host's firewall. AIO updates the containers it manages from
  its UI when you ask it to; the AIO version itself changes with the pin.
- `nvr`: Frigate with GPU detection, recordings on `/surveillance`, state in
  `/var/lib/frigate`. Camera credentials (FRIGATE_* variables the config
  expands) come from `/var/lib/secrets/frigate.env`. Hosts that still have
  the old `/etc/secrets/frigate.env` get it copied over on the next start;
  remove the old file once Frigate works.
- `unifi`: UniFi Network controller (linuxserver image) with its own
  MongoDB container (auth enabled). Expects MONGO_INITDB_ROOT_USERNAME,
  MONGO_INITDB_ROOT_PASSWORD, MONGO_USER and MONGO_PASS in
  `/var/lib/secrets/unifi.env` at runtime.
- `registry`: private OCI image registry (Docker Official `registry` image,
  CNCF Distribution) for your own images, published through the reverse
  proxy. Every pull and push needs a login from a bcrypt htpasswd file at
  `/var/lib/secrets/registry.htpasswd` at runtime.
- `forgejo`: Forgejo git forge (rootless image, SQLite) at git.<domain>
  through the reverse proxy, with its built in SSH server published on the
  tailnet address, port 2222 (`homelab.forgejo.sshAddress`,
  `homelab.forgejo.sshPort`), Actions enabled and registration closed. Site
  specific settings go in `homelab.forgejo.extraEnvironment` as
  FORGEJO__section__KEY values. Expects a secret key at
  `/var/lib/secrets/forgejo-secret-key` at runtime (for example
  `openssl rand -hex 32`, owned by forgejo, mode 0400); Forgejo does not
  start while it is empty.
  With `homelab.forgejo.admin.name` and `homelab.forgejo.admin.email` set,
  the `forgejo-admin` unit creates that admin once Forgejo answers, if it
  has no admin yet, and safely does nothing on later boots. Its one-time
  password is only in one line of the unit's journal, with the sign in URL,
  https://git.<domain>/user/login:
  `journalctl -u forgejo-admin`. Forgejo asks for a new password at the
  first sign in; add a passkey after that. Unset, the admin is created by
  hand as the module's header comment shows. The module does not back
  itself up; add a backup job on the host, as `examples/server.nix` does:
  `homelab.backups.jobs.forgejo` with path `/var/lib/forgejo` and database
  `/var/lib/forgejo/data/gitea.db`.
  With `homelab.forgejo.proxyAuth.enable`, the tailnet logins in
  `homelab.forgejo.proxyAuth.users` sign in to the web UI as the Forgejo
  user they map to, through a git site that imports `forgejo_identity`.
  Users are not created on sign in. Forgejo then serves HTTP only on the
  socket `/run/forgejo-http/http.sock`, which the caddy container mounts,
  so the git site proxies to `unix//run/forgejo-http/http.sock` instead of
  `forgejo:3000`. Tokens and git over SSH work as before.
  With `homelab.forgejo.oidc.enable` instead, the web UI signs in through
  tsidp (the `tsidp` module), and Forgejo creates an account on a user's
  first sign in. The `forgejo-oidc` unit adds tsidp as the sign in source
  `tailscale` and restarts Forgejo when it changes. Its client in tsidp
  has the redirect URI
  `https://git.<domain>/user/oauth2/tailscale/callback`; declared in
  `homelab.tsidp.clients`, tsidp writes its id and secret to
  `/var/lib/secrets/forgejo-oidc-client-id` and
  `/var/lib/secrets/forgejo-oidc-client-secret`. A service uses proxy
  authentication or OIDC, never both
  (docs/adr/0006-tsidp-for-oidc-sign-in.md).
- `agent-sandbox`: a rootless podman sandbox for AI coding agents (Claude
  Code, Antigravity) with per-project state, shared gh/Claude auth, pinned
  commit identity, and an optional personal skills repo synced into every
  session.

System:

- `common` (auto-upgrade, GC, flakes, user, firewall), `openssh` (keys from
  `homelab.adminKeys`), `acme` (Cloudflare DNS-01), `backups` (restic to any
  rclone remote: Vaultwarden, plus the jobs in `homelab.backups.jobs`, with
  consistent SQLite snapshots, and each job's last successful run as a
  node exporter metric; restoring is in [docs/backups.md](docs/backups.md)),
  `locale`, `yubikey` (pam_u2f with a
  host-independent origin), `firewall` (role-based baseline), `nvidia` (proprietary driver;
  the host must allow the unfree `nvidia-x11` and `nvidia-settings`, as
  `examples/workstation.nix` does), `vm-disko` (single-disk VM layout; needs
  disko's NixOS module from your own flake, as `examples/vm.nix` shows),
  `tailscale`, `logging-agent`, `observability-agent` (node exporter with
  the systemd collector, and the textfile collector reading
  `homelab.observabilityAgent.textfileDirectory`; with
  `homelab.observabilityAgent.nvidiaGpu.enable`, also nixpkgs' NVIDIA GPU
  exporter on port 9835, open on `tailscale0` only, which needs the `nvidia`
  module and works on GeForce cards), and the desktop
  modules.
- `tsidp` (`homelab.tsidp`): tsidp, Tailscale's OpenID Connect provider,
  with nixpkgs' `services.tsidp`, as its own tailnet node
  `homelab.tsidp.hostName` (`idp`); the issuer is
  `https://idp.<tailnet>.ts.net`. Forgejo and Grafana sign in through it.
  Joins the tailnet with the auth key in `/var/lib/secrets/tsidp.env`
  (`TS_AUTHKEY=tskey-auth-...`; a one-off tagged key). Its node and signing
  keys and the registered clients live in `homelab.tsidp.stateDir`
  (`/var/lib/private/tsidp`); back it up with a job, as
  `examples/server.nix` does. Clients are declared in
  `homelab.tsidp.clients.<id>` (`redirectUris`, `idFile`, `secretFile`,
  `owner`): before tsidp starts, each gets its id and a generated secret in
  its files under `/var/lib/secrets` when they are missing or empty, and is
  written into tsidp's clients; clients added in the admin UI are left
  alone (docs/adr/0010-tsidp-clients-declared-in-nix.md). The example
  declares Forgejo's and Grafana's from their OIDC options. Other clients
  can be registered in its admin UI at the issuer URL, which needs a grant
  in the tailnet policy:

  ```hujson
  "grants": [{
    "src": ["alice@example.com"],
    "dst": ["tag:idp"],
    "app": { "tailscale.com/cap/tsidp": [{ "allow_admin_ui": true }] }
  }]
  ```

## Secrets

Secrets are never part of the configuration: modules reference runtime paths
under `/var/lib/secrets/` that you provision on the host out of band. For the
files containers read, a tmpfiles rule creates an empty file with the right
owner and mode if none exists, so a missing secret never stops podman from
starting a container or makes it create a directory in the file's place.

| File | Read by | Owner, mode | When empty or missing |
| --- | --- | --- | --- |
| `frigate.env` | `nvr` | root, 0400 | Frigate cannot expand the camera credentials in its config; no camera connects |
| `unifi.env` | `unifi` | root, 0400 | `unifi-db` refuses to start (MongoDB would run without auth), so `unifi` does not start |
| `homeassistant-secrets.yaml` | `homeassistant` | root, 0400 | Home Assistant starts; config that uses `!secret` does not load |
| `ha-prometheus-token` | `observability` | prometheus, 0640 | Prometheus runs; the home-assistant scrape fails with 401 |
| `registry.htpasswd` | `registry` | registry, 0400 | the registry refuses to start, naming the file |
| `forgejo-secret-key` | `forgejo` | forgejo, 0400 | Forgejo refuses to start |
| `grafana-oidc-client-id`, `grafana-oidc-client-secret` | `observability`, with `grafanaOidc` | grafana, 0400 | written by tsidp for a client in `homelab.tsidp.clients`; otherwise Grafana runs and no one can sign in |
| `forgejo-oidc-client-id`, `forgejo-oidc-client-secret` | `forgejo`, with `oidc` | root, 0400 | written by tsidp for a client in `homelab.tsidp.clients`; otherwise the `forgejo-oidc` unit fails and Forgejo runs without the sign in source |
| `grafana-dashboards-deploy-key` | `observability`, with `dashboardsGit` | root, 0400 | the `grafana-dashboards-sync` unit fails; Grafana keeps the dashboards it has |
| `tsidp.env` | `tsidp` | root, 0400 | missing, tsidp does not start, even once it has joined the tailnet; empty, a new tsidp prints a sign in link to its journal instead of joining |
| `cloudflare.env` | `acme` | root | certificate renewal fails |
| `restic-password`, `rclone.env` | `backups` | root | backups fail |
| `tailscale-authkey` | `tailscale` | root | not needed once the host is on the tailnet; deleted after use |

`cloudflare.env`, the backup secrets, `tailscale-authkey`, `tsidp.env`,
the dashboards' deploy key and Forgejo's OIDC files are read by NixOS services, not containers, and get no
tmpfiles rule: missing, their units fail, as most would with an empty file,
and the Tailscale key must stay absent once used. Once tsidp has joined,
its key may be revoked; the file stays, emptied if you like.

## Static user ids

Containers that run as a dedicated user need its uid at evaluation time, so
those users get static ids. NixOS assigns automatic system ids downward from
999 and never moves an existing user to a declared id; it also does not check
that a declared id is free. A static id near 999 can therefore silently share
a uid with a user that already exists on the host. New static ids come from
the block 600 to 699, which automatic assignment does not reach in practice:

- 600: vaultwarden
- 601: registry
- 602: forgejo

Older modules predate the block and keep their ids, since changing the uid of
a deployed user is not applied by NixOS: 990 frigate (nvr), 989 unifi, 988
unifi-db. Config repos that add their own container users should use a
separate block (for example 700 to 799).

## Configuration files

Modules take their service configs as paths (`homelab.reverseProxy.caddyfile`,
`homelab.nvr.configFile`, ...). Files are templated at build time: the literal
`__DOMAIN__` is replaced with `homelab.domain`, so the same config works for
any domain.

## Checks

`nix flake check` deep-evaluates the example hosts down to derivation
paths, which catches option and type errors without building full systems.
`examples/server-proxy-auth.nix` is the example server with Forgejo and
Grafana on proxy authentication instead of tsidp, so both are evaluated. The
checks also run the `forgejo-admin` and `forgejo-oidc` scripts against
stubs, the `tsidp-clients` script against a fake tsidp state directory,
and the Caddy identity snippets in a real Caddy.

## CI

`.forgejo/workflows/check.yml` runs
`nix flake check --no-update-lock-file --show-trace` in Forgejo Actions on
every push to any branch and on pull requests, in a digest-pinned `nixos/nix`
container.

## Deploy TUI

`nix run .#deploy` starts a small fzf picker over `scripts/deploy/*.sh` in
your config repo.

## Agent skills (Claude Code plugin)

This repo doubles as a Claude Code plugin shipping read-only observability
skills for the stack it deploys: host health from node_exporter
(host-metrics), journal logs from Loki (service-logs), and Home Assistant
entity state from the Prometheus exporter (ha-state). Install per project:

```
claude plugin marketplace add heavy-oil1462/homelab
claude plugin install homelab@homelab
```

Endpoints resolve from HOMELAB_PROM_URL / HOMELAB_LOKI_URL environment
variables, else a `.claude/homelab-endpoints.json` found upward from the
current directory (commit one in your private config repo), else
`~/.claude/homelab-endpoints.json`:

```json
{
  "prom_url": "https://metrics.home.example.com",
  "loki_url": "https://logs.home.example.com"
}
```

See `skills/README.md` for layout and conventions.
