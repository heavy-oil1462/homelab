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
        tsidp = ./modules/tsidp.nix;
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
        # The example's alert rules in promtool: every query parses, and the
        # vulnerability rules alert on what they should.
        alert-rules = pkgs.callPackage ./tests/alert-rules.nix { };
        # The forgejo-oidc unit's script against a stubbed podman and systemctl.
        forgejo-oidc = pkgs.callPackage ./tests/forgejo-oidc.nix { };
        # The script writing tsidp's declared clients, against a fake state
        # directory.
        tsidp-clients = pkgs.callPackage ./tests/tsidp-clients.nix { };
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
