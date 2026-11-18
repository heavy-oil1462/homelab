#!/usr/bin/env python3
"""Report pinned container images whose tag now points at another image.

Read-only. See skills/image-updates/SKILL.md for usage.
"""
import argparse
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "lib"))
from homelab import images  # noqa: E402


def short(digest: str | None) -> str:
    return digest.removeprefix("sha256:")[:12] if digest else "-"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Find pinned images (image = \"<name>@sha256:...\"; # <version>, :<tag> as of <date>) "
        "in a repository's *.nix files and ask each registry whether the tag has moved. "
        "Read-only; exits 0 whatever it finds.")
    parser.add_argument("path", nargs="?", default=".", help="repository to scan (default: the current directory)")
    parser.add_argument("--json", action="store_true", help="emit JSON")
    parser.add_argument("--no-majors", action="store_true", help="skip the tag list lookup for newer majors")
    parser.add_argument("--registry", action="append", default=[], metavar="NAME=URL",
                        help="API base URL of a registry, such as a mirror (repeatable)")
    args = parser.parse_args()

    client = images.RegistryClient(images.parse_registries(args.registry))
    results = images.check(args.path, client, majors=not args.no_majors)

    if args.json:
        print(json.dumps([r.to_dict() for r in results], indent=2))
        return
    if not results:
        print(f"no pinned images under {args.path}")
        return

    for r in results:
        print(f"{r.status:10} {r.file}:{r.line} {r.image}:{r.tag or '?'}")
        if r.status == "update":
            print(f"           {short(r.pinned_digest)} -> {short(r.current_digest)}, "
                  f"version {r.old_version or '-'} -> {r.new_version or '-'}")
        elif r.status == "up-to-date":
            print(f"           {short(r.pinned_digest)}, version {r.old_version or '-'}")
        if r.note:
            print(f"           note: {r.note}")
        if r.newer_major:
            print(f"           newer major: :{r.newer_major} (not bumped; a deliberate upgrade)")
        if r.newer_in_major:
            print(f"           newer release: :{r.newer_in_major} (the tag names one release; not bumped)")
    counts: dict[str, int] = {}
    for r in results:
        counts[r.status] = counts.get(r.status, 0) + 1
    print()
    print(", ".join(f"{n} {s}" for s, n in sorted(counts.items())))


if __name__ == "__main__":
    main()
