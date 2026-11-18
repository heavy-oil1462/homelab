{ config, lib, pkgs, ... }:

{
  imports = [ ../modules/options.nix ];

  # Static uid so the container's user option has a value at eval time.
  # See "Static user ids" in the README for the allocation. A host that
  # already has a vaultwarden user keeps its uid (NixOS does not change it), so
  # such a host overrides these defaults with its existing uid and gid.
  users.users.vaultwarden = {
    isSystemUser = true;
    group = "vaultwarden";
    uid = lib.mkDefault 600;
  };
  users.groups.vaultwarden = {
    gid = lib.mkDefault 600;
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
      image = "docker.io/vaultwarden/server@sha256:4fe17f415f90087377d37c755e0ea3cf189dcc6794e49cdd2a9adbb4937d9e1f"; # 1.37.5, :latest as of 2026-11-18
      user = "${toString config.users.users.vaultwarden.uid}:${toString config.users.groups.vaultwarden.gid}";
      # docs/adr/0014-containers-run-unprivileged.md
      extraOptions = [
        "--security-opt=no-new-privileges"
        "--cap-drop=ALL"
      ];
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
