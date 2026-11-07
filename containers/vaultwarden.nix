{ config, lib, pkgs, ... }:

{
  imports = [ ../modules/options.nix ];

  # Static uid so the container's user option has a value at eval time.
  # See "Static user ids" in the README for the allocation. A host that
  # already has a vaultwarden user with another uid keeps that uid (NixOS does
  # not change it), so delete the old user before the first deploy of this.
  users.users.vaultwarden = {
    isSystemUser = true;
    group = "vaultwarden";
    uid = 600;
  };
  users.groups.vaultwarden = {
    gid = 600;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/vaultwarden 0750 vaultwarden vaultwarden -"
  ];

  # Hand everything in the data dir to the service user before each start.
  # Files restored from a backup, or left by an older version of this module
  # that ran the container as root, would otherwise be unwritable for it.
  systemd.services.podman-vaultwarden.serviceConfig.ExecStartPre = lib.mkBefore [
    "${pkgs.coreutils}/bin/chown -R vaultwarden:vaultwarden /var/lib/vaultwarden"
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
        # Above 1024: an unprivileged process cannot bind port 80.
        ROCKET_PORT = "8080";
        DOMAIN = "https://vault.${config.homelab.domain}";
      };
    };
  };
}
