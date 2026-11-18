# ADR-0016: Container image updates are found by a tool and land as reviewed bumps

Status: Accepted

## Context

The owner asked for something that keeps the homelab's containers up to date
with security fixes (board, cue entry 01a1ef79-dda6, 2026-11-18). Goal 5 of
DIRECTION.md already asks that image digests stay current without manual
tracking. Until now a digest moved only when someone bumped it by hand, so
most pins were months old.

Two principles of DIRECTION.md bound the answer:

- Container images are pinned by digest, with a comment giving version or
  tag and date.
- Servers change only when deliberately rebuilt; nothing in a server module
  auto-upgrades or self-modifies.

Three ways were considered.

1. podman auto-update, or running `:latest` on the hosts. Either breaks both
   principles: the image a host runs is no longer the one in the
   repository, nobody reviews it, two hosts can run different images from
   the same configuration, and a rollback has no digest to go back to.
2. Renovate, which opens a pull request per update. The team's review flow
   is cue change sets, which a worker makes and the supervisor reviews, not
   forge pull requests. Renovate would need a bot account and a token on
   Forgejo, and its pull requests would bypass the review the team gives
   every other change.
3. A read-only tool that finds every pin whose tag now points at another
   image, and a separate script that rewrites those pins, run by the team.

## Decision

Option 3. `skills/image-updates` (logic in `lib/homelab/images.py`):

- `image_updates.py` finds every `image = "<name>@sha256:<digest>"; #
  <version>, :<tag> as of <date>` in a repository's `*.nix` files, asks the
  registry for the tag's current digest over the OCI distribution API with
  anonymous bearer tokens, and reports each pin as `up-to-date`, `update`,
  `unknown` (no tag in the comment) or `error`. For a multi-arch image it
  compares the index digest, which is what is pinned; a pin of the index's
  linux/amd64 manifest counts as the index. The new version comes from the
  image's version label. It changes nothing.
- `image_bump.py` is the one script that writes. It rewrites the pins with
  an update: the new digest, and the comment's version and date in the
  existing format. Nothing else changes, so the diff is one line per image.
- A tag that names a major (`:17-rootless`, `:8.0`) keeps the bump within
  it. A newer major found in the registry's tag list is reported and never
  bumped, so a major upgrade is a deliberate issue of its own, asked of the
  owner first when it migrates data (DIRECTION.md, "Ask the owner first").
- Every pin in `containers/` names its tag; the `skills` check fails on one
  that does not, so new pins stay checkable.

The supervisor's loop: with each status report it runs the tool against
homelab and homelab-config, and files one bump issue per repository with
updates, security-relevant ones first. A worker runs `image_bump.py` and
checks the result, the supervisor reviews the change set, and the owner
deploys it with `update-fleet`. A fix published upstream reaches the fleet
within about a day, reviewed, and reproducible from the repository.

## Consequences

- What a host runs is still exactly what the repository pins. A bad image
  is reverted like any other change.
- A fix waits for the next status report, the review and the owner's
  deploy. Nothing reaches a host faster than that, by design.
- Images with no version label (Prometheus and Loki today) keep their old
  version in the comment after a bump; the report says so, and the worker
  fills it in by hand where it matters.
- A pin whose comment names a fixed release (`:0.17.1-tensorrt`) never
  moves; the report names the latest release of its major instead, for an
  issue.
- The tool asks registries anonymously and reads only manifests, configs
  and tag lists. docker.io's anonymous pull limit counts manifest GETs;
  a check costs a HEAD per pin and a few GETs per update, well inside it.
- A bump can bring an image that runs differently: another user, a new
  capability, a changed entrypoint. The `container-hardening` check
  (ADR-0014) evaluates the modules, not the images, so such a change shows
  only on the host; the worker reads the release notes of what it bumps.
- Not covered: images built from our own repositories (cue, fyr, podium,
  vaka) are rebuilt by podium on merge, so their base images get fixes only
  when their repository changes. Rebuilding them when their base image
  moves is a follow-up. A vulnerability scan of the pinned images (such as
  Trivy) is proposed to the owner separately, and running the check on a
  schedule in CI is not part of this.

Related: [ADR-0014](0014-containers-run-unprivileged.md) (containers run
unprivileged; this record keeps what they run current).
