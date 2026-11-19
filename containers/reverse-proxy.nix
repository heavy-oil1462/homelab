{ config, pkgs, lib, utils, ... }:

let
  domain = config.homelab.domain;
  tailnetIp = config.homelab.tailnetIp;
  cfg = config.homelab.reverseProxy;

  forgejoAuth = config.homelab.forgejo.proxyAuth;
  grafanaAuth = config.homelab.observability.grafanaProxyAuth;
  pocketId = config.homelab.pocketId;
  gate = cfg.oidcGate;

  # Snippets that turn the tailnet login from tailnet_identity into what a
  # service accepts, for the services with proxy authentication on. Each
  # imports tailnet_identity itself, so a site cannot use one without the
  # stripping of forged headers. A login that is not listed maps to an empty
  # Remote-User, which Forgejo and Grafana both treat as no identity. The map
  # is read when request_header sets the header, while Remote-User still
  # holds the login. See docs/adr/0005-proxy-auth-only-from-caddy.md.
  identitySnippet = name: dests: mappings: setHeaders: lib.concatStringsSep "\n" ([
    "(${name}) {"
    "\timport tailnet_identity"
    "\troute {"
    "\t\tmap {header.Remote-User} ${dests} {"
  ] ++ map (m: "\t\t\t${m}") mappings ++ [
    "\t\t}"
  ] ++ map (h: "\t\trequest_header ${h}") setHeaders ++ [
    "\t}"
    "}"
    ""
    ""
  ]);

  identitySnippets = lib.concatStrings [
    (lib.optionalString forgejoAuth.enable (identitySnippet "forgejo_identity" "{forgejo_user}"
      (lib.mapAttrsToList (login: user: "${login} ${user}") forgejoAuth.users)
      [ "Remote-User {forgejo_user}" ]))
    (lib.optionalString grafanaAuth.enable (identitySnippet "grafana_identity" "{grafana_user} {grafana_role}"
      # unique: Caddy 2.11.6 and later refuse a map with a repeated input.
      (map (login: "${login} ${login} Admin") (lib.unique grafanaAuth.admins))
      [ "Remote-User {grafana_user}" "Remote-Role {grafana_role}" ]))
  ];

  # Pocket ID's first-admin setup, the pages and the API call that makes
  # the admin, as Pocket ID 2.7.0 has them (/setup redirects to
  # /signup/setup). Only the logins in homelab.pocketId.setupLogins reach
  # them; everyone else, and requests with a token, which get no identity,
  # get 403. See docs/adr/0018-pocket-id-is-the-oidc-provider.md.
  pocketIdSetupPaths = [
    "/setup" "/setup/*"
    "/signup/setup" "/signup/setup/*"
    "/api/signup/setup" "/api/signup/setup/*"
  ];
  pocketIdSnippet = lib.optionalString pocketId.enable (lib.concatStringsSep "\n" ([
    "(pocket_id_setup) {"
    "\t@pocket_id_setup path ${toString pocketIdSetupPaths}"
    "\troute @pocket_id_setup {"
    "\t\timport tailnet_identity"
    # One header line per login, which Caddy ORs within the field.
    "\t\t@pocket_id_setup_refused not {"
  ] ++ map (login: "\t\t\theader Remote-User ${login}") (lib.unique pocketId.setupLogins) ++ [
    "\t\t}"
    "\t\trespond @pocket_id_setup_refused \"Pocket ID's setup is only for the site's owner.\" 403"
    "\t}"
    "}"
    ""
    ""
  ]));

  # The OIDC login gate's snippets, from homelab.reverseProxy.oidcGate
  # (docs/adr/0019-oidc-login-gate-at-the-proxy.md). oauth2-proxy's own
  # pages under /oauth2/ (the sign-in, its callback and sign-out) go to it;
  # everything else asks its /oauth2/auth first. It answers 202 with the
  # user name for a session of a user in allowed_emails, which holds the
  # user names here since oauth2-proxy takes preferred_username as the
  # email; 401 with no session, which starts the sign-in at the provider
  # and comes back to the page asked for; and 403 for anyone else.
  # copy_headers deletes the client's Remote-User before it sets it. Both
  # directives come before handle in Caddy's order, so a site's own handle
  # blocks cannot skip the gate. The uri's query replaces the client's, so
  # a client cannot add names to allowed_emails. /oauth2/start keeps the
  # client's query, and with it any rd, which oauth2-proxy takes only as a
  # path on the same site, since it has no whitelisted domains.
  gateDial = "unix/${gate.socket}";
  gateSnippet = name: users: lib.concatStringsSep "\n" [
    "(${name}) {"
    "\t@${name}_flow path /oauth2/*"
    "\thandle @${name}_flow {"
    "\t\treverse_proxy ${gateDial}"
    "\t}"
    "\t@${name}_site not path /oauth2/*"
    "\tforward_auth @${name}_site ${gateDial} {"
    "\t\turi /oauth2/auth?allowed_emails=${lib.concatStringsSep "," (lib.unique users)}"
    "\t\tcopy_headers X-Auth-Request-Email>Remote-User"
    "\t\t@${name}_no_session status 401"
    "\t\thandle_response @${name}_no_session {"
    "\t\t\treverse_proxy ${gateDial} {"
    "\t\t\t\trewrite /oauth2/start"
    "\t\t\t\theader_up X-Auth-Request-Redirect {http.request.orig_uri}"
    "\t\t\t}"
    "\t\t}"
    "\t\t@${name}_refused status 403"
    "\t\thandle_response @${name}_refused {"
    "\t\t\trespond \"This site is not open to the account you signed in with. /oauth2/sign_out signs out.\" 403"
    "\t\t}"
    "\t}"
    "}"
    ""
    ""
  ];
  gateSnippets = lib.optionalString gate.enable (
    gateSnippet "oidc_gate" (gate.owners ++ gate.users)
    + gateSnippet "oidc_owner_only" gate.owners);

  generatedSnippets = identitySnippets + pocketIdSnippet + gateSnippets;

  caddyfileText = builtins.readFile cfg.caddyfile;

  # Snippet definitions may come before the global options block; Caddy only
  # needs them defined before a site imports them.
  caddyFile = pkgs.writeText "caddyfile" (
    lib.optionalString (generatedSnippets != "")
      "# Generated by containers/reverse-proxy.nix from homelab.forgejo.proxyAuth,\n# homelab.observability.grafanaProxyAuth, homelab.pocketId.setupLogins and\n# homelab.reverseProxy.oidcGate.\n${generatedSnippets}"
    + builtins.replaceStrings [ "__DOMAIN__" ] [ domain ] caddyfileText
  );

  isTailnetLogin = login: builtins.match "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+" login != null;
  notFoundHtml = pkgs.writeText "404.html" (builtins.readFile cfg.notFoundPage);

  # The tailnet_identity snippet in the example Caddyfile dials this path.
  # It sits in its own directory, mounted into the container, rather than
  # under nginx-auth's RuntimeDirectory: systemd deletes and recreates that
  # one when the service restarts, and the container's bind mount would keep
  # pointing at the deleted directory.
  identitySocketDir = "/run/tailnet-identity";

  # oauth2-proxy's socket directory, made by tmpfiles rather than as a
  # RuntimeDirectory for the same reason.
  gateSocketDir = dirOf gate.socket;
  gateImports = lib.hasInfix "import oidc_gate" caddyfileText
    || lib.hasInfix "import oidc_owner_only" caddyfileText;
  gateClient = pocketId.clients.${gate.clientId} or null;

  # Writes 16 random bytes as hex to the file named, unless it has a key
  # already. oauth2-proxy decodes the hex as base64, to a 24-byte AES key.
  gateCookieSecret = pkgs.writeShellApplication {
    name = "oidc-gate-cookie-secret";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      umask 077
      file=$1
      [ -s "$file" ] && exit 0
      install -d -m 0700 "$(dirname "$file")"
      tmp=$(mktemp "$(dirname "$file")/.oidc-gate-cookie-secret.XXXXXX")
      od -An -tx1 -N16 /dev/urandom | tr -d ' \n' > "$tmp"
      chmod 0400 "$tmp"
      mv -f "$tmp" "$file"
      echo "Generated $file."
    '';
  };
  minutes = d: let m = builtins.match "([0-9]+)(h|m)" d;
    in lib.toInt (builtins.head m) * (if lib.last m == "h" then 60 else 1);

  uid = config.users.users.caddy.uid;
  gid = config.users.groups.caddy.gid;
  hostUserCheck = pkgs.callPackage ./host-user-check.nix { };
