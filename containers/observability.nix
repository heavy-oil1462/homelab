{ config, pkgs, ... }:

let
  cfg = config.homelab.observability;
  proxyAddress = config.homelab.reverseProxy.address;

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

  # Probes for homelab.observability.probeTargets. http_2xx_tls is an HTTPS
  # GET that fails on anything but a 2xx answer over TLS with a certificate
  # the host trusts, so probe_success covers "down" and "invalid
  # certificate", and probe_ssl_earliest_cert_expiry gives the expiry. IPv4
  # because Caddy publishes 443 on the tailnet IPv4 address only.
  blackboxConfig = pkgs.writeText "blackbox.yml" ''
    modules:
      http_2xx_tls:
        prober: http
        timeout: 10s
        http:
          method: GET
          fail_if_not_ssl: true
          preferred_ip_protocol: ip4
          ip_protocol_fallback: false
  '';

  # The targets as a file_sd file, so the blackbox job in the consumer's
  # prometheus.yml reads them from the option instead of repeating them.
  probeTargets = pkgs.writeText "probe-targets.json" (builtins.toJSON [
    { targets = cfg.probeTargets; }
  ]);

  # The default podman network's bridge, as the NixOS podman module defines
  # it. The Prometheus container reaches the host's blackbox exporter here.
  podmanBridge = "podman0";
  podmanGateway = "10.88.0.1";

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

  assertions = [
    {
      assertion = !cfg.grafanaProxyAuth.enable || proxyAddress != null;
      message = "homelab.observability.grafanaProxyAuth trusts Remote-User from homelab.reverseProxy.address, which is null.";
    }
  ];

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

  # The blackbox exporter runs on the host, next to Prometheus, so the sites
  # are probed once, from the host that alerts on them. It listens on the
  # podman bridge only and the port is open on that interface only, like
  # aardvark-dns on 53: containers on the default network reach it, nothing
  # on the LAN or the tailnet does.
  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = podmanGateway;
    port = 9115;
    configFile = blackboxConfig;
  };

  # The bridge address exists once podman has started a container on the
  # default network. Start after Prometheus, and keep retrying (rather than
  # hitting the start limit) if the bridge is not up yet.
  systemd.services.prometheus-blackbox-exporter = {
    after = [ "podman-prometheus.service" ];
    serviceConfig.RestartSec = "5s";
    unitConfig.StartLimitIntervalSec = 0;
  };

  networking.firewall.interfaces.${podmanBridge}.allowedTCPPorts = [
    config.services.prometheus.exporters.blackbox.port
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
        "${probeTargets}:/etc/prometheus/probe-targets.json:ro"
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
      environment = if cfg.grafanaProxyAuth.enable then {
        # The tailnet user from Caddy's grafana_identity snippet, trusted only
        # from Caddy's address; Grafana answers 401 to the header from
        # anywhere else. Users are created on first sign in with the role
        # Caddy passes in Remote-Role, Admin for every login it lets through.
        GF_AUTH_PROXY_ENABLED = "true";
        GF_AUTH_PROXY_HEADER_NAME = "Remote-User";
        GF_AUTH_PROXY_HEADER_PROPERTY = "username";
        GF_AUTH_PROXY_HEADERS = "Role:Remote-Role";
        GF_AUTH_PROXY_WHITELIST = proxyAddress;
        GF_AUTH_PROXY_AUTO_SIGN_UP = "true";
        # No other way in: the built in admin still has the password admin
        # unless someone changed it, so basic auth goes too. Service account
        # tokens keep working.
        GF_AUTH_ANONYMOUS_ENABLED = "false";
        GF_AUTH_DISABLE_LOGIN_FORM = "true";
        GF_AUTH_BASIC_ENABLED = "false";
      } else {
        # Single user on the tailnet: anonymous Admin access with no login
        # form. The endpoint is only reachable over the tailnet (the reverse
        # proxy binds to the tailnet IP), which is the access control here.
        GF_AUTH_ANONYMOUS_ENABLED = "true";
        GF_AUTH_ANONYMOUS_ORG_ROLE = "Admin";
        GF_AUTH_DISABLE_LOGIN_FORM = "true";
      };
    };
  };
}
