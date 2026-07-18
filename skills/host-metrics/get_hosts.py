#!/usr/bin/env python3
"""At-a-glance health table for every node-exporter host, read from Prometheus.

See .claude/skills/host-metrics/SKILL.md for usage.
"""
import argparse
import json
import math
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "lib"))
from homelab.nodeexporter import list_hosts  # noqa: E402
from homelab.prometheus import PrometheusError  # noqa: E402


def fmt_uptime(seconds: float | None) -> str:
    if seconds is None:
        return "-"
    d, rem = divmod(int(seconds), 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f"{d}d{h}h"
    if h:
        return f"{h}h{m}m"
    return f"{m}m"


def fmt_pct(v: float | None) -> str:
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return "-"
    return f"{v:.0f}"


def main() -> None:
    parser = argparse.ArgumentParser(description="Per-host health summary.")
    parser.add_argument("--json", action="store_true", help="emit JSON")
    args = parser.parse_args()

    try:
        hosts = list_hosts()
    except PrometheusError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)

    if args.json:
        print(json.dumps(hosts, indent=2))
        return

    if not hosts:
        print("no node-exporter targets found")
        return

    header = f"{'HOST':12} {'UP':3} {'UPTIME':8} {'CORES':5} {'LOAD1':6} {'CPU%':5} {'MEM%':5} {'SWAP%':6} {'ROOT%':6} {'FAILED':6}"
    print(header)
    print("-" * len(header))
    for h in hosts:
        load1 = "-" if h["load1"] is None else f"{h['load1']:.2f}"
        print(
            f"{h['instance']:12} "
            f"{'y' if h['up'] else 'N':3} "
            f"{fmt_uptime(h['uptime_seconds']):8} "
            f"{h['cores']:<5} "
            f"{load1:6} "
            f"{fmt_pct(h['cpu_pct']):5} "
            f"{fmt_pct(h['mem_pct']):5} "
            f"{fmt_pct(h['swap_pct']):6} "
            f"{fmt_pct(h['root_pct']):6} "
            f"{h['failed_units']:<6}"
        )


if __name__ == "__main__":
    main()