in
{
  imports = [ ../modules/options.nix ];

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.tailscaleIdentity.enable
            || !(lib.hasInfix "import tailnet_identity" caddyfileText);
          message = "The Caddyfile imports tailnet_identity, which needs homelab.reverseProxy.tailscaleIdentity.enable.";
        }
        {
          assertion = cfg.tailscaleIdentity.enable || !(forgejoAuth.enable || grafanaAuth.enable);
          message = "homelab.forgejo.proxyAuth and homelab.observability.grafanaProxyAuth take the identity from tailnet_identity, which needs homelab.reverseProxy.tailscaleIdentity.enable.";
        }
        {
          assertion = forgejoAuth.enable || !(lib.hasInfix "import forgejo_identity" caddyfileText);
          message = "The Caddyfile imports forgejo_identity, which needs homelab.forgejo.proxyAuth.enable.";
        }
        {
          assertion = grafanaAuth.enable || !(lib.hasInfix "import grafana_identity" caddyfileText);
          message = "The Caddyfile imports grafana_identity, which needs homelab.observability.grafanaProxyAuth.enable.";
        }
        {
          assertion = pocketId.enable || !(lib.hasInfix "import pocket_id_setup" caddyfileText);
          message = "The Caddyfile imports pocket_id_setup, which needs homelab.pocketId.enable.";
        }
        {
          # Without the guard, anyone on the tailnet who opens Pocket ID's
          # setup first becomes its admin.
          assertion = !pocketId.enable || lib.hasInfix "import pocket_id_setup" caddyfileText;
          message = "homelab.pocketId needs its site in the Caddyfile to import pocket_id_setup, which keeps its first-admin setup to homelab.pocketId.setupLogins.";
        }
        {
          assertion = !pocketId.enable || (cfg.tailscaleIdentity.enable && pocketId.setupLogins != [ ]);
          message = "homelab.pocketId needs homelab.pocketId.setupLogins and homelab.reverseProxy.tailscaleIdentity.enable, so that only those tailnet logins reach its first-admin setup.";
        }
        {
          assertion = gate.enable || !gateImports;
          message = "The Caddyfile imports oidc_gate or oidc_owner_only, which need homelab.reverseProxy.oidcGate.enable.";
        }
        {
          # Without it the gate has no client to sign in with.
          assertion = !(gate.enable && pocketId.enable && gate.issuer == pocketId.url)
            || (gateClient != null && lib.elem "oauth2-proxy.service" gateClient.units);
          message = "homelab.reverseProxy.oidcGate signs in through Pocket ID, which needs its client declared as homelab.pocketId.clients.${gate.clientId} with oauth2-proxy.service among its units (see examples/server.nix).";
        }
        {
          assertion = !gate.enable || minutes gate.sessionLifetime > 30;
          message = "homelab.reverseProxy.oidcGate.sessionLifetime must be longer than the 30 minutes after which a session is renewed.";
        }
        {
          assertion = lib.all isTailnetLogin (lib.attrNames forgejoAuth.users);
          message = "homelab.forgejo.proxyAuth.users has keys that are not tailnet logins (alice@github): ${toString (lib.filter (l: !isTailnetLogin l) (lib.attrNames forgejoAuth.users))}.";
        }
      ];

      # Caddy runs as this user, not as root in the container
      # (docs/adr/0014-containers-run-unprivileged.md). Static uid so the
      # container's user option has a value at eval time; see "Static user
      # ids" in the README for the allocation. A host that already has a
      # caddy user keeps its uid (NixOS does not change it), so such a host
      # overrides these defaults with its existing uid and gid.
      users.users.caddy = {
        isSystemUser = true;
        group = "caddy";
        uid = lib.mkDefault 606;
      };
      users.groups.caddy = {
        gid = lib.mkDefault 606;
      };

      # The certificate's directory and files belong to the caddy group, so
      # Caddy reads them without root. The acme units re-own the files with
      # the group they are given when they next run, which a rebuild that
      # changes it does.
      security.acme.certs.${domain}.group = "caddy";

      virtualisation.oci-containers.containers.caddy = {
        image = "docker.io/library/caddy@sha256:4851e54a46b206517c574821bb5cc67f170d2156041e9fbc4c9193b45e84a75b"; # 2.11.9, :2 as of 2026-11-18
        # When homelab.tailnetIp is set, publishing 443 bound to that address
        # (instead of 0.0.0.0) is what makes every site tailnet-only: there is
        # simply no listener on the LAN interfaces. This replaces a per-vhost
        # tailnet matcher in the Caddyfile, which could not work because
        # tailscale source-NATs the forwarded connections to the bridge
        # gateway before Caddy sees the client IP, unless
        # tailscaleIdentity turns that off.
        ports = [ (if tailnetIp != null then "${tailnetIp}:443:443" else "443:443") ];
        autoStart = true;
        user = "${toString uid}:${toString gid}";
        # /data and /config are the image's XDG_DATA_HOME and
        # XDG_CONFIG_HOME, where Caddy keeps its state and autosaves its
        # config. :U hands each volume to the caddy user on every start, so
        # data written while Caddy ran as root, or restored from a backup,
        # is its own.
        volumes = [
          "${caddyFile}:/etc/caddy/Caddyfile"
          "${notFoundHtml}:/var/www/404.html:ro"
          "/var/lib/acme/${domain}:/certs:ro"
          "caddy-volume:/data:U"
          "caddy-config:/config:U"
        ] ++ lib.optional cfg.tailscaleIdentity.enable "${identitySocketDir}:${identitySocketDir}"
        # Forgejo's HTTP socket with proxy authentication on; containers/forgejo.nix
        # creates the directory. Mounting the directory rather than the socket
        # keeps it working when Forgejo restarts and makes a new socket.
        ++ lib.optional forgejoAuth.enable "/run/forgejo-http:/run/forgejo-http"
        # Pocket ID's socket (modules/pocket-id.nix), in a directory of the
        # caddy group; mounted as a directory for the same reason.
        ++ lib.optional pocketId.enable "${dirOf pocketId.socket}:${dirOf pocketId.socket}"
        # oauth2-proxy's socket, for the OIDC gate; the same again.
        ++ lib.optional gate.enable "${gateSocketDir}:${gateSocketDir}";
        extraOptions = [
          "--security-opt=no-new-privileges"
          "--cap-drop=ALL"
          # Listening on 443 in the container, a privileged port. podman
          # gives a non-root user the capabilities it adds as ambient ones.
          "--cap-add=NET_BIND_SERVICE"
        ]
        # A fixed address on podman's default network, so services can trust
        # headers from Caddy by its address.
        ++ lib.optional (cfg.address != null) "--ip=${cfg.address}"
        # Forgejo's socket directory is mode 0750, owned by forgejo; its
        # group lets Caddy in, and only Caddy mounts it.
        ++ lib.optional forgejoAuth.enable "--group-add=${toString config.users.groups.forgejo.gid}";
      };

      # The tailnet port bind only succeeds once tailscale has assigned the
      # tailnet IP. On a cold boot podman can start before that, so order after
      # tailscaled and retry on failure (with the start-rate limiter disabled)
      # until the address exists, instead of leaving Caddy down.
      systemd.services.podman-caddy = lib.mkIf (tailnetIp != null) {
        after = [ "tailscaled.service" ];
        wants = [ "tailscaled.service" ];
        startLimitIntervalSec = 0;
        serviceConfig = {
          Restart = lib.mkForce "on-failure";
          RestartSec = lib.mkForce 5;
        };
      };
    }

    {
      # The certificate and the identity socket are the caddy group's by
      # name; the container runs as its number.
      systemd.services.podman-caddy.serviceConfig.ExecStartPre = lib.mkBefore [
        (utils.escapeSystemdExecArgs [ "${hostUserCheck}/bin/host-user-check" "caddy" (toString uid) (toString gid) ])
      ];
    }

    (lib.mkIf cfg.tailscaleIdentity.enable {
      # tailscale's nginx-auth answers a request carrying Remote-Addr and
      # Remote-Port with the tailnet user behind that address (204 and
      # Tailscale-User), 403 for a tagged node and 401 for an address that is
      # not a tailnet peer.
      services.tailscaleAuth = {
        enable = true;
        socketPath = "${identitySocketDir}/whois.sock";
      };

      # The socket stays owned by nginx-auth's user, and its group becomes
      # caddy's, mode 0660, so Caddy, which no longer runs as root, connects
      # to it and nothing else but root does. systemd makes the directory
      # when it binds the socket; 0755 lets the caddy user through it. Both
      # modes are set here, not left to nixpkgs' and systemd's defaults,
      # since the identity-socket check holds them to what 606 needs.
      systemd.sockets.tailscale-nginx-auth.socketConfig = {
        SocketGroup = lib.mkForce "caddy";
        SocketMode = lib.mkForce "0660";
        DirectoryMode = "0755";
      };

      # systemd sets a socket's owner and mode only when it creates the
      # socket, and switch-to-configuration does not restart a changed
      # .socket unit (nixpkgs issue 74899), so a switch that changed the
      # group left the old socket, which Caddy could not open. It does
      # restart a changed socket-activated service by stopping it and its
      # socket and starting the socket again, which makes a new socket. The
      # trigger makes every change to the socket a change to the service.
      # Caddy requires the socket, so it stops with it and comes back when
      # the switch starts multi-user.target again.
      systemd.services.tailscale-nginx-auth.restartTriggers = [
        (builtins.toJSON {
          inherit (config.systemd.sockets.tailscale-nginx-auth) listenStreams socketConfig;
        })
      ];

      # tailscale marks everything forwarded in from tailscale0 and
      # masquerades it on the way out (its subnet-route SNAT, on by default).
      # Podman DNATs 443 to the caddy container, so these connections are
      # forwarded and arrive from the podman bridge address, which WhoIs
      # cannot resolve. podman itself only masquerades hairpin and localhost
      # traffic. Without the SNAT the container sees the tailnet peer.
      services.tailscale.extraSetFlags = [ "--snat-subnet-routes=false" ];

      systemd.services.podman-caddy = {
        after = [ "tailscale-nginx-auth.socket" ];
        requires = [ "tailscale-nginx-auth.socket" ];
      };
    })

    (lib.mkIf gate.enable {
      # The OIDC login gate (docs/adr/0019-oidc-login-gate-at-the-proxy.md):
      # nixpkgs' oauth2-proxy, which answers Caddy's forward_auth and runs
      # the sign-in with the provider. It keeps no state; the session is
      # the encrypted cookie, with the provider's tokens in it.
      services.oauth2-proxy = {
        enable = true;
        provider = "oidc";
        oidcIssuerUrl = gate.issuer;
        clientID = gate.clientId;
        inherit (gate) clientSecretFile;
        # preferred_username is in profile. Groups and email are not asked
        # for: Pocket ID marks emails unverified unless told otherwise,
        # and oauth2-proxy refuses an unverified email claim.
        scope = "openid profile";
        # The socket is the only listener; its directory keeps out
        # everyone but oauth2-proxy and Caddy.
        httpAddress = "unix://${gate.socket},mode=0666";
        # forward_auth needs only the answer, never an upstream.
        upstream = "static://202";
        # Who may pass is up to each snippet's allowed_emails; any user of
        # the provider gets a session.
        email.domains = [ "*" ];
        passBasicAuth = false;
        # /oauth2/auth answers with X-Auth-Request-Email, which Caddy
        # passes on as Remote-User.
        setXauthrequest = true;
        cookie = {
          domain = gate.cookieDomain;
          expire = gate.sessionLifetime;
          # Renewed with the refresh token after half an hour, which
          # Pocket ID refuses once the user is disabled or deleted.
          refresh = "30m";
          secretFile = gate.cookieSecretFile;
        };
        extraConfig = {
          # The user name stands in for the email: always there, unique,
          # and what allowed_emails matches.
          oidc-email-claim = "preferred_username";
          code-challenge-method = "S256";
          # /oauth2/sign_in goes to the provider without a page of its own.
          skip-provider-button = true;
        };
      };

      systemd.tmpfiles.rules = [
        "d ${gateSocketDir} 0750 oauth2-proxy caddy - -"
      ];

      # Before oauth2-proxy, since systemd loads its credentials before any
      # ExecStartPre would run.
      systemd.services.oidc-gate-cookie-secret = {
        description = "The OIDC gate's cookie secret";
        before = [ "oauth2-proxy.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = utils.escapeSystemdExecArgs [ "${gateCookieSecret}/bin/oidc-gate-cookie-secret" gate.cookieSecretFile ];
        };
      };

      systemd.services.oauth2-proxy = {
        after = [ "oidc-gate-cookie-secret.service" ];
        requires = [ "oidc-gate-cookie-secret.service" ];
        # It reads the provider's discovery document at start and exits
        # when the provider, behind this host's own Caddy, is not up yet;
        # it tries again until it is.
        startLimitIntervalSec = 0;
        serviceConfig = {
          RestartSec = 5;
          # A socket left behind by a crash would keep it from listening.
          ExecStartPre = "${pkgs.coreutils}/bin/rm -f ${gate.socket}";
          ReadWritePaths = [ gateSocketDir ];
          NoNewPrivileges = true;
          CapabilityBoundingSet = "";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
        };
      };
    })
  ];
}
