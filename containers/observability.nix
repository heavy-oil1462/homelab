{ config, lib, pkgs, utils, ... }:

let
  cfg = config.homelab.observability;
  proxyAddress = config.homelab.reverseProxy.address;
  oidc = cfg.grafanaOidc;
  pocketId = config.homelab.pocketId;
  # Users cannot change their own username or email in Pocket ID: its
  # settings come from the environment, and own-account editing is off.
  pocketIdSettings = config.services.pocket-id.settings;
  pocketIdOwnEditOff = (pocketIdSettings.UI_CONFIG_DISABLED or false) == true
    && (pocketIdSettings.ALLOW_OWN_ACCOUNT_EDIT or true) == false;

  # Pocket ID's endpoints, as its discovery document has them (2.7.0).
  oidcEndpoints = {
    auth = "${pocketId.url}/authorize";
    token = "${pocketId.url}/api/oidc/token";
    userinfo = "${pocketId.url}/api/oidc/userinfo";
  };
  # JMESPath over the token's and userinfo's claims. Anyone else gets no
  # role, which role_attribute_strict turns into a refused sign in.
  oidcRolePath = "contains([${lib.concatMapStringsSep ", " (e: "'${e}'") oidc.admins}], email) && 'Admin'";

  hostUserCheck = pkgs.callPackage ./host-user-check.nix { };
  userCheck = name: [
    (utils.escapeSystemdExecArgs [
      "${hostUserCheck}/bin/host-user-check"
      name
      (toString config.users.users.${name}.uid)
      (toString config.users.groups.${name}.gid)
    ])
  ];

  # Every container here runs as its host user, with no capabilities and no
  # way to gain any (docs/adr/0014-containers-run-unprivileged.md). Each
  # data volume has :U, so podman hands it to that user on every start:
  # data written while the containers ran as root, a volume new from the
  # image's own owner, and data restored from a backup.
  hardening = [
    "--security-opt=no-new-privileges"
    "--cap-drop=ALL"
  ];

  prometheusConfig = pkgs.writeText "prometheus.yml" (
    builtins.readFile cfg.prometheusConfig
  );

  lokiConfig = pkgs.writeText "local-config.yaml" (
    builtins.readFile cfg.lokiConfig
  );

  grafanaDatasources = pkgs.writeText "datasources.yml" ''
    apiVersion: 1
    deleteDatasources:
      - name: Prometheus
        orgId: 1
      - name: Loki
        orgId: 1
    datasources:
      - name: Prometheus
        type: prometheus
        uid: Prometheus
        url: http://prometheus:9090
        access: proxy
        isDefault: true
      - name: Loki
        type: loki
        uid: Loki
        url: http://loki:3100
        access: proxy
  '';

  grafanaAlerting = pkgs.writeText "alerting.yaml" (
    builtins.readFile cfg.alertingConfig
  );

  # Probes for homelab.observability.probeTargets. http_2xx_tls is an HTTPS
  # GET that fails on anything but a 2xx answer over TLS with a certificate
  # the host trusts, so probe_success covers "down" and "invalid
  # certificate", and probe_ssl_earliest_cert_expiry gives the expiry. IPv4
  # because Caddy publishes 443 on the tailnet IPv4 address only.
  blackboxConfig = pkgs.writeText "blackbox.yml" ''
    modules:
      http_2xx_tls:
        prober: http
        timeout: 10s
        http:
          method: GET
          fail_if_not_ssl: true
          preferred_ip_protocol: ip4
          ip_protocol_fallback: false
  '';

  # The targets as a file_sd file, so the blackbox job in the consumer's
  # prometheus.yml reads them from the option instead of repeating them.
  probeTargets = pkgs.writeText "probe-targets.json" (builtins.toJSON [
    { targets = cfg.probeTargets; }
  ]);

  # The NVIDIA GPU exporters to scrape, as a file_sd file for the nvidia-gpu
  # job in the same way.
  nvidiaGpuTargets = pkgs.writeText "nvidia-gpu-targets.json" (builtins.toJSON [
    { targets = cfg.nvidiaGpuTargets; }
  ]);

  # The default podman network's bridge, as the NixOS podman module defines
  # it. The Prometheus container reaches the host's blackbox exporter here.
  podmanBridge = "podman0";
  podmanGateway = "10.88.0.1";

  # The dashboards in dashboardsDir, read-only in the Homelab folder.
  grafanaDashboards = pkgs.writeText "dashboards.yml" ''
    apiVersion: 1
    providers:
      - name: 'Homelab Dashboards'
        orgId: 1
        folder: 'Homelab'
        type: file
        disableDeletion: false
        updateIntervalSeconds: 10
        allowUiUpdates: false
        options:
          path: /etc/grafana/dashboards
  '';

  # Dashboards synced both ways with a Git repository through Grafana's Git
  # Sync (docs/adr/0009-dashboards-through-grafana-git-sync.md). The
  # grafana-git-sync unit puts this Repository resource into Grafana, with
  # the token from tokenFile added. Pure Git: plain Git over HTTPS, the only
  # type that speaks to Forgejo. Grafana pushes saved dashboards straight
  # to the branch ("write"); it cannot open pull requests on Forgejo.
  gitSync = cfg.grafanaGitSync;
  gitSyncScript = pkgs.callPackage ./grafana-git-sync.nix { };
  # The URL's host name, without a port.
  gitSyncHost = builtins.head (lib.splitString ":"
    (builtins.head (lib.splitString "/" (lib.removePrefix "https://" gitSync.url))));
  gitSyncRepository = pkgs.writeText "grafana-git-sync-repository.json" (builtins.toJSON {
    apiVersion = "provisioning.grafana.app/v0alpha1";
    kind = "Repository";
    metadata = {
      name = "homelab-dashboards";
      namespace = "default";
    };
    spec = {
      title = "Dashboards";
      type = "git";
      git = {
        inherit (gitSync) url branch path;
        # Forgejo takes an access token as the password whatever the user
        # name.
        tokenUser = "git";
      };
      # A folder of its own, named after the title, beside Homelab.
      sync = {
        enabled = true;
        target = "folder";
        inherit (gitSync) intervalSeconds;
      };
      workflows = [ "write" ];
    };
  });
  # The headers the grafana-git-sync unit signs in to Grafana with, as its
  # built-in admin, to make the service account whose token it uses when
  # apiTokenFile is empty (docs/adr/0012-git-sync-service-account-made-by-the-host.md).
  # Grafana's proxy authentication takes them from 127.0.0.1 only, which
  # in its container is Grafana itself, and root on the host through
  # nsenter. It has one user header, so with grafanaProxyAuth the unit uses
  # Remote-User and Remote-Role, which Grafana then also takes from there.
  gitSyncAdminHeaders =
    if cfg.grafanaProxyAuth.enable
    then { user = "Remote-User"; role = "Remote-Role"; }
    else { user = "X-Grafana-Git-Sync-User"; role = "X-Grafana-Git-Sync-Role"; };
