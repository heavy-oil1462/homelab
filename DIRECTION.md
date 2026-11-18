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
Frigate), dev/cue, dev/fyr and dev/podium, dev/design-system (the
shared look, tokens and Preact components, of cue, fyr, podium and
vaka), and dev/oidc (the shared OpenID Connect sign-in package for the
domain's Go services). Each has its own DIRECTION.md where it has one, and that decides
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
- Containers run unprivileged: as a dedicated host user with a static id,
  with `no-new-privileges` and all capabilities dropped but those each
  names. Root stays only where the image supports nothing else, on the
  commented allowlist of the `container-hardening` check. Rootless podman is
  not pursued for now (owner, question 01a1ea3d-c147, 2026-11-17;
  ADR-0014).
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
   image-updates finds moved tags; bumps are reviewed issues (owner, board,
   2026-11-18).
6. New services the owner picks on the board.

## Not now

- Multi-architecture support (only x86_64-linux).
- Packaging anything beyond the NixOS modules, the deploy TUI and the plugin.

## How to work

- homelab-config is private and is never published ("You can commit it to
  homelab-config it is private", owner, owner-todo 01a1dfe9-0875,
  2026-11-15). Its `settings.nix` holds the site's own values: the tailnet
  name and addresses, the owner's tailnet login and the domains. The rule
  that main may be published, with no private hostnames or personal data
  in files, applies to this library and the domain's other public
  repositories, not to homelab-config. Secrets (tokens, keys, passwords)
  go into neither; they stay in `/var/lib/secrets/`.
- Long-term initiatives and products are planned in fyr. The supervisor
  proposes new ones there as suggested, for the owner to accept, and links
  each cue issue to its initiative (owner, board, 2026-11-11). Every
  product (cue, fyr, podium, homelab, vaka) has its capabilities in fyr's
  homelab workspace, and vaka's longer-term initiatives are planned there;
  the supervisor keeps them current ("I want the capabilities to be in
  there", owner, board, 2026-11-14). Cross-product work carries a `theme`
  tag in fyr (today: Security, Sign-in, Reliability, Observability, Design
  system), so it shows in the views "Products overview", "Cross-product
  themes" and "Security and sign-in"; the supervisor tags new work and keeps
  the statuses current ("Things like the security, OIDC stuff that are cross
  products I would like some tags with views to follow that progress",
  owner, board, 2026-11-14). A change to a product's UI updates that
  repository's screenshots in its docs ("do add some screenshots in the docs
  too so I can see the progress").
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
- The owner's web apps use vaka's layout: a slim vertical side bar on the
  left, with no top bar ("Just to stay consistent it should have the top
  menu bar on the left side instead just like vaka", owner, board,
  2026-11-15, about podium). podium follows now (cue issue
  01a1de25-caef); cue and fyr follow when the owner says so. The side bar
  is a candidate for a shared component in dev/design-system.
- Go services that sign users in through OIDC (tsidp, ADR-0006) use
  dev/oidc ("Start work on a generic oidc client module that fyr, cue and
  podium can use in the future, for now just vaka should use it", owner,
  board, 2026-11-14): vaka now; cue, fyr and podium when the owner says
  so. A change to sign-in is made there first.
- vaka is deployed containerized for testing, like cue and fyr: podium
  publishes `vaka:latest` from vaka's flake, and the site runs it under
  `virtualisation.oci-containers` on the NVR host, reached at
  `camera2.<domain>` behind Caddy with owner sign-in ("Time to add vaka to
  homelab so I can start to test it. I think for now make it
  camera2.domain in caddy … I am thinking containerized but can do both
  here since its a dedicated NVR host anyway", owner, board, 2026-11-14).
  vaka's recording can be turned off ("It must be possible to disable the
  recording since I don't want double the storage usage before I am
  confident enough to replace frigate", owner, board, 2026-11-14). It ran
  next to Frigate at `cameras.<domain>` with recording off until the
  owner started a trial: Frigate is disabled on the NVR host by
  commenting it out, not removing it, and its data is kept; vaka records
  for a few days, and the owner then reviews how it performs ("Lets give
  vaka a chance then. You can disable frigate just comment out. Then I
  will let vaka record for a few days and review how it performs", owner,
  board, 2026-11-15). During the trial vaka is reached at
  `cameras.<domain>`, where the owner's shortcuts point, and
  `camera2.<domain>` redirects there ("while I am testing vaka please set
  its url to cameras.domain since that is what I have shortcuts for etc.",
  owner, board, 2026-11-15). Whether Frigate is retired for good is the
  owner's call after that review. vaka's NixOS module remains, and the library
  module that replaces Frigate comes later.
- Dashboards are edited in Grafana or in Git and reach the other side
  without a deploy, through Grafana's own two-way Git Sync with a Forgejo
  repository ("start provisioning my grafana dashboards directly from
  forgejo so they can be updated easily without deploy", owner, board,
  2026-11-14; the owner chose Git Sync over the pull timer of ADR-0008,
  question 01a1daf3-fb83, 2026-11-14; ADR-0009).
- Services are configured from Nix; a manual step in a UI is a gap to
  close, not the design ("can forgejo and grafana OIDC be configured from
  the nix config instead of manually in the UI?", owner, board,
  2026-11-14; ADR-0010).
- Every step only the owner can do (provisioning a secret, a token or an
  OAuth client, a deploy, a setting in a UI) is listed in one cue issue
  tagged `owner-todo`, today 01a1dfe9-0875 ("please make sure to document
  my remaining todos in a separate issue. The OICD stuff, Complete grafana
  git, MQTT security/password and vaka google drive sync setup", owner,
  board, 2026-11-15). Each step is a checklist item with its exact
  commands and the doc it comes from. The supervisor adds a step when a
  merged change brings one, and the issue closes when all are done. A
  change that adds owner steps lists them exactly in its summary, so they
  can be copied there. Cue questions stay for decisions; the owner-todo
  issue is for actions.
- The site keeps a printable recovery card for total server loss,
  homelab-config's `scripts/recovery-card.py` (issue 01a1dbef-dcd9): the
  commands, URLs and secrets needed to get up again ("make a script for
  homelab to create a recovery card. It should have all the information I
  would need to get up again from a total server loss … take secrets such
  as restic backup password as input when the script is run … A QR code I
  can scan with phone", owner, board, 2026-11-14). The card is generated
  from the configuration, so it stays current. Secrets are taken only
  when the script runs and are shown as text and QR codes, never
  committed. It assumes the owner reaches their Google account unaided
  ("It is safe to assume that I will be able to access my google account
  myself without any help"). A change that adds a service, a backup job
  or a secret keeps the card generator in step.
- Every host carries the terminfo of common terminals (kitty, alacritty,
  foot, wezterm, ghostty and others), so SSH from any terminal works with
  ncurses programs ("can this be fixed once and for all too", owner, board,
  2026-11-14, after nano on a server refused `xterm-kitty`).
  `homelab.allTerminfo` turns it off.
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
