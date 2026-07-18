{ config, pkgs, ... }:

{
  imports = [ ../modules/options.nix ];

  users.users.vaultwarden = {
    isSystemUser = true;
    group = "vaultwarden";
  };
  users.groups.vaultwarden = { };

  systemd.tmpfiles.rules = [
    "d /var/lib/vaultwarden 0750 vaultwarden vaultwarden -"
  ];

  virtualisation.oci-containers.containers = {
    vaultwarden = {
      image = "docker.io/vaultwarden/server@sha256:d626d04934cd1192ad8ced1adb975099fca78cec33ab467d2d3c923cde7f3b0c"; # :latest as of 2026-06-13
      user = "${toString config.users.users.vaultwarden.uid}:${toString config.users.groups.vaultwarden.gid}";
      autoStart = true;
      volumes = [
        "/var/lib/vaultwarden:/data"
      ];
      environment = {
        # Keep registration closed so nobody reaching vault.<domain> can
        # self-register. To add a new account later, flip this to "true"
        # briefly, register, then flip back (or use the admin page gated by
        # an ADMIN_TOKEN).
        SIGNUPS_ALLOWED = "false";
        ROCKET_PORT = "80";
        DOMAIN = "https://vault.${config.homelab.domain}";
      };
    };
  };
}
