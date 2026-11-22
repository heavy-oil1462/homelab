# ADR-0026: Servers take SSH through sshd only, not Tailscale SSH

Status: Accepted

## Context

Every host ran Tailscale SSH: `modules/tailscale.nix` passed `--ssh` to
`tailscale up`. Tailscale SSH takes port 22 on the tailnet address ahead
of sshd and lets in whom the tailnet's ACL allows. The site's ACL allowed
the owner's devices in as the admin user, in "check" mode, which asks for
the tailnet login (a Google account) every 12 hours. Servers give that
user sudo without a password (`roles/server.nix`). So root on every server
rested on the Google account, not on the YubiKey keys sshd takes from
`homelab.adminKeys`. This was proposal 3 of the security review, which the
owner accepted (question 01a2033d-c70f, 2026-11-22); DIRECTION.md asks
for one gate per thing, sized evenly, and SSH access is a change the
owner decides.

sshd already takes the owner's keys and the deploy CA's root certificates
(`modules/deploy-ca.nix`, [ADR-0015](0015-forgejo-trusts-the-deploy-ca.md)),
listens on every address on servers, and `tailscale0` allows port 22
(`modules/firewall.nix`). Break-glass SSH from the LAN reaches the same
sshd ([ADR-0024](0024-break-glass-ssh-from-the-lan.md)), and the owner
confirmed it works with the keys only (owner-todo 14, 2026-11-22). The
workstations' prompts are sized for sshd's `sk` keys
([ADR-0025](0025-yubikey-prompts-once-per-session.md)). The site's agent
host already ran without `--ssh`, for sshd's forced command.

`extraUpFlags` reach only the node's first `tailscale up`; a running node
keeps its prefs until `tailscale set` changes them. Turning Tailscale SSH
off on a node cuts every Tailscale SSH connection open to it: tailscaled
decides per packet whether to take port 22 (`ShouldInterceptTCPPort` in
`ipn/ipnlocal`, tailscale 1.104.6), so the next packet of an open
connection goes to the kernel, which resets it. A deploy that reached the
host over Tailscale SSH would lose its session in the switch that turns it
off, or in the checks after it. The site's fleet update keeps a session
open through the switch (`systemd-run --wait`) and runs its health and
container checks over the same connection after it. tailscaled counts open
sessions, `ssh_active_sessions`, and accepted connections,
`ssh_incoming_connections`, in `tailscale debug metrics`, always printed,
zero included; a connection with no session, such as an idle ssh
ControlMaster, is in neither gauge.

## Decision

- `homelab.tailscale.ssh`, a boolean, defaults to off on hosts with
  `homelab.network.role = "server"` and on everywhere else. Workstations
  keep Tailscale SSH as before. With it off, `tailscale up` gets no
  `--ssh`.
- With it off, the `tailscale-ssh-off` unit turns it off on a node that
  runs it. It polls tailscaled every 15 seconds and runs
  `tailscale set --ssh=false` after 10 minutes in a row with no session
  open and no connection accepted. It checks the node's prefs before each
  poll and stops once RunSSH is off, so on later boots it does nothing.
  When tailscaled answers without the session gauge it fails and leaves
  Tailscale SSH on, so the failed unit alert says it needs a look.
- The unit is `Type=exec`, wanted by `multi-user.target`. The switch that
  adds it starts it and goes on; a oneshot would hold the switch until the
  deploy's session ended, which waits for the switch.
- A server with it off must have sshd enabled, listening beyond loopback,
  and its port open on `tailscale0` (or the firewall off, or `tailscale0`
  trusted); otherwise the build fails, so no server ends up with no SSH.
  The server role has all three.

It does not amend [ADR-0003](0003-tailscale-identity-for-sign-in.md),
which is about sign-in to the sites and does not cover Tailscale SSH.

## Consequences

- SSH to a server takes the owner's YubiKey keys or a deploy CA
  certificate, from the tailnet or the admin subnet alike. The tailnet
  login no longer opens a shell; the ACL still decides who reaches port 22.
- The deploy that brings this change is safe over Tailscale SSH: its
  session holds the unit off through the switch and its checks, and the
  quiet time covers the pauses between its commands. The next deploy
  reaches sshd on port 22 over the tailnet, which `tailscale0` already
  allows, as root with the deploy certificate or as the admin user with
  the owner's key.
- An idle connection, such as a ControlMaster kept open after its last
  session, is reset when Tailscale SSH goes off. ssh then opens a new one,
  to sshd. A session started in the instant between the last poll and the
  switch-off is reset too.
- The ACL's `ssh` section has nothing left to grant on servers; the site
  removes it.
- Turning the option back on takes effect at the node's next
  `tailscale up`; the unit only turns Tailscale SSH off.
- The unit reads `tailscale debug`, which tailscale does not promise to
  keep. The `tailscale-ssh-off` check runs the script against nixpkgs'
  tailscaled, so a bump that drops the counters or the prefs fails the
  check, and the script fails rather than guess.
- Changing who may reach SSH remains a change to ask the owner about first.
