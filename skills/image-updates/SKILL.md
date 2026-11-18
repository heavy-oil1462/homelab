---
name: image-updates
description: Find the container images pinned by digest in a repository's Nix files whose tag now points at another image, and the newer majors a tag does not follow. Use to see which containers have updates, including security fixes, and to prepare an image bump. image_bump.py WRITES the Nix files; image_updates.py only reads.
---

# Image updates

Container images are pinned by digest, with a comment naming the tag the
digest came from (DIRECTION.md):

```nix
image = "codeberg.org/forgejo/forgejo@sha256:..."; # 17.0.1-rootless, :17-rootless as of 2026-11-09
```

These scripts ask each image's registry what the tag points at now. They
reach the registries directly (docker.io, ghcr.io, codeberg.org, lscr.io and
any other OCI registry), anonymously, through the environment's
`https_proxy` if one is set. Nothing on the hosts changes; a bump is a
change to the repository that is reviewed and deployed like any other
(docs/adr/0016-image-updates-as-reviewed-bumps.md).

## Scripts

Report, read-only. Exits 0 whatever it finds:

```
python3 "${CLAUDE_SKILL_DIR}/image_updates.py" [PATH] [--json] [--no-majors]
```

PATH is the repository to scan, default the current directory; every
`*.nix` file under it is read. Per pin: file and line, image, tag, pinned
and current digest, old and new version, and a status:

- `up-to-date`: the tag still points at the pinned digest. A pin of the
  index's linux/amd64 manifest counts as a pin of the index.
- `update`: the tag points at another image. The new version comes from
  the linux/amd64 image's `org.opencontainers.image.version` label, or the
  index's annotation of it; an image with neither keeps its old version,
  and the note says so.
- `unknown`: the comment names no tag, so there is nothing to ask.
- `error`: the registry could not answer; the note says why.

For a tag that names a version (`:17-rootless`, `:8.0`), the tag list also
gives `newer_major`, a later major of the same form (`:18-rootless`,
`:9.0`), which a bump never moves to: a major upgrade is its own issue,
and one that migrates data is the owner's call. A tag that names one
release (`:0.17.1-tensorrt`) never moves, so `newer_in_major` gives the
latest release of its major. `--no-majors` skips the tag lists.

## Writes: image_bump.py

**This script changes files.** It rewrites every pin whose status is
`update`: the new digest (the index's, for a multi-arch image), and in the
comment the version, where the comment has one and the image's label gives
the new one, and the date. Nothing else in the files changes. Review the
diff before committing it.

```
python3 "${CLAUDE_SKILL_DIR}/image_bump.py" [PATH] [--only IMAGE] [--json]
```

`--only library/caddy` bumps only images whose name ends so. It exits 1
when a registry could not answer for some pin, after bumping the others.

Both take `--registry NAME=URL` to send a registry's requests elsewhere,
such as a mirror. Logic lives in lib/homelab/images.py at the plugin root.
