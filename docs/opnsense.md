# OPNsense in Prometheus

`homelab.observability.scrape.opnsense` brings an OPNsense router into
Prometheus, in two parts
(docs/adr/0029-network-gear-scraped-through-exporters.md):

- **The router's node_exporter.** OPNsense's os-node_exporter plugin
  serves the router's own `node_*` metrics: CPU, memory, disks, load,
  temperature. Prometheus scrapes it directly as the job `opnsense`.
- **The opnsense-exporter.** It reads OPNsense's API (interfaces,
  gateways, firewall, services, ARP, DHCP leases, firmware) and serves
  `opnsense_*` metrics. It runs as the container `opnsense-exporter` on
  the observability host, as the opnsense-exporter user (608), with no
  capabilities and no published port; Prometheus scrapes it as the job
  `opnsense-exporter`.

Both jobs label every series with the router's name as `instance`, and
the exporter adds the same name as `opnsense_instance`: the "OPNSense
Monitoring" dashboard (Grafana 24738) matches both with one variable.

The exporter is github.com/AthennaMind/opnsense-exporter, a small Apache
2.0 project maintained by AthennaMind, pinned by digest in
`containers/observability-scrape.nix`.

## On the router

1. **The node_exporter plugin.** Under System, Firmware, Plugins, install
   `os-node_exporter`. Under Services, Prometheus Exporter, enable it on
   the interface the observability host reaches it through, on port
   9100. If that interface's rules do not already let the observability
   host in, add a rule passing TCP 9100 from it to the router.
2. **A user for the exporter.** Under System, Access, Users, add a user
   with no login shell and a random password nobody needs, and give it
   read-only privileges only: those covering the API endpoints the
   exporter reads (`api/diagnostics/*`, `api/core/service/search`,
   `api/core/system/status`, `api/core/firmware/status`,
   `api/routing/settings/searchGateway`, `api/unbound/diagnostics/stats`,
   `api/cron/settings/searchJobs`, and those of the VPN and DHCP services
   in use). Temperature, PF states and mbuf usage need "Lobby:
   Dashboard"; the CARP status needs "Interfaces: Virtual IPs: Status".
   The exporter logs a 403 naming each endpoint it is refused, and its
   README lists the switches that turn a collector off.
3. **Its API key.** On the user's page, under API keys, add a key.
   OPNsense hands over a file with `key=` and `secret=` once; they go
   into the secret file below.
4. **Unbound's statistics**, for its collector: Services, Unbound DNS,
   Advanced, Extended Statistics.
5. **The certificate.** The exporter verifies the web GUI's certificate.
   The one OPNsense makes at install is self-signed and names the
   router's host name. Either issue the web GUI a certificate from
   OPNsense's own CA (System, Trust) that names the address the
   observability host uses, and give the exporter that CA's certificate
   as `caFile`; or use a certificate from a public CA and leave `caFile`
   unset.

## On the observability host

```nix
homelab.observability.scrape.opnsense = {
  enable = true;
  name = "router";
  address = "192.0.2.1";
  # api.scheme = "https"; api.port = null;  # the web GUI's
  caFile = "/var/lib/secrets/opnsense-ca.pem";
  # secretFile = "/var/lib/secrets/opnsense-exporter.env";
  # nodeExporter = { enable = true; port = 9100; };
};
```

prometheus.yml must list the jobs' file once, as
`examples/assets/prometheus.yml` does; the host refuses to build
otherwise:

```yaml
scrape_config_files:
  - /etc/prometheus/scrape-configs.yml
```

Remove any job named `opnsense` or `opnsense-exporter` from
prometheus.yml: Prometheus refuses a config with two jobs of one name.

The secret file, root's, mode 0400, holds the key and secret from step 3:

```sh
OPNSENSE_EXPORTER_OPS_API_KEY=<key>
OPNSENSE_EXPORTER_OPS_API_SECRET=<secret>
```

The host creates it empty. Until it holds both, the exporter does not
start: `systemctl status podman-opnsense-exporter` shows the unit failed
and its journal says which variables are missing, while Prometheus,
Loki and Grafana run, and the failed unit alerts. Once the file is
filled in, `systemctl restart podman-opnsense-exporter` starts it. The
site's own setup script should write the file and restart the unit in
one step.

`caFile` is a certificate, not a secret; it must be readable by the
opnsense-exporter user. `insecure = true` turns verification off
instead, which hands the API key to anyone who can intercept the
connection; prefer `caFile`.

## Checking it

- `up{job="opnsense"}` is 1 when Prometheus reaches the router's
  node_exporter.
- `opnsense_up` is 1 when the exporter read the API on its last scrape;
  `opnsense_exporter_endpoint_errors_total` counts refused or failed
  endpoints.
- The "OPNsense unreachable" rule in `examples/assets/grafana-alerting.yaml`
  fires when either is 0 for 10 minutes.
