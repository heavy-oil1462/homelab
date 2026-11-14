{ config, lib, pkgs, ... }:

# node_exporter on port 9100, with the systemd collector for unit states and
# the textfile collector for metrics other modules write as *.prom files into
# homelab.observabilityAgent.textfileDirectory (the backups module's last
# successful run per job). A writer replaces its file atomically (a temporary
# name without .prom, then a rename), so a scrape never reads half a file.
#
# With homelab.observabilityAgent.nvidiaGpu.enable, also nixpkgs' NVIDIA GPU
# exporter on port 9835, reachable over the tailnet only. It runs the
# driver's nvidia-smi, so the host needs the nvidia module.

let
  cfg = config.homelab.observabilityAgent;
  textfileDir = cfg.textfileDirectory;
in
{
  imports = [ ./options.nix ];

  config = lib.mkMerge [
    {
      services.prometheus.exporters.node = {
        enable = true;
        enabledCollectors = [ "systemd" "processes" ];
        extraFlags = [ "--collector.textfile.directory=${textfileDir}" ];
        port = 9100;
      };

      systemd.tmpfiles.rules = [
        "d ${textfileDir} 0755 root root -"
      ];
    }

    (lib.mkIf cfg.nvidiaGpu.enable {
      assertions = [
        {
          assertion = config.hardware.nvidia.enabled;
          message = "homelab.observabilityAgent.nvidiaGpu reads nvidia-smi from the NVIDIA driver; import the nvidia module.";
        }
      ];

      services.prometheus.exporters.nvidia-gpu = {
        enable = true;
        port = 9835;
      };

      networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 9835 ];
    })
  ];
}
