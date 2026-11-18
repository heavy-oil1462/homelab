#!/usr/bin/env python3
"""WRITES FILES. Rewrite the pins whose tag has moved: the new digest, and
the comment's version and date. Nothing else in the files changes.

See skills/image-updates/SKILL.md for usage.
"""
import argparse
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "lib"))
from homelab import images  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Rewrite every pinned image whose tag has moved to the tag's current digest, "
        "with the comment's version and date. Writes the *.nix files in place; review the diff.")
    parser.add_argument("path", nargs="?", default=".", help="repository to rewrite (default: the current directory)")
    parser.add_argument("--json", action="store_true", help="emit the rewritten pins as JSON")
    parser.add_argument("--only", action="append", default=[], metavar="IMAGE",
                        help="bump only images whose name ends with IMAGE, such as library/caddy (repeatable)")
    parser.add_argument("--registry", action="append", default=[], metavar="NAME=URL",
                        help="API base URL of a registry, such as a mirror (repeatable)")
    args = parser.parse_args()

    client = images.RegistryClient(images.parse_registries(args.registry))
    results = images.check(args.path, client, majors=False)
    if args.only:
        results = [r for r in results if any(r.image.endswith(o) for o in args.only)]
    try:
        bumped = images.apply_bumps(args.path, results)
    except (ValueError, OSError) as exc:
        print(f"error: {exc}; nothing written", file=sys.stderr)
        sys.exit(1)

    failed = [r for r in results if r.status == "error"]
    if args.json:
        print(json.dumps({"bumped": [r.to_dict() for r in bumped],
                          "errors": [r.to_dict() for r in failed]}, indent=2))
    else:
        for r in bumped:
            print(f"bumped {r.file}:{r.line} {r.image}:{r.tag} "
                  f"{r.old_version or '-'} -> {r.new_version or '-'}"
                  + (f" ({r.note})" if r.note else ""))
        for r in failed:
            print(f"error  {r.file}:{r.line} {r.image}: {r.note}", file=sys.stderr)
        if not bumped:
            print("nothing to bump")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
