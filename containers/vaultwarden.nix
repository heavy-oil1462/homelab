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
      image = "docker.io/vaultwarden/server@sha256:ebdfe70701c60ac0c28c697e787cea767d7972940b786037b29fe0d507f821e8"; # 1.37.1, :latest as of 2026-08-04
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
