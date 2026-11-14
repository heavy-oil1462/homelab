{ config, pkgs, ... }:

# node_exporter on port 9100, with the systemd collector for unit states and
# the textfile collector for metrics other modules write as *.prom files into
# homelab.observabilityAgent.textfileDirectory (the backups module's last
# successful run per job). A writer replaces its file atomically (a temporary
# name without .prom, then a rename), so a scrape never reads half a file.

let
  textfileDir = config.homelab.observabilityAgent.textfileDirectory;
in
{
  imports = [ ./options.nix ];

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
