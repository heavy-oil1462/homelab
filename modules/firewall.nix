{ config, lib, ... }:

let
  cfg = config.homelab.network;
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
      # hostnames resolve to the tailnet IP), so the LAN no longer needs port
      # 22. Console access via the hypervisor remains as a recovery path if
      # Tailscale is ever down.
      networking.firewall.interfaces = {
        tailscale0.allowedTCPPorts = [ 22 ];
      };
    })

    (lib.mkIf (cfg.role == "workstation") {
      networking.firewall.trustedInterfaces = [ "virbr0" ];
    })

    # Per-host rules (service ports on specific LAN interfaces, htpc media
    # ports and similar) belong in the consumer's host files as plain
    # networking.firewall config; only role-level baselines live here.
  ];
}
