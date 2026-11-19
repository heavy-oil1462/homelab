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
#
# image-updates follows :latest because AIO publishes no version tags to
# follow instead. Its registries (tag lists of docker.io/nextcloud/all-in-one
# and ghcr.io/nextcloud-releases/all-in-one, checked 2026-11-19) carry only
# the channels latest, beta and develop, plus a date tag per build
# (20261119_161514). A date tag names no major and never moves, so following
# one would hide every new build. AIO's readme ("How to switch the channel",
# "How to update the containers") runs the mastercontainer from :latest or
# :beta and moves the Nextcloud major itself, so a major upgrade has to be
# spotted in the release notes of the bump.
#
# The pin is on ghcr.io, the registry AIO's readme names; Docker Hub carries
# the same builds. AIO takes no setting for its own image name: it reads the
# mastercontainer's image reference from the container API and splits it at
# ':' into a name and a channel, which it uses for its own update check and
# as the tag of the containers it starts (GetCurrentImageName and
# GetCurrentChannel in php/src/Docker/DockerActionManager.php).
let
  cfg = config.homelab.nextcloud;
in
{
  imports = [ ../modules/options.nix ];

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
      image = "ghcr.io/nextcloud-releases/all-in-one@sha256:b81a56854642cf2e991feae6dee652fe4837e2c2c4d51d6d167e38d5cfb6d6b5"; # :latest (built 2026-11-19, revision 6d3b1ab) as of 2026-11-19
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
      # Runs as root: the AIO mastercontainer only supports it. Its start
      # script sets up its volume as root and drops to www-data with sudo
      # for its own web server. It also holds podman's socket, which is
      # root on the host whatever its user; the containers it starts are
      # not under this module. It is on the root allowlist in
      # tests/container-hardening.nix
      # (docs/adr/0014-containers-run-unprivileged.md).
      extraOptions = [
        "--sig-proxy=false"
        "--security-opt=no-new-privileges"
        "--cap-drop=ALL"
        # Setting owners and modes on its volume for www-data.
        "--cap-add=CHOWN"
        "--cap-add=DAC_OVERRIDE"
        "--cap-add=FOWNER"
        # sudo to www-data, Apache dropping to it, and stopping them.
        "--cap-add=SETUID"
        "--cap-add=SETGID"
        "--cap-add=KILL"
        # Apache's listeners on ports below 1024 in the container.
        "--cap-add=NET_BIND_SERVICE"
      ];
    };
  };
}
