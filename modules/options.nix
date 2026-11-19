{ config, lib, ... }:

let
  cfg = config.homelab;

  # A tailnet login name as Tailscale reports it: alice@github,
  # alice@example.com. Restricted to characters that need no quoting in the
  # Caddyfile snippets built from them.
  tailnetLogin = lib.types.strMatching "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+";

  # A Pocket ID user name, by Pocket ID's own rule (validateUsernameRegex).
  # It has no comma, so the OIDC gate's snippets can list names in a query.
  pocketIdUsernameRegex = "[a-zA-Z0-9]([a-zA-Z0-9_.@-]*[a-zA-Z0-9])?";

  # A service's sign in through an OpenID Connect provider: tsidp
  # (docs/adr/0006-tsidp-for-oidc-sign-in.md) or Pocket ID
  # (docs/adr/0018-pocket-id-is-the-oidc-provider.md). The client id and
  # secret are runtime files, never in the store. self is the option set
  # itself, for the issuer's default.
  oidcClientOptions = { service, redirect, secretPrefix, unit, self }: {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Sign in to ${service} through the OpenID Connect provider named by
        provider, at the issuer URL. Its client has the redirect URI
        ${redirect}. Declare it in homelab.pocketId.clients or
        homelab.tsidp.clients, with the two files below, and the provider
        writes its id and secret there; with another provider, register it
        there and put them in the files by hand.
      '';
    };
    provider = lib.mkOption {
      type = lib.types.enum [ "tsidp" "pocket-id" ];
      default = "tsidp";
      description = ''
        The provider ${service} signs in through. With tsidp (homelab.tsidp)
        the issuer is set by hand. With pocket-id the issuer is
        homelab.pocketId.url, Pocket ID must run on this host, and its
        client must be declared in homelab.pocketId.clients with the two
        files below and ${unit} among its units
        (docs/pocket-id.md has the switch).
      '';
    };
    issuer = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "https://[^/]+(/.*[^/])?");
      default = if self.provider == "pocket-id" then cfg.pocketId.url else null;
      defaultText = lib.literalExpression ''
        if provider == "pocket-id" then homelab.pocketId.url else null
      '';
      example = "https://idp.tailnet.invalid";
      description = ''
        The provider's issuer URL, without a trailing slash. For tsidp it is
        https://<homelab.tsidp.hostName>.<tailnet>.ts.net and must be set.
        For Pocket ID it is homelab.pocketId.url; leave it unset.
      '';
    };
    clientIdFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/secrets/${secretPrefix}-client-id";
      description = "File holding ${service}'s client id, written by Pocket ID or tsidp for a declared client, or provisioned out of band.";
    };
    clientSecretFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/secrets/${secretPrefix}-client-secret";
      description = "File holding ${service}'s client secret, made by Pocket ID or tsidp for a declared client, or provisioned out of band.";
    };
  };
