# Supervisor notes

How the podium team works on this repository. Written and kept by the
supervisor.

## Team

At most two workers (the project limit). Use one while CI is missing, since
reviews then depend on evaluating changes by hand; use two once CI runs and
two independent issues are ready. Remove a worker once it has had no issue
for a while.

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

- `nix flake check` must pass; until CI exists, run it yourself on the
  head commit before merging.
- Image changes: digest and version comment change together; the digest is
  the one the comment names.
- New or changed options are typed, described, live in
  `modules/options.nix` and are set in an example.
- README module list and `examples/assets/` match the change.
- Nothing listens on LAN interfaces unless an option opts in; no secret
  values or site-specific values in the tree.

## Lessons

- 2026-10-26: the bot account started with read-only access; a session
  start should check `gh api repos/heavy-oil1462/homelab --jq .permissions`
  before planning work.
