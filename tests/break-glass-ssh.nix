# Break-glass SSH from the LAN with homelab.network.sshFrom
# (docs/adr/0024-break-glass-ssh-from-the-lan.md). Pure evaluation of the
# example server's config:
#
# - on: with sshFrom set to documentation ranges, the iptables firewall
#   accepts TCP 22 from each of them on every interface but tailscale0,
#   tailscale0 keeps its rule, and sshd listens on every address and takes
#   keys only;
# - nftables: the same host on the nftables firewall gets the rules as
#   input rules instead;
# - off: with sshFrom empty, no rule is added and keyboard-interactive is
#   left as the deploy CA sets it;
# - password auth or keyboard-interactive on, PermitRootLogin "yes", sshd
#   on loopback only, and 0.0.0.0/0 or ::/0 fail the build.
#
# It cannot open a connection: that needs the firewall loaded in a VM,
# which the checks do not start.
{ lib, writeText, on, nftables, off, broken }:

let
  # What the host's extraCommands carry beyond those of the example server
  # without sshFrom (the NAT module's cleanup, for one).
  added = cfg: lib.removePrefix "\n"
    (lib.removePrefix off.networking.firewall.extraCommands cfg.networking.firewall.extraCommands);
  sshRule = cfg: lib.hasInfix "--dport 22" cfg.networking.firewall.extraCommands;
  failed = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);

  expect = what: want: have:
    lib.optional (want != have) "${what}: expected ${builtins.toJSON want}, got ${builtins.toJSON have}";
  expectFailure = what: needle: cfg:
    lib.optional (!(lib.any (lib.hasInfix needle) (failed cfg)))
      "${what}: no failed assertion with ${builtins.toJSON needle}, got ${builtins.toJSON (failed cfg)}";

  problems =
    expect "on: homelab.network.sshFrom" [ "192.0.2.0/24" "2001:db8::/64" ] on.homelab.network.sshFrom
    ++ expect "on: iptables rules, after the host's own" ''
      iptables -A nixos-fw ! -i tailscale0 -p tcp --dport 22 -s 192.0.2.0/24 -j nixos-fw-accept
      ip6tables -A nixos-fw ! -i tailscale0 -p tcp --dport 22 -s 2001:db8::/64 -j nixos-fw-accept
    ''
      (added on)
    ++ expect "on: nftables input rules, unused on iptables" "" on.networking.firewall.extraInputRules
    ++ expect "on: tailscale0 takes SSH" true (lib.elem 22 on.networking.firewall.interfaces.tailscale0.allowedTCPPorts)
    ++ expect "on: ports open on every interface" [ ] on.networking.firewall.allowedTCPPorts
    ++ expect "on: sshd's listen addresses" [ ] on.services.openssh.listenAddresses
    ++ expect "on: PasswordAuthentication" false on.services.openssh.settings.PasswordAuthentication
    ++ expect "on: KbdInteractiveAuthentication" false on.services.openssh.settings.KbdInteractiveAuthentication
    ++ expect "on: failed assertions" [ ] (failed on)
    ++ expect "nftables: input rules" ''
      iifname != "tailscale0" ip saddr { 192.0.2.0/24 } tcp dport 22 accept
      iifname != "tailscale0" ip6 saddr { 2001:db8::/64 } tcp dport 22 accept
    ''
      nftables.networking.firewall.extraInputRules
    ++ expect "nftables: iptables rules, unused on nftables" false (sshRule nftables)
    ++ expect "nftables: failed assertions" [ ] (failed nftables)
    ++ expect "off: homelab.network.sshFrom" [ ] off.homelab.network.sshFrom
    ++ expect "off: an iptables rule for port 22" false (sshRule off)
    ++ expect "off: nftables input rules" "" off.networking.firewall.extraInputRules
    ++ expectFailure "passwordAuth" "keys" broken.passwordAuth
    ++ expectFailure "kbdInteractive" "keys" broken.kbdInteractive
    ++ expectFailure "rootLogin" "keys" broken.rootLogin
    ++ expectFailure "loopbackOnly" "beyond" broken.loopbackOnly
    ++ expectFailure "everyone" "prefix length 0" broken.everyone
    ++ expectFailure "everyone6" "prefix length 0" broken.everyone6;
in
if problems == [ ] then
  writeText "break-glass-ssh" (added on)
else
  throw "Break-glass SSH breaks docs/adr/0024-break-glass-ssh-from-the-lan.md:\n${lib.concatStringsSep "\n" problems}"
