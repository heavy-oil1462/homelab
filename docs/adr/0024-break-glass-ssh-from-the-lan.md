# ADR-0024: Break-glass SSH from the LAN, keys only

Status: Accepted

## Context

Servers take SSH only on `tailscale0` (`modules/firewall.nix`). Deploys,
admin logins and, through [ADR-0003](0003-tailscale-identity-for-sign-in.md),
sign-in all lean on Tailscale. When a server's Tailscale key expired,
the owner nearly lost access to it: a VM has its hypervisor's console, but
bare metal hosts have no console login, and with Tailscale down nothing
else reached sshd.

Opening a port on LAN interfaces and changing SSH access are both changes
DIRECTION.md asks the owner about first. The owner chose "SSH on port 22
from the LAN, keys only" (option B of question 01a2001c-d9ed, 2026-11-21).

The hosts run NixOS' iptables firewall; none sets
`networking.nftables.enable`. `networking.firewall.allowedTCPPorts` cannot
limit a port to source addresses, so a rule per source is needed. The
iptables firewall flushes its `nixos-fw` chain on every start and reload,
and unhooks it from `INPUT` on stop.

sshd listens on every address on hosts with the openssh module, and only
on loopback on hosts that have sshd through `deploy-ca.nix` alone. The
openssh module turns password authentication off, but leaves
keyboard-interactive on unless the deploy CA is set, and keyboard-interactive
through PAM takes a password.

## Decision

- `homelab.network.sshFrom`, a list of IPv4 and IPv6 CIDRs, default empty,
  lists the networks that may reach port 22 on any interface but
  `tailscale0`, which keeps its own rule. The site's LAN admin subnets go
  there, from homelab-config.
- On the iptables firewall each network is a rule
  `-A nixos-fw ! -i tailscale0 -p tcp --dport 22 -s <net> -j nixos-fw-accept`,
  through `iptables` or `ip6tables` by address family, in
  `networking.firewall.extraCommands`. They live in the firewall's own
  chain, so its start, reload and stop remove them and no
  `extraStopCommands` is needed. A host on the nftables firewall gets the
  same as `extraInputRules` instead.
- With any network set, the openssh module turns keyboard-interactive off,
  and assertions refuse a host whose sshd takes a password or
  keyboard-interactive, has `PermitRootLogin = "yes"`, or listens on
  loopback only.
- A network with prefix length 0, such as `0.0.0.0/0` or `::/0`, fails an
  assertion, so SSH cannot be opened to every address by mistake.
- Empty, nothing changes: the example hosts' system derivations are the
  same as before the option.

## Consequences

- With Tailscale down, the owner reaches a server from the admin subnet by
  its LAN address, `ssh <user>@<LAN address>`; MagicDNS names need
  Tailscale. Root keeps logging in with deploy CA certificates only.
- Any machine in the listed subnets can reach sshd and try keys. Its
  safety rests on the keys and on who is on that subnet; LAN addresses can
  be spoofed on the LAN itself, so the subnets are a filter, not an
  identity.
- On a host without the deploy CA, setting the option turns
  keyboard-interactive off, which it had been on until now. Hosts that keep
  the option empty keep their sshd config unchanged.
- Hosts that set the option import the openssh module, or listen on a LAN
  address themselves; a host with sshd on loopback only fails to build.
- The `break-glass-ssh` check holds the rules and the refusals in
  evaluation. It does not load them into a kernel; the rules' syntax was
  tried by hand with iptables and nft in a network namespace.
- Changing who may reach SSH remains a change to ask the owner about first.
