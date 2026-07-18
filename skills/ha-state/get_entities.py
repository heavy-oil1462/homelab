#!/usr/bin/env python3
"""List all Home Assistant entities and their state, read from Prometheus.

Groups entities by area and shows availability, so it doubles as a quick
inventory. See .claude/skills/ha-state/SKILL.md for usage.
"""
import argparse
import json
import pathlib
import sys

# Make the shared homelab toolkit importable (.claude/lib).
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "lib"))
from homelab.ha import list_entities  # noqa: E402
from homelab.prometheus import PrometheusError  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description="List HA entities and their state.")
    parser.add_argument("--json", action="store_true", help="emit JSON")
    parser.add_argument("--area", help="filter by area substring")
    parser.add_argument("--domain", help="filter by HA domain (light, sensor, ...)")
    parser.add_argument(
        "--unavailable",
        action="store_true",
        help="only entities currently unavailable",
    )
    args = parser.parse_args()

    try:
        rows = list_entities()
    except PrometheusError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)

    if args.area:
        rows = [r for r in rows if args.area.lower() in (r["area"] or "").lower()]
    if args.domain:
        rows = [r for r in rows if r["domain"] == args.domain]
    if args.unavailable:
        rows = [r for r in rows if not r["available"]]

    if args.json:
        print(json.dumps(rows, indent=2))
        return

    if not rows:
        print("no matching entities")
        return

    width = max(len(r["entity"]) for r in rows)
    current_area = object()
    for r in rows:
        area = r["area"] or "(no area)"
        if area != current_area:
            current_area = area
            print(f"\n# {area}")
        flag = "  " if r["available"] else "X "
        print(f"{flag}{r['entity']:<{width}}  {r['friendly_name']}")


if __name__ == "__main__":
    main()
