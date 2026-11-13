{ config, lib, ... }:

let
  cfg = config.homelab;

  # A tailnet login name as Tailscale reports it: alice@github,
  # alice@example.com. Restricted to characters that need no quoting in the
  # Caddyfile snippets built from them.
  tailnetLogin = lib.types.strMatching "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+";
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
        type = lib.types.path;
        description = "Directory of Grafana dashboard JSON files, provisioned read-only.";
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
