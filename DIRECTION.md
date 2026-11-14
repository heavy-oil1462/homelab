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

This repository is the home of the Homelab domain, which the team works
across: homelab, homelab-config (the owner's private site configuration),
vaka (homelab/vaka, a NixOS-native camera system meant to replace
Frigate), dev/cue, dev/fyr and dev/podium, and dev/design-system (the
shared look, tokens and Preact components, of cue, fyr, podium and
vaka). Each has its own DIRECTION.md where it has one, and that decides
work in its repository.

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

1. CI: a GitHub workflow runs `nix flake check` on every pull request, and
   every module (including `nvidia`, `vm-disko`) is evaluated by an example.
2. Existing modules follow the principles: Nextcloud pinned and
   tailnet-only, Frigate secrets under `/var/lib/secrets/`, no container
   breaks when a secret file is missing.
3. Every stateful service is backed up with a consistent snapshot, and a
   restore runbook exists. Forgejo, cue and fyr come first (owner, board,
   2026-11-11).
4. Failures alert: provisioned rules for failed backups and units, disk,
   host down and certificate expiry, with a contact point.
5. Image digests and `flake.lock` stay current without manual tracking.
6. New services the owner picks on the board.

## Not now

- Multi-architecture support (only x86_64-linux).
- Packaging anything beyond the NixOS modules, the deploy TUI and the plugin.

## How to work

- Long-term initiatives and products are planned in fyr. The supervisor
  proposes new ones there as suggested, for the owner to accept, and links
  each cue issue to its initiative (owner, board, 2026-11-11). Every
  product (cue, fyr, podium, homelab, vaka) has its capabilities in fyr's
  homelab workspace, and vaka's longer-term initiatives are planned there;
  the supervisor keeps them current ("I want the capabilities to be in
  there", owner, board, 2026-11-14).
- The supervisor creates and initializes new repositories for the domain
  when the work needs them, through podium's orchestrator (podium ADR-027,
  issue 01a1d8bb-e037; owner, board, 2026-11-14). They are created
  private, in an organisation the domain already uses, and added to the
  cue domain. Deleting, renaming or making a repository public stays with
  the owner.
- The team, supervisor and workers, may query the site's Prometheus and
  Loki through podium's team egress, to inspect the homelab and debug
  issues against real data ("I think it makes sense you get read access
  to inspect my homelab", owner, board, 2026-11-14). Only read: the
  query, labels and series endpoints. Never push to Loki, delete series
  or use an admin API. Their hostnames stay out of the repository.
- Every UI in the domain takes its look from dev/design-system ("They
  should all have same feel", owner, board, 2026-11-14): vaka from the
  start, so its modules can be reused; cue, fyr and podium when the owner
  says so. A change to the shared look is made there first.
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
- Making a repository public, deleting, renaming or transferring one.
