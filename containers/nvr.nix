{ pkgs, config, ... }:

let
  frigateConfig = pkgs.writeText "config.yaml" (
    builtins.replaceStrings [ "__DOMAIN__" ] [ config.homelab.domain ]
      (builtins.readFile config.homelab.nvr.configFile)
  );
in
{
  imports = [ ../modules/options.nix ];

  users.users.frigate = {
    isSystemUser = true;
    group = "frigate";
    uid = 990;
  };
  users.groups.frigate = {
    gid = 990;
  };

  # Recordings stay on the dedicated /surveillance volume, but Frigate's state
  # (frigate.db plus model cache) lives on the root disk. The SQLite database
  # must not share a filesystem that runs at 100% by design; a full disk during
  # a write is how the recording index gets corrupted.
  systemd.tmpfiles.rules = [
    "d /surveillance/media 0750 frigate frigate -"
    "d /var/lib/frigate 0750 frigate frigate -"
  ];

  virtualisation.oci-containers.containers = {
    frigate = {
      image = "ghcr.io/blakeblackshear/frigate@sha256:643667fdb054089277d45efdd33849248f628cbb76b6329950ec8cf217fa6107";
      autoStart = true;
      extraOptions = [
        "--network=host"
        "--shm-size=1000mb"
        "--gpus"
        "all"
        "--tmpfs"
        "/tmp/cache:rw,size=1G"
      ];
      volumes = [
        "/surveillance/media:/media/frigate"
        "/var/lib/frigate:/config"
        "${frigateConfig}:/config/config.yaml"
      ];
      environmentFiles = [ "/etc/secrets/frigate.env" ];
    };
  };

  systemd.services."podman-frigate".preStart = pkgs.lib.mkBefore ''
    mkdir -p /surveillance/media /var/lib/frigate
    # One-time migration from the old config location on the recordings
    # volume. Copies the database and caches on the first start after the
    # move and never runs again; the old directory is left in place to be
    # removed by hand once the new location is confirmed working.
    if [ ! -e /var/lib/frigate/frigate.db ] && [ -e /surveillance/config/frigate.db ]; then
      cp -a /surveillance/config/. /var/lib/frigate/
      rm -f /var/lib/frigate/config.yaml
    fi
    chown -R 990:990 /surveillance/media /var/lib/frigate
  '';
}
