"""node_exporter helpers built on the Prometheus client.

Read-only host health: identity, uptime, CPU/memory/disk usage, network link
state and throughput, and failed systemd units. Reused by the host-metrics
skill scripts. Note: node_exporter does not export IP addresses, only link
state and counters.
"""
from __future__ import annotations

from typing import Any

from .prometheus import PrometheusClient

JOB = 'job="node-exporter"'
# Pseudo filesystems that are not interesting for "disk full" reporting.
_FS_EXCLUDE = "tmpfs|ramfs|overlay|squashfs|iso9660|devtmpfs"


def _by_instance(client: PrometheusClient, expr: str) -> dict[str, float]:
    """Run an instant query and map each result to its instance label value."""
    out: dict[str, float] = {}
    for s in client.query(expr):
        inst = s["metric"].get("instance")
        try:
            out[inst] = float(s["value"][1])
        except (TypeError, ValueError):
            pass
    return out


def list_hosts(client: PrometheusClient | None = None) -> list[dict[str, Any]]:
    """One summary row per node-exporter target, for an at-a-glance health table."""
    client = client or PrometheusClient()
    up = _by_instance(client, f"up{{{JOB}}}")
    uptime = _by_instance(client, f"time() - node_boot_time_seconds{{{JOB}}}")
    cores = _by_instance(client, f'count by (instance) (node_cpu_seconds_total{{{JOB},mode="idle"}})')
    load1 = _by_instance(client, f"node_load1{{{JOB}}}")
    cpu = _by_instance(
        client,
        f'100 - (avg by (instance) (rate(node_cpu_seconds_total{{{JOB},mode="idle"}}[5m])) * 100)',
    )
    mem = _by_instance(
        client,
        f"100 * (1 - node_memory_MemAvailable_bytes{{{JOB}}} / node_memory_MemTotal_bytes{{{JOB}}})",
    )
    swap = _by_instance(
        client,
        f"100 * (1 - node_memory_SwapFree_bytes{{{JOB}}} / node_memory_SwapTotal_bytes{{{JOB}}})",
    )
    rootfs = _by_instance(
        client,
        f'100 * (1 - node_filesystem_avail_bytes{{{JOB},mountpoint="/"}} '
        f'/ node_filesystem_size_bytes{{{JOB},mountpoint="/"}})',
    )
    failed = _by_instance(
        client, f'count by (instance) (node_systemd_unit_state{{{JOB},state="failed"}} == 1)'
    )

    hosts = []
    for inst in sorted(up):
        hosts.append(
            {
                "instance": inst,
                "up": up.get(inst, 0.0) == 1.0,
                "uptime_seconds": uptime.get(inst),
                "cores": int(cores.get(inst, 0)),
                "load1": load1.get(inst),
                "cpu_pct": cpu.get(inst),
                "mem_pct": mem.get(inst),
                "swap_pct": swap.get(inst),  # NaN when the host has no swap
                "root_pct": rootfs.get(inst),
                "failed_units": int(failed.get(inst, 0)),
            }
        )
    return hosts


def failed_unit_names(instance: str, client: PrometheusClient | None = None) -> list[str]:
    client = client or PrometheusClient()
    q = f'node_systemd_unit_state{{{JOB},instance="{instance}",state="failed"}} == 1'
    return sorted(s["metric"].get("name", "?") for s in client.query(q))


def filesystems(instance: str, client: PrometheusClient | None = None) -> list[dict[str, Any]]:
    client = client or PrometheusClient()
    size = {
        s["metric"]["mountpoint"]: float(s["value"][1])
        for s in client.query(
            f'node_filesystem_size_bytes{{{JOB},instance="{instance}",fstype!~"{_FS_EXCLUDE}"}}'
        )
    }
    avail = {
        s["metric"]["mountpoint"]: float(s["value"][1])
        for s in client.query(
            f'node_filesystem_avail_bytes{{{JOB},instance="{instance}",fstype!~"{_FS_EXCLUDE}"}}'
        )
    }
    rows = []
    for mp in sorted(size):
        sz, av = size[mp], avail.get(mp, 0.0)
        rows.append(
            {"mount": mp, "size": sz, "avail": av, "used_pct": 100 * (1 - av / sz) if sz else 0.0}
        )
    return rows


def interfaces(instance: str, client: PrometheusClient | None = None) -> list[dict[str, Any]]:
    client = client or PrometheusClient()
    up = {
        s["metric"]["device"]: float(s["value"][1])
        for s in client.query(f'node_network_up{{{JOB},instance="{instance}"}}')
    }
    rx = {
        s["metric"]["device"]: float(s["value"][1])
        for s in client.query(
            f'rate(node_network_receive_bytes_total{{{JOB},instance="{instance}"}}[5m])'
        )
    }
    tx = {
        s["metric"]["device"]: float(s["value"][1])
        for s in client.query(
            f'rate(node_network_transmit_bytes_total{{{JOB},instance="{instance}"}}[5m])'
        )
    }
    rows = []
    for dev in sorted(up):
        if dev == "lo":
            continue
        rows.append(
            {"device": dev, "up": up.get(dev) == 1.0, "rx_bps": rx.get(dev, 0.0), "tx_bps": tx.get(dev, 0.0)}
        )
    return rows


def host_detail(instance: str, client: PrometheusClient | None = None) -> dict[str, Any]:
    client = client or PrometheusClient()
    summary = next((h for h in list_hosts(client) if h["instance"] == instance), None)

    identity: dict[str, Any] = {}
    for s in client.query(f'node_uname_info{{{JOB},instance="{instance}"}}'):
        m = s["metric"]
        identity.update({"nodename": m.get("nodename"), "kernel": m.get("release"), "arch": m.get("machine")})
    for s in client.query(f'node_os_info{{{JOB},instance="{instance}"}}'):
        m = s["metric"]
        identity.update({"os": m.get("pretty_name") or m.get("name"), "version": m.get("version_id")})

    eol = _by_instance(
        client, f'node_os_support_end_timestamp_seconds{{{JOB},instance="{instance}"}}'
    ).get(instance)

    return {
        "summary": summary,
        "identity": identity,
        "eol_timestamp": eol,
        "filesystems": filesystems(instance, client),
        "interfaces": interfaces(instance, client),
        "failed_units": failed_unit_names(instance, client),
    }
