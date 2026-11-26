# Network gear Prometheus scrapes through exporters on the observability
# host, homelab.observability.scrape
# (docs/adr/0029-network-gear-scraped-through-exporters.md): an OPNsense
# router through its node_exporter plugin and the opnsense-exporter, a
# UniFi controller through unpoller. The exporters are containers on
# podman's default network, which Prometheus reaches by name; nothing is
# published on the host. Their jobs are written to
# /etc/prometheus/scrape-configs.yml, which the consumer's prometheus.yml
# lists under scrape_config_files. Imported by observability.nix.
{ config, lib, pkgs, utils, ... }:

let
  cfg = config.homelab.observability;
  opnsense = cfg.scrape.opnsense;
  unifi = cfg.scrape.unifi;

  # As in observability.nix (docs/adr/0014-containers-run-unprivileged.md).
  hardening = [
    "--security-opt=no-new-privileges"
    "--cap-drop=ALL"
  ];

  hostUserCheck = pkgs.callPackage ./host-user-check.nix { };
  userCheck = name: utils.escapeSystemdExecArgs [
    "${hostUserCheck}/bin/host-user-check"
    name
    (toString config.users.users.${name}.uid)
    (toString config.users.groups.${name}.gid)
  ];
  containerUser = name:
    "${toString config.users.users.${name}.uid}:${toString config.users.groups.${name}.gid}";

  secretCheck = pkgs.callPackage ./scrape-secret-check.nix { };
  checkSecret = { exporter, doc, file, variables }: utils.escapeSystemdExecArgs
    ([ "${secretCheck}/bin/scrape-secret-check" exporter doc file ] ++ variables);

  # Where Prometheus finds the jobs; the consumer's prometheus.yml must
  # list this path under scrape_config_files.
  scrapeConfigsPath = "/etc/prometheus/scrape-configs.yml";

  # One target, with the instance label set to the device's name rather
  # than the exporter's address, so every series of a device carries it.
  job = name: instance: target: extra: {
    job_name = name;
    static_configs = [{
      targets = [ target ];
      labels = { inherit instance; };
    }];
  } // extra;

  opnsenseExporterPort = 8080;
  unpollerPort = 9130;

  jobs =
    lib.optionals (opnsense.enable && opnsense.nodeExporter.enable) [
      # The router itself: its scrape failing is OPNsense unreachable.
      (job "opnsense" opnsense.name "${opnsense.address}:${toString opnsense.nodeExporter.port}" { })
    ]
    ++ lib.optionals opnsense.enable [
      (job "opnsense-exporter" opnsense.name "opnsense-exporter:${toString opnsenseExporterPort}" {
        # The exporter asks the API for every collector on each scrape.
        scrape_timeout = "20s";
      })
    ]
    ++ lib.optionals unifi.enable [
      (job "unifi" unifi.name "unpoller:${toString unpollerPort}" { })
    ];

  # JSON is YAML. Always mounted, with no jobs when nothing is enabled, so
  # prometheus.yml can list it on every host.
  scrapeConfigs = pkgs.writeText "scrape-configs.yml" (builtins.toJSON {
    scrape_configs = jobs;
  });

  opnsenseApi = opnsense.address
    + lib.optionalString (opnsense.api.port != null) ":${toString opnsense.api.port}";

  # unpoller's own config, in place of the example the image carries:
  # Prometheus output only, the controller from the options. The user and
  # password come from the environment file, which overrides the file.
  unpollerCertPath = "/etc/unpoller/controller.pem";
  unpollerConfig = (pkgs.formats.toml { }).generate "up.conf" {
    poller = {
      debug = false;
      # Only start-up and errors in the journal, not a line per poll.
      quiet = true;
    };
    prometheus = {
      disable = false;
      http_listen = "0.0.0.0:${toString unpollerPort}";
      # A background poll every minute serves the scrapes; the cache age
      # it reports is what the UniFi alert reads.
      interval = "60s";
      report_errors = false;
    };
    influxdb.disable = true;
    loki.disable = true;
    datadog.enable = false;
    webserver.enable = false;
    unifi = {
      dynamic = false;
      defaults = {
        inherit (unifi) url sites;
        verify_ssl = !unifi.insecure;
        ssl_cert_paths = lib.optional (unifi.certFile != null) unpollerCertPath;
        save_sites = true;
        # Clients' names and addresses are what the dashboards show; no
        # events, alarms or IDS records, which are logs, not metrics.
        hash_pii = false;
        save_ids = false;
        save_events = false;
        save_alarms = false;
        save_anomalies = false;
        save_dpi = false;
      };
    };
  };
