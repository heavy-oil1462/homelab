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

  virtualisation.oci-containers.containers.home-assistant = {
    image = "ghcr.io/home-assistant/home-assistant@sha256:aed891b8f801072302815b4b0fab5adb714182967e9d2e2d4a2be558241c73ad"; # :stable as of 2026-06-13
    autoStart = true;
    extraOptions = [
      "--network=host"
      "--cap-add=NET_RAW"
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
