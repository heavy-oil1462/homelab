{ config, lib, pkgs, ... }:

let
  domain = config.homelab.domain;
  cfg = config.homelab.homepage;
  uid = config.users.users.homepage.uid;
  gid = config.users.groups.homepage.gid;
in
{
  imports = [ ../modules/options.nix ];

  # Static uid so the container's user option has a value at eval time.
  # See "Static user ids" in the README for the allocation. The image has no
  # non-root user of its own: it starts as root and drops to PUID and PGID,
  # which were empty without a static uid, so it ran as root. Nothing on the
  # host is owned by this user, so a host that already has a homepage user
  # with another uid only gets NixOS's warning that it keeps it; setting
  # that uid and gid here silences it.
  users.users.homepage = {
    isSystemUser = true;
    group = "homepage";
    uid = lib.mkDefault 607;
  };
  users.groups.homepage = {
    gid = lib.mkDefault 607;
  };

  virtualisation.oci-containers.containers = {
    homepage = {
      image = "ghcr.io/gethomepage/homepage@sha256:019d8f063a7299e7c1c51ee4a70b692291809af3244894fbec2c2ac7d1f71b18"; # 2.8.0, :latest as of 2026-11-18
      autoStart = true;
      user = "${toString uid}:${toString gid}";
      environment = {
        # The same ids as the user above, so the entrypoint finds
        # /app/config owned by them and leaves it alone. It cannot re-own
        # /app/.next, says so, and goes on; not being root, it runs
        # Homepage as it is.
        PUID = toString uid;
        PGID = toString gid;
        HOMEPAGE_ALLOWED_HOSTS = "${domain},start.${domain},localhost,127.0.0.1";
      };
      extraOptions = [
        "--no-healthcheck"
        "--security-opt=no-new-privileges"
        "--cap-drop=ALL"
      ];
      # Homepage writes the config files it is not given (bookmarks,
      # widgets, custom.css, ...) and its logs to /app/config, and Next.js
      # its cache to /app/.next/cache; the image's are root's and uid 1000's.
      # :U hands each volume to the homepage user on every start. Neither
      # holds anything worth a backup.
      volumes = [
        "homepage-config:/app/config:U"
        "homepage-cache:/app/.next/cache:U"
        "${cfg.settingsFile}:/app/config/settings.yaml:ro"
        "${pkgs.writeText "services.yaml" (builtins.replaceStrings [ "__DOMAIN__" ] [ domain ] (builtins.readFile cfg.servicesFile))}:/app/config/services.yaml:ro"
      ];
    };
  };
}
