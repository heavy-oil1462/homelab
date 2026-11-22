{ config, lib, ... }:

let
  cfg = config.homelab.network;
  ssh = config.services.openssh;

  ipv6 = lib.hasInfix ":";
  sshFrom4 = lib.filter (n: !ipv6 n) cfg.sshFrom;
  sshFrom6 = lib.filter ipv6 cfg.sshFrom;
  loopback = [ "127.0.0.1" "[::1]" "::1" "localhost" ];
in
{
  imports = [ ./options.nix ];

  config = lib.mkMerge [
    {
      networking.firewall = {
        enable = true;
        checkReversePath = lib.mkIf config.services.tailscale.enable "loose";
      };
    }

    (lib.mkIf (cfg.role == "server") {
      # SSH is tailnet-only. Deploys and admin SSH go over Tailscale (the bare
      # hostnames resolve to the tailnet IP) to sshd, since servers do not
      # run Tailscale SSH (docs/adr/0026-servers-ssh-through-sshd-only.md),
      # so the LAN no longer needs port 22. Console access via the hypervisor remains as a recovery path for
      # VMs if Tailscale is ever down. Bare metal hosts have no console login,
      # so they join the tailnet at install time (modules/tailscale.nix).
      # homelab.network.sshFrom adds break-glass access from the LAN below.
      networking.firewall.interfaces = {
        tailscale0.allowedTCPPorts = [ 22 ];
      };
    })

    # Break-glass SSH from the LAN for when Tailscale is down, keys only
    # (owner, question 01a2001c-d9ed, 2026-11-21;
    # docs/adr/0024-break-glass-ssh-from-the-lan.md).
    (lib.mkIf (cfg.sshFrom != [ ]) {
      assertions = [
        {
          assertion = lib.all (n: !(lib.hasSuffix "/0" n)) cfg.sshFrom;
          message = ''
            homelab.network.sshFrom has a network with prefix length 0
            (${lib.concatStringsSep ", " (lib.filter (lib.hasSuffix "/0") cfg.sshFrom)}),
            which opens SSH to every address. List the LAN's admin subnets.
          '';
        }
        {
          assertion = ssh.enable
            && (ssh.listenAddresses == [ ]
              || lib.any (a: !(lib.elem a.addr loopback)) ssh.listenAddresses);
          message = ''
            homelab.network.sshFrom is set, but sshd does not listen beyond
            loopback. Import the openssh module (the server role does), which
            listens on every address.
          '';
        }
        {
          assertion = ssh.settings.PasswordAuthentication == false
            && ssh.settings.KbdInteractiveAuthentication == false
            && ssh.settings.PermitRootLogin != "yes";
          message = ''
            homelab.network.sshFrom is set, so SSH from the LAN must take keys
            only: services.openssh.settings.PasswordAuthentication and
            KbdInteractiveAuthentication must be false and PermitRootLogin
            not "yes" (they are ${builtins.toJSON ssh.settings.PasswordAuthentication},
            ${builtins.toJSON ssh.settings.KbdInteractiveAuthentication} and
            ${builtins.toJSON ssh.settings.PermitRootLogin}).
          '';
        }
      ];

      # Rules appended to the nixos-fw chain, which the firewall flushes on
      # every start and reload and unhooks from INPUT on stop, so they need
      # no extraStopCommands. tailscale0 keeps its own rule above.
      networking.firewall.extraCommands = lib.mkIf (!config.networking.nftables.enable)
        (lib.concatMapStrings
          (n: "iptables -A nixos-fw ! -i tailscale0 -p tcp --dport 22 -s ${n} -j nixos-fw-accept\n")
          sshFrom4
        + lib.concatMapStrings
          (n: "ip6tables -A nixos-fw ! -i tailscale0 -p tcp --dport 22 -s ${n} -j nixos-fw-accept\n")
          sshFrom6);

      networking.firewall.extraInputRules = lib.mkIf config.networking.nftables.enable
        (lib.optionalString (sshFrom4 != [ ]) ''
          iifname != "tailscale0" ip saddr { ${lib.concatStringsSep ", " sshFrom4} } tcp dport 22 accept
        ''
        + lib.optionalString (sshFrom6 != [ ]) ''
          iifname != "tailscale0" ip6 saddr { ${lib.concatStringsSep ", " sshFrom6} } tcp dport 22 accept
        '');
    })

    (lib.mkIf (cfg.role == "workstation") {
      networking.firewall.trustedInterfaces = [ "virbr0" ];
    })

    # Per-host rules (service ports on specific LAN interfaces, htpc media
    # ports and similar) belong in the consumer's host files as plain
    # networking.firewall config; only role-level baselines live here.
  ];
}
