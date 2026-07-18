#!/usr/bin/env python3
"""Fetch service logs from Loki (the systemd-journal stream).

Filter by host, service, severity, time window, and a message regex. See
.claude/skills/service-logs/SKILL.md for usage.
"""
import argparse
import datetime
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "lib"))
from homelab.logs import LEVEL_TO_PRIORITY, PRIORITY_NAMES, fetch_logs  # noqa: E402
from homelab.loki import LokiError  # noqa: E402


def parse_duration(s: str) -> float:
    """Parse 90s / 30m / 2h / 1d into seconds."""
    m = re.fullmatch(r"(\d+)([smhd])", s.strip())
    if not m:
        raise argparse.ArgumentTypeError(f"bad duration '{s}', use e.g. 30m, 2h, 1d")
    n, unit = int(m.group(1)), m.group(2)
    return n * {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit]


def parse_level(s: str) -> int:
    """Accept a priority name (warning) or number (4)."""
    s = s.strip().lower()
    if s.isdigit():
        return int(s)
    if s in LEVEL_TO_PRIORITY:
        return LEVEL_TO_PRIORITY[s]
    raise argparse.ArgumentTypeError(
        f"bad level '{s}', use a number 0-7 or one of {', '.join(LEVEL_TO_PRIORITY)}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Fetch service logs from Loki.")
    parser.add_argument("--host", help="limit to one host by hostname (omit for all)")
    parser.add_argument("-s", "--service", help="match unit/identifier/container (substring)")
    parser.add_argument("--since", type=parse_duration, default=3600, help="time window, e.g. 30m, 2h, 1d (default 1h)")
    parser.add_argument("--level", type=parse_level, help="minimum severity: name or 0-7 (e.g. warning)")
    parser.add_argument("--grep", help="case-insensitive regex on the message")
    parser.add_argument("--limit", type=int, default=200, help="max lines (default 200)")
    parser.add_argument("--full", action="store_true", help="do not truncate long messages")
    parser.add_argument("--json", action="store_true", help="emit JSON")
    args = parser.parse_args()

    try:
        rows = fetch_logs(
            host=args.host,
            service=args.service,
            since_seconds=args.since,
            limit=args.limit,
            priority=args.level,
            grep=args.grep,
        )
    except LokiError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)

    if args.json:
        print(json.dumps(rows, indent=2))
        return

    if not rows:
        print("no matching log lines")
        return

    for r in rows:
        when = datetime.datetime.fromtimestamp(r["ns"] / 1e9).strftime("%m-%d %H:%M:%S")
        level = PRIORITY_NAMES.get(r["priority"], "") if r["priority"] is not None else ""
        level = f" {level}" if level else ""
        msg = r["message"]
        if not args.full and len(msg) > 300:
            msg = msg[:300] + " ..."
        print(f"{when} {r['host']} {r['unit']}{level}: {msg}")


if __name__ == "__main__":
    main()