in
{
  options.homelab = {
    username = lib.mkOption {
      type = lib.types.str;
      example = "alice";
      description = "Primary user account created on every host.";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      example = "home.example.com";
      description = ''
        Base domain for all services. Modules that consume asset files
        replace the literal __DOMAIN__ in them with this value at build time.
      '';
    };

    acmeEmail = lib.mkOption {
      type = lib.types.str;
      default = "admin@${cfg.domain}";
      defaultText = lib.literalExpression ''"admin@''${config.homelab.domain}"'';
      description = "Contact email for ACME certificate registration.";
    };

    adminKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "SSH public keys authorized for the primary user.";
    };

    deployCaKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "sk-ssh-ed25519@openssh.com AAAA... deploy-ca" ];
      description = ''
        SSH CA public keys trusted for root logins. When set, every host runs
        sshd (loopback only unless the openssh module is imported) and accepts
        root certificates signed by these keys, so a deploy tool can sign one
        short-lived certificate and reach the whole fleet with it.
      '';
    };

    tailnetIp = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "100.64.0.1";
      description = ''
        This host's tailnet IP. When set, the reverse proxy publishes 443
        bound to this address only, which makes every site tailnet-only:
        there is simply no listener on the LAN interfaces.
      '';
    };

    allTerminfo = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install the terminfo of the terminals nixpkgs packages (kitty,
        alacritty, foot, wezterm, ghostty and others), so ncurses programs
        such as nano work over SSH from any of them. It is nixpkgs'
        environment.enableAllTerminfo without termite, whose terminfo does
        not build at our pin.
      '';
    };

    timeZone = lib.mkOption {
      type = lib.types.str;
      default = "Etc/UTC";
      example = "Europe/Stockholm";
      description = "System time zone for all hosts.";
    };

    defaultLocale = lib.mkOption {
      type = lib.types.str;
      default = "en_US.UTF-8";
      description = "Default system locale (messages, fallback for everything).";
    };

    regionalLocale = lib.mkOption {
      type = lib.types.str;
      default = cfg.defaultLocale;
      defaultText = lib.literalExpression "config.homelab.defaultLocale";
      example = "sv_SE.UTF-8";
      description = ''
        Locale for regional formats (LC_TIME, LC_MONETARY, LC_PAPER, ...),
        kept separate so messages can stay English while dates, units and
        currency follow the local convention.
      '';
    };

    keyboard = {
      layout = lib.mkOption {
        type = lib.types.str;
        default = "us";
        example = "se";
        description = "XKB keyboard layout for greeters and X/Wayland sessions.";
      };
      variant = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "us";
        description = "XKB layout variant.";
      };
      consoleKeyMap = lib.mkOption {
        type = lib.types.str;
        default = "us";
        example = "sv-latin1";
        description = "Virtual console keymap.";
      };
    };

    logsHost = lib.mkOption {
      type = lib.types.str;
      default = "logs.${cfg.domain}";
      defaultText = lib.literalExpression ''"logs.''${config.homelab.domain}"'';
      description = "Hostname the fluent-bit logging agent ships journals to (TLS, port 443).";
    };

    observabilityAgent.textfileDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/prometheus-node-exporter/textfile";
      description = ''
        Directory of the node exporter's textfile collector: it exports the
        metrics in every *.prom file there. The observability-agent module
        creates it; the backups module writes each job's last successful
        run into it, and the vulnerability-scan module its counts.
      '';
    };

    observabilityAgent.nvidiaGpu.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run nixpkgs' NVIDIA GPU exporter (nvidia_gpu_exporter, which reads
        nvidia-smi and works on consumer GeForce cards) on port 9835, open
        on tailscale0 only. Its metrics are named nvidia_smi_* with a uuid
        label per GPU, as the example GPU dashboard expects. Needs the
        driver from the nvidia module.
      '';
    };

    nvidia.cdiCheck.units = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9:_.@-]+");
      default = [ ];
      example = [ "podman-frigate" ];
      description = ''
        systemd services, named without .service, of containers that get
        the GPU through the NVIDIA container toolkit's CDI spec
        (/run/cdi/nvidia-container-toolkit.json). Each checks the spec
        before every start, as its first ExecStartPre: it must mount this
        system's driver and every path it names must exist, or this
        system's generator writes it again. Each also starts after, and
        requires, nvidia-container-toolkit-cdi-generator, so a restart of
        the generator restarts it. Needs the nvidia module and
        hardware.nvidia-container-toolkit.enable (docs/nvidia.md,
        docs/adr/0013-gpu-containers-check-the-cdi-spec.md).
      '';
    };

    network.role = lib.mkOption {
      type = lib.types.enum [ "server" "workstation" "htpc" "custom" ];
      default = "custom";
      description = "The primary role of the host for determining base firewall rules.";
    };

    backups.resticRepo = lib.mkOption {
      type = lib.types.str;
      example = "rclone:gdrive:my-backup";
      description = ''
        restic repository string shared by every backup job: the built in
        vaultwarden job and each entry of homelab.backups.jobs. Jobs tell
        their snapshots apart by tag (the job name) and by path.
      '';
    };

    backups.jobs = lib.mkOption {
      default = { };
      example = lib.literalExpression ''
        {
          forgejo = {
            paths = [ "/var/lib/forgejo" ];
            sqliteDatabases = [ "/var/lib/forgejo/data/gitea.db" ];
          };
        }
      '';
      description = ''
        restic backup jobs, each a restic-backups-<name> unit and timer
        against homelab.backups.resticRepo, with the password and rclone
        credentials in /var/lib/secrets/restic-password and
        /var/lib/secrets/rclone.env. The name vaultwarden is taken by the
        built in job. Restoring is described in docs/backups.md.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          paths = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            example = [ "/var/lib/forgejo" ];
            description = "Files and directories to back up.";
          };

          sqliteDatabases = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "/var/lib/forgejo/data/gitea.db" ];
            description = ''
              Live SQLite databases, as absolute paths. Before each run every
              one is copied with sqlite3's .backup to the same path under
              /var/backup/<name>/ (for example
              /var/backup/forgejo/var/lib/forgejo/data/gitea.db), and the
              copy is backed up instead of the live file. The live file and
              its -wal, -shm and -journal sidecars are excluded. The copies
              are removed after the run, also when it fails. A database that
              does not exist fails the run.
            '';
          };

          exclude = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "/var/lib/forgejo/data/tmp" ];
            description = "restic exclude patterns, in addition to the live databases.";
          };

          schedule = lib.mkOption {
            type = lib.types.str;
            default = "daily";
            example = "*-*-* 03:00:00";
            description = ''
              When the job runs, as a systemd OnCalendar value. Missed runs
              are caught up after boot (Persistent). Jobs may overlap; they
              wait for each other's repository lock.
            '';
          };
        };
      });
    };

    vulnerabilityScan = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Scan the image of every container in
          virtualisation.oci-containers.containers for known vulnerabilities
          with Trivy, from the host's podman storage, without pulling
          (docs/adr/0017-running-images-are-scanned.md). The counts per
          severity go to the node exporter's textfile collector, and each
          container's full report to
          /var/lib/vulnerability-scan/<container>.json. Trivy downloads its
          vulnerability database from mirror.gcr.io (ghcr.io as fallback)
          over HTTPS on each run. Needs the observability-agent module.
        '';
      };
      schedule = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        example = "*-*-* 04:00:00";
        description = ''
          When the scan runs, as a systemd OnCalendar value, delayed by up
          to an hour at random. A missed run is caught up after boot
          (Persistent). The alerts in examples/assets/grafana-alerting.yaml
          expect a run at least daily.
        '';
      };
    };

    yubikey.u2fKeysFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        pam_u2f authfile with the enrolled keys (u2f_keys format). Generate
        with pamu2fcfg using origin/appid pam://yubikey.
      '';
    };

    hyprland = {
      hyprlandLua = lib.mkOption {
        type = lib.types.path;
        description = ''
          hyprland.lua installed into the user's ~/.config/hypr. Hyprland
          0.57 and later read only the Lua config.
        '';
      };
      hyprpaperConf = lib.mkOption {
        type = lib.types.path;
        description = "hyprpaper.conf installed into the user's ~/.config/hypr.";
      };
      monitorsLua = lib.mkOption {
        type = lib.types.path;
        description = ''
          Host-specific monitor layout, installed as monitors.lua next to
          hyprland.lua so that require("monitors") loads it. Point it at a
          per-host file from your config repo.
        '';
      };
      hyprlockConf = lib.mkOption {
        type = lib.types.path;
        description = "hyprlock.conf installed into the user's ~/.config/hypr.";
      };
      hypridleConf = lib.mkOption {
        type = lib.types.path;
        description = "hypridle.conf installed into the user's ~/.config/hypr.";
      };
      waybarConfig = lib.mkOption {
        type = lib.types.path;
        description = "waybar config.jsonc installed into the user's ~/.config/waybar.";
      };
      waybarStyle = lib.mkOption {
        type = lib.types.path;
        description = "waybar style.css installed into the user's ~/.config/waybar.";
      };
    };

    reverseProxy = {
      caddyfile = lib.mkOption {
        type = lib.types.path;
        description = "Caddyfile; __DOMAIN__ occurrences are templated with homelab.domain.";
      };
      notFoundPage = lib.mkOption {
        type = lib.types.path;
        description = "Static 404 page served by Caddy.";
      };
      tailscaleIdentity.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Let Caddy look up the tailnet user behind each request, so sites
          that `import tailnet_identity` (see the example Caddyfile) pass the
          login name (`alice@github`) to their upstream as `Remote-User`.
          Runs tailscale's nginx-auth WhoIs helper on a unix socket that the
          caddy container mounts, and turns off tailscale's source NAT of
          forwarded traffic (`tailscale set --snat-subnet-routes=false`) so
          Caddy sees the tailnet client address. Do not enable on a host
          that is a subnet router or exit node unless its LAN routes the
          tailnet range back to it (docs/adr/0003-tailscale-identity-for-sign-in.md).
        '';
      };
      address = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "10.88.255.2";
        example = null;
        description = ''
          Fixed address of the caddy container on podman's default network
          (10.88.0.0/16), given to podman as --ip. Services that take
          Remote-User from Caddy, like Grafana with
          homelab.observability.grafanaProxyAuth, trust only this address.
          The default sits high in the range, clear of the addresses podman
          hands out in order. Null lets podman pick one, which the proxy
          authentication options refuse.
        '';
      };
      oidcGate = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            A sign-in gate in front of sites that cannot sign anyone in
            themselves (docs/adr/0019-oidc-login-gate-at-the-proxy.md).
            Runs nixpkgs' oauth2-proxy on a unix socket that only the caddy
            container mounts. A site that imports the generated snippet
            oidc_gate or oidc_owner_only is reached only after signing in
            at the OpenID Connect provider, and gets the user's name as
            Remote-User. Declare its client in homelab.pocketId.clients
            (see examples/server.nix).
          '';
        };
        issuer = lib.mkOption {
          type = lib.types.strMatching "https://[^/]+(/.*[^/])?";
          default = cfg.pocketId.url;
          defaultText = lib.literalExpression "homelab.pocketId.url";
          description = ''
            The provider's issuer URL, without a trailing slash. Users are
            told apart by its preferred_username claim, which Pocket ID
            fills with the user name.
          '';
        };
        clientId = lib.mkOption {
          type = lib.types.strMatching "[A-Za-z0-9._-]{2,128}";
          default = "oidc-gate";
          description = ''
            The gate's client id at the provider: the key of its entry in
            homelab.pocketId.clients.
          '';
        };
        clientSecretFile = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/secrets/oidc-gate-oidc-client-secret";
          description = ''
            File holding the client secret, readable by root; systemd hands
            it to oauth2-proxy as a credential. Pocket ID's default
            secretFile for a client named oidc-gate.
          '';
        };
        cookieSecretFile = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/secrets/oidc-gate-cookie-secret";
          description = ''
            The key the session cookie is encrypted and signed with, owned
            by root, mode 0400. Generated on the first start when missing;
            replacing it signs everyone out.
          '';
        };
        cookieDomain = lib.mkOption {
          type = lib.types.str;
          default = ".${cfg.domain}";
          defaultText = lib.literalExpression ''".''${homelab.domain}"'';
          description = ''
            Domain of the session cookie. Under the default one sign-in
            covers every gated site of homelab.domain, and signing out of
            one signs out of all.
          '';
        };
        sessionLifetime = lib.mkOption {
          type = lib.types.strMatching "[0-9]+(h|m)";
          default = "24h";
          description = ''
            How long a sign-in lasts, in hours or minutes, after which the
            browser goes through the provider again. Within it the session
            is renewed with the provider every 30 minutes, so a user
            disabled or deleted there is out within half an hour.
          '';
        };
        owners = lib.mkOption {
          type = lib.types.nonEmptyListOf (lib.types.strMatching pocketIdUsernameRegex);
          example = [ "alice" ];
          description = ''
            Provider user names (Pocket ID's username) let through
            oidc_owner_only, and through oidc_gate.
          '';
        };
        users = lib.mkOption {
          type = lib.types.listOf (lib.types.strMatching pocketIdUsernameRegex);
          default = [ ];
          example = [ "bob" ];
          description = ''
            Further user names let through oidc_gate, besides
            homelab.reverseProxy.oidcGate.owners.
          '';
        };
        socket = lib.mkOption {
          type = lib.types.str;
          default = "/run/oidc-gate/oauth2-proxy.sock";
          readOnly = true;
          description = ''
            The unix socket oauth2-proxy serves on. Its directory is
            mounted into the caddy container, and the generated snippets
            dial it.
          '';
        };
      };
    };

    observability = {
      prometheusConfig = lib.mkOption {
        type = lib.types.path;
        description = "prometheus.yml with the scrape targets.";
      };
      lokiConfig = lib.mkOption {
        type = lib.types.path;
        description = "Loki local-config.yaml.";
      };
      alertingConfig = lib.mkOption {
        type = lib.types.path;
        description = "Grafana alerting provisioning YAML (rules and contact points).";
      };
      dashboardsDir = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Directory of Grafana dashboard JSON files, provisioned read-only
          into the Homelab folder. A change needs a rebuild. Null provisions
          no files, for a host whose dashboards all come through
          homelab.observability.grafanaGitSync. A dashboard is in one or the
          other, never both.
        '';
      };
      grafanaGitSync = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Sync dashboards both ways between Grafana and a directory of a
            Git repository with Grafana's Git Sync, Pure Git type. Grafana
            pulls the branch every intervalSeconds, and a dashboard saved in
            Grafana's UI is committed and pushed to the branch. The
            grafana-git-sync unit creates or updates the repository in
            Grafana through its API. The repository must let the token push
            to the branch, so it is not a protected one
            (docs/adr/0009-dashboards-through-grafana-git-sync.md,
            docs/dashboards.md).
          '';
        };
        url = lib.mkOption {
          type = lib.types.strMatching "https://[^/@]+/.+";
          example = "https://git.example.com/org/dashboards.git";
          description = ''
            HTTPS URL of the repository, without credentials. Git Sync
            speaks Smart HTTP protocol v2 only, which Forgejo serves; not
            SSH. Grafana is allowed to reach this host even where it
            resolves to a private address.
          '';
        };
        branch = lib.mkOption {
          type = lib.types.str;
          default = "main";
          description = "Branch that Grafana pulls from and pushes to.";
        };
        path = lib.mkOption {
          type = lib.types.str;
          default = "dashboards";
          description = ''
            Directory in the repository holding the dashboards, relative to
            its root. Grafana ignores everything outside it.
          '';
        };
        intervalSeconds = lib.mkOption {
          type = lib.types.ints.between 10 86400;
          default = 60;
          description = ''
            How often Grafana pulls the branch. Forgejo sends Pure Git no
            webhooks, so this is how long a pushed change takes to show.
          '';
        };
        tokenFile = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/secrets/grafana-git-sync-token";
          description = ''
            Forgejo access token, with read and write access to the
            repository's contents, that Grafana pulls and pushes with.
            Owned by root, mode 0400, provisioned out of band; the
            grafana-git-sync unit hands it to Grafana, which keeps it
            encrypted.
          '';
        };
        apiTokenFile = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/secrets/grafana-git-sync-api-token";
          description = ''
            Token of a Grafana service account with the Admin role, which
            the grafana-git-sync unit calls Grafana's API with. Owned by
            root, mode 0400. When the file is missing or empty, the unit
            makes the service account grafana-git-sync and writes a new
            token of it here, deleting the account's older tokens; a token
            already in the file is used as it is. To make the unit sign in
            as Grafana's built-in admin, Grafana takes proxy authentication
            headers from 127.0.0.1 in its container
            (docs/adr/0012-git-sync-service-account-made-by-the-host.md).
          '';
        };
        seed = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = lib.literalExpression "./assets/dashboards";
          description = ''
            Directory of dashboard JSON files, searched recursively, that
            the grafana-git-sync unit commits once to a repository with no
            commits yet, under path on branch, before setting the
            repository up in Grafana. Plain dashboards need a uid and are
            put in the dashboard.grafana.app/v1 form Git Sync writes;
            files already in that form are kept. A repository with any
            history is never changed, so later edits to the directory have
            no effect. Null seeds nothing
            (docs/adr/0011-git-sync-seeds-an-empty-repository.md).
          '';
        };
      };
      probeTargets = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "https://.+");
        default = [ ];
        example = [ "https://vault.example.com" "https://status.example.com/api/health" ];
        description = ''
          HTTPS URLs the blackbox exporter probes with its http_2xx_tls
          module, the way clients reach them. A probe fails on a non-2xx
          answer or an invalid certificate, and reports the certificate's
          expiry. The host running the observability module must resolve
          each name to the address clients use (Caddy's tailnet address).
          Prometheus reads the list from
          /etc/prometheus/probe-targets.json (file_sd); the blackbox job in
          prometheus.yml points at it.
        '';
      };
      nvidiaGpuTargets = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching ".+:[0-9]+");
        default = [ ];
        example = [ "192.0.2.20:9835" ];
        description = ''
          host:port of the NVIDIA GPU exporters to scrape, the hosts with
          homelab.observabilityAgent.nvidiaGpu.enable, at addresses the
          Prometheus container reaches over the tailnet. Prometheus reads the
          list from /etc/prometheus/nvidia-gpu-targets.json (file_sd); the
          nvidia-gpu job in prometheus.yml points at it.
        '';
      };
      grafanaProxyAuth = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Sign in to Grafana with the tailnet identity Caddy passes as
            Remote-User, from homelab.reverseProxy.address only, and turn off
            anonymous access, password logins and basic auth. Grafana creates
            the user on first sign in. The status site imports
            `grafana_identity`, which the reverse proxy generates from
            homelab.observability.grafanaProxyAuth.admins
            (docs/adr/0005-proxy-auth-only-from-caddy.md). Off, Grafana keeps
            anonymous access with the Admin role, so anyone who reaches it is
            an admin.
          '';
        };
        admins = lib.mkOption {
          type = lib.types.listOf tailnetLogin;
          default = [ ];
          example = [ "alice@github" ];
          description = ''
            Tailnet logins that sign in to Grafana, all with the Admin role
            in the main organisation. Caddy passes no identity for anyone
            else, so they get no access.
          '';
        };
      };
      grafanaOidc = oidcClientOptions {
        service = "Grafana";
        redirect = "https://status.<domain>/login/generic_oauth";
        secretPrefix = "grafana-oidc";
        unit = "podman-grafana.service";
        self = cfg.observability.grafanaOidc;
      } // {
        admins = lib.mkOption {
          type = lib.types.listOf tailnetLogin;
          default = [ ];
          example = [ "alice@github" ];
          description = ''
            The users that sign in to Grafana, all with the Admin role in
            the main organisation, by their email claim. Grafana refuses
            everyone else. With tsidp they are tailnet logins: tsidp passes
            the login as the email claim, with its own name appended to
            GitHub and passkey logins (alice@github.idp.<tailnet>.ts.net),
            and the module matches both forms. With Pocket ID they are the
            emails of the users' Pocket ID accounts, which Pocket ID keeps
            unique; list only addresses an account holds, since a user may
            change their own email to one no one has.
          '';
        };
      };
    };

    homeassistant = {
      configurationFile = lib.mkOption {
        type = lib.types.path;
        description = "Home Assistant configuration.yaml; __DOMAIN__ is templated.";
      };
      automationsFile = lib.mkOption {
        type = lib.types.path;
        description = "Home Assistant automations.yaml; __DOMAIN__ is templated.";
      };
      scriptsFile = lib.mkOption {
        type = lib.types.path;
        description = "Home Assistant scripts.yaml; __DOMAIN__ is templated.";
      };
    };

    nvr.configFile = lib.mkOption {
      type = lib.types.path;
      description = "Frigate config.yaml; __DOMAIN__ is templated. RTSP credentials stay in the runtime env file.";
    };

    homepage = {
      settingsFile = lib.mkOption {
        type = lib.types.path;
        description = "homepage settings.yaml (mounted verbatim).";
      };
      servicesFile = lib.mkOption {
        type = lib.types.path;
        description = "homepage services.yaml; __DOMAIN__ is templated.";
      };
    };

    nextcloud = {
      bindAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = cfg.tailnetIp;
        defaultText = lib.literalExpression "config.homelab.tailnetIp";
        example = "192.0.2.10";
        description = ''
          Host address the Nextcloud AIO admin UI (port 8080) and its Apache
          container (APACHE_PORT, 11000) listen on. Defaults to the tailnet
          address, which keeps Nextcloud tailnet-only; set a LAN address, or
          "0.0.0.0", to opt in to LAN access. The module refuses to evaluate
          while it is null rather than listen on every interface.
        '';
      };
    };

    forgejo = {
      sshPort = lib.mkOption {
        type = lib.types.port;
        default = 2222;
        description = ''
          Port of Forgejo's built in SSH server, both inside the container
          and where it is published on the host. Clone URLs carry it:
          ssh://git@git.<domain>:<port>/<owner>/<repo>.git.
        '';
      };
      sshAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = cfg.tailnetIp;
        defaultText = lib.literalExpression "config.homelab.tailnetIp";
        example = "100.64.0.1";
        description = ''
          Host address Forgejo's SSH port is published on. Defaults to the
          tailnet address, which keeps git over SSH tailnet-only; the module
          refuses to evaluate while it is null rather than listen on every
          interface.
        '';
      };
      extraEnvironment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          FORGEJO__mailer__ENABLED = "true";
          FORGEJO__repository__DEFAULT_BRANCH = "main";
        };
        description = ''
          Site specific Forgejo settings as FORGEJO__section__KEY environment
          variables, added to the module's own and overriding them on a
          clash. Never put secrets here: the values end up in the Nix store.
        '';
      };
      admin = {
        name = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "alice";
          description = ''
            User name of Forgejo's first admin. With this and the email set,
            the forgejo-admin unit creates the admin on start when Forgejo
            has none, with a one-time password it prints to its journal
            (journalctl -u forgejo-admin). Null leaves the admin to be
            created by hand.
          '';
        };
        email = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "alice@example.com";
          description = "Email address of Forgejo's first admin; see homelab.forgejo.admin.name.";
        };
      };
      proxyAuth = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Sign in to Forgejo's web UI with the tailnet identity Caddy
            passes as Remote-User. Forgejo does not check where that header
            comes from, so its HTTP moves from port 3000 on the podman
            network to the unix socket /run/forgejo-http/http.sock, which
            only the caddy container mounts; the git site's reverse_proxy
            must point there. Only existing users sign in this way, with the
            name homelab.forgejo.proxyAuth.users maps the login to; the git
            site imports `forgejo_identity`, which the reverse proxy
            generates from it (docs/adr/0005-proxy-auth-only-from-caddy.md).
            Tokens over HTTPS and git over SSH work as before.
          '';
        };
        users = lib.mkOption {
          type = lib.types.attrsOf (lib.types.strMatching "[A-Za-z0-9._-]+");
          default = { };
          example = { "alice@github" = "alice"; };
          description = ''
            Tailnet login to Forgejo user name, for the users that may sign
            in with their tailnet identity. Keys are tailnet logins
            (alice@github). Caddy passes no identity for logins not listed.
          '';
        };
      };
      trustDeployCa = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Let Forgejo's built in SSH server accept user certificates signed
          by homelab.deployCaKeys, so the certificate a fleet run signs for
          the hosts also fetches and pushes on Forgejo, with one hardware key
          touch for the whole run. A certificate signs in as the Forgejo
          user whose account lists one of its principals as an SSH
          principal, and a user may list only their own user name
          (SSH_AUTHORIZED_PRINCIPALS_ALLOW = username). The user adds it
          once under Settings, SSH / GPG keys, Manage SSH principals. Off
          by default: it widens SSH access to Forgejo, and the hosts' CA
          alone does not ask for it
          (docs/adr/0015-forgejo-trusts-the-deploy-ca.md).
        '';
      };
      oidc = oidcClientOptions {
        service = "Forgejo";
        redirect = "https://git.<domain>/user/oauth2/<source>/callback, the source being tailscale with tsidp and pocket-id with Pocket ID";
        secretPrefix = "forgejo-oidc";
        unit = "forgejo-oidc.service";
        self = cfg.forgejo.oidc;
      };
    };

    tsidp = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Run tsidp, Tailscale's OpenID Connect provider, as its own tailnet
          node, with nixpkgs' services.tsidp. Its users are the tailnet's
          users; Forgejo and Grafana sign in through it with
          homelab.forgejo.oidc and homelab.observability.grafanaOidc
          (docs/adr/0006-tsidp-for-oidc-sign-in.md). It listens on its own
          node only, never on the host's interfaces.
        '';
      };
      hostName = lib.mkOption {
        type = lib.types.strMatching "[a-z0-9]([a-z0-9-]*[a-z0-9])?";
        default = "idp";
        description = ''
          tsidp's machine name on the tailnet. Its issuer URL is
          https://<hostName>.<tailnet>.ts.net.
        '';
      };
      authKeyFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/secrets/tsidp.env";
        description = ''
          Environment file with the Tailscale auth key tsidp joins the
          tailnet with, as one line TS_AUTHKEY=tskey-auth-..., owned by root,
          mode 0400. Only read while tsidp has no node state yet; tsidp does
          not start while the file is missing.
        '';
      };
      stateDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/private/tsidp";
        readOnly = true;
        description = ''
          Where tsidp keeps its node key, its signing keys and the clients
          registered with it, as nixpkgs' module sets it (a DynamicUser
          StateDirectory, linked from /var/lib/tsidp). Losing it signs every
          client out and needs the clients registered again, so back it up
          with a homelab.backups.jobs entry.
        '';
      };
      clients = lib.mkOption {
        default = { };
        example = lib.literalExpression ''
          {
            forgejo.redirectUris = [ "https://git.example.com/user/oauth2/tailscale/callback" ];
            grafana = {
              redirectUris = [ "https://status.example.com/login/generic_oauth" ];
              owner = "grafana";
            };
          }
        '';
        description = ''
          OIDC clients declared in tsidp, keyed by client id
          (docs/adr/0010-tsidp-clients-declared-in-nix.md). Before tsidp
          starts, each gets its id and a generated secret in its two files,
          when they are missing or empty, and is written into tsidp's
          clients with the secret from its file. Clients registered by hand
          in the admin UI are left alone; a client removed here is removed
          from tsidp, its files are left.
        '';
        type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
          options = {
            redirectUris = lib.mkOption {
              type = lib.types.nonEmptyListOf (lib.types.strMatching "https?://[^[:space:]]+");
              description = "The redirect URIs tsidp accepts for this client.";
            };
            idFile = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/secrets/${name}-oidc-client-id";
              description = "File the client id is written to, for the service to read.";
            };
            secretFile = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/secrets/${name}-oidc-client-secret";
              description = ''
                File holding the client secret. Generated, 64 random hex
                digits, when missing or empty; a secret put there by hand
                is kept and replaces the one in tsidp on its next start.
              '';
            };
            owner = lib.mkOption {
              type = lib.types.str;
              default = "root";
              example = "grafana";
              description = ''
                User owning the id and secret files, with that user's group;
                both are mode 0400. The user the service reads them as.
              '';
            };
          };
        }));
      };
    };

    pocketId = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Run Pocket ID, the site's OpenID Connect provider, with nixpkgs'
          services.pocket-id, behind Caddy at homelab.pocketId.url
          (docs/adr/0018-pocket-id-is-the-oidc-provider.md). It listens only
          on a unix socket that the caddy container mounts, so it needs the
          reverse proxy on the same host. Its owner signs in with a passkey;
          docs/pocket-id.md has the first run.
        '';
      };
      hostName = lib.mkOption {
        type = lib.types.strMatching "[a-z0-9]([a-z0-9-]*[a-z0-9])?";
        default = "id";
        description = ''
          Pocket ID's name under homelab.domain. Passkeys are bound to the
          host name, so changing it later means registering them again.
          The Caddyfile needs a site of that name.
        '';
      };
      url = lib.mkOption {
        type = lib.types.str;
        default = "https://${cfg.pocketId.hostName}.${cfg.domain}";
        defaultText = lib.literalExpression ''"https://''${homelab.pocketId.hostName}.''${homelab.domain}"'';
        readOnly = true;
        description = ''
          Pocket ID's URL, which is also the issuer URL of the services
          that sign in through it.
        '';
      };
      socket = lib.mkOption {
        type = lib.types.str;
        default = "/run/pocket-id-http/pocket-id.sock";
        readOnly = true;
        description = ''
          The unix socket Pocket ID serves HTTP on, for Caddy's
          reverse_proxy (unix//run/pocket-id-http/pocket-id.sock). Its
          directory is mounted into the caddy container.
        '';
      };
      setupLogins = lib.mkOption {
        type = lib.types.listOf tailnetLogin;
        default = [ ];
        example = [ "alice@github" ];
        description = ''
          The tailnet logins that may open Pocket ID's first-admin setup
          (/setup, /signup/setup and /api/signup/setup), which makes
          whoever finishes it first the admin. The reverse proxy generates
          the snippet pocket_id_setup from it, which Pocket ID's site in
          the Caddyfile must import: everyone else, tokens included, gets
          403 there. Needs homelab.reverseProxy.tailscaleIdentity.enable.
        '';
      };
      allowOwnAccountEdit = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Let users change their own username, email and name in Pocket ID.
          Off, only the admin changes them, in the admin UI's Users page,
          and a user cannot take a username or email no one holds, which
          apps such as Grafana match accounts on. Grafana on Pocket ID
          (homelab.observability.grafanaOidc) needs it off
          (docs/adr/0019-forgejo-and-grafana-on-pocket-id.md). Pocket ID's
          application settings then come from its environment
          (UI_CONFIG_DISABLED) and its admin UI shows them read-only; set
          others in services.pocket-id.settings by their environment names.
        '';
      };
      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/pocket-id";
        readOnly = true;
        description = ''
          Where Pocket ID keeps its SQLite database, its uploads and the
          ids of the declared clients. Back it up with a
          homelab.backups.jobs entry that lists
          homelab.pocketId.databaseFile as a SQLite database.
        '';
      };
      databaseFile = lib.mkOption {
        type = lib.types.str;
        default = "${cfg.pocketId.dataDir}/data/pocket-id.db";
        defaultText = lib.literalExpression ''"''${homelab.pocketId.dataDir}/data/pocket-id.db"'';
        readOnly = true;
        description = "Pocket ID's SQLite database, for homelab.backups.jobs.<name>.sqliteDatabases.";
      };
      encryptionKeyFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/secrets/pocket-id-encryption-key";
        description = ''
          The key Pocket ID encrypts its signing keys with in the database,
          owned by root, mode 0400. Generated on the first start, while
          there is no database yet; with a database and no key Pocket ID
          does not start, since the database cannot be read without it.
          Keep a copy outside the host: a restored database needs this key.
        '';
      };
      apiKeyFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/secrets/pocket-id-api-key";
        description = ''
          Pocket ID's static admin API key, which the pocket-id-clients unit
          declares the clients with, owned by root, mode 0400. Generated
          when missing; a new one takes effect when Pocket ID restarts.
        '';
      };
      clients = lib.mkOption {
        default = { };
        example = lib.literalExpression ''
          {
            grafana = {
              displayName = "Grafana";
              redirectUris = [ "https://status.example.com/login/generic_oauth" ];
              owner = "grafana";
              units = [ "podman-grafana.service" ];
            };
          }
        '';
        description = ''
          OIDC clients declared in Pocket ID, keyed by client id
          (docs/adr/0018-pocket-id-is-the-oidc-provider.md). Once Pocket ID
          answers, the pocket-id-clients unit creates or updates each one
          through Pocket ID's admin API and writes its id and secret files.
          Pocket ID makes the secret; a missing secret file, or one Pocket ID
          no longer accepts, gets a new secret. Clients created in Pocket
          ID's admin UI are left alone; a client removed here is deleted
          from Pocket ID, its files are left.
        '';
        type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
          options = {
            displayName = lib.mkOption {
              type = lib.types.strMatching ".{1,50}";
              default = name;
              description = "The client's name, shown on Pocket ID's consent and apps pages.";
            };
            redirectUris = lib.mkOption {
              type = lib.types.nonEmptyListOf (lib.types.strMatching "https?://[^[:space:]]+");
              description = ''
                The redirect URIs Pocket ID accepts for this client. Pocket
                ID takes * as a wildcard in them.
              '';
            };
            logoutRedirectUris = lib.mkOption {
              type = lib.types.listOf (lib.types.strMatching "https?://[^[:space:]]+");
              default = [ ];
              description = "Where Pocket ID may send the browser after signing out of this client.";
            };
            pkce = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Require PKCE from this client, for clients that send it.";
            };
            idFile = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/secrets/${name}-oidc-client-id";
              description = "File the client id is written to, for the service to read.";
            };
            secretFile = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/secrets/${name}-oidc-client-secret";
              description = ''
                File the client secret is written to. To rotate it, empty
                the file and restart pocket-id-clients.
              '';
            };
            owner = lib.mkOption {
              type = lib.types.str;
              default = "root";
              example = "grafana";
              description = ''
                User owning the id and secret files, with that user's group;
                both are mode 0400. The user the service reads them as.
              '';
            };
            units = lib.mkOption {
              type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9@._:-]+\\.(service|target)");
              default = [ ];
              example = [ "podman-grafana.service" ];
              description = ''
                systemd units that read the client's files. They start after
                pocket-id-clients and pull it in, and are restarted when it
                writes a new id or secret.
              '';
            };
          };
        }));
      };
    };

    agentSandbox = {
      gitName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Commit author name pinned inside the agent sandbox on every start. Null disables the pin.";
      };
      gitEmail = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Commit author email pinned inside the agent sandbox on every start. Null disables the pin.";
      };
      allowedEmails = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "12345+user@users.noreply.github.com" "*@internal.lan" ];
        description = ''
          Shell case patterns for acceptable commit emails in the mounted
          repo. When non-empty, the sandbox warns at start if the effective
          repo identity matches none of them. Empty disables the check.
        '';
      };
      skillsRepo = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://github.com/user/skills";
        description = ''
          Git URL of a personal skills repo synced into ~/.claude on every
          container start (shared volume across projects). Null disables
          the sync.
        '';
      };
    };
  };
}
