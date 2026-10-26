# Direction

Set by the owner, @heavy-oil1462. The supervisor reads this at the start of
every session. Change it through a pull request, or ask on the board issue.

## Goal

A reusable NixOS module library for a container-based homelab that the
owner's private config repo consumes as a flake input. It covers server and
workstation roles, tailnet-only services behind Caddy, observability, backups
and a sandbox for AI coding agents. The repo stays free of site-specific
values so anyone can consume it, and it doubles as a Claude Code plugin with
read-only observability skills for the stack it deploys.

## Guiding principles

- No site-specific values in the tree: domains, users, keys, IPs and service
  configs come in through `homelab.*` options. Examples use `example.com` and
  RFC 5737 addresses.
- Secrets are never in the Nix store or the repo. Modules reference runtime
  paths under `/var/lib/secrets/` that the owner provisions out of band.
- Every `homelab.*` option is declared in `modules/options.nix`, typed, with
  a description; modules only read them.
- Container images are pinned by digest, with a comment giving version or tag
  and date (`# 1.37.1, :latest as of 2026-08-04`).
- Services are tailnet-only by default: nothing new listens on LAN
  interfaces unless an option opts in.
- A module that consumes a config file takes it as a path option and gets a
  commented starting point in `examples/assets/`.
- Skills are read-only by default, standard library only, and thin: logic
  lives in `lib/homelab`, each script supports `--help` and `--json`.
- Servers change only when deliberately rebuilt; nothing in a server module
  auto-upgrades or self-modifies.

## Architecture

```
flake.nix            exports nixosModules, packages.deploy, checks
modules/options.nix  the homelab.* namespace; imported by every module
modules/             system modules (common, openssh, podman, acme, backups,
  desktop/           tailscale, firewall, agents, ...) and desktop pieces
roles/               server.nix, workstation.nix: bundles of modules/ and
                     containers/; set homelab.network.role
containers/          one OCI service per file under virtualisation.oci-containers
examples/            server, workstation and consumer flake; assets/ holds
                     starting configs; evaluated by `nix flake check`
skills/, lib/homelab Claude Code plugin (.claude-plugin/): skills call lib
```

Dependencies: everything may import `modules/options.nix`. Roles import
modules and containers; containers and modules do not import roles.
Containers may rely on modules (podman, acme) but not on each other except
through the reverse proxy's Caddyfile. The Python under `skills/` and
`lib/homelab` has no dependency on the Nix side; it talks to Prometheus and
Loki over HTTP. Individual decisions go in `docs/adr`.

## Priorities, in order

1. Keep the existing modules working on nixos-unstable: fixes the owner
   reports come first.
2. New services and workstation features as the owner asks for them on the
   board.
3. A CI workflow that runs `nix flake check` on every pull request.

## Not now

- Multi-architecture support (only x86_64-linux).
- Packaging anything beyond the NixOS modules, the deploy TUI and the plugin.

## How to work

- Verify with `nix flake check`. A new module or option must be used by an
  example host so the check evaluates it.
- A new or changed module updates the README module list, and the example
  assets when it consumes a config file.
- Image bumps change the digest and the version comment together.
- Python under `skills/` and `lib/` follows `skills/README.md`.

## Ask the owner first

- Opening any port on LAN interfaces or relaxing the firewall baseline.
- Changes to the YubiKey/PAM login, SSH access or the agent sandbox's
  isolation and credential handling.
- Image major-version upgrades that migrate data (databases, Nextcloud,
  Home Assistant).
- Anything that changes what consumers must provision on their hosts
  (new secret files, renamed options): say so in the pull request.
