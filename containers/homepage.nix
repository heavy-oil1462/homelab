{ config, pkgs, ... }:

let
  domain = config.homelab.domain;
  cfg = config.homelab.homepage;
in
{
  imports = [ ../modules/options.nix ];

  users.users.homepage = {
    isSystemUser = true;
    group = "homepage";
  };
  users.groups.homepage = { };

  virtualisation.oci-containers.containers = {
    homepage = {
      image = "ghcr.io/gethomepage/homepage@sha256:a0b71c8e757298d02560186bab9fbe3fc2d375c523a62cc1019177b37e48aa28"; # :latest as of 2026-07-03
      autoStart = true;
      environment = {
        PUID = toString config.users.users.homepage.uid;
        PGID = toString config.users.groups.homepage.gid;
        HOMEPAGE_ALLOWED_HOSTS = "${domain},start.${domain},localhost,127.0.0.1";
      };
      extraOptions = [ "--no-healthcheck" ];
      volumes = [
        "${cfg.settingsFile}:/app/config/settings.yaml:ro"
        "${pkgs.writeText "services.yaml" (builtins.replaceStrings [ "__DOMAIN__" ] [ domain ] (builtins.readFile cfg.servicesFile))}:/app/config/services.yaml:ro"
      ];
    };
  };
}
