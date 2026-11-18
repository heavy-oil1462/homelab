{ config, lib, pkgs, utils, ... }:

# Pocket ID, the site's OpenID Connect provider, with nixpkgs'
# services.pocket-id (docs/adr/0018-pocket-id-is-the-oidc-provider.md). Its
# users sign in with passkeys; docs/pocket-id.md has the first run.
#
# It serves HTTP only on a unix socket, homelab.pocketId.socket, in a
# directory that only its own user and the caddy group can enter, and Caddy
# serves it as https://<hostName>.<domain> on the tailnet like every other
# site. Nothing listens on a port. It runs as nixpkgs' pocket-id system
# user with no capabilities and nixpkgs' sandboxing.
#
# Its encryption key and its static admin API key are files under
# /var/lib/secrets, made on the first start by pocket-id-keys. The clients
# in homelab.pocketId.clients are created through the admin API by
# pocket-id-clients once Pocket ID answers, which writes each client's id
# and secret file and restarts the units that read them.

let
  cfg = config.homelab.pocketId;
  socketDir = dirOf cfg.socket;
  declaredFile = "${cfg.dataDir}/homelab-clients.json";

  clientsScript = pkgs.callPackage ./pocket-id-clients.nix { };
  clientsSpec = pkgs.writeText "pocket-id-clients.json" (builtins.toJSON (lib.mapAttrsToList (id: c: {
    inherit id;
    inherit (c) displayName redirectUris logoutRedirectUris pkce idFile secretFile units;
    owner = "${c.owner}:${(config.users.users.${c.owner} or { group = c.owner; }).group}";
  }) cfg.clients));
  clientUnits = lib.unique (lib.concatMap (c: c.units) (lib.attrValues cfg.clients));

  # The encryption key is made only while there is no database: one made
  # for a restored database would leave its signing keys unreadable.
  keysScript = pkgs.writeShellApplication {
    name = "pocket-id-keys";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      umask 077
      # 32 random bytes as hex.
      generate() {
        install -d -m 0700 "$(dirname "$1")"
        tmp=$(mktemp "$(dirname "$1")/.pocket-id-keys.XXXXXX")
        od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$tmp"
        chmod 0400 "$tmp"
        mv -f "$tmp" "$1"
        echo "Generated $1."
      }
      if [ ! -s ${lib.escapeShellArg cfg.encryptionKeyFile} ]; then
        if [ -e ${lib.escapeShellArg cfg.databaseFile} ]; then
          echo "Pocket ID has a database, ${cfg.databaseFile}, but no encryption key in ${cfg.encryptionKeyFile}. Put the key it was made with there." >&2
          exit 1
        fi
        generate ${lib.escapeShellArg cfg.encryptionKeyFile}
      fi
      if [ ! -s ${lib.escapeShellArg cfg.apiKeyFile} ]; then
        generate ${lib.escapeShellArg cfg.apiKeyFile}
      fi
    '';
  };
in
{
  imports = [ ./options.nix ];

  config = lib.mkIf cfg.enable {
    services.pocket-id = {
      enable = true;
      inherit (cfg) dataDir;
      settings = {
        APP_URL = cfg.url;
        UNIX_SOCKET = cfg.socket;
        # The directory keeps out everyone but Pocket ID and Caddy.
        UNIX_SOCKET_MODE = "0666";
        # Only Caddy reaches the socket, so its X-Forwarded-For is the
        # client's address.
        TRUST_PROXY = true;
        ANALYTICS_DISABLED = true;
        VERSION_CHECK_DISABLED = true;
      };
      # Read by systemd as root (LoadCredential), so the files stay root's.
      credentials = {
        ENCRYPTION_KEY = cfg.encryptionKeyFile;
        STATIC_API_KEY = cfg.apiKeyFile;
      };
    };

    # Not a RuntimeDirectory: systemd would delete and recreate it on every
    # restart of Pocket ID, and the caddy container's bind mount would keep
    # pointing at the deleted one. Its group lets Caddy in.
    systemd.tmpfiles.rules = [
      "d ${socketDir} 0750 ${config.services.pocket-id.user} caddy - -"
    ];

    systemd.services.pocket-id = {
      after = [ "pocket-id-keys.service" ];
      requires = [ "pocket-id-keys.service" ];
      serviceConfig.ReadWritePaths = [ socketDir ];
    };

    # Before Pocket ID, since systemd loads its credentials before any
    # ExecStartPre would run.
    systemd.services.pocket-id-keys = {
      description = "Pocket ID's encryption and API keys";
      before = [ "pocket-id.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${keysScript}/bin/pocket-id-keys";
      };
    };

    # The units reading a client's files start after this one and pull it
    # in; it restarts them itself when it writes new files. It runs again
    # whenever Pocket ID restarts or the declared clients change.
    systemd.services.pocket-id-clients = {
      description = "Pocket ID's declared OIDC clients";
      after = [ "pocket-id.service" ];
      requires = [ "pocket-id.service" ];
      before = clientUnits;
      wantedBy = [ "multi-user.target" ] ++ clientUnits;
      path = [ config.systemd.package ];
      restartTriggers = [ clientsSpec ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = utils.escapeSystemdExecArgs [
          "${clientsScript}/bin/pocket-id-clients"
          clientsSpec
          cfg.socket
          cfg.apiKeyFile
          declaredFile
        ];
      };
    };

    assertions = [
      {
        assertion = config.virtualisation.oci-containers.containers ? caddy;
        message = "homelab.pocketId serves only on a socket that the caddy container mounts; import containers/reverse-proxy.nix on the same host.";
      }
      {
        assertion = config.systemd.services.pocket-id.serviceConfig.WorkingDirectory == cfg.dataDir;
        message = "nixpkgs' services.pocket-id no longer runs in ${cfg.dataDir}; update homelab.pocketId.databaseFile.";
      }
    ] ++ lib.concatLists (lib.mapAttrsToList (id: c: [
      {
        # Pocket ID's own rule for client ids (validateClientIDRegex).
        assertion = builtins.match "[A-Za-z0-9._-]{2,128}" id != null;
        message = "homelab.pocketId.clients.\"${id}\": a client id is 2 to 128 letters, digits, '.', '_' and '-'.";
      }
      {
        assertion = config.users.users ? ${c.owner};
        message = "homelab.pocketId.clients.${id}.owner: there is no user ${c.owner}.";
      }
    ]) cfg.clients);
  };
}
