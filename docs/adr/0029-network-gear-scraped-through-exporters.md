# ADR-0029: Network gear is scraped through exporters on the observability host

Status: Accepted

## Context

The owner wants the router and the UniFi network in Grafana (board,
2026-11-26). homelab-config ships the "OPNSense Monitoring" dashboard
(Grafana 24738), which reads `opnsense_*` series from the
opnsense-exporter and `node_*` series from OPNsense's os-node_exporter
plugin, but Prometheus had no job for the router at all, so every panel
was empty. The UniFi controller was not scraped either.

Neither device runs anything of the library's. Their metrics come from
their APIs, read with credentials: an OPNsense API key and secret, a
UniFi user and password. Only the router's node_exporter plugin serves
metrics itself. Something has to turn the APIs into metrics, run
somewhere, hold the credentials and be scraped.

Prometheus's jobs are in the consumer's prometheus.yml, which the
observability module mounts verbatim. ADR-0004 gets lists of targets the
Nix side knows into it through file_sd, with the job written once in
prometheus.yml. These jobs carry more than targets: each device's name
as the `instance` label, which the dashboard matches against the
exporter's own `opnsense_instance` label through one variable, and a
timeout. Each would be a job the consumer copies and keeps in step with
the module.

## Decision

- The exporters run as containers under `virtualisation.oci-containers`
  on the observability host, beside Prometheus, on podman's default
  network: the opnsense-exporter (github.com/AthennaMind/opnsense-exporter,
  the exporter the dashboard was built for) and unpoller
  (github.com/unpoller/unpoller) with its Prometheus output. They are
  pinned by digest, run as host users with static ids (opnsense-exporter
  608, unpoller 609) with no capabilities (ADR-0014), and publish no
  port: Prometheus reaches them by container name, and they reach the
  devices over the host's own routes.
- They are part of the observability module, in
  `containers/observability-scrape.nix`, which `observability.nix`
  imports, and are turned on per device under
  `homelab.observability.scrape.<device>`. The router's node_exporter is
  scraped directly, as it serves metrics itself.
- Credentials come from environment files under `/var/lib/secrets/`,
  which a tmpfiles rule creates empty. Before each start, a check fails
  the exporter's unit while its file lacks a variable, naming the file
  and the variables. Nothing in the rest of the stack waits for the
  exporters, so Prometheus, Loki and Grafana run without them.
- TLS to the devices is verified: by a CA file for OPNsense, whose
  certificate must name the address, and by a pinned certificate for
  UniFi, as unpoller checks no names. `insecure` turns verification off,
  with a warning in the option's description.
- The module writes the jobs into one file, mounted at
  `/etc/prometheus/scrape-configs.yml`, and the consumer's prometheus.yml
  lists it under `scrape_config_files`, once. The file has no jobs while
  nothing is enabled. A host that enables a device without listing the
  file fails an assertion. The jobs are `opnsense` (the router's
  node_exporter), `opnsense-exporter` and `unifi`, each with the device's
  name as `instance`.
- The example's alert rules gain "OPNsense unreachable" and "UniFi
  controller unreachable".

## Consequences

- A device is scraped with one option set and its secret file filled in;
  prometheus.yml changes once, for all devices to come.
- prometheus.yml stays the consumer's file, never rewritten, as ADR-0004
  has it; jobs move in from the module only for devices the module
  manages. A job of the same name in prometheus.yml makes Prometheus
  refuse its config, so a host that scraped a device by hand drops that
  job when it turns the option on.
- The `network-scrape` check evaluates the example server's jobs,
  containers and units, runs the secret check on missing, empty,
  incomplete and complete files, and has promtool load the jobs with the
  example's prometheus.yml. The exporters against a real router and
  controller were not run.
- Two more images to keep current and scan, each from a small project:
  the opnsense-exporter is maintained by AthennaMind, unpoller by its
  community (the unpoller organisation on GitHub). Should one stop being
  maintained, its device loses its metrics but nothing else.
- A failed exporter alerts as a failed unit; a device the exporter cannot
  reach alerts as unreachable. With its secret missing, an exporter's
  unit stays failed until it is restarted after the file is filled in.
- Other network gear (switches, access points of other makes, a UPS) can
  follow the same pattern: an exporter container in that file, its job in
  the scrape config file, its secret under `/var/lib/secrets/`.

Related: [ADR-0004](0004-probe-targets-through-file-sd.md) (prometheus.yml
stays the consumer's), [ADR-0014](0014-containers-run-unprivileged.md).
