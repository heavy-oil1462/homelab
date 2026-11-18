{ config, lib, ... }:

# Private OCI image registry (the Docker Official Image of CNCF Distribution).
# It listens on the podman bridge only; publish it through the reverse proxy,
# for example:
#
#   registry.__DOMAIN__:443 {
#       import site_tls
#       reverse_proxy registry:5000
#   }
#
# Caddy sets Host and X-Forwarded-Proto, which the registry uses to build the
# https upload URLs it hands to clients, and imposes no request body limit, so
# large layers push without extra proxy settings.
#
# Every request (pull and push) requires a login from the htpasswd file at
# /var/lib/secrets/registry.htpasswd, provisioned out of band. It must use
# bcrypt and be readable by the registry user:
#
#   htpasswd -Bc /var/lib/secrets/registry.htpasswd <user>
#   chown registry:registry /var/lib/secrets/registry.htpasswd
#   chmod 0400 /var/lib/secrets/registry.htpasswd
#
# A tmpfiles rule creates the file empty if it is missing, so podman never
# makes a directory at the mount's source, and the unit refuses to start
# while it is empty, naming the file. An empty htpasswd has no users, so
# the registry would be of no use, and it never comes up open.

{
  imports = [ ../modules/options.nix ];

  # Static uid so the container's user option has a value at eval time.
  # See "Static user ids" in the README for the allocation.
  users.users.registry = {
    isSystemUser = true;
    group = "registry";
    uid = 601;
  };
  users.groups.registry = {
    gid = 601;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/registry 0750 registry registry -"
    "f /var/lib/secrets/registry.htpasswd 0400 registry registry -"
  ];

  systemd.services.podman-registry.preStart = lib.mkBefore ''
    if [ ! -s /var/lib/secrets/registry.htpasswd ]; then
      echo "/var/lib/secrets/registry.htpasswd is empty; refusing to start the registry without users." >&2
      exit 1
    fi
  '';

  virtualisation.oci-containers.containers.registry = {
    image = "docker.io/library/registry@sha256:82f6ff4a7f982960c8aa51617fea3aabc485df6e55cce80d22deb1de36f1bc3c"; # 3.1.2, :3 as of 2026-11-18
    autoStart = true;
    user = "${toString config.users.users.registry.uid}:${toString config.users.groups.registry.gid}";
    # docs/adr/0014-containers-run-unprivileged.md
    extraOptions = [
      "--security-opt=no-new-privileges"
      "--cap-drop=ALL"
    ];
    volumes = [
      "/var/lib/registry:/var/lib/registry"
      "/var/lib/secrets/registry.htpasswd:/auth/htpasswd:ro"
    ];
    environment = {
      REGISTRY_AUTH = "htpasswd";
      REGISTRY_AUTH_HTPASSWD_REALM = "registry";
      REGISTRY_AUTH_HTPASSWD_PATH = "/auth/htpasswd";
      # The image's built-in config logs at debug level, which floods the
      # journal (and Loki) with a line per request detail.
      REGISTRY_LOG_LEVEL = "info";
      # Allows deleting manifests through the API. Space is only reclaimed
      # by running garbage-collect inside the container afterwards:
      #   podman exec registry registry garbage-collect --delete-untagged /etc/distribution/config.yml
      # Do it while nothing is pushing; a concurrent push can lose layers.
      REGISTRY_STORAGE_DELETE_ENABLED = "true";
    };
  };
}
