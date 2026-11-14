# Example server host wiring most of the library together. Used by the
# flake's checks to prove the module set evaluates standalone; copy it as a
# starting point for your own host. All values here are placeholders and all
# IPs are from the RFC 5737 documentation ranges.
{ config, lib, pkgs, ... }:

{
  imports = [
    ../modules/common.nix
    ../roles/server.nix
    ../modules/acme.nix
    ../modules/backups.nix
    ../modules/tsidp.nix
    ../modules/nvidia.nix
    ../containers/reverse-proxy.nix
    ../containers/observability.nix
    ../containers/vaultwarden.nix
    ../containers/homepage.nix
    ../containers/homeassistant.nix
    ../containers/nvr.nix
    ../containers/nextcloud.nix
    ../containers/unifi.nix
    ../containers/registry.nix
    ../containers/forgejo.nix
  ];

  homelab = {
    username = "alice";
    domain = "home.example.com";
    adminKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderPlaceholderPlaceholder0000000000A alice@example"
    ];
    tailnetIp = "100.64.0.1";
    # GPU load for the GPU dashboard, from the NVIDIA driver the nvidia module
    # installs. Prometheus scrapes it on port 9835 over the tailnet, through
    # observability.nvidiaGpuTargets below.
    observabilityAgent.nvidiaGpu.enable = true;
    backups = {
      resticRepo = "rclone:remote:homelab-backup";
      # Forgejo's data dir is /var/lib/gitea in the container, and the
      # rootless image keeps the SQLite database at data/gitea.db (not forgejo.db).
      jobs.forgejo = {
        paths = [ "/var/lib/forgejo" ];
        sqliteDatabases = [ "/var/lib/forgejo/data/gitea.db" ];
      };
      # tsidp's node and signing keys and its registered clients.
      jobs.tsidp.paths = [ config.homelab.tsidp.stateDir ];
    };

    # Forgejo and Grafana sign in through tsidp, at
    # https://idp.<tailnet>.ts.net. The auth key, and each client's id and
    # secret, are files under /var/lib/secrets at their default paths.
    tsidp.enable = true;

    reverseProxy = {
      caddyfile = ./assets/caddy/Caddyfile;
      notFoundPage = ./assets/caddy/404.html;
      tailscaleIdentity.enable = true;
    };
    observability = {
      prometheusConfig = ./assets/prometheus.yml;
      lokiConfig = ./assets/loki-config.yaml;
      alertingConfig = ./assets/grafana-alerting.yaml;
      dashboardsDir = ./assets/dashboards;
      # Sites behind Caddy, probed for availability and certificate expiry.
      # Each must answer 2xx (Grafana's /api/health does; Loki's / is a 404).
      probeTargets = [
        "https://start.home.example.com"
        "https://vault.home.example.com"
        "https://status.home.example.com/api/health"
      ];
      # The NVIDIA GPU exporters of hosts with
      # homelab.observabilityAgent.nvidiaGpu.enable, by tailnet address.
      nvidiaGpuTargets = [ "192.0.2.20:9835" ];
      grafanaOidc = {
        enable = true;
        issuer = "https://idp.tailnet.invalid";
        admins = [ "alice@example.com" "alice@github" ];
      };
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
    forgejo = {
      extraEnvironment = {
        FORGEJO__repository__DEFAULT_BRANCH = "main";
      };
      admin = {
        name = "alice";
        email = "alice@example.com";
      };
      oidc = {
        enable = true;
        issuer = "https://idp.tailnet.invalid";
      };
    };
  };

  networking.hostName = "example-server";

  # The NVIDIA driver from the nvidia module is unfree; allow exactly its
  # packages.
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [
      "nvidia-x11"
      "nvidia-settings"
    ];

  boot.loader.grub.devices = [ "nodev" ];
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  system.stateVersion = "25.05";
}
