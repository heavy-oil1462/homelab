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

See `examples/` for a full server host, a workstation host, and a consumer
flake. `examples/assets/` holds commented starting points for every config
file a module consumes (Caddyfile, Frigate, Prometheus, homepage, Home
Assistant, Hyprland). All example IPs are from RFC 5737 documentation ranges.

## Modules

Roles:

- `server-role`: headless VM baseline (grub, DHCP, podman, tailscale,
  node exporter, fluent-bit log shipping, tailnet-only SSH).
- `workstation-role`: Hyprland desktop, greetd/tuigreet, pipewire, YubiKey
  login, libvirt, and the agent sandbox.

Services (OCI containers, pinned by digest):

- `reverse-proxy`: Caddy. With `homelab.tailnetIp` set, 443 binds to the
  tailnet address only, which makes every site tailnet-only.
- `observability`: Prometheus, Loki, Grafana with provisioned datasources,
  dashboards and alerting.
- `vaultwarden`, `homepage`, `homeassistant`, `nvr` (Frigate), `nextcloud`
  (AIO).
- `unifi`: UniFi Network controller (linuxserver image) with its own
  MongoDB container (auth enabled). Expects MONGO_INITDB_ROOT_USERNAME,
  MONGO_INITDB_ROOT_PASSWORD, MONGO_USER and MONGO_PASS in
  `/var/lib/secrets/unifi.env` at runtime.
- `agent-sandbox`: a rootless podman sandbox for AI coding agents (Claude
  Code, Antigravity) with per-project state, shared gh/Claude auth, pinned
  commit identity, and an optional personal skills repo synced into every
  session.

System:

- `common` (auto-upgrade, GC, flakes, user, firewall), `openssh` (keys from
  `homelab.adminKeys`), `acme` (Cloudflare DNS-01), `backups` (restic to any
  rclone remote), `locale`, `yubikey` (pam_u2f with a host-independent
  origin), `firewall` (role-based baseline), `nvidia`, `vm-disko`,
  `tailscale`, `logging-agent`, `observability-agent`, and the desktop
  modules.

Secrets are never part of the configuration: modules reference runtime paths
under `/var/lib/secrets/` (Cloudflare token, restic password, HA token,
camera credentials) that you provision on the host out of band.

## Configuration files

Modules take their service configs as paths (`homelab.reverseProxy.caddyfile`,
`homelab.nvr.configFile`, ...). Files are templated at build time: the literal
`__DOMAIN__` is replaced with `homelab.domain`, so the same config works for
any domain.

## Checks

`nix flake check` deep-evaluates the two example hosts down to derivation
paths, which catches option and type errors without building full systems.

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
