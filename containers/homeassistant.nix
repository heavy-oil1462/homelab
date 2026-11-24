{ config, lib, pkgs, ... }:

let
  domain = config.homelab.domain;
  cfg = config.homelab.homeassistant;

  # Render an HA config file with __DOMAIN__ substituted. The config is split
  # across several files (configuration.yaml pulls in automations.yaml and
  # scripts.yaml via !include), and each one is bind-mounted read-only.
  haFile = name: path: pkgs.writeText name (
    builtins.replaceStrings [ "__DOMAIN__" ] [ domain ] (builtins.readFile path)
  );

  # The reverse proxy settings, merged into .storage/http before Home
  # Assistant starts, which applies the stored config without a trial
  # (docs/adr/0022-home-assistant-http-settings-after-the-yaml.md).
  httpTool = pkgs.callPackage ../modules/homeassistant-http.nix { };
  httpSettings = pkgs.writeText "homeassistant-http.json" (builtins.toJSON {
    use_x_forwarded_for = cfg.trustedProxies != [ ];
    trusted_proxies = cfg.trustedProxies;
  });
  yamlHasHttp = lib.any (lib.hasPrefix "http:")
    (lib.splitString "\n" (builtins.readFile cfg.configurationFile));
in
{
  imports = [ ../modules/options.nix ];

  assertions = lib.optional (cfg.trustedProxies != null) {
    assertion = !yamlHasHttp;
    message = ''
      homelab.homeassistant.trustedProxies sets Home Assistant's reverse
      proxy settings in .storage/http; remove the http: block from
      homelab.homeassistant.configurationFile, which Home Assistant would
      otherwise take over as a trial or ignore.
    '';
  };

  # Wanted by the container's unit, so it runs on every start of the
  # container, before it. A failure leaves the stored settings as they were
  # and Home Assistant starts with them; the unit shows as failed.
  systemd.services.home-assistant-http = lib.mkIf (cfg.trustedProxies != null) {
    description = "Home Assistant's reverse proxy settings in .storage/http";
    wantedBy = [ "podman-home-assistant.service" ];
    before = [ "podman-home-assistant.service" ];
    path = [ config.virtualisation.podman.package ];
    serviceConfig.Type = "oneshot";
    script = ''
      podman volume exists homeassistant-config || podman volume create homeassistant-config
      dir=$(podman volume inspect --format '{{.Mountpoint}}' homeassistant-config)
      exec ${httpTool}/bin/homeassistant-http "$dir/.storage/http" ${httpSettings}
    '';
  };
  # A change of the settings restarts the container, and with it the unit
  # above; Home Assistant reads .storage/http only when it starts.
  systemd.services.podman-home-assistant.restartTriggers =
    lib.mkIf (cfg.trustedProxies != null) [ httpTool httpSettings ];

  # The secrets.yaml that !secret reads, provisioned out of band at
  # /var/lib/secrets/homeassistant-secrets.yaml, root:root 0400; the
  # container runs as root. The f rule creates it empty if it is missing, so
  # podman never makes a directory at the mount's source. Empty, Home
  # Assistant starts, but a config that uses !secret does not load until the
  # secret is there; authentication is HA's own and does not depend on it.
  systemd.tmpfiles.rules = [
    "f /var/lib/secrets/homeassistant-secrets.yaml 0400 root root -"
  ];

  virtualisation.oci-containers.containers.home-assistant = {
    # Upgrading from 2026.6 or earlier migrates /config/.storage one way
    # (device registry 3.4); going back means restoring .storage from a
    # backup (README).
    image = "ghcr.io/home-assistant/home-assistant@sha256:24e541ddae5818bf8eb27898b9ba00d0c344a655aa5097e9e9bd4b19356be847"; # 2026.11.3, :stable as of 2026-11-23
    autoStart = true;
    # Runs as root: the image's s6-overlay init and Home Assistant itself
    # expect root, and with host networking it reaches the LAN's devices
    # directly (discovery, raw sockets). Home Assistant only supports this
    # setup. It is on the root allowlist in tests/container-hardening.nix
    # (docs/adr/0014-containers-run-unprivileged.md). The capabilities are
    # podman's defaults that it can use, plus NET_RAW.
    extraOptions = [
      "--network=host"
      "--security-opt=no-new-privileges"
      "--cap-drop=ALL"
      # Ping, DHCP and other discovery on the LAN use raw sockets.
      "--cap-add=NET_RAW"
      # Integrations that listen below 1024 on the host's network, such as
      # emulated_hue on 80.
      "--cap-add=NET_BIND_SERVICE"
      # s6-overlay's init and Home Assistant's installs of integration
      # requirements into /config set owners and modes as root, on files
      # that are not always root's.
      "--cap-add=CHOWN"
      "--cap-add=DAC_OVERRIDE"
      "--cap-add=FOWNER"
      # s6-overlay runs its services under a user it switches to, and
      # signals them on stop.
      "--cap-add=SETUID"
      "--cap-add=SETGID"
      "--cap-add=KILL"
    ];

    volumes = [
      "homeassistant-config:/config"
      "${haFile "configuration.yaml" cfg.configurationFile}:/config/configuration.yaml:ro"
      "${haFile "automations.yaml" cfg.automationsFile}:/config/automations.yaml:ro"
      "${haFile "scripts.yaml" cfg.scriptsFile}:/config/scripts.yaml:ro"
      "/var/lib/secrets/homeassistant-secrets.yaml:/config/secrets.yaml:ro"
    ];
  };
}
