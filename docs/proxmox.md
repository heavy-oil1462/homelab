# Proxmox VE metrics

Proxmox VE 9 sends its metrics itself, over OpenTelemetry (OTLP/HTTP,
JSON, gzip), and Prometheus takes them with its OTLP receiver. No exporter
and no OpenTelemetry Collector run in between
(docs/adr/0030-proxmox-pushes-opentelemetry-into-prometheus.md).

## The observability host

```nix
homelab.observability.otlpReceiver = {
  enable = true;
  # The Proxmox host's LAN address; nothing else reaches the port.
  allowedSources = [ "192.0.2.30" ];
};
```

The host then listens on port 4318 (`otlpReceiver.port`) for
`POST /v1/metrics`, from the listed addresses only, and Caddy passes that
path to Prometheus. Every other path answers 404. The host needs the
reverse-proxy module too. prometheus.yml needs the `otlp` block and the
out-of-order window of the example's, `examples/assets/prometheus.yml`,
for the names and labels below.

## Proxmox

In the web UI: Datacenter, Metric Server, Add, OpenTelemetry.

| Field | Value |
| --- | --- |
| Name | `homelab` |
| Server | the observability host's LAN address |
| Port | `4318` |
| Protocol | `HTTP` |
| Path | `/v1/metrics` |
| Compression | `gzip` |

Or as one command on the Proxmox host, as root:

```sh
pvesh create /cluster/metrics/server/homelab --type opentelemetry \
  --server 192.0.2.10 --port 4318 --otel-protocol http --otel-path /v1/metrics
```

with `192.0.2.10` replaced by the observability host's LAN address. Set
the port even though it is the usual one: for plain HTTP, Proxmox's
default is 4317. Saving the server sends an empty push as a test, which
must succeed.

## What arrives

Within a minute, Prometheus has `proxmox_node_*`, `proxmox_vm_*` and
`proxmox_storage_*` series with `job="proxmox-ve"`, labelled with `node`,
`proxmox_cluster` and `proxmox_node`, and with `vmid`, `name` and `type`
for guests and `storage` for storage:

```promql
proxmox_node_uptime_seconds{job="proxmox-ve"}
```

Grafana dashboard 23855, "Proxmox VE Dashboard", is built on these names.
The example's "Proxmox metrics stale" alert fires for a node that pushed
in the last 7 days but not in the last 15 minutes.

## When nothing arrives

- On the Proxmox host, `journalctl -u pvestatd` logs each failed push
  ("OpenTelemetry export failed").
- On the observability host, `systemctl status otlp-receiver.socket` and
  `journalctl -u otlp-receiver` show the socket and its proxy, and
  `journalctl -u podman-caddy` Caddy.
- A source not in `allowedSources` gets no answer at all; the firewall
  drops it.
