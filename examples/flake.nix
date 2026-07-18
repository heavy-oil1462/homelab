# Example consumer flake: copy this into your own (private) config repo and
# point the hosts at your hardware configs and real asset files. This file is
# documentation; it is not evaluated as part of the homelab flake.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    homelab.url = "github:heavy-oil1462/homelab";
  };

  outputs = { self, nixpkgs, homelab, ... }: {
    nixosConfigurations.myserver = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        homelab.nixosModules.common
        homelab.nixosModules.server-role
        homelab.nixosModules.reverse-proxy
        ({ ... }: {
          homelab = {
            username = "alice";
            domain = "home.example.com";
            adminKeys = [ "ssh-ed25519 AAAA... alice@laptop" ];
            tailnetIp = "100.64.0.1";
            reverseProxy = {
              caddyfile = ./assets/Caddyfile;
              notFoundPage = ./assets/404.html;
            };
          };
          networking.hostName = "myserver";
          boot.loader.grub.devices = [ "nodev" ];
          fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
          system.stateVersion = "25.05";
        })
      ];
    };
  };
}
