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
    ../modules/vulnerability-scan.nix
    ../modules/pocket-id.nix
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
    # Root logs in over SSH with certificates signed by this CA, which a
    # fleet update signs once per run (modules/deploy-ca.nix); Forgejo
    # trusts it too, below.
    deployCaKeys = [
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tPlaceholderPlaceholderPlaceholder00000000000 deploy-ca@example"
    ];
    tailnetIp = "100.64.0.1";
    # Break-glass SSH from the LAN for when Tailscale is down, keys only
    # (docs/adr/0024-break-glass-ssh-from-the-lan.md). Left empty here; the
    # break-glass-ssh check evaluates this host with it set:
    # network.sshFrom = [ "192.0.2.0/24" ];
    # No Tailscale SSH: sshd is the server's one SSH gate, and the
    # tailscale-ssh-off unit turns Tailscale SSH off on a node that still
    # runs it (docs/adr/0026-servers-ssh-through-sshd-only.md). The server
    # role's default; workstations keep it.
    tailscale.ssh = false;
    # GPU load for the GPU dashboard, from the NVIDIA driver the nvidia module
    # installs. Prometheus scrapes it on port 9835 over the tailnet, through
    # observability.nvidiaGpuTargets below.
    observabilityAgent.nvidiaGpu.enable = true;
    # Frigate gets the GPU through the container toolkit's CDI spec (podman's
    # --gpus), so it checks the spec before every start (docs/nvidia.md).
    nvidia.cdiCheck.units = [ "podman-frigate" ];
    backups = {
      resticRepo = "rclone:remote:homelab-backup";
      # Forgejo's data dir is /var/lib/gitea in the container, and the
      # rootless image keeps the SQLite database at data/gitea.db (not forgejo.db).
      jobs.forgejo = {
        paths = [ "/var/lib/forgejo" ];
        sqliteDatabases = [ "/var/lib/forgejo/data/gitea.db" ];
      };
      # Pocket ID's users, passkeys, clients and encrypted signing keys,
      # with a consistent copy of its database. The encryption key in
      # /var/lib/secrets is not in the backup; keep it with the restic
      # password.
      jobs.pocket-id = {
        paths = [ config.homelab.pocketId.dataDir ];
        sqliteDatabases = [ config.homelab.pocketId.databaseFile ];
      };
    };

    # Trivy scans the images of every container below once a day, from
    # podman's storage; the counts reach Prometheus through the node
    # exporter, and the reports stay in /var/lib/vulnerability-scan.
    vulnerabilityScan.enable = true;

    # Pocket ID at https://id.home.example.com, the site's OpenID Connect
    # provider (docs/adr/0018-pocket-id-is-the-oidc-provider.md). Forgejo
    # and Grafana sign in through it: a service with OIDC turned on below
    # declares its client here, and pocket-id-clients writes the client's
    # id and secret files and restarts the units that read them. Only
    # alice's tailnet login reaches its first-admin setup. A sign-in lasts
    # as long as the login gate's, 24h, so the passkey is needed once a
    # day.
    pocketId = {
      enable = true;
      setupLogins = [ "alice@github" ];
      sessionDuration = 1440;
      clients = lib.mkMerge [
        (lib.mkIf config.homelab.forgejo.oidc.enable {
          forgejo = {
            displayName = "Forgejo";
            redirectUris = [ "https://git.${config.homelab.domain}/user/oauth2/pocket-id/callback" ];
            idFile = config.homelab.forgejo.oidc.clientIdFile;
            secretFile = config.homelab.forgejo.oidc.clientSecretFile;
            units = [ "forgejo-oidc.service" ];
          };
        })
        (lib.mkIf config.homelab.observability.grafanaOidc.enable {
          grafana = {
            displayName = "Grafana";
            redirectUris = [ "https://status.${config.homelab.domain}/login/generic_oauth" ];
            pkce = true;
            idFile = config.homelab.observability.grafanaOidc.clientIdFile;
            secretFile = config.homelab.observability.grafanaOidc.clientSecretFile;
            owner = "grafana";
            units = [ "podman-grafana.service" ];
          };
        })
        {
          # The OIDC gate's client, below. Its callback is /oauth2/callback
          # on whichever gated site the sign-in started from. Systemd hands
          # the secret to oauth2-proxy, so the files stay root's.
          ${config.homelab.reverseProxy.oidcGate.clientId} = {
            displayName = "Sites behind the proxy";
            redirectUris = [ "https://*.${config.homelab.domain}/oauth2/callback" ];
            pkce = true;
            secretFile = config.homelab.reverseProxy.oidcGate.clientSecretFile;
            units = [ "oauth2-proxy.service" ];
          };
        }
      ];
    };

    reverseProxy = {
      caddyfile = ./assets/caddy/Caddyfile;
      notFoundPage = ./assets/caddy/404.html;
      tailscaleIdentity.enable = true;
      # A login gate for sites that cannot sign anyone in themselves: the
      # camera's own pages in the example Caddyfile import oidc_owner_only,
      # so only alice, signed in at Pocket ID, reaches them
      # (docs/adr/0020-oidc-login-gate-at-the-proxy.md).
      oidcGate = {
        enable = true;
        owners = [ "alice" ];
      };
    };
    observability = {
      prometheusConfig = ./assets/prometheus.yml;
      lokiConfig = ./assets/loki-config.yaml;
      alertingConfig = ./assets/grafana-alerting.yaml;
      # The library's dashboards, read-only in the Homelab folder.
      dashboardsDir = ./assets/dashboards;
      # The owner's own dashboards, synced both ways with a Forgejo
      # repository through Grafana's Git Sync. The Forgejo token is
      # /var/lib/secrets/grafana-git-sync-token; the unit makes Grafana's
      # own, /var/lib/secrets/grafana-git-sync-api-token.
      grafanaGitSync = {
        enable = true;
        url = "https://git.example.com/org/dashboards.git";
        # Committed once to the repository while it has no commits.
        seed = ./assets/git-sync-seed;
      };
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
      # The router and the UniFi controller, through exporters on this host
      # (docs/opnsense.md, docs/unifi.md). Their credentials are
      # /var/lib/secrets/opnsense-exporter.env and
      # /var/lib/secrets/unpoller.env.
      scrape.opnsense = {
        enable = true;
        name = "router";
        address = "192.0.2.1";
        # OPNsense's self-signed certificate, which names 192.0.2.1.
        caFile = "/var/lib/secrets/opnsense-ca.pem";
      };
      scrape.unifi = {
        enable = true;
        url = "https://192.0.2.2:11443";
        # UniFi OS's self-signed certificate, pinned.
        certFile = "/var/lib/secrets/unifi-cert.pem";
      };
      grafanaOidc = {
        enable = true;
        # The emails of the admins' Pocket ID accounts.
        admins = [ "alice@example.com" ];
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
      # The caddy container, as Home Assistant on the host network sees it
      # connect. Written into .storage/http before HA starts
      # (docs/adr/0022-home-assistant-http-settings-after-the-yaml.md).
      trustedProxies = [ "${config.homelab.reverseProxy.address}/32" ];
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
      # The fleet run's certificate, with the principals root and alice,
      # also fetches from Forgejo once the Forgejo user alice lists alice as a principal.
      trustDeployCa = true;
      oidc.enable = true;
    };
  };

  networking.hostName = "example-server";

  # The CDI spec that hands the GPU to containers, for Frigate.
  hardware.nvidia-container-toolkit.enable = true;

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
