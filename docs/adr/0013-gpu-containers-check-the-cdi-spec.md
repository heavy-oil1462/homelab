# ADR-0013: GPU containers check the CDI spec before they start

Status: Accepted

## Context

Containers get the GPU through the NVIDIA container toolkit's CDI spec,
`/run/cdi/nvidia-container-toolkit.json`. nixpkgs writes it once with
`nvidia-container-toolkit-cdi-generator`, a oneshot that stays active, from
`hardware.nvidia-container-toolkit`. The spec names store paths: the
driver's libraries, the toolkit's hooks, glibc. A container also gets the
host's `/run/opengl-driver`, whose `libcuda.so.1` links into the driver's
store path, and that path exists in the container only if the spec mounts
it.

On 2026-11-16 a rebuild of homelab-config's NVR host moved the driver to a
new store path at the same version, and vaka-detect started with a spec that
still mounted the previous one. `libcuda.so.1` was a dangling link in the
container and the detector failed at every start. Which step left the old
spec behind is not on record. homelab-config fixed it for vaka-detect alone
(`containers/vaka-detect.nix`, cue 01a1e643-95a4) with an `ExecStartPre`
that checks the spec and writes it again. Any container using the spec has
the same problem: Frigate (`containers/nvr.nix`, podman's `--gpus all`)
when it is restored, and future GPU containers.

Two places could make sure the spec is right:

1. The generator: restart it on every switch, or run it as an
   `ExecStartPre` of podman. That changes nixpkgs' unit, still leaves a
   window where a container starts before the spec is written, and does not
   catch a spec whose paths were collected later.
2. The containers: each checks the spec right before it starts, and runs
   the generator itself when the spec is stale. The check runs at the only
   moment the spec matters, for the units that need it.

## Decision

- The nvidia module (`homelab.nixosModules.nvidia`) takes
  `homelab.nvidia.cdiCheck.units`, a list of systemd services. Each gets
  `nvidia-cdi-check` as its first `ExecStartPre` (`lib.mkBefore`, ahead of
  podman's own pre-start), starts after and requires
  `nvidia-container-toolkit-cdi-generator`.
- The check holds the spec stale when it is missing or empty, when no mount
  has this system's driver (`lib.getLib config.hardware.nvidia.package`) as
  its host path, or when a mount or hook names a path that does not exist.
  It then runs this system's generator directly, the unit's `ExecStart`
  with `RUNTIME_DIRECTORY=/run/cdi`, and checks again; still stale, it
  exits 1 and the start fails. Restarting the generator's unit from the
  check would restart the container's unit too, since it requires it.
- The script is a package of its own, `modules/nvidia-cdi-check.nix`,
  taking the unit, spec, driver and generator as arguments, so the flake's
  `nvidia-cdi-check` check runs the same script against stub specs:
  current, missing, empty, another driver, a deleted path.
- Listing a unit asserts `hardware.nvidia-container-toolkit.enable` and that
  the unit exists. The module does not turn the toolkit on itself.
- The failure and the manual fix are in [docs/nvidia.md](../nvidia.md).

## Consequences

- A rebuild that moves the driver needs no manual step for a listed unit;
  the next start fixes the spec and says why in the unit's journal.
- The spec a check writes again serves every container using it, listed
  or not. Two listed units starting at once can both run the generator;
  both write the same content from the same inputs, and a check that reads
  a half-written spec fails its start and tries again on its unit's
  `Restart=`.
- A running container keeps the mounts it started with. The check does not
  restart anything; a restart of the generator does, through `Requires=`.
- Requiring the generator means a listed unit does not start when the
  generator fails, which it would not have done usefully anyway.
- Units not listed, and containers started by hand, are not checked; the
  manual fix in docs/nvidia.md applies to them.
- homelab-config's vaka-detect keeps its own copy until it moves to the
  option, in a follow-up after its homelab input is updated.
