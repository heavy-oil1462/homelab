{ config, pkgs, ... }:

{
  systemd.tmpfiles.rules = [
    "d /var/lib/nextcloud_aio_mastercontainer 0750 root root -"
  ];

  virtualisation.oci-containers.containers = {
    nextcloud-aio-mastercontainer = {
      image = "docker.io/nextcloud/all-in-one:latest";
      autoStart = true;
      ports = [
        "8080:8080" # AIO Mastercontainer Interface
      ];
      environment = {
        APACHE_PORT = "11000";
        APACHE_IP_BINDING = "0.0.0.0";
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
