#!/usr/bin/env python3
"""Deep-dive health for one node-exporter host, read from Prometheus.

Shows identity, uptime, load/CPU, memory/swap, per-filesystem usage, network
interfaces (link state and throughput), and any failed systemd units. See
.claude/skills/host-metrics/SKILL.md for usage.
"""
import argparse
import datetime
import json
import math
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "lib"))
from homelab.nodeexporter import host_detail, list_hosts  # noqa: E402
from homelab.prometheus import PrometheusError  # noqa: E402


def fmt_bytes(n: float) -> str:
    for unit in ("B", "K", "M", "G", "T"):
        if abs(n) < 1024:
            return f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}P"


def fmt_pct(v) -> str:
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return "-"
    return f"{v:.0f}%"


def main() -> None:
    parser = argparse.ArgumentParser(description="Deep-dive one host's metrics.")
    parser.add_argument("host", help="instance name (get_hosts.py lists them)")
    parser.add_argument("--json", action="store_true", help="emit JSON")
    args = parser.parse_args()

    try:
        known = [h["instance"] for h in list_hosts()]
        if args.host not in known:
            print(f"unknown host '{args.host}'. known: {', '.join(known)}", file=sys.stderr)
            sys.exit(1)
        detail = host_detail(args.host)
    except PrometheusError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)

    if args.json:
        print(json.dumps(detail, indent=2))
        return

    s = detail["summary"] or {}
    ident = detail["identity"]
    print(f"{args.host}")
    print(f"  os:        {ident.get('os', '?')} (kernel {ident.get('kernel', '?')}, {ident.get('arch', '?')})")
    if detail["eol_timestamp"]:
        eol = datetime.date.fromtimestamp(detail["eol_timestamp"])
        print(f"  eol:       {eol.isoformat()}")
    print(f"  up:        {s.get('up')}")
    print(f"  cores:     {s.get('cores')}    load1: {s.get('load1')}")
    print(f"  cpu:       {fmt_pct(s.get('cpu_pct'))}")
    print(f"  memory:    {fmt_pct(s.get('mem_pct'))} used    swap: {fmt_pct(s.get('swap_pct'))}")

    print("  filesystems:")
    for fs in detail["filesystems"]:
        print(f"    {fs['mount']:20} {fmt_pct(fs['used_pct']):>5}  ({fmt_bytes(fs['size'] - fs['avail'])} / {fmt_bytes(fs['size'])})")

    print("  interfaces:")
    for nic in detail["interfaces"]:
        state = "up" if nic["up"] else "DOWN"
        print(f"    {nic['device']:14} {state:5}  rx {fmt_bytes(nic['rx_bps'])}/s  tx {fmt_bytes(nic['tx_bps'])}/s")

    failed = detail["failed_units"]
    if failed:
        print(f"  failed units ({len(failed)}):")
        for u in failed:
            print(f"    {u}")
    else:
        print("  failed units: none")


if __name__ == "__main__":
    main()
