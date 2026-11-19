# The example server's Pocket ID, with the clients forgejo and grafana
# declared by the flake (docs/adr/0018-pocket-id-is-the-oidc-provider.md).
# Pure evaluation of the host config, then a build that reads only the
# spec file the pocket-id-clients unit names:
#
# - Pocket ID serves on its socket at homelab.pocketId.url, with its keys
#   as credentials and pocket-id-keys before it;
# - its settings come from the environment, and users cannot edit their
#   own accounts;
# - the socket's directory is the caddy group's, writable for Pocket ID and
#   mounted into the caddy container;
# - pocket-id-clients runs after Pocket ID and before the clients' units,
#   which pull it in;
# - the spec has each client with its files and owner as "user:group";
# - the example backs up the database with a consistent copy.
#
# It cannot sign anyone in: the clients script has its own check against a
# stand-in, and Pocket ID itself is tested by hand.
{ lib, runCommand, jq, config }:

let
  cfg = config.homelab.pocketId;
  socketDir = dirOf cfg.socket;
  pocketId = config.services.pocket-id;
  service = config.systemd.services.pocket-id;
  clients = config.systemd.services.pocket-id-clients;
  caddy = config.virtualisation.oci-containers.containers.caddy;
  backup = config.homelab.backups.jobs.pocket-id or null;
  units = [ "forgejo-oidc.service" "podman-grafana.service" ];

  problems =
    lib.optional (!cfg.enable) "homelab.pocketId.enable is off"
    ++ lib.optional (cfg.url != "https://id.home.example.com") "homelab.pocketId.url is ${cfg.url}"
    ++ lib.optional (pocketId.settings.APP_URL != cfg.url) "APP_URL is ${pocketId.settings.APP_URL}, not homelab.pocketId.url"
    ++ lib.optional ((pocketId.settings.UNIX_SOCKET or null) != cfg.socket) "Pocket ID does not serve on ${cfg.socket}"
    ++ lib.optional (!pocketId.settings.TRUST_PROXY) "Pocket ID does not trust Caddy's X-Forwarded-For"
    ++ lib.optional ((pocketId.settings.UI_CONFIG_DISABLED or false) != true) "Pocket ID takes its settings from the admin UI"
    ++ lib.optional ((pocketId.settings.ALLOW_OWN_ACCOUNT_EDIT or true) != false) "Pocket ID lets users edit their own accounts"
    ++ lib.optional (pocketId.credentials != { ENCRYPTION_KEY = cfg.encryptionKeyFile; STATIC_API_KEY = cfg.apiKeyFile; })
      "Pocket ID's credentials are ${builtins.toJSON pocketId.credentials}"
    ++ lib.optional (!(lib.elem "pocket-id-keys.service" service.requires && lib.elem "pocket-id-keys.service" service.after))
      "Pocket ID does not start after pocket-id-keys"
    ++ lib.optional (!(lib.elem socketDir service.serviceConfig.ReadWritePaths)) "Pocket ID cannot write ${socketDir}"
    ++ lib.optional ((service.serviceConfig.CapabilityBoundingSet or null) != "") "Pocket ID keeps capabilities"
    ++ lib.optional (service.serviceConfig.User != "pocket-id") "Pocket ID runs as ${service.serviceConfig.User}"
    ++ lib.optional (!(lib.elem "d ${socketDir} 0750 pocket-id caddy - -" config.systemd.tmpfiles.rules))
      "no tmpfiles rule makes ${socketDir} the caddy group's, mode 0750"
    ++ lib.optional (!(lib.elem "${socketDir}:${socketDir}" caddy.volumes)) "the caddy container does not mount ${socketDir}"
    ++ lib.optional (!(lib.elem "pocket-id.service" clients.after && lib.elem "pocket-id.service" clients.requires))
      "pocket-id-clients does not run after Pocket ID"
    ++ lib.concatMap (u:
      lib.optional (!(lib.elem u clients.before)) "pocket-id-clients does not run before ${u}"
      ++ lib.optional (!(lib.elem u clients.wantedBy)) "${u} does not pull in pocket-id-clients")
      units
    ++ lib.optional (backup == null) "the example backs up no pocket-id job"
    ++ lib.optional (backup != null && backup.sqliteDatabases != [ cfg.databaseFile ])
      "the pocket-id job does not copy ${cfg.databaseFile} through SQLite";

  expected = [
    {
      id = "forgejo";
      displayName = "forgejo";
      redirectUris = [ "https://git.home.example.com/user/oauth2/pocket-id/callback" ];
      logoutRedirectUris = [ ];
      pkce = false;
      idFile = "/var/lib/secrets/forgejo-oidc-client-id";
      secretFile = "/var/lib/secrets/forgejo-oidc-client-secret";
      owner = "root:root";
      units = [ "forgejo-oidc.service" ];
    }
    {
      id = "grafana";
      displayName = "Grafana";
      redirectUris = [ "https://status.home.example.com/login/generic_oauth" ];
      logoutRedirectUris = [ ];
      pkce = true;
      idFile = "/var/lib/secrets/grafana-oidc-client-id";
      secretFile = "/var/lib/secrets/grafana-oidc-client-secret";
      owner = "grafana:grafana";
      units = [ "podman-grafana.service" ];
    }
  ];
in
if problems != [ ] then
  throw "Pocket ID breaks docs/adr/0018-pocket-id-is-the-oidc-provider.md:\n${lib.concatStringsSep "\n" problems}"
else
  runCommand "pocket-id-module" {
    nativeBuildInputs = [ jq ];
    expected = builtins.toJSON expected;
    # The whole command line, which keeps the spec's string context; the
    # spec is its first argument after the script.
    command = clients.serviceConfig.ExecStart;
  } ''
    read -r _ spec _ <<< "$command"
    spec=''${spec//\"/}
    if ! jq -e --argjson expected "$expected" 'sort_by(.id) == $expected' "$spec" > /dev/null; then
      echo "pocket-id-clients gets:" >&2; jq . "$spec" >&2
      echo "expected:" >&2; jq . <<< "$expected" >&2
      exit 1
    fi
    touch $out
  ''
