{ config, lib, pkgs, ... }:

# A freshly installed host joins the tailnet on its own when a Tailscale auth
# key is waiting in keyFile. The installer puts it there (nixos-anywhere
# --extra-files); use a one-off, pre-approved key carrying the host's tags.
# Servers allow SSH on the tailnet only and nobody has a console password, so
# without this a bare metal install cannot be reached at all.
#
# The key is deleted once the node runs, and without the file the unit is
# skipped, so hosts that are already logged in never touch it and a used key
# never leaves a failed unit at a later boot.
#
# The same goes for a node key that expires: the host drops off the tailnet
# and SSH with it. On a host with the observability agent, the
# tailscale-metrics unit writes the key's expiry and whether the node is
# online for the node exporter's textfile collector
# (modules/tailscale-metrics.sh), so a rule can alert weeks ahead.

let
  keyFile = "/var/lib/secrets/tailscale-authkey";
  textfileDir = config.homelab.observabilityAgent.textfileDirectory;
  metrics = pkgs.callPackage ./tailscale-metrics-script.nix { };
in
{
  imports = [ ./options.nix ];

  config = lib.mkMerge [
    {
      services.tailscale = {
        enable = true;
        extraUpFlags = [ "--ssh" ];
        authKeyFile = keyFile;
      };

      systemd.services.tailscaled-autoconnect = {
        unitConfig.ConditionPathExists = keyFile;
        serviceConfig.ExecStartPost = "${pkgs.coreutils}/bin/rm -f ${keyFile}";
      };
    }

    (lib.mkIf config.services.prometheus.exporters.node.enable {
      systemd.services.tailscale-metrics = {
        description = "Write the Tailscale key expiry and state for the node exporter";
        after = [ "tailscaled.service" ];
        path = [ config.services.tailscale.package ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${metrics}/bin/tailscale-metrics ${lib.escapeShellArg textfileDir}";
          # Root only to write into the textfile directory; it reads
          # tailscaled's status over its socket and nothing else.
          ProtectSystem = "strict";
          ReadWritePaths = [ textfileDir ];
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          PrivateNetwork = true;
          NoNewPrivileges = true;
          CapabilityBoundingSet = "";
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          RestrictAddressFamilies = [ "AF_UNIX" ];
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "@system-service" "~@privileged" ];
        };
      };

      # Every 5 minutes, the first 2 minutes after boot, when tailscaled has
      # had time to connect. Hourly would leave the node offline in the
      # metrics for up to an hour after a reboot, and "Tailscale down"
      # would alert on every one.
      systemd.timers.tailscale-metrics = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "5min";
        };
      };
    })
  ];
}
