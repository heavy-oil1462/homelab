{
  description = "Reusable NixOS modules for a container-based homelab: reverse proxy, observability, backups, desktop, and an AI agent sandbox, all configured through a typed homelab.* options namespace.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Only for the checks: examples/vm.nix evaluates vm-disko against disko's
    # module. The exported modules do not import it; consumers bring their
    # own disko (docs/adr/0001-disko-input-for-checks.md).
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      exampleHost = module: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ module ];
      };
      exampleServer = exampleHost ./examples/server.nix;
      exampleServerProxyAuth = exampleHost ./examples/server-proxy-auth.nix;
      exampleWorkstation = exampleHost ./examples/workstation.nix;
      exampleVm = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ disko.nixosModules.disko ./examples/vm.nix ];
      };
    in
    {
      nixosModules = {
        # The options namespace. Every module imports it internally, so
        # importing it explicitly is only needed when consuming none of the
        # modules below but still setting homelab.* values.
        options = ./modules/options.nix;

        # Base system: auto-upgrade defaults, GC, flakes, terminfo of common
        # terminals, user, firewall.
        common = ./modules/common.nix;

        # Individual modules.
        user = ./modules/user.nix;
        openssh = ./modules/openssh.nix;
        deploy-ca = ./modules/deploy-ca.nix;
        locale = ./modules/locale.nix;
        podman = ./modules/podman.nix;
        tailscale = ./modules/tailscale.nix;
        firewall = ./modules/firewall.nix;
        observability-agent = ./modules/observability-agent.nix;
        logging-agent = ./modules/logging-agent.nix;
        acme = ./modules/acme.nix;
        backups = ./modules/backups.nix;
        vulnerability-scan = ./modules/vulnerability-scan.nix;
        pocket-id = ./modules/pocket-id.nix;
        nvidia = ./modules/nvidia.nix;
        vm-disko = ./modules/vm-disko.nix;
        yubikey = ./modules/yubikey.nix;
        desktop-sound = ./modules/desktop/sound.nix;
        desktop-greeter = ./modules/desktop/greeter.nix;
        desktop-hyprland = ./modules/desktop/hyprland.nix;
        desktop-bluetooth = ./modules/desktop/bluetooth.nix;
        desktop-removable-media = ./modules/desktop/removable-media.nix;

        # Role bundles.
        server-role = ./roles/server.nix;
        workstation-role = ./roles/workstation.nix;

        # OCI container services.
        reverse-proxy = ./containers/reverse-proxy.nix;
        observability = ./containers/observability.nix;
        vaultwarden = ./containers/vaultwarden.nix;
        homepage = ./containers/homepage.nix;
        homeassistant = ./containers/homeassistant.nix;
        nvr = ./containers/nvr.nix;
        nextcloud = ./containers/nextcloud.nix;
        unifi = ./containers/unifi.nix;
        registry = ./containers/registry.nix;
        forgejo = ./containers/forgejo.nix;
        agent-sandbox = ./containers/agent-sandbox.nix;
      };

      packages.${system} = {
        # Interactive deployment TUI (fzf + zellij) for a config repo with
        # per-host scripts under scripts/deploy/.
        deploy = pkgs.writeShellApplication {
          name = "deploy";
          runtimeInputs = with pkgs; [ fzf zellij ];
          text = ''
            if [ ! -d "scripts/deploy" ]; then
              echo -e "\033[1;33m[!] You are not currently in the NixOS workspace.\033[0m"
              echo "Searching for NixOS workspace..."
              workspace=$(find ~ -maxdepth 4 -type d -name "scripts" -exec test -d '{}/deploy' \; -print -quit | sed 's|/scripts||')

              if [ -n "$workspace" ]; then
                echo "Found workspace at $workspace. Changing directory..."
                cd "$workspace" || exit 1
              else
                echo "❌ Error: Could not automatically locate the NixOS workspace."
                echo "Please run this command from the root of your NixOS repository."
                read -r -p "Press Enter to exit..."
                exit 1
              fi
            fi

            while true; do
              clear
              echo -e "\033[1;36m==================================================\033[0m"
              echo -e "\033[1;36m       🚀 NIXOS DEPLOYMENT COMMAND CENTER        \033[0m"
              echo -e "\033[1;36m==================================================\033[0m"
              echo ""

              script=$(find scripts/deploy -maxdepth 1 -name "*.sh" -printf "%f\n" | fzf --prompt="Deploy Target > ")

              if [ -n "$script" ]; then
                echo -e "\n\033[1;34m[+] Initiating deployment sequence for: $script\033[0m\n"
                bash "scripts/deploy/$script"
                echo -e "\n\033[1;33m[!] Deployment process ended. Press Enter to return to menu...\033[0m"
                read -r
              else
                break
              fi
            done
          '';
        };
      };

      checks.${system} = {
        # Deep evaluation of the example hosts down to their derivation paths.
        # Forcing drvPath evaluates the entire module set (type errors, missing
        # options, infinite recursion) without building the systems; consumers
        # build real systems in their own flake check. The string context is
        # discarded so the resulting file carries no store references and the
        # check stays a pure evaluation probe.
        example-server = pkgs.writeText "example-server-drv"
          (builtins.unsafeDiscardStringContext exampleServer.config.system.build.toplevel.drvPath);
        example-server-proxy-auth = pkgs.writeText "example-server-proxy-auth-drv"
          (builtins.unsafeDiscardStringContext exampleServerProxyAuth.config.system.build.toplevel.drvPath);
        example-workstation = pkgs.writeText "example-workstation-drv"
          (builtins.unsafeDiscardStringContext exampleWorkstation.config.system.build.toplevel.drvPath);
        example-vm = pkgs.writeText "example-vm-drv"
          (builtins.unsafeDiscardStringContext exampleVm.config.system.build.toplevel.drvPath);
        # common brings every host the terminfo of common terminals: the
        # example server's system packages carry kitty's.
        terminfo =
          let terminfo = exampleServer.pkgs.kitty.terminfo;
          in if builtins.any (p: (p.outPath or null) == terminfo.outPath)
            exampleServer.config.environment.systemPackages
          then pkgs.writeText "terminfo" (builtins.unsafeDiscardStringContext terminfo.outPath)
          else throw "example server lacks kitty's terminfo; is homelab.allTerminfo off?";
        # Every container of the example servers runs as a user that is not
        # root, or is on the test's allowlist, with no-new-privileges and its
        # capabilities dropped (docs/adr/0014-containers-run-unprivileged.md).
        container-hardening = pkgs.callPackage ./tests/container-hardening.nix {
          hosts = {
            example-server = exampleServer.config;
            example-server-proxy-auth = exampleServerProxyAuth.config;
          };
        };
        # The caddy container can open nginx-auth's identity socket, and a
        # switch that changes the socket makes a new one.
        identity-socket = pkgs.callPackage ./tests/identity-socket.nix {
          hosts = {
            example-server = exampleServer.config;
            example-server-proxy-auth = exampleServerProxyAuth.config;
          };
        };
        # The logging agent labels journal lines with their unit and
        # container, and the body stays the journal record: the example
        # server's fluent-bit config, evaluated and run against a stand-in
        # for Loki.
        logging-labels = pkgs.callPackage ./tests/logging-labels.nix {
          inherit (exampleServer.config.services.fluent-bit) settings;
          inherit (exampleServer.config.networking) hostName;
        };
        # The forgejo-admin unit's script against a stubbed podman.
        forgejo-admin = pkgs.callPackage ./tests/forgejo-admin.nix { };
        # Forgejo's SSH server trusts the deploy CA with
        # homelab.forgejo.trustDeployCa, and no CA without it.
        forgejo-deploy-ca = pkgs.callPackage ./tests/forgejo-deploy-ca.nix {
          on = exampleServer.config;
          off = (exampleServer.extendModules {
            modules = [{ homelab.forgejo.trustDeployCa = nixpkgs.lib.mkForce false; }];
          }).config;
        };
        # The example server's vulnerability-scan unit scans exactly its
        # containers' images, and its scan step runs unprivileged. A
        # container in a user's rootless podman is added and must not be
        # scanned (ADR-0017).
        vulnerability-scan-images = pkgs.callPackage ./tests/vulnerability-scan-images.nix {
          config = (exampleServer.extendModules {
            modules = [{
              users.users.rootless-test = { isNormalUser = true; linger = true; };
              virtualisation.oci-containers.containers.rootless-test = {
                image = "registry.example.com/rootless-test@sha256:${nixpkgs.lib.fixedWidthString 64 "0" ""}";
                podman.user = "rootless-test";
              };
            }];
          }).config;
        };
        # The vulnerability-scan script against a stubbed podman and trivy
        # and a fixture report: counts per severity and fixable, no CVE
        # labels, the exposition format.
        vulnerability-scan = pkgs.callPackage ./tests/vulnerability-scan.nix { };
        # The tailscale-metrics script against the real tailscaled logged
        # out and samples of its status with an expiry, none and expired.
        tailscale-metrics = pkgs.callPackage ./tests/tailscale-metrics.nix { };
        # The restic-check script against a local restic repository, sound
        # and with a data pack deleted, and the example server's unit and
        # timer for it, and with the check off.
        backup-check = pkgs.callPackage ./tests/backup-check.nix {
          config = exampleServer.config;
          off = (exampleServer.extendModules {
            modules = [{ homelab.backups.check.enable = false; }];
          }).config;
        };
        # The jobs' own forget and the restic-prune script against a local
        # restic repository, and the example server's units and timer for
        # them: each job forgets only its own snapshots, and only
        # restic-prune removes data.
        backup-prune = pkgs.callPackage ./tests/backup-prune.nix {
          config = exampleServer.config;
        };
        # The restic-restore-test script against a local restic repository
        # with a SQLite job and a git job, sound and damaged, and the example
        # server's unit, config and timer for it, and with the test off.
        backup-restore-test = pkgs.callPackage ./tests/backup-restore-test.nix {
          config = exampleServer.config;
          off = (exampleServer.extendModules {
            modules = [{ homelab.backups.restoreTest.enable = false; }];
          }).config;
        };
        # Proxmox's OTLP pushes: the example server's receiver as evaluated,
        # on iptables and nftables, off, and the configurations it refuses;
        # then a Proxmox-shaped push through its Caddy site into the real
        # Prometheus, and every other path refused.
        otlp-receiver =
          let
            with' = host: module: (host.extendModules { modules = [ module ]; }).config;
          in
          pkgs.callPackage ./tests/otlp-receiver.nix {
            on = exampleServer.config;
            nftables = with' exampleServer { networking.nftables.enable = true; };
            off = with' exampleServer { homelab.observability.otlpReceiver.enable = nixpkgs.lib.mkForce false; };
            broken = {
              noSources = with' exampleServer { homelab.observability.otlpReceiver.allowedSources = nixpkgs.lib.mkForce [ ]; };
              everyone = with' exampleServer { homelab.observability.otlpReceiver.allowedSources = [ "0.0.0.0/0" ]; };
              noCaddyAddress = with' exampleServer {
                homelab.reverseProxy.address = nixpkgs.lib.mkForce null;
                homelab.homeassistant.trustedProxies = nixpkgs.lib.mkForce null;
              };
            };
            prometheusConfig = ./examples/assets/prometheus.yml;
          };
        # The scrapers of network gear: the example server's jobs, exporter
        # containers, secrets and their check, with nothing enabled, and the
        # configurations the host refuses (ADR-0029).
        network-scrape =
          let
            with' = module: (exampleServer.extendModules { modules = [ module ]; }).config;
          in
          pkgs.callPackage ./tests/network-scrape.nix {
            config = exampleServer.config;
            off = with' {
              homelab.observability.scrape.opnsense.enable = nixpkgs.lib.mkForce false;
              homelab.observability.scrape.unifi.enable = nixpkgs.lib.mkForce false;
            };
            broken = {
              noScrapeConfigFiles = with' {
                homelab.observability.prometheusConfig = nixpkgs.lib.mkForce
                  (pkgs.writeText "prometheus.yml" "scrape_configs: []\n");
              };
              opnsenseInsecureWithCa = with' { homelab.observability.scrape.opnsense.insecure = true; };
              unifiInsecureWithCert = with' { homelab.observability.scrape.unifi.insecure = true; };
            };
          };
        # The example's alert rules in promtool: every query parses, and the
        # vulnerability and Tailscale rules alert on what they should.
        alert-rules = pkgs.callPackage ./tests/alert-rules.nix { };
        # Forgejo's and Grafana's OIDC sign in on Pocket ID, the example
        # server's, a host that still names the provider, and the assertions
        # that refuse a half-done setup, Grafana on a Pocket ID whose users
        # edit their own email, or tsidp's removed options.
        oidc-providers = pkgs.callPackage ./tests/oidc-providers.nix {
          pocketId = exampleServer.config;
          broken =
            let
              with' = host: module: (host.extendModules { modules = [ module ]; }).config;
            in
            {
              providerNamed = with' exampleServer {
                homelab.forgejo.oidc.provider = "pocket-id";
                homelab.observability.grafanaOidc.provider = "pocket-id";
              };
              noPocketId = with' exampleServer { homelab.pocketId.enable = nixpkgs.lib.mkForce false; };
              noClients = with' exampleServer { homelab.pocketId.clients = nixpkgs.lib.mkForce { }; };
              ownEdit = with' exampleServer { homelab.pocketId.allowOwnAccountEdit = true; };
              ownEditDirect = with' exampleServer {
                services.pocket-id.settings.ALLOW_OWN_ACCOUNT_EDIT = nixpkgs.lib.mkForce true;
              };
              tsidp = with' exampleServer {
                homelab.tsidp.enable = true;
                homelab.forgejo.oidc.issuer = "https://idp.tailnet.invalid";
                homelab.observability.grafanaOidc.issuer = "https://idp.tailnet.invalid";
              };
            };
        };
        # Break-glass SSH from the LAN: the example server with sshFrom set
        # to documentation ranges gets the rules, on iptables and nftables,
        # and password logins, a loopback-only sshd or 0.0.0.0/0 fail the
        # build (ADR-0024).
        break-glass-ssh =
          let
            with' = host: module: (host.extendModules { modules = [ module ]; }).config;
            sshFrom = { homelab.network.sshFrom = [ "192.0.2.0/24" "2001:db8::/64" ]; };
            # The example server without the OTLP receiver's firewall rule,
            # so the rules compared are SSH's alone; otlp-receiver checks
            # its own.
            server = exampleServer.extendModules {
              modules = [{ homelab.observability.otlpReceiver.enable = nixpkgs.lib.mkForce false; }];
            };
            onHost = server.extendModules { modules = [ sshFrom ]; };
          in
          pkgs.callPackage ./tests/break-glass-ssh.nix {
            on = onHost.config;
            nftables = with' onHost { networking.nftables.enable = true; };
            off = server.config;
            broken = {
              passwordAuth = with' onHost {
                services.openssh.settings.PasswordAuthentication = nixpkgs.lib.mkForce true;
              };
              kbdInteractive = with' onHost {
                services.openssh.settings.KbdInteractiveAuthentication = nixpkgs.lib.mkForce true;
              };
              rootLogin = with' onHost {
                services.openssh.settings.PermitRootLogin = nixpkgs.lib.mkForce "yes";
              };
              loopbackOnly = with' onHost {
                services.openssh.listenAddresses = nixpkgs.lib.mkForce [{ addr = "127.0.0.1"; port = 22; }];
              };
              everyone = with' server { homelab.network.sshFrom = [ "192.0.2.0/24" "0.0.0.0/0" ]; };
              everyone6 = with' server { homelab.network.sshFrom = [ "::/0" ]; };
            };
          };
        # Servers take SSH through sshd only: the example server has no
        # --ssh and turns Tailscale SSH off once nobody uses it, the
        # workstation keeps it, and a server left with no sshd on the
        # tailnet fails the build (ADR-0026). Then the unit's script against
        # tailscaled and a stub of its counters.
        tailscale-ssh-off =
          let
            with' = host: module: (host.extendModules { modules = [ module ]; }).config;
          in
          pkgs.callPackage ./tests/tailscale-ssh-off.nix {
            server = exampleServer.config;
            workstation = exampleWorkstation.config;
            serverSsh = with' exampleServer { homelab.tailscale.ssh = nixpkgs.lib.mkForce true; };
            broken = {
              noSshd = with' exampleServer {
                services.openssh.enable = nixpkgs.lib.mkForce false;
                homelab.deployCaKeys = nixpkgs.lib.mkForce [ ];
              };
              loopbackOnly = with' exampleServer {
                services.openssh.listenAddresses = nixpkgs.lib.mkForce [{ addr = "127.0.0.1"; port = 22; }];
              };
              closedOnTailnet = with' exampleServer {
                networking.firewall.interfaces.tailscale0.allowedTCPPorts = nixpkgs.lib.mkForce [ 9100 ];
              };
            };
          };
        # The example workstation's PAM stacks, sudo timestamp and ssh client
        # config: PIN at login and screen lock, touch only for sudo, one
        # shared connection per listed host, no yubikey-agent (ADR-0025).
        yubikey-prompts = pkgs.callPackage ./tests/yubikey-prompts.nix {
          config = exampleWorkstation.config;
        };
        # The forgejo-oidc unit's script against a stubbed podman and systemctl.
        forgejo-oidc = pkgs.callPackage ./tests/forgejo-oidc.nix { };
        # The script declaring Pocket ID's clients, against nixpkgs' Pocket
        # ID with the example's settings, and a stubbed systemctl.
        pocket-id-clients = pkgs.callPackage ./tests/pocket-id-clients.nix {
          inherit (exampleServer.config.services.pocket-id) package settings;
        };
        # How long a sign-in to nixpkgs' Pocket ID lasts, with the example
        # server's settings (a day) and with homelab.pocketId.sessionDuration
        # at the option's default, which must be Pocket ID's own (an hour).
        pocket-id-session =
          let
            defaultDuration = (exampleServer.extendModules {
              modules = [{
                homelab.pocketId.sessionDuration = nixpkgs.lib.mkForce
                  exampleServer.options.homelab.pocketId.sessionDuration.default;
              }];
            }).config;
          in
          pkgs.callPackage ./tests/pocket-id-session.nix {
            inherit (exampleServer.config.services.pocket-id) package;
            hosts = [
              {
                name = "example";
                inherit (exampleServer.config.services.pocket-id) settings;
                minutes = 1440;
              }
              {
                name = "default";
                inherit (defaultDuration.services.pocket-id) settings;
                minutes = 60;
              }
            ];
          };
        # The example server's Pocket ID, its clients and one more with
        # every default: the spec the unit gets, its ordering before the
        # clients' units, the socket Caddy mounts and the backup.
        pocket-id-module = pkgs.callPackage ./tests/pocket-id-module.nix {
          config = (exampleServer.extendModules {
            modules = [{
              homelab.pocketId.clients.wiki.redirectUris = [ "https://wiki.home.example.com/callback" ];
            }];
          }).config;
        };
        # Home Assistant's reverse proxy settings, merged into .storage/http
        # by the example server's unit, against nixpkgs' Home Assistant, and
        # the http: block in configuration.yaml the module refuses.
        homeassistant-http = pkgs.callPackage ./tests/homeassistant-http.nix {
          config = exampleServer.config;
          withYamlHttp = (exampleServer.extendModules {
            modules = [{
              homelab.homeassistant.configurationFile = nixpkgs.lib.mkForce
                (pkgs.writeText "configuration.yaml" "homeassistant:\nhttp:\n  use_x_forwarded_for: true\n");
            }];
          }).config;
        };
        # The CDI spec check of GPU containers against stub specs, and its
        # place in the example server's Frigate unit. The unit's strings are
        # compared, never run: their string context is discarded, so the
        # check builds neither the driver nor the generator.
        nvidia-cdi-check =
          let
            cfg = exampleServer.config;
            text = builtins.unsafeDiscardStringContext;
          in
          pkgs.callPackage ./tests/nvidia-cdi-check.nix {
            firstExecStartPre = text (builtins.head cfg.systemd.services.podman-frigate.serviceConfig.ExecStartPre);
            requires = cfg.systemd.services.podman-frigate.requires;
            driver = text "${nixpkgs.lib.getLib cfg.hardware.nvidia.package}";
            generator = text cfg.systemd.services.nvidia-container-toolkit-cdi-generator.serviceConfig.ExecStart;
          };
        # The grafana-git-sync unit's script against a stand-in for Grafana.
        grafana-git-sync = pkgs.callPackage ./tests/grafana-git-sync.nix { };
        # The skills' Python: image-updates against a fake registry on
        # 127.0.0.1, every image pin in containers/ naming its tag, and the
        # service-logs queries against a stub Loki client.
        skills = pkgs.runCommand "skills-test"
          {
            nativeBuildInputs = [ pkgs.python3 ];
            src = nixpkgs.lib.fileset.toSource {
              root = ./.;
              fileset = nixpkgs.lib.fileset.unions [ ./lib ./skills ./containers ./tests/test_images.py ./tests/test_logs.py ];
            };
          } ''
          cd "$src"
          PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v
          touch "$out"
        '';
        # The example Caddyfile's tailnet_identity snippet in a real Caddy.
        tailnet-identity = pkgs.callPackage ./tests/tailnet-identity.nix { };
        # The example server's OIDC login gate as evaluated, and the
        # configurations it refuses.
        oidc-gate-module =
          let
            without = module: (exampleServer.extendModules { modules = [ module ]; }).config;
          in
          pkgs.callPackage ./tests/oidc-gate-module.nix {
            config = exampleServer.config;
            withoutGate = without { homelab.reverseProxy.oidcGate.enable = nixpkgs.lib.mkForce false; };
            withoutClient = without { homelab.pocketId.clients = nixpkgs.lib.mkForce { }; };
            ownAccountEdit = without { homelab.pocketId.allowOwnAccountEdit = true; };
            shortSession = without { homelab.reverseProxy.oidcGate.sessionLifetime = "30m"; };
          };
        # The OIDC login gate in a real Caddy and oauth2-proxy, against a
        # stand-in for Pocket ID, with oidc_gate opened to bob as well.
        oidc-gate =
          let
            cfg = (exampleServer.extendModules {
              modules = [{ homelab.reverseProxy.oidcGate.users = [ "bob" ]; }];
            }).config;
          in
          pkgs.callPackage ./tests/oidc-gate.nix {
            caddyfile = nixpkgs.lib.removeSuffix ":/etc/caddy/Caddyfile"
              (builtins.head cfg.virtualisation.oci-containers.containers.caddy.volumes);
            command = cfg.systemd.services.oauth2-proxy.serviceConfig.ExecStart;
            cookieSecret = cfg.systemd.services.oidc-gate-cookie-secret.serviceConfig.ExecStart;
            clientId = cfg.homelab.reverseProxy.oidcGate.clientId;
          };
        # The identity snippets the reverse proxy generates for the example
        # server on proxy authentication, in a real Caddy. The Caddyfile is the store path the caddy
        # container mounts; removeSuffix keeps its string context.
        identity-mapping = pkgs.callPackage ./tests/identity-mapping.nix {
          caddyfile = nixpkgs.lib.removeSuffix ":/etc/caddy/Caddyfile"
            (builtins.head exampleServerProxyAuth.config.virtualisation.oci-containers.containers.caddy.volumes);
        };
      };
    };
}
