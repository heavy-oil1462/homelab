#!/usr/bin/env python3
"""Show the full Prometheus-exported state of one Home Assistant entity.

Accepts an exact entity_id (e.g. lock.lock) or a name/substring; if the term
is ambiguous it lists the candidates instead of guessing. See
.claude/skills/ha-state/SKILL.md for usage.
"""
import argparse
import json
import pathlib
import sys

# Make the shared homelab toolkit importable (.claude/lib).
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "lib"))
from homelab.ha import entity_state, find_entities  # noqa: E402
from homelab.prometheus import PrometheusError  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description="Show one HA entity's state.")
    parser.add_argument("entity", help="entity_id or name substring")
    parser.add_argument("--json", action="store_true", help="emit JSON")
    args = parser.parse_args()

    try:
        matches = find_entities(args.entity)
    except PrometheusError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)

    exact = [m for m in matches if m["entity"] == args.entity]
    if exact:
        target = exact[0]
    elif len(matches) == 1:
        target = matches[0]
    elif not matches:
        print(f"no entity matching '{args.entity}'", file=sys.stderr)
        sys.exit(1)
    else:
        print(f"'{args.entity}' is ambiguous, candidates:")
        for m in matches:
            print(f"  {m['entity']}  ({m['friendly_name']})")
        sys.exit(2)

    state = entity_state(target["entity"])
    state.update(
        {
            "friendly_name": target["friendly_name"],
            "domain": target["domain"],
            "area": target["area"],
            "available": target["available"],
        }
    )

    if args.json:
        print(json.dumps(state, indent=2))
        return

    print(f"{state['entity']}  ({state['friendly_name']})")
    print(f"  area:      {state['area'] or '(none)'}")
    print(f"  domain:    {state['domain']}")
    print(f"  available: {state['available']}")
    if state["metrics"]:
        print("  metrics:")
        for m in state["metrics"]:
            labels = "".join(f" {k}={v}" for k, v in m["labels"].items())
            print(f"    {m['metric']} = {m['value']}{labels}")


if __name__ == "__main__":
    main()