in
{
  imports = [ ../modules/options.nix ];

  assertions = [
    {
      assertion = !cfg.grafanaProxyAuth.enable || proxyAddress != null;
      message = "homelab.observability.grafanaProxyAuth trusts Remote-User from homelab.reverseProxy.address, which is null.";
    }
    {
      assertion = !(cfg.grafanaProxyAuth.enable && oidc.enable);
      message = "homelab.observability.grafanaProxyAuth and homelab.observability.grafanaOidc are both enabled; Grafana signs in with one or the other.";
    }
  ] ++ lib.optionals oidc.enable [
    {
      assertion = pocketId.enable;
      message = "homelab.observability.grafanaOidc signs in through Pocket ID, but homelab.pocketId is not enabled on this host.";
    }
    {
      assertion = lib.any (c: c.idFile == oidc.clientIdFile && c.secretFile == oidc.clientSecretFile
        && c.owner == "grafana" && lib.elem "podman-grafana.service" c.units) (lib.attrValues pocketId.clients);
      message = "homelab.observability.grafanaOidc signs in through Pocket ID: declare Grafana's client in homelab.pocketId.clients, with idFile ${oidc.clientIdFile}, secretFile ${oidc.clientSecretFile}, owner grafana and podman-grafana.service among its units (docs/pocket-id.md).";
    }
    {
      # Grafana matches its admins, and looks existing users up, by the
      # email claim, which a user who edits their own account could set
      # to an address no account holds.
      assertion = !pocketId.enable || pocketIdOwnEditOff;
      message = "homelab.observability.grafanaOidc signs in through Pocket ID, which matches users by email, but Pocket ID lets users change their own email; turn homelab.pocketId.allowOwnAccountEdit off (docs/adr/0019-forgejo-and-grafana-on-pocket-id.md).";
    }
  ];

  # Static uids so the containers' user option has a value at eval time.
  # See "Static user ids" in the README for the allocation. Without one the
  # option read ":", and podman ran the containers as root. A host that
  # already has these users keeps their ids (NixOS does not change them), so
  # such a host overrides these defaults with its existing uid and gid;
  # host-user-check below refuses to start a container until it does.
  users.users.prometheus = {
    isSystemUser = true;
    group = "prometheus";
    uid = lib.mkDefault 603;
  };
  users.groups.prometheus = {
    gid = lib.mkDefault 603;
  };

  users.users.loki = {
    isSystemUser = true;
    group = "loki";
    uid = lib.mkDefault 604;
  };
  users.groups.loki = {
    gid = lib.mkDefault 604;
  };

  users.users.grafana = {
    isSystemUser = true;
    group = "grafana";
    uid = lib.mkDefault 605;
  };
  users.groups.grafana = {
    gid = lib.mkDefault 605;
  };

  # The secret files below, the OIDC client's included, are owned by the
  # host users by name; the containers run as their numbers.
  systemd.services.podman-prometheus.serviceConfig.ExecStartPre = lib.mkBefore (userCheck "prometheus");
  systemd.services.podman-loki.serviceConfig.ExecStartPre = lib.mkBefore (userCheck "loki");
  systemd.services.podman-grafana.serviceConfig.ExecStartPre = lib.mkBefore (userCheck "grafana");

  # Guarantee the HA scrape token exists as a FILE before the Prometheus
  # container starts. The container bind-mounts it read-only; if the host path
  # is missing, podman would create a directory there and Prometheus would
  # crash-loop reading credentials_file as a directory. Creating an empty file
  # if absent means a not-yet-provisioned token only makes the home-assistant
  # target fail auth (401), never takes Prometheus down. tmpfiles 'f' does not
  # truncate an existing file, so the real token is left untouched once
  # written.
  systemd.tmpfiles.rules = [
    "f /var/lib/secrets/ha-prometheus-token 0640 prometheus prometheus -"
  ] ++ lib.optionals oidc.enable [
    # The same for the OIDC client's id and secret, which Grafana's
    # container reads: missing, sign in fails and Grafana runs.
    "f ${oidc.clientIdFile} 0400 grafana grafana -"
    "f ${oidc.clientSecretFile} 0400 grafana grafana -"
  ];

  # Grafana reads the client's id and secret only when it starts.
  # pocket-id-clients writes them and restarts Grafana when they change.
  systemd.services.podman-grafana.after = lib.mkIf oidc.enable [ "pocket-id-clients.service" ];

  # Create or update the Git Sync repository in Grafana, through its API on
  # the container's address, whenever the config or a token changed and at
  # every boot, then have Grafana test it against the Git server. With a
  # seed, an empty repository first gets the seed's dashboards
  # (docs/adr/0011-git-sync-seeds-an-empty-repository.md). With
  # apiTokenFile missing or empty, it first makes Grafana's service account
  # and writes its token there
  # (docs/adr/0012-git-sync-service-account-made-by-the-host.md). Grafana
  # keeps the repository in its database, so turning the option off leaves
  # it there until deleted in Administration, Provisioning.
  systemd.services.grafana-git-sync = lib.mkIf gitSync.enable {
    description = "Set up Grafana's Git Sync repository";
    after = [ "podman-grafana.service" "network-online.target" ];
    wants = [ "podman-grafana.service" "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ config.virtualisation.podman.package pkgs.util-linux ];
    environment = {
      GRAFANA_GIT_SYNC_USER_HEADER = gitSyncAdminHeaders.user;
      GRAFANA_GIT_SYNC_ROLE_HEADER = gitSyncAdminHeaders.role;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # A oneshot has no start timeout of its own. The script gives up
      # after about 25 minutes; this stops it should anything else hang.
      TimeoutStartSec = "30min";
      StateDirectory = "grafana-git-sync";
      StateDirectoryMode = "0700";
      ExecStart = utils.escapeSystemdExecArgs ([
        "${gitSyncScript}/bin/grafana-git-sync"
        "grafana"
        gitSyncRepository
        gitSync.tokenFile
        gitSync.apiTokenFile
        "/var/lib/grafana-git-sync/applied"
      ] ++ lib.optional (gitSync.seed != null) "${gitSync.seed}");
    };
  };

  # The blackbox exporter runs on the host, next to Prometheus, so the sites
  # are probed once, from the host that alerts on them. It listens on the
  # podman bridge only and the port is open on that interface only, like
  # aardvark-dns on 53: containers on the default network reach it, nothing
  # on the LAN or the tailnet does.
  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = podmanGateway;
    port = 9115;
    configFile = blackboxConfig;
  };

  # The bridge address exists once podman has started a container on the
  # default network. Start after Prometheus, and keep retrying (rather than
  # hitting the start limit) if the bridge is not up yet.
  systemd.services.prometheus-blackbox-exporter = {
    after = [ "podman-prometheus.service" ];
    serviceConfig.RestartSec = "5s";
    unitConfig.StartLimitIntervalSec = 0;
  };

  networking.firewall.interfaces.${podmanBridge}.allowedTCPPorts = [
    config.services.prometheus.exporters.blackbox.port
  ];

  virtualisation.oci-containers.containers = {
    prometheus = {
      image = "docker.io/prom/prometheus@sha256:e04987641b57704f408e31f6373ba4138ecf27cb4a165d24aabb6c38fddd0f06"; # 3.16.0, :latest as of 2026-11-18
      user = "${toString config.users.users.prometheus.uid}:${toString config.users.groups.prometheus.gid}";
      autoStart = true;
      extraOptions = hardening;
      volumes = [
        "${prometheusConfig}:/etc/prometheus/prometheus.yml:ro"
        "prometheus-data:/prometheus:U"
        # Long-lived Home Assistant token for the home-assistant scrape job.
        # Runtime secret, never committed; provision it out of band and make
        # it readable by the prometheus container uid.
        "/var/lib/secrets/ha-prometheus-token:/etc/prometheus/ha-token:ro"
        "${probeTargets}:/etc/prometheus/probe-targets.json:ro"
        "${nvidiaGpuTargets}:/etc/prometheus/nvidia-gpu-targets.json:ro"
      ];
    };

    loki = {
      image = "docker.io/grafana/loki@sha256:b43c257ccfc925d4a50b8717cac61a3b51df8c48d01847936057e5c4075a24a7"; # 3.7.10, :latest as of 2026-11-18
      user = "${toString config.users.users.loki.uid}:${toString config.users.groups.loki.gid}";
      autoStart = true;
      extraOptions = hardening;
      volumes = [
        "${lokiConfig}:/etc/loki/local-config.yaml:ro"
        "loki-data:/var/lib/loki:U"
      ];
    };

    grafana = {
      image = "docker.io/grafana/grafana@sha256:0615ec4fbd4072004b7d86b46ded63013a74b7d6eb1119273dd89e8fa25c13cf"; # 13.3.1, :latest as of 2026-11-14
      user = "${toString config.users.users.grafana.uid}:${toString config.users.groups.grafana.gid}";
      autoStart = true;
      extraOptions = hardening;
      volumes = [
        "grafana-data:/var/lib/grafana:U"
        "${grafanaDatasources}:/etc/grafana/provisioning/datasources/datasources.yml:ro"
        "${grafanaAlerting}:/etc/grafana/provisioning/alerting/alerting.yaml:ro"
      ] ++ lib.optionals (cfg.dashboardsDir != null) [
        "${grafanaDashboards}:/etc/grafana/provisioning/dashboards/dashboards.yml:ro"
        "${cfg.dashboardsDir}:/etc/grafana/dashboards:ro"
      ] ++ lib.optionals oidc.enable [
        "${oidc.clientIdFile}:/run/secrets/oidc-client-id:ro"
        "${oidc.clientSecretFile}:/run/secrets/oidc-client-secret:ro"
      ];
      environment = (if oidc.enable then {
        # Sign in through the OpenID Connect provider, Pocket ID
        # (docs/adr/0018-pocket-id-is-the-oidc-provider.md). The redirect
        # URI is built from the root URL. The image's entrypoint reads the
        # __FILE variables' files into the settings.
        GF_SERVER_ROOT_URL = "https://status.${config.homelab.domain}/";
        GF_AUTH_GENERIC_OAUTH_ENABLED = "true";
        GF_AUTH_GENERIC_OAUTH_NAME = "Pocket ID";
        GF_AUTH_GENERIC_OAUTH_CLIENT_ID__FILE = "/run/secrets/oidc-client-id";
        GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET__FILE = "/run/secrets/oidc-client-secret";
        GF_AUTH_GENERIC_OAUTH_SCOPES = "openid email profile";
        GF_AUTH_GENERIC_OAUTH_AUTH_URL = oidcEndpoints.auth;
        GF_AUTH_GENERIC_OAUTH_TOKEN_URL = oidcEndpoints.token;
        GF_AUTH_GENERIC_OAUTH_API_URL = oidcEndpoints.userinfo;
        GF_AUTH_GENERIC_OAUTH_USE_PKCE = "true";
        # Users are the email claim, the Pocket ID account's email, unique
        # there.
        GF_AUTH_GENERIC_OAUTH_LOGIN_ATTRIBUTE_PATH = "email";
        GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH = "email";
        GF_AUTH_GENERIC_OAUTH_NAME_ATTRIBUTE_PATH = "name";
        # The admins get Admin on every sign in; everyone else is refused.
        GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH = oidcRolePath;
        GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_STRICT = "true";
        GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP = "true";
        GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN = "true";
        # As with proxy authentication: no anonymous access, no password
        # login and no basic auth. Service account tokens keep working.
        GF_AUTH_ANONYMOUS_ENABLED = "false";
        GF_AUTH_DISABLE_LOGIN_FORM = "true";
        GF_AUTH_BASIC_ENABLED = "false";
        # Grafana finds a generic OAuth user by the provider's user id, and
        # by email only with this. Pocket ID's ids are not another
        # provider's, so after a switch (from tsidp, before ADR-0023) an
        # existing user with the same email is taken over, keeping its preferences and stars, instead of a second user
        # being made. Only the admins sign in at all, by the same claim.
        # Safe only because Pocket ID's users cannot change their own email,
        # which an assertion above holds
        # (docs/adr/0019-forgejo-and-grafana-on-pocket-id.md).
        GF_AUTH_OAUTH_ALLOW_INSECURE_EMAIL_LOOKUP = "true";
      } else if cfg.grafanaProxyAuth.enable then {
        # The tailnet user from Caddy's grafana_identity snippet, trusted only
        # from Caddy's address; Grafana answers 401 to the header from
        # anywhere else. Users are created on first sign in with the role
        # Caddy passes in Remote-Role, Admin for every login it lets through.
        GF_AUTH_PROXY_ENABLED = "true";
        GF_AUTH_PROXY_HEADER_NAME = "Remote-User";
        GF_AUTH_PROXY_HEADER_PROPERTY = "username";
        GF_AUTH_PROXY_HEADERS = "Role:Remote-Role";
        GF_AUTH_PROXY_WHITELIST = proxyAddress;
        GF_AUTH_PROXY_AUTO_SIGN_UP = "true";
        # No other way in: the built in admin still has the password admin
        # unless someone changed it, so basic auth goes too. Service account
        # tokens keep working.
        GF_AUTH_ANONYMOUS_ENABLED = "false";
        GF_AUTH_DISABLE_LOGIN_FORM = "true";
        GF_AUTH_BASIC_ENABLED = "false";
      } else {
        # Single user on the tailnet: anonymous Admin access with no login
        # form. The endpoint is only reachable over the tailnet (the reverse
        # proxy binds to the tailnet IP), which is the access control here.
        GF_AUTH_ANONYMOUS_ENABLED = "true";
        GF_AUTH_ANONYMOUS_ORG_ROLE = "Admin";
        GF_AUTH_DISABLE_LOGIN_FORM = "true";
      }) // lib.optionalAttrs gitSync.enable {
        # Git Sync is on by default from Grafana 13; this allows Pure Git
        # repositories only, and lets Grafana reach the repository's host,
        # which it would refuse where the name resolves to a private
        # address (a tailnet's IPv6 ULA, a LAN).
        GF_PROVISIONING_REPOSITORY_TYPES = "git";
        GF_PROVISIONING_ALLOWED_GIT_URLS = gitSyncHost;
        # The grafana-git-sync unit's sign in as the built-in admin, from
        # 127.0.0.1 in the container only; from anywhere else Grafana
        # refuses the headers. No password, so the login form and basic
        # auth stay as they are. Besides Caddy's address with
        # grafanaProxyAuth, which keeps signing up its users.
        GF_AUTH_PROXY_ENABLED = "true";
        GF_AUTH_PROXY_HEADER_NAME = gitSyncAdminHeaders.user;
        GF_AUTH_PROXY_HEADER_PROPERTY = "username";
        GF_AUTH_PROXY_HEADERS = "Role:${gitSyncAdminHeaders.role}";
        GF_AUTH_PROXY_WHITELIST = lib.concatStringsSep ","
          (lib.optional cfg.grafanaProxyAuth.enable proxyAddress ++ [ "127.0.0.1" ]);
        GF_AUTH_PROXY_AUTO_SIGN_UP = lib.boolToString cfg.grafanaProxyAuth.enable;
      };
    };
  };
}
