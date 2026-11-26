# UniFi in Prometheus

`homelab.observability.scrape.unifi` brings a UniFi Network controller
into Prometheus through unpoller
(docs/adr/0029-network-gear-scraped-through-exporters.md). unpoller signs
in to the controller with a read-only local user, polls it every minute,
and serves `unpoller_*` metrics for its sites, devices and clients. It
runs as the container `unpoller` on the observability host, as the
unpoller user (609), with no capabilities and no published port;
Prometheus scrapes it as the job `unifi`.

unpoller is github.com/unpoller/unpoller, an MIT project maintained by
its community in the unpoller organisation on GitHub, pinned by digest in
`containers/observability-scrape.nix`. Its Grafana dashboards for
Prometheus are published on grafana.com by the same project.

It works with a controller on UniFi OS (a console, or UniFi OS Server)
and with a classic Network application, such as this library's `unifi`
container.

## On the controller

1. **A read-only local user.** In the controller's admins and users
   settings, add an admin restricted to local access, with a password
   and no remote or cloud sign in, and the view-only role for the
   Network application on every site to poll. unpoller cannot change
   anything with it.
2. **The certificate.** unpoller verifies the controller's certificate.
   UniFi OS makes a self-signed one that names no address the
   observability host uses, so pin it instead: save the certificate the
   controller serves as a PEM file on the observability host, as
   `certFile`. unpoller accepts the connection when that certificate, or
   the CA that signed it, is in the chain the controller presents, and
   checks no names. `openssl s_client -connect <address>:<port>
   -showcerts` prints the chain. When the controller makes a new
   certificate, the pin must be replaced. A controller with a
   certificate from a public CA needs no `certFile`.

## On the observability host

```nix
homelab.observability.scrape.unifi = {
  enable = true;
  # UniFi OS: its web address; UniFi OS Server serves it on 11443.
  # A classic controller: the web UI's port, usually 8443.
  url = "https://192.0.2.2:11443";
  certFile = "/var/lib/secrets/unifi-cert.pem";
  # sites = [ "all" ];
  # name = "unifi";
  # secretFile = "/var/lib/secrets/unpoller.env";
};
```

prometheus.yml must list the jobs' file once, as
`examples/assets/prometheus.yml` does; the host refuses to build
otherwise:

```yaml
scrape_config_files:
  - /etc/prometheus/scrape-configs.yml
```

Remove any job named `unifi` from prometheus.yml: Prometheus refuses a
config with two jobs of one name.

The secret file, root's, mode 0400, holds the user from step 1:

```sh
UP_UNIFI_DEFAULT_USER=<user>
UP_UNIFI_DEFAULT_PASS=<password>
```

The host creates it empty. Until it holds both, unpoller does not start:
`systemctl status podman-unpoller` shows the unit failed and its journal
says which variables are missing, while Prometheus, Loki and Grafana
run, and the failed unit alerts. Once the file is filled in,
`systemctl restart podman-unpoller` starts it. The site's own setup
script should write the file and restart the unit in one step.

`certFile` is a certificate, not a secret; it must be readable by the
unpoller user. `insecure = true` turns verification off instead, which
hands the user's password to anyone who can intercept the connection;
prefer `certFile`.

unpoller keeps no events, alarms or IDS records, only metrics, and does
not hash client names: the dashboards show clients by name.

## Checking it

- `up{job="unifi"}` is 1 when Prometheus reaches unpoller.
- `unpoller_prometheus_cache_age_seconds` is the age of unpoller's last
  good poll of the controller, under a minute or so while it works, and
  -1 until one succeeds. unpoller serves that poll's metrics until a new
  one succeeds, so `unpoller_controller_up` alone stays 1 while the
  controller is down.
- The "UniFi controller unreachable" rule in
  `examples/assets/grafana-alerting.yaml` fires when the last good poll
  is over 5 minutes old, none has succeeded, or unpoller cannot be
  scraped, for 10 minutes.
