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
        # Copies of the journal's unit and container name, for the output
        # to make labels of. The loki output removes every key it labels on
        # from the line it sends, so labelling _SYSTEMD_UNIT itself would
        # take it out of the JSON body and break `| json` queries on it.
        # The copies go instead; the body keeps the record as it was.
        # Copy does nothing when the source key is missing, and journal
        # field names are upper case, so the lower case copies never clash.
        filters = [
          {
            name = "modify";
            match = "host.*";
            copy = [
              "_SYSTEMD_UNIT unit"
              "CONTAINER_NAME container"
            ];
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
            # Stream labels from the record: the unit, and the container for
            # lines a podman container logged. Both are few per host: podman
            # runs from the container's systemd service, so it leaves conmon
            # in that service's cgroup and a container's lines have the unit
            # podman-<name>.service, not a scope per container id. A line
            # without the key gets no label rather than an empty one, so
            # kernel lines carry no unit and host services no container.
            # Never label on MESSAGE, PRIORITY or PIDs: every value is a
            # new stream.
            label_keys = "$unit, $container";
          }
        ];
      };
    };
  };
}
