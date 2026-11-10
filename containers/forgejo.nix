{ config, lib, ... }:

# Forgejo, the git forge, as git.<domain>. The web UI and the API go through
# the reverse proxy, for example:
#
#   git.__DOMAIN__:443 {
#       import site_tls
#       reverse_proxy forgejo:3000
#   }
#
# Git over SSH goes to Forgejo's built in SSH server, published on
# homelab.forgejo.sshAddress (the tailnet address by default) at
# homelab.forgejo.sshPort (2222 by default). Clone URLs read
# ssh://git@git.<domain>:2222/<owner>/<repo>.git.
#
# Data, the SQLite database, repositories and the generated app.ini live in
# /var/lib/forgejo. Registration is closed; create the first admin by hand
# after the first start:
#
#   podman exec forgejo forgejo admin user create --admin \
#     --username <name> --email <address> --random-password
#
# Forgejo Actions is enabled; runners are registered separately.
#
# The secret key is a file provisioned out of band, never committed:
#
#   openssl rand -hex 32 > /var/lib/secrets/forgejo-secret-key
#   chown forgejo:forgejo /var/lib/secrets/forgejo-secret-key
#   chmod 0400 /var/lib/secrets/forgejo-secret-key
#
# Forgejo refuses to start while the file is empty, so it never comes up
# with the well known default key. It does not make a key of its own: with
# INSTALL_LOCK and no key, 17.0.1 writes INTERNAL_TOKEN and the oauth2
# JWT_SECRET into app.ini but leaves SECRET_KEY empty and uses the default
# compiled into it.

let
  domain = config.homelab.domain;
  cfg = config.homelab.forgejo;
  sshPort = toString cfg.sshPort;
  uid = config.users.users.forgejo.uid;
  gid = config.users.groups.forgejo.gid;
in
{
  imports = [ ../modules/options.nix ];

  # Static uid so the container's user option has a value at eval time.
  # See "Static user ids" in the README for the allocation. A host that
  # already has a forgejo user keeps its uid (NixOS does not change it), so
  # such a host overrides these defaults with its existing uid and gid.
  users.users.forgejo = {
    isSystemUser = true;
    group = "forgejo";
    uid = lib.mkDefault 602;
  };
  users.groups.forgejo = {
    gid = lib.mkDefault 602;
  };

  assertions = [{
    assertion = cfg.sshAddress != null;
    message = "containers/forgejo.nix publishes SSH on homelab.forgejo.sshAddress (homelab.tailnetIp by default), which is unset.";
  }];

  # The f rule creates an empty file if none exists, so podman never makes a
  # directory at the mount's source; it does not touch an existing file.
  systemd.tmpfiles.rules = [
    "d /var/lib/forgejo 0750 forgejo forgejo -"
    "f /var/lib/secrets/forgejo-secret-key 0400 forgejo forgejo -"
  ];

  virtualisation.oci-containers.containers.forgejo = {
    image = "codeberg.org/forgejo/forgejo@sha256:5ef02fbcf22beef56b8c844952ffad58cfe177b6f98e46e6abb5df90b88dc8d3"; # 17.0.1-rootless, :17-rootless as of 2026-11-09
    autoStart = true;
    user = "${toString uid}:${toString gid}";
    # Only SSH is published, and only on sshAddress; HTTP stays on the podman
    # network behind Caddy.
    ports = [ "${toString cfg.sshAddress}:${sshPort}:${sshPort}" ];
    volumes = [
      "/var/lib/forgejo:/var/lib/gitea"
      "/var/lib/secrets/forgejo-secret-key:/etc/forgejo/secret-key:ro"
    ];
    environment = {
      # The image writes RUN_USER from USER into app.ini on the first start,
      # and Forgejo refuses to run as anyone else. podman names the
      # container's user after the host user with that uid, forgejo.
      USER = "forgejo";

      FORGEJO__database__DB_TYPE = "sqlite3";

      FORGEJO__server__DOMAIN = "git.${domain}";
      FORGEJO__server__ROOT_URL = "https://git.${domain}/";
      FORGEJO__server__HTTP_PORT = "3000";
      FORGEJO__server__SSH_DOMAIN = "git.${domain}";
      FORGEJO__server__SSH_PORT = sshPort;
      FORGEJO__server__SSH_LISTEN_PORT = sshPort;
      # Clone URLs use git@; the built in server accepts only this user.
      FORGEJO__server__BUILTIN_SSH_SERVER_USER = "git";

      FORGEJO__security__INSTALL_LOCK = "true";
      FORGEJO__security__SECRET_KEY_URI = "file:/etc/forgejo/secret-key";

      # Accounts are made by the admin only.
      FORGEJO__service__DISABLE_REGISTRATION = "true";

      FORGEJO__actions__ENABLED = "true";
    } // cfg.extraEnvironment;
  };

  # The tailnet port bind only succeeds once tailscale has assigned the
  # tailnet IP, so order after tailscaled and retry until it exists, as the
  # reverse proxy does.
  systemd.services.podman-forgejo = {
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    startLimitIntervalSec = 0;
    serviceConfig = {
      Restart = lib.mkForce "on-failure";
      RestartSec = lib.mkForce 5;
    };
  };
}
