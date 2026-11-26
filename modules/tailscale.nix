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
# tailscale-metrics unit writes the key's expiry, whether the node is
# online and its Tailnet Lock state for the node exporter's textfile
# collector (modules/tailscale-metrics.sh), so a rule can alert weeks ahead,
# and when the lock goes off or stops trusting the node
# (docs/adr/0028-tailnet-lock-decides-which-nodes-join.md).
#
# Servers do not run Tailscale SSH (homelab.tailscale.ssh): sshd with the
# owner's keys and the deploy CA is their one SSH gate
# (docs/adr/0026-servers-ssh-through-sshd-only.md).

let
  cfg = config.homelab;
  keyFile = "/var/lib/secrets/tailscale-authkey";
  textfileDir = cfg.observabilityAgent.textfileDirectory;
  metrics = pkgs.callPackage ./tailscale-metrics-script.nix { };
  sshOff = pkgs.callPackage ./tailscale-ssh-off-script.nix { };

  # The units below talk to tailscaled over its socket and nothing else.
  # tailscale-ssh-off runs as root because `tailscale set` needs it.
  hardening = {
    ProtectSystem = "strict";
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

  sshd = config.services.openssh;
  firewall = config.networking.firewall;
  loopback = [ "127.0.0.1" "[::1]" "::1" "localhost" ];
  tailnetPorts = firewall.allowedTCPPorts
    ++ (firewall.interfaces.tailscale0.allowedTCPPorts or [ ]);
  sshdOnTailnet = sshd.enable
    && (sshd.listenAddresses == [ ]
      || lib.any (a: !(lib.elem a.addr loopback)) sshd.listenAddresses)
    && (!firewall.enable
      || lib.elem "tailscale0" firewall.trustedInterfaces
      || lib.any (p: lib.elem p tailnetPorts) sshd.ports);
in
{
  imports = [ ./options.nix ];

  config = lib.mkMerge [
    {
      services.tailscale = {
        enable = true;
        # Only at the node's first `tailscale up`; tailscale-ssh-off below
        # turns it off on a node that already runs it.
        extraUpFlags = lib.optional cfg.tailscale.ssh "--ssh";
        authKeyFile = keyFile;
      };

      systemd.services.tailscaled-autoconnect = {
        unitConfig.ConditionPathExists = keyFile;
        serviceConfig.ExecStartPost = "${pkgs.coreutils}/bin/rm -f ${keyFile}";
      };
    }

    (lib.mkIf (!cfg.tailscale.ssh) {
      assertions = [{
        assertion = cfg.network.role != "server" || sshdOnTailnet;
        message = ''
          homelab.tailscale.ssh is off on this server, so sshd is its only
          SSH, but sshd is off, listens on loopback only, or its port is not
          open on tailscale0. Import the openssh module and the server role,
          which do all three.
        '';
      }];

      # Turns Tailscale SSH off on a node that runs it, when nobody has used
      # it for 10 minutes. Turning it off resets every open Tailscale SSH
      # connection, so a deploy over it that switched this host must be done
      # first: it holds a session through the switch and the checks after.
      # Type exec, so the switch that adds it, and boot, do not wait for it;
      # a oneshot would hold the switch until the deploy's session ended,
      # which waits for the switch. The next deploy reaches sshd on port 22
      # over the tailnet, which tailscale0 allows.
      systemd.services.tailscale-ssh-off = {
        description = "Turn Tailscale SSH off once no session is open";
        after = [ "tailscaled.service" "tailscaled-autoconnect.service" ];
        wants = [ "tailscaled.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [ config.services.tailscale.package ];
        serviceConfig = {
          Type = "exec";
          ExecStart = "${sshOff}/bin/tailscale-ssh-off 15 600";
        } // hardening;
      };
    })

    (lib.mkIf config.services.prometheus.exporters.node.enable {
      systemd.services.tailscale-metrics = {
        description = "Write the Tailscale key expiry, state and Tailnet Lock for the node exporter";
        after = [ "tailscaled.service" ];
        path = [ config.services.tailscale.package ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${metrics}/bin/tailscale-metrics ${lib.escapeShellArg textfileDir} /var/lib/tailscale-metrics";
          # Root only to write into the textfile directory; it reads
          # tailscaled's status over its socket and nothing else. The state
          # directory remembers whether the lock was ever on.
          ReadWritePaths = [ textfileDir ];
          StateDirectory = "tailscale-metrics";
        } // hardening;
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
