{ config, pkgs, ... }:

{
  imports = [ ./options.nix ];

  services.fluent-bit = {
    enable = true;
    settings = {
      service = {
        flush = 1;
        log_level = "info";
      };
      pipeline = {
        inputs = [
          {
            name = "systemd";
            tag = "host.*";
            read_from_tail = "On";
          }
        ];
        outputs = [
          {
            name = "loki";
            match = "*";
            # Ship to the reverse-proxy vhost (logs.<domain>), which proxies
            # to the Loki container. The name matches the ACME cert, so
            # certificate verification stays enabled.
            host = config.homelab.logsHost;
            port = 443;
            tls = "On";
            "tls.verify" = "On";
            labels = "job=systemd-journal, host=${config.networking.hostName}";
          }
        ];
      };
    };
  };
}
