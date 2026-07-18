{ config, pkgs, ... }:

let
  cfg = config.homelab.observability;

  prometheusConfig = pkgs.writeText "prometheus.yml" (
    builtins.readFile cfg.prometheusConfig
  );

  lokiConfig = pkgs.writeText "local-config.yaml" (
    builtins.readFile cfg.lokiConfig
  );

  grafanaDatasources = pkgs.writeText "datasources.yml" ''
    apiVersion: 1
    deleteDatasources:
      - name: Prometheus
        orgId: 1
      - name: Loki
        orgId: 1
    datasources:
      - name: Prometheus
        type: prometheus
        uid: Prometheus
        url: http://prometheus:9090
        access: proxy
        isDefault: true
      - name: Loki
        type: loki
        uid: Loki
        url: http://loki:3100
        access: proxy
  '';

  grafanaAlerting = pkgs.writeText "alerting.yaml" (
    builtins.readFile cfg.alertingConfig
  );

  grafanaDashboards = pkgs.writeText "dashboards.yml" ''
    apiVersion: 1
    providers:
      - name: 'Homelab Dashboards'
        orgId: 1
        folder: 'Homelab'
        type: file
        disableDeletion: false
        updateIntervalSeconds: 10
        options:
          path: /etc/grafana/dashboards
  '';
in
{
  imports = [ ../modules/options.nix ];

  users.users.prometheus = {
    isSystemUser = true;
    group = "prometheus";
  };
  users.groups.prometheus = { };

  users.users.grafana = {
    isSystemUser = true;
    group = "grafana";
  };
  users.groups.grafana = { };

  users.users.loki = {
    isSystemUser = true;
    group = "loki";
  };
  users.groups.loki = { };

  # Guarantee the HA scrape token exists as a FILE before the Prometheus
  # container starts. The container bind-mounts it read-only; if the host path
  # is missing, podman would create a directory there and Prometheus would
  # crash-loop reading credentials_file as a directory. Creating an empty file
  # if absent means a not-yet-provisioned token only makes the home-assistant
  # target fail auth (401), never takes Prometheus down. tmpfiles 'f' does not
  # truncate an existing file, so the real token is left untouched once
  # written.
  systemd.tmpfiles.rules = [
    "f /var/lib/secrets/ha-prometheus-token 0640 prometheus prometheus -"
  ];

  virtualisation.oci-containers.containers = {
    prometheus = {
      image = "docker.io/prom/prometheus@sha256:69f5241418838263316593f7274a304b095c40bcf22e57272865da91bd60a8ac"; # :latest as of 2026-06-13
      user = "${toString config.users.users.prometheus.uid}:${toString config.users.groups.prometheus.gid}";
      autoStart = true;
      volumes = [
        "${prometheusConfig}:/etc/prometheus/prometheus.yml:ro"
        "prometheus-data:/prometheus"
        # Long-lived Home Assistant token for the home-assistant scrape job.
        # Runtime secret, never committed; provision it out of band and make
        # it readable by the prometheus container uid.
        "/var/lib/secrets/ha-prometheus-token:/etc/prometheus/ha-token:ro"
      ];
    };

    loki = {
      image = "docker.io/grafana/loki@sha256:191d4fdfb7264f16989f0a57f320872620a5a7c2ceeec6229212c4190ec49b86"; # :latest as of 2026-06-13
      user = "${toString config.users.users.loki.uid}:${toString config.users.groups.loki.gid}";
      autoStart = true;
      volumes = [
        "${lokiConfig}:/etc/loki/local-config.yaml:ro"
        "loki-data:/var/lib/loki"
      ];
    };

    grafana = {
      image = "docker.io/grafana/grafana@sha256:5dad0df181cb644a14e13617b913b261a54f7d4fd4510721dba420929f35bea2"; # :latest as of 2026-06-13
      user = "${toString config.users.users.grafana.uid}:${toString config.users.groups.grafana.gid}";
      autoStart = true;
      volumes = [
        "grafana-data:/var/lib/grafana"
        "${grafanaDatasources}:/etc/grafana/provisioning/datasources/datasources.yml:ro"
        "${grafanaDashboards}:/etc/grafana/provisioning/dashboards/dashboards.yml:ro"
        "${grafanaAlerting}:/etc/grafana/provisioning/alerting/alerting.yaml:ro"
        "${cfg.dashboardsDir}:/etc/grafana/dashboards:ro"
      ];
      # Single user on the tailnet: anonymous Admin access with no login form.
      # The endpoint is only reachable over the tailnet (the reverse proxy
      # binds to the tailnet IP), which is the access control here.
      environment = {
        GF_AUTH_ANONYMOUS_ENABLED = "true";
        GF_AUTH_ANONYMOUS_ORG_ROLE = "Admin";
        GF_AUTH_DISABLE_LOGIN_FORM = "true";
      };
    };
  };
}
