{ config, lib, pkgs, ... }:

let
  # Runs only on the first start, when /data/db is still empty; the mongo
  # entrypoint sources non-executable .sh files so the MONGO_* variables from
  # the environment file expand here. Re-running it requires wiping
  # /var/lib/unifi-db.
  mongoInit = pkgs.writeText "init-mongo.sh" ''
    mongosh <<EOF
    use ''${MONGO_AUTHSOURCE}
    db.auth("''${MONGO_INITDB_ROOT_USERNAME}", "''${MONGO_INITDB_ROOT_PASSWORD}")
    db.createUser({
      user: "''${MONGO_USER}",
      pwd: "''${MONGO_PASS}",
      roles: [
        { db: "admin", role: "clusterMonitor" },
        { db: "''${MONGO_DBNAME}", role: "dbOwner" },
        { db: "''${MONGO_DBNAME}_stat", role: "dbOwner" },
        { db: "''${MONGO_DBNAME}_audit", role: "dbOwner" },
        { db: "''${MONGO_DBNAME}_restore", role: "dbOwner" }
      ]
    })
    EOF
  '';
in
{
  imports = [ ../modules/options.nix ];

  # Static uids so the linuxserver image's PUID/PGID and the mongo container's
  # user option get real values at eval time; auto-allocated system users have
  # no uid until activation. 990 is taken by frigate (nvr.nix).
  users.users.unifi = {
    isSystemUser = true;
    group = "unifi";
    uid = 989;
  };
  users.groups.unifi = {
    gid = 989;
  };
  users.users.unifi-db = {
    isSystemUser = true;
    group = "unifi-db";
    uid = 988;
  };
  users.groups.unifi-db = {
    gid = 988;
  };

  # Both containers expect /var/lib/secrets/unifi.env on the host, provisioned
  # out of band (never committed), root:root 0400 (podman reads it as root),
  # containing MONGO_INITDB_ROOT_USERNAME, MONGO_INITDB_ROOT_PASSWORD,
  # MONGO_USER and MONGO_PASS. Keep the passwords alphanumeric: they are
  # interpolated into JavaScript strings in the init script and into the
  # mongo connection URI built by the image.
  #
  # The f rule creates the file empty if it is missing, so podman never fails
  # on a missing env file. The mongo image only turns on auth when the root
  # credentials are set, so without them mongod would run open; unifi-db's
  # preStart refuses to start until they are there.
  systemd.tmpfiles.rules = [
    "d /var/lib/unifi 0750 unifi unifi -"
    "d /var/lib/unifi-db 0700 unifi-db unifi-db -"
    "f /var/lib/secrets/unifi.env 0400 root root -"
  ];

  virtualisation.oci-containers.containers = {
    # MongoDB for the UniFi application, on the default podman bridge.
    # Setting the root credentials switches the image into auth mode, which
    # matters here: containers on the shared bridge reach each other's ports
    # directly, so mongod must not accept unauthenticated connections. The
    # loopback publish is for the host-networked unifi container, which is
    # outside the bridge and its DNS. Pinned to the 8.0 line because mongod
    # does not support skipping major versions on upgrade and UniFi caps the
    # supported server version; bump majors deliberately.
    unifi-db = {
      image = "docker.io/library/mongo@sha256:479e85ced54ffb8a40dade1dcde2da2a9ae858515b9415e9cc54bfb8f0575d01"; # 8.0.38, :8.0 as of 2026-11-20
      autoStart = true;
      user = "${toString config.users.users.unifi-db.uid}:${toString config.users.groups.unifi-db.gid}";
      ports = [ "127.0.0.1:27017:27017" ];
      # The unit reports ready only once mongod answers ping, so dependsOn on
      # the unifi container waits for a usable database, not just a started
      # process. First init (temporary mongod plus the init script) can take
      # a minute; sdnotify=healthy absorbs that.
      podman.sdnotify = "healthy";
      extraOptions = [
        "--security-opt=no-new-privileges"
        "--cap-drop=ALL"
        "--health-cmd"
        "mongosh --quiet --eval 'db.runCommand({ping: 1}).ok'"
        "--health-interval=10s"
      ];
      volumes = [
        "/var/lib/unifi-db:/data/db"
        "${mongoInit}:/docker-entrypoint-initdb.d/init-mongo.sh:ro"
      ];
      environment = {
        MONGO_DBNAME = "unifi";
        MONGO_AUTHSOURCE = "admin";
      };
      environmentFiles = [ "/var/lib/secrets/unifi.env" ];
    };

    # Host networking so device discovery broadcasts (UDP 10001) and STUN
    # reach the controller; with bridge networking newly adopted gear cannot
    # find it. The web UI on 8443 stays unreachable from the LAN as long as
    # the host firewall does not open it; the reverse proxy reaches it via
    # the podman bridge gateway. No user option here: the linuxserver init
    # runs as root and drops to PUID/PGID itself, so the controller runs as
    # the unifi user. It is on the root allowlist in
    # tests/container-hardening.nix
    # (docs/adr/0014-containers-run-unprivileged.md).
    unifi = {
      image = "lscr.io/linuxserver/unifi-network-application@sha256:31d2bc6f7df15fd737d7995e3907bf24e106e8b55deae22ad7bdea183c9b2e8b"; # 10.6.109, :latest as of 2026-11-27
      autoStart = true;
      dependsOn = [ "unifi-db" ];
      extraOptions = [
        "--network=host"
        "--security-opt=no-new-privileges"
        "--cap-drop=ALL"
        # The init sets the abc user to PUID/PGID and re-owns /config, mode
        # 0750 and the unifi user's, as root.
        "--cap-add=CHOWN"
        "--cap-add=DAC_OVERRIDE"
        "--cap-add=FOWNER"
        # s6-overlay drops to that user for the controller and signals it
        # on stop.
        "--cap-add=SETUID"
        "--cap-add=SETGID"
        "--cap-add=KILL"
      ];
      volumes = [
        "/var/lib/unifi:/config"
      ];
      environment = {
        PUID = toString config.users.users.unifi.uid;
        PGID = toString config.users.groups.unifi.gid;
        TZ = config.homelab.timeZone;
        MONGO_HOST = "127.0.0.1";
        MONGO_PORT = "27017";
        MONGO_DBNAME = "unifi";
        MONGO_AUTHSOURCE = "admin";
        MEM_LIMIT = "1024";
        MEM_STARTUP = "1024";
      };
      environmentFiles = [ "/var/lib/secrets/unifi.env" ];
    };
  };

  # dependsOn gives Requires plus After, but a slow database first init must
  # not exhaust the unifi unit's start rate limit and leave it failed for
  # good; same pattern as the reverse proxy waiting for tailscaled.
  systemd.services.podman-unifi.startLimitIntervalSec = 0;

  systemd.services.podman-unifi-db.preStart = lib.mkBefore ''
    for var in MONGO_INITDB_ROOT_USERNAME MONGO_INITDB_ROOT_PASSWORD; do
      if ! grep -q "^$var=." /var/lib/secrets/unifi.env; then
        echo "/var/lib/secrets/unifi.env does not set $var; refusing to start MongoDB without auth." >&2
        exit 1
      fi
    done
  '';
}
