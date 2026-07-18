{ config, pkgs, ... }:

{
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = [ "systemd" "processes" ];
    port = 9100;
  };
}
