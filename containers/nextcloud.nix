{ config, pkgs, ... }:

# Nextcloud All-in-One. This module runs only the AIO mastercontainer; it
# starts and manages the Nextcloud containers itself through the docker
# socket. Its admin UI (port 8080) and the Apache container it starts (port
# 11000) are published on homelab.nextcloud.bindAddress, the tailnet address
# by default. Set it to a LAN address, or "0.0.0.0", to reach them from the
# LAN; that is the opt in.
#
# The mastercontainer is pinned by digest, which fixes the AIO version the
# host runs until the pin is bumped here. From its UI the mastercontainer
# updates the containers it manages, but only when the owner asks it to, so
# nothing upgrades on its own. Major AIO upgrades migrate data: ask the owner
# before bumping across one.
let
  cfg = config.homelab.nextcloud;
in
{
  assertions = [
    {
      assertion = cfg.bindAddress != null;
      message = "containers/nextcloud.nix publishes the AIO UI and Apache on homelab.nextcloud.bindAddress (homelab.tailnetIp by default), which is unset.";
    }
  ];

  systemd.tmpfiles.rules = [
    "d /var/lib/nextcloud_aio_mastercontainer 0750 root root -"
  ];

  virtualisation.oci-containers.containers = {
    nextcloud-aio-mastercontainer = {
      image = "docker.io/nextcloud/all-in-one@sha256:c1da0c8c5ee2378c971f5f61a956dfa826f9230bb1d1022a4e4346dd27bf543e"; # :latest (built 2026-11-03, revision 97ef10c) as of 2026-11-12
      autoStart = true;
      ports = [
        "${toString cfg.bindAddress}:8080:8080" # AIO Mastercontainer Interface
      ];
      environment = {
        APACHE_PORT = "11000";
        APACHE_IP_BINDING = toString cfg.bindAddress;
        NEXTCLOUD_DATADIR = "/var/lib/nextcloud_data";
      };
      volumes = [
        "nextcloud_aio_mastercontainer:/mnt/docker-aio-config"
        "/var/run/docker.sock:/var/run/docker.sock:ro"
      ];
      extraOptions = [
        "--sig-proxy=false"
      ];
    };
  };
}
