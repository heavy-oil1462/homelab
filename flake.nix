{
  description = "Reusable NixOS modules for a container-based homelab: reverse proxy, observability, backups, desktop, and an AI agent sandbox, all configured through a typed homelab.* options namespace.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      exampleHost = module: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ module ];
      };
      exampleServer = exampleHost ./examples/server.nix;
      exampleWorkstation = exampleHost ./examples/workstation.nix;
    in
    {
      nixosModules = {
        # The options namespace. Every module imports it internally, so
        # importing it explicitly is only needed when consuming none of the
        # modules below but still setting homelab.* values.
        options = ./modules/options.nix;

        # Base system: auto-upgrade defaults, GC, flakes, user, firewall.
        common = ./modules/common.nix;

        # Individual modules.
        user = ./modules/user.nix;
        openssh = ./modules/openssh.nix;
        locale = ./modules/locale.nix;
        podman = ./modules/podman.nix;
        tailscale = ./modules/tailscale.nix;
        firewall = ./modules/firewall.nix;
        observability-agent = ./modules/observability-agent.nix;
        logging-agent = ./modules/logging-agent.nix;
        acme = ./modules/acme.nix;
        backups = ./modules/backups.nix;
        nvidia = ./modules/nvidia.nix;
        vm-disko = ./modules/vm-disko.nix;
        yubikey = ./modules/yubikey.nix;
        desktop-sound = ./modules/desktop/sound.nix;
        desktop-greeter = ./modules/desktop/greeter.nix;
        desktop-hyprland = ./modules/desktop/hyprland.nix;
        desktop-bluetooth = ./modules/desktop/bluetooth.nix;

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
        example-workstation = pkgs.writeText "example-workstation-drv"
          (builtins.unsafeDiscardStringContext exampleWorkstation.config.system.build.toplevel.drvPath);
      };
    };
}
