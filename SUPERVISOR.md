# Supervisor notes

How the podium team works on this repository. Written and kept by the
supervisor.

## Team

At most the limit set on podium's status page (GET /team, max_workers).
Use one while CI checks do not report, since reviews then depend on
evaluating changes by hand; add more only for independent issues that are
ready. Remove a worker once it has had no issue for a while.

## Cutting issues

- One module or one concern per issue: a container fix, a backup target, a
  set of alert rules. Changes that touch `modules/options.nix` plus one
  module are normal; touching several services at once is not.
- Acceptance criteria name the option paths, the example host that
  exercises the change, and what `nix flake check` must evaluate.
- Say which runtime files consumers must provision (`/var/lib/secrets/...`)
  and whether existing data migrates. Anything in DIRECTION.md's "Ask the
  owner first" list is decided in a needs:owner issue before assignment.
- Workers cannot deploy or reach the homelab. Behaviour that only shows on a
  real host (podman networking, GPU, Tailscale) goes in the issue as a
  manual test step for the owner, listed in the pull request description.

## Review

- `nix flake check` must pass; until CI checks report in cue, run it
  yourself on the head commit before approving. homelab-config needs the
  private podium input overridden with a stub to evaluate here.
- Image changes: digest and version comment change together; the digest is
  the one the comment names.
- New or changed options are typed, described, live in
  `modules/options.nix` and are set in an example.
- README module list and `examples/assets/` match the change.
- Nothing listens on LAN interfaces unless an option opts in; no secret
  values or site-specific values in the tree.

## Stuck issues

Owner direction (board, 2026-11-12): clean up stuck issues. Each event
batch, look at issues that have not moved for a day: in review with checks
pending, blocked, open with needs:owner, or ready with nobody taking them.
Review what can be reviewed, release idle workers, and name what is
outside the team (runner, deploy, an owner click) on the issue and in the
next report, rather than letting it sit.

## What waits on the owner

Owner direction (board, 2026-11-13): "It is quite unclear now for me if
something is waiting for my approval. Can that be made more clear".

- Anything that needs the owner's decision or action is a cue question,
  never only a comment or a needs:owner tag, since cue shows questions to
  the owner.
- Every status report starts with a "Waiting for you" list: each item with
  what to do and where (cue question, podium setting, deploy), or
  "nothing".
- The "Waiting for you" list links the owner-todo issue, where the
  owner's remaining steps are listed (DIRECTION.md, How to work).
- The supervisor never leaves its own change sets for the owner to
  approve. Docs changes go through a worker issue like any other.
- With each status report, run `skills/image-updates` against homelab
  and homelab-config; file one bump issue per repository for the updates
  found, security-relevant first (ADR-0016).
- With each status report, read vaka's stream health from Prometheus
  (vaka's docs/metrics.md) and add one line to the report: streams up;
  disconnects in the last day; main-stream frame rate and keyframe
  interval per camera, against their usual; motion lag; detection
  latency p95; live-view time to first frame p50; and the recordings
  disk. Flag anything off, and open an issue when it needs work (owner,
  board 01a1f5f2-dab2, 2026-11-19).

## Lessons

- 2026-10-26: the bot account started with read-only access; a session
  start should check `gh api repos/heavy-oil1462/homelab --jq .permissions`
  before planning work.
- 2026-11-12: Forgejo Actions run 122 waited a day with no runner picking
  up `runs-on: docker`. Check run state with the Forgejo API
  (/api/v1/repos/homelab/homelab/actions/runs) before blaming a workflow.
- 2026-11-13: change sets the supervisor makes itself do not merge; carry
  docs changes in worker issues.
- 2026-11-14: four change sets in podium and cue sat in review overnight
  with no review event reaching the supervisor. Each session, list
  in_review issues and review any whose change set is waiting, rather than
  relying on events alone.
- 2026-11-14: four times today (podium ADR-028, vaka ADR-0003, homelab
  ADR-0010, vaka ADR-0006) a worker wrote an ADR as Proposed for a
  decision the owner or the supervisor had already made, and each cost a
  review round: podium gives workers only Accepted ADRs, so a Proposed one
  never reaches later work.
  - An issue that asks for an ADR says its Status. **Accepted** when the
    owner directed it or the supervisor decides it in the issue.
    **Proposed** only when the ADR is a proposal the owner must still
    accept, and then the issue says so.
  - A worker who adds an ADR for its own implementation decisions within
    the issue's scope writes it Accepted and names it in the summary for
    the supervisor to confirm. The supervisor sends it back only if it
    disagrees with a decision.
