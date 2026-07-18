---
name: host-metrics
description: Inspect host health for the homelab servers via the Prometheus node_exporter. Use for uptime, CPU/memory/disk usage, swap, load, network interface link state and throughput, OS/EOL, and failed systemd units. Note it cannot show IP addresses; node_exporter does not export them.
---

# Host metrics

Read-only host health from the Prometheus node_exporter. Covers identity,
uptime, CPU/memory/disk/swap, network link state and throughput, and failed
systemd units across all scraped hosts. Hosts are discovered dynamically
from the node-exporter scrape job; get_hosts.py lists them.

Limitation: node_exporter does not export IP addresses, only link state and
counters. For addresses you need data from the hosts themselves.

## Scripts

Health summary across all hosts (one row each):

```
python3 "${CLAUDE_SKILL_DIR}/get_hosts.py" [--json]
```

Columns: UP, UPTIME, CORES, LOAD1, CPU%, MEM%, SWAP% (dash if no swap), ROOT%,
FAILED (failed systemd unit count). The quick "is the homelab healthy" view.

Deep dive on one host:

```
python3 "${CLAUDE_SKILL_DIR}/get_host.py" <host> [--json]
```

Shows OS and kernel, EOL date, load/CPU, memory/swap, per-filesystem usage,
network interfaces with link state and throughput, and the named failed units.

## Configuration

The Prometheus endpoint resolves from HOMELAB_PROM_URL, else a
.claude/homelab-endpoints.json found upward from the current directory, else
~/.claude/homelab-endpoints.json (see lib/homelab/config.py at the plugin
root). Logic lives in lib/homelab/nodeexporter.py on top of the shared
Prometheus client.
