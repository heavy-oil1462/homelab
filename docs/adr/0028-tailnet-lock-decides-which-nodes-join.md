# ADR-0028: Tailnet Lock decides which nodes join

Status: Accepted

## Context

The tailnet is the site's outer fence. Services listen on it only, sshd
takes port 22 from it ([ADR-0026](0026-servers-ssh-through-sshd-only.md)),
and deploys go over it. Who may add a node to it is decided by Tailscale's
control plane, and the control plane trusts whoever signs in to the
tailnet's identity provider, the owner's Google account. Someone who takes
over that account, by phishing or with a stolen session, can add a node of
their own, or approve one, and reach every service's sign-in page and every
server's sshd from the inside. The same holds for anyone who can make the
control plane itself hand out a node.

DIRECTION.md sizes each layer to the realistic threats, phishing and
malware on a workstation among them, and asks that no path be much weaker
than the others. Behind the fence each service has its own sign-in through
Pocket ID ([ADR-0018](0018-pocket-id-is-the-oidc-provider.md)) and sshd
takes the owner's YubiKey keys only, so a node on the tailnet alone opens
nothing. The fence itself, though, rested on one account that the rest of
the site does not depend on.

Tailnet Lock moves that decision from the control plane to the owner's
devices. Nodes accept a peer only when its node key carries a signature
from a trusted Tailnet Lock key, and those keys live on nodes the owner
chooses. The control plane can still list a node, but the others drop its
traffic. Disablement secrets, made when the lock is set up, turn it off for
the whole tailnet if every signing node is lost.

The owner chose Tailnet Lock (question 01a216b7, 2026-11-26).
homelab-config turns it on with one setup script, which puts the
disablement secrets on the recovery card.

## Decision

- Tailnet Lock is on for the site's tailnet. The workstation and
  nixserver1 hold its trusted keys and are the signing nodes: two, so the
  loss of either does not lock the owner out of signing.
- Two disablement secrets are made at setup and kept on the printed
  recovery card only, never in a repository or under `/var/lib/secrets`.
- Setting it up, and signing new nodes, are owner steps in homelab-config
  (`scripts/setup/`, docs/tailnet-lock.md). The library does not run
  `tailscale lock` commands that change anything.
- The library watches it. On every host with the `tailscale` and
  `observability-agent` modules, the `tailscale-metrics` unit reads
  `tailscale lock status --json` every 5 minutes and writes
  `homelab_tailscale_lock_enabled` and `homelab_tailscale_lock_node_signed`.
  The example rules alert as "Tailnet Lock off" and "Node not signed for
  Tailnet Lock" after 10 minutes.
- So that a tailnet without the lock does not alert, a host writes
  `homelab_tailscale_lock_enabled` only once it has seen the lock on. It
  remembers that in `/var/lib/tailscale-metrics/lock-seen`, a runtime
  state file, not a Nix option: the lock is turned on outside a rebuild,
  and a Prometheus range query would forget it after the retention time.
  `homelab_tailscale_lock_node_signed` is written only while the lock is
  on, as tailscaled reports it only then. A tailscale without
  `lock status`, or one that answers without `Enabled`, leaves both out
  and logs it once.

Relation to the other access decisions:

- [ADR-0024](0024-break-glass-ssh-from-the-lan.md), break-glass SSH from
  the LAN: unchanged, and the way in to a server the lock has locked out,
  such as one that lost its state and has an unsigned key. It reaches sshd
  without the tailnet, so a locked-out server can be signed and repaired.
- [ADR-0026](0026-servers-ssh-through-sshd-only.md), sshd only: still the
  gate behind the fence. The lock decides which nodes reach sshd at all;
  sshd still asks for the owner's keys or a deploy certificate. Neither
  rests on the Google account.

## Consequences

- A takeover of the Google account no longer adds a working node: it
  needs a signing node, or a disablement secret, as well. Using a
  disablement secret turns the lock off for every node, which alerts as
  "Tailnet Lock off".
- Every new device needs a signature from a signing node,
  `tailscale lock sign <node key>`, before it reaches anything; until then
  it alerts as "Node not signed for Tailnet Lock". A reinstalled host, or
  one that lost its tailscaled state, gets a new node key and needs
  signing again.
- Unattended installs, where `tailscaled-autoconnect` logs in with the
  auth key the installer left in `/var/lib/secrets/tailscale-authkey`,
  need a pre-signed auth key, made with `tailscale lock sign <auth key>`
  on a signing node. An unsigned key joins a node its peers ignore, which
  then can only be reached from the LAN (ADR-0024).
- Losing both signing nodes leaves the tailnet working, but no new node
  can be signed; the recovery card's disablement secrets then turn the
  lock off, and setup runs again.
- A host's `lock-seen` file outlives the lock: if the owner turns the lock
  off on purpose, every host alerts until the file is removed. That is
  wanted, as nobody should turn it off without knowing.
- A host whose state directory is lost while the lock is off writes no
  lock series. Other hosts still alert.
- Tailnet Lock is a feature of Tailscale's own. It belongs with the
  Tailscale modules, so a later move to another control plane, which the
  owner keeps open (DIRECTION.md), touches those modules and these rules
  only.
- The `tailscale-metrics` check runs the script against the real
  tailscaled's answer when logged out, and against samples of the answer
  with the lock on, signed and unsigned. The lock on a real tailnet was
  not run here.