in
{
  imports = [ ../modules/options.nix ];

  assertions = [
    {
      assertion = !(opnsense.enable || unifi.enable)
        || lib.hasInfix scrapeConfigsPath (builtins.readFile cfg.prometheusConfig);
      message = "homelab.observability.scrape writes its jobs to ${scrapeConfigsPath}, which homelab.observability.prometheusConfig does not name; add scrape_config_files: [${scrapeConfigsPath}] to it, as examples/assets/prometheus.yml has.";
    }
    {
      assertion = !(opnsense.insecure && opnsense.caFile != null);
      message = "homelab.observability.scrape.opnsense sets both insecure and caFile; with caFile the certificate is verified, so turn insecure off.";
    }
    {
      assertion = !(unifi.insecure && unifi.certFile != null);
      message = "homelab.observability.scrape.unifi sets both insecure and certFile; with certFile the certificate is verified, so turn insecure off.";
    }
  ];

  virtualisation.oci-containers.containers = {
    prometheus.volumes = [ "${scrapeConfigs}:${scrapeConfigsPath}:ro" ];

    opnsense-exporter = lib.mkIf opnsense.enable {
      image = "ghcr.io/athennamind/opnsense-exporter@sha256:4e2b8ba8be111455090664e161c5dc68ab7706e3eb4dcfae40609e5fc33e959c"; # 0.0.20, :latest as of 2026-11-26
      user = containerUser "opnsense-exporter";
      autoStart = true;
      extraOptions = hardening;
      environment = {
        OPNSENSE_EXPORTER_OPS_PROTOCOL = opnsense.api.scheme;
        OPNSENSE_EXPORTER_OPS_API = opnsenseApi;
        OPNSENSE_EXPORTER_OPS_INSECURE = lib.boolToString opnsense.insecure;
        # The opnsense_instance label, which the dashboard matches with
        # the instance label of both jobs.
        OPNSENSE_EXPORTER_INSTANCE_LABEL = opnsense.name;
      } // lib.optionalAttrs (opnsense.caFile != null) {
        # Go reads its trusted CAs from here instead of the image's.
        SSL_CERT_FILE = "/etc/ssl/opnsense-ca.pem";
      };
      environmentFiles = [ opnsense.secretFile ];
      volumes = lib.optional (opnsense.caFile != null) "${opnsense.caFile}:/etc/ssl/opnsense-ca.pem:ro";
    };

    unpoller = lib.mkIf unifi.enable {
      image = "ghcr.io/unpoller/unpoller@sha256:1bd77eecb10f00c2f57d33a63fc1b3ccca73f3b5f0a9d13d2f9ab467e32bd6fb"; # v5.10.2, :latest as of 2026-11-26
      user = containerUser "unpoller";
      autoStart = true;
      extraOptions = hardening;
      cmd = [ "--config" "/etc/unpoller/up.conf" ];
      environmentFiles = [ unifi.secretFile ];
      volumes = [ "${unpollerConfig}:/etc/unpoller/up.conf:ro" ]
        ++ lib.optional (unifi.certFile != null) "${unifi.certFile}:${unpollerCertPath}:ro";
    };
  };

  # Static ids, from the README's block, as for the other containers.
  users.users = lib.mkMerge [
    (lib.mkIf opnsense.enable {
      opnsense-exporter = {
        isSystemUser = true;
        group = "opnsense-exporter";
        uid = lib.mkDefault 608;
      };
    })
    (lib.mkIf unifi.enable {
      unpoller = {
        isSystemUser = true;
        group = "unpoller";
        uid = lib.mkDefault 609;
      };
    })
  ];
  users.groups = lib.mkMerge [
    (lib.mkIf opnsense.enable { opnsense-exporter.gid = lib.mkDefault 608; })
    (lib.mkIf unifi.enable { unpoller.gid = lib.mkDefault 609; })
  ];

  # The environment files start empty, so podman never fails on a missing
  # one, and the check below keeps the exporter from starting until they
  # are filled in. Nothing else waits for the exporters: Prometheus,
  # Grafana and Loki run, and the scrape shows the exporter down.
  systemd.tmpfiles.rules =
    lib.optional opnsense.enable "f ${opnsense.secretFile} 0400 root root -"
    ++ lib.optional unifi.enable "f ${unifi.secretFile} 0400 root root -";

  systemd.services.podman-opnsense-exporter = lib.mkIf opnsense.enable {
    serviceConfig.ExecStartPre = lib.mkBefore ([
      (checkSecret {
        exporter = "The OPNsense exporter";
        doc = "docs/opnsense.md";
        file = opnsense.secretFile;
        variables = [ "OPNSENSE_EXPORTER_OPS_API_KEY" "OPNSENSE_EXPORTER_OPS_API_SECRET" ];
      })
    ] ++ lib.optional (opnsense.caFile != null) (userCheck "opnsense-exporter"));
  };

  systemd.services.podman-unpoller = lib.mkIf unifi.enable {
    serviceConfig.ExecStartPre = lib.mkBefore ([
      (checkSecret {
        exporter = "unpoller";
        doc = "docs/unifi.md";
        file = unifi.secretFile;
        variables = [ "UP_UNIFI_DEFAULT_USER" "UP_UNIFI_DEFAULT_PASS" ];
      })
    ] ++ lib.optional (unifi.certFile != null) (userCheck "unpoller"));
  };
}
