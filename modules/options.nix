{ config, lib, ... }:

let
  cfg = config.homelab;
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
      description = "restic repository string for the vaultwarden backup job.";
    };

    yubikey.u2fKeysFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        pam_u2f authfile with the enrolled keys (u2f_keys format). Generate
        with pamu2fcfg using origin/appid pam://yubikey.
      '';
    };

    hyprland = {
      hyprlandConf = lib.mkOption {
        type = lib.types.path;
        description = "hyprland.conf installed into the user's ~/.config/hypr.";
      };
      hyprpaperConf = lib.mkOption {
        type = lib.types.path;
        description = "hyprpaper.conf installed into the user's ~/.config/hypr.";
      };
      monitorsConf = lib.mkOption {
        type = lib.types.path;
        description = ''
          Host-specific monitor layout, sourced by hyprland.conf as
          monitors.conf. Point it at a per-host file from your config repo.
        '';
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
