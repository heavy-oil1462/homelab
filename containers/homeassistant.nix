{ config, pkgs, ... }:

let
  domain = config.homelab.domain;
  cfg = config.homelab.homeassistant;

  # Render an HA config file with __DOMAIN__ substituted. The config is split
  # across several files (configuration.yaml pulls in automations.yaml and
  # scripts.yaml via !include), and each one is bind-mounted read-only.
  haFile = name: path: pkgs.writeText name (
    builtins.replaceStrings [ "__DOMAIN__" ] [ domain ] (builtins.readFile path)
  );
in
{
  imports = [ ../modules/options.nix ];

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
    image = "ghcr.io/home-assistant/home-assistant@sha256:aed891b8f801072302815b4b0fab5adb714182967e9d2e2d4a2be558241c73ad"; # :stable as of 2026-06-13
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
