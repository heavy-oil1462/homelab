#!/usr/bin/env python3
"""List which systemd units have logged recently, with line counts, from Loki.

Useful for discovering the service name to pass to get_logs.py --service.
See .claude/skills/service-logs/SKILL.md for usage.
"""
import argparse
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "lib"))
from homelab.logs import list_services  # noqa: E402
from homelab.loki import LokiError  # noqa: E402


def parse_duration(s: str) -> float:
    m = re.fullmatch(r"(\d+)([smhd])", s.strip())
    if not m:
        raise argparse.ArgumentTypeError(f"bad duration '{s}', use e.g. 30m, 2h, 1d")
    n, unit = int(m.group(1)), m.group(2)
    return n * {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit]


def main() -> None:
    parser = argparse.ArgumentParser(description="List units logging recently.")
    parser.add_argument("--host", help="limit to one host")
    parser.add_argument("--since", type=parse_duration, default=3600, help="window, e.g. 1h, 6h, 1d (default 1h)")
    parser.add_argument("--json", action="store_true", help="emit JSON")
    args = parser.parse_args()

    try:
        rows = list_services(host=args.host, since_seconds=args.since)
    except LokiError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)

    if args.json:
        print(json.dumps(rows, indent=2))
        return

    if not rows:
        print("no units logged in the window")
        return

    width = max(len(r["unit"]) for r in rows)
    for r in rows:
        print(f"{r['unit']:<{width}}  {r['count']}")


if __name__ == "__main__":
    main()
