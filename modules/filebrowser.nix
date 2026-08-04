{ config, lib, ... }:

let
  username = config.homelab.username;
in
{
  imports = [ ./options.nix ];

  # Web file manager for the primary user's home directory: browse, upload
  # and download from any browser on the tailnet at http://<host>:8080.
  #
  # The service runs as the primary user so the web view has exactly the
  # permissions a local shell has and uploads land owned by that user.
  # Filebrowser keeps its account database under /var/lib/filebrowser. The
  # first start creates an admin account with a random password; read it
  # with journalctl -u filebrowser (search for "password"), then change it
  # in Settings > User Management.
  services.filebrowser = {
    enable = true;
    user = username;
    group = "users";
    settings = {
      address = "0.0.0.0";
      port = 8080;
      root = "/home/${username}";
    };
  };

  # Reachable over the tailnet only, like SSH (modules/firewall.nix keeps
  # per-service ports with the module that owns the service). The listener
  # binds to all interfaces but the firewall drops LAN traffic.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    config.services.filebrowser.settings.port
  ];
}
