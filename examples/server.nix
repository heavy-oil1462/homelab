# Example server host wiring most of the library together. Used by the
# flake's checks to prove the module set evaluates standalone; copy it as a
# starting point for your own host. All values here are placeholders and all
# IPs are from the RFC 5737 documentation ranges.
{ config, pkgs, ... }:

{
  imports = [
    ../modules/common.nix
    ../roles/server.nix
    ../modules/acme.nix
    ../modules/backups.nix
    ../containers/reverse-proxy.nix
    ../containers/observability.nix
    ../containers/vaultwarden.nix
    ../containers/homepage.nix
    ../containers/homeassistant.nix
    ../containers/nvr.nix
    ../containers/nextcloud.nix
  ];

  homelab = {
    username = "alice";
    domain = "home.example.com";
    adminKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderPlaceholderPlaceholder0000000000A alice@example"
    ];
    tailnetIp = "100.64.0.1";
    backups.resticRepo = "rclone:remote:homelab-backup";

    reverseProxy = {
      caddyfile = ./assets/caddy/Caddyfile;
      notFoundPage = ./assets/caddy/404.html;
    };
    observability = {
      prometheusConfig = ./assets/prometheus.yml;
      lokiConfig = ./assets/loki-config.yaml;
      alertingConfig = ./assets/grafana-alerting.yaml;
      dashboardsDir = ./assets/dashboards;
    };
    homepage = {
      settingsFile = ./assets/homepage/settings.yaml;
      servicesFile = ./assets/homepage/services.yaml;
    };
    homeassistant = {
      configurationFile = ./assets/homeassistant/configuration.yaml;
      automationsFile = ./assets/homeassistant/automations.yaml;
      scriptsFile = ./assets/homeassistant/scripts.yaml;
    };
    nvr.configFile = ./assets/frigate.yaml;
  };

  networking.hostName = "example-server";

  boot.loader.grub.devices = [ "nodev" ];
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  system.stateVersion = "25.05";
}
