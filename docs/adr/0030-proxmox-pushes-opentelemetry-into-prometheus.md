# ADR-0030: Proxmox pushes OpenTelemetry into Prometheus

Status: Accepted

## Context

The owner asked whether an OpenTelemetry server could take Proxmox's
metrics instead of Prometheus (board, 2026-11-26). Nothing collects
Proxmox today: there is no pve-exporter target, so the "Proxmox via
Prometheus" dashboard is empty.

Proxmox VE 9 has an OpenTelemetry metric server of its own
(`PVE/Status/OpenTelemetry.pm` in pve-manager). Every 10 seconds pvestatd
sends OTLP/HTTP as JSON, gzip by default, with `POST` to
`<protocol>://<server>:<port><path>`. The path defaults to `/v1/metrics`;
the port to 4318 for https and 4317 for http. The resource carries
`service.name` (`proxmox-ve`), `service.version`, `proxmox.cluster` and
`proxmox.node`; data points carry `node`, and for guests `vmid`, `name`
and `type`, for storage `storage`, for interfaces `device`. Names are
`proxmox_node_*`, `proxmox_vm_*` and `proxmox_storage_*`, with a unit, and
counters are monotonic sums named with `_total`. Grafana dashboard 23855
queries them as Prometheus names them by default:
`proxmox_vm_netin_bytes_total`, `proxmox_node_cpustat_avg1_ratio`,
`proxmox_node_uptime_seconds`.

Prometheus 3 has an OTLP receiver, `--web.enable-otlp-receiver`, at
`/api/v1/otlp/v1/metrics`. Run by hand, nixpkgs' Prometheus 3.16.0, the
version the pinned image runs, took a gzip JSON push shaped as Proxmox
sends it with 200 and stored it under those names, so no OpenTelemetry
Collector is needed in between. How it names metrics and which resource
attributes become labels is set in prometheus.yml's `otlp` block, and
prometheus.yml is the consumer's file, mounted as it is
([ADR-0004](0004-probe-targets-through-file-sd.md)).

Proxmox is on the LAN; the observability host's services are on the
tailnet only. The endpoint must take the OTLP path from Proxmox and keep
every other endpoint of Prometheus out of reach, its API and its remote
write included. Three ways were looked at:

1. A site `otlp.<domain>` in Caddy, limited with `remote_ip`. Caddy
   publishes 443 on the tailnet address only. For Proxmox to reach it
   from the LAN, 443 would have to be published on the LAN as well, which
   puts every site's listener on the LAN with only matchers in front.
2. A port of a container, Caddy's or Prometheus's, published on the LAN.
   podman DNATs a published port in PREROUTING, so the connection is
   forwarded to the container and never passes the firewall's INPUT
   chain. A source rule there does not hold it; only `remote_ip` in Caddy
   would. Publishing Prometheus's own port opens all of it.
3. A port the host itself listens on, behind a firewall rule per allowed
   source, as break-glass SSH has
   ([ADR-0024](0024-break-glass-ssh-from-the-lan.md)), whose connections
   go to Caddy, which passes the one path on to Prometheus.

ADR-0029 is the open OPNsense and UniFi change (cue issue 01a219a0-0021);
this is the next free number.

## Decision

- **No collector.** Prometheus takes the pushes itself:
  `homelab.observability.otlpReceiver.enable` starts it with
  `--web.enable-otlp-receiver` (the container's `cmd`, the image's own
  `--config.file` and `--storage.tsdb.path` with the flag added).
- **The endpoint is a host port** (option 3), `otlpReceiver.port`, 4318 by
  default, OTLP/HTTP's own. A systemd socket listens on it, and
  `systemd-socket-proxyd`, as a dynamic user with no capabilities, hands
  each connection to Caddy on the same port at its fixed address
  (`homelab.reverseProxy.address`), which podman does not publish.
- **Only the listed sources reach it.** `otlpReceiver.allowedSources`
  holds the addresses or CIDRs, the Proxmox host's LAN address. Each is a
  rule in the firewall's own chain, through `iptables` or `ip6tables` by
  family, or an input rule on the nftables firewall. Empty, or a network
  with prefix length 0, fails an assertion.
- **Only the OTLP path goes through.** The reverse proxy appends a site
  `http://:<port>` to the Caddyfile when the option is on. `POST
  /v1/metrics` is rewritten to `/api/v1/otlp/v1/metrics` and passed to
  `prometheus:9090`, with bodies up to 16 MB; every other method and path
  gets 404. It is plain HTTP, as Proxmox sends it on the LAN.
- **Names stay Prometheus's.** The example prometheus.yml sets
  `translation_strategy: UnderscoreEscapingWithSuffixes`, the default,
  stated, and promotes `proxmox.cluster` and `proxmox.node` to the labels
  `proxmox_cluster` and `proxmox_node` on every series. `service.name`
  becomes `job="proxmox-ve"`; the rest of the resource goes to
  `target_info`. `out_of_order_time_window: 10m` keeps a push that arrives
  after a newer one.
- **An alert.** "Proxmox metrics stale" fires for a node that sent
  `proxmox_node_uptime_seconds` in the last 7 days but nothing in the last
  15 minutes. Pushed series have no `up` to watch.
- The observability host must also run the reverse proxy, with its
  address set; an assertion says so.

## Consequences

- Turning the option on opens a port on the LAN, which DIRECTION.md asks
  the owner about first. It is off by default, and the site turns it on
  with the Proxmox host's address in homelab-config.
- The firewall is the only check of the sender: Caddy sees the host's
  bridge address, not Proxmox's. An allowed source can push any series,
  not only Proxmox's, and could overwrite another job's names. That
  source is the hypervisor, which holds every guest already; another LAN
  device would have to take its address to get in.
- Metrics cross the LAN in clear text: guests' names, usage and the
  nodes' load. Nothing secret is in them. TLS would need a certificate for
  a LAN name and the site's DNS for it, left for when it matters.
- Prometheus is published nowhere, as before. Containers on the podman
  network already reach it directly, and still do.
- Caddy down, or the proxy unit failing, makes Proxmox's pushes fail and
  the stale alert fire after 15 minutes; Proxmox drops what it could not
  send.
- A Proxmox node silent for over 7 days has no series left in the alert's
  window and stops alerting; one never seen never alerts.
- No new image, package or secret. `systemd-socket-proxyd` is systemd's.
- The `otlp-receiver` check runs a Proxmox-shaped push through the
  example server's generated Caddy site into nixpkgs' Prometheus with the
  container's flags and the example prometheus.yml, queries the series
  back by the names dashboard 23855 uses, and has every other path
  refused. The socket and the firewall rules are checked as evaluated, not
  with a connection, which would need a VM.
