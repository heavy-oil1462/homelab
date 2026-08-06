{ config, pkgs, ... }:

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
        { db: "''${MONGO_DBNAME}", role: "dbOwner" },
        { db: "''${MONGO_DBNAME}_stat", role: "dbOwner" },
        { db: "''${MONGO_DBNAME}_audit", role: "dbOwner" }
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

  systemd.tmpfiles.rules = [
    "d /var/lib/unifi 0750 unifi unifi -"
    "d /var/lib/unifi-db 0700 unifi-db unifi-db -"
  ];

  # Both containers expect /var/lib/secrets/unifi.env on the host, provisioned
  # out of band (never committed), containing MONGO_INITDB_ROOT_USERNAME,
  # MONGO_INITDB_ROOT_PASSWORD, MONGO_USER and MONGO_PASS. Keep the passwords
  # alphanumeric: they are interpolated into JavaScript strings in the init
  # script and into the mongo connection URI built by the image.
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
      image = "docker.io/library/mongo@sha256:98605bfa1bb2a15dd82109e1d78ad31527a9a744909fab4606076fa71a0ae515"; # 8.0.28, :8.0 as of 2026-08-06
      autoStart = true;
      user = "${toString config.users.users.unifi-db.uid}:${toString config.users.groups.unifi-db.gid}";
      ports = [ "127.0.0.1:27017:27017" ];
      # The unit reports ready only once mongod answers ping, so dependsOn on
      # the unifi container waits for a usable database, not just a started
      # process. First init (temporary mongod plus the init script) can take
      # a minute; sdnotify=healthy absorbs that.
      podman.sdnotify = "healthy";
      extraOptions = [
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
    # runs as root and drops to PUID/PGID itself.
    unifi = {
      image = "lscr.io/linuxserver/unifi-network-application@sha256:3b3780b99ab811ebedb4c83604e0f08b6e1ac2a4fb99bfa9893539dae8c650fa"; # 10.4.57, :latest as of 2026-08-06
      autoStart = true;
      dependsOn = [ "unifi-db" ];
      extraOptions = [ "--network=host" ];
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
}
