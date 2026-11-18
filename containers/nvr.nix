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
  #
  # Camera credentials (FRIGATE_RTSP_PASSWORD and any other FRIGATE_*
  # variables the config expands) come from /var/lib/secrets/frigate.env,
  # provisioned out of band, root:root 0400; podman reads it as root. The f
  # rule creates it empty if it is missing, so podman never fails on a missing
  # env file. With it empty Frigate cannot expand the variables in the config
  # and no camera connects; nothing is exposed that was not before.
  systemd.tmpfiles.rules = [
    "d /surveillance/media 0750 frigate frigate -"
    "d /var/lib/frigate 0750 frigate frigate -"
    "f /var/lib/secrets/frigate.env 0400 root root -"
  ];

  virtualisation.oci-containers.containers = {
    frigate = {
      image = "ghcr.io/blakeblackshear/frigate@sha256:643667fdb054089277d45efdd33849248f628cbb76b6329950ec8cf217fa6107"; # 0.17.1-tensorrt, :0.17.1-tensorrt as of 2026-07-18
      autoStart = true;
      # Runs as root: the image's s6-overlay init, nginx and go2rtc expect
      # it, and Frigate supports no other setup. It is on the root
      # allowlist in tests/container-hardening.nix
      # (docs/adr/0014-containers-run-unprivileged.md). The data
      # directories stay the frigate user's (990), as preStart below makes
      # them; root reaches them with DAC_OVERRIDE.
      extraOptions = [
        "--security-opt=no-new-privileges"
        "--cap-drop=ALL"
        # Writing to /media/frigate and /config, mode 0750 and owned by
        # frigate, and setting owners and modes in them as root.
        "--cap-add=DAC_OVERRIDE"
        "--cap-add=CHOWN"
        "--cap-add=FOWNER"
        # s6-overlay and nginx switch users for their workers and signal
        # them on stop.
        "--cap-add=SETUID"
        "--cap-add=SETGID"
        "--cap-add=KILL"
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
      environmentFiles = [ "/var/lib/secrets/frigate.env" ];
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
    # One-time migration of the env file from its old location. The f rule
    # above may already have created the new file empty, so empty counts as
    # missing. The old file is left in place to be removed by hand.
    if [ ! -s /var/lib/secrets/frigate.env ] && [ -e /etc/secrets/frigate.env ]; then
      install -D -m 0400 -o root -g root /etc/secrets/frigate.env /var/lib/secrets/frigate.env
      echo "Copied /etc/secrets/frigate.env to /var/lib/secrets/frigate.env; remove the old file once Frigate works." >&2
    fi
  '';
}
