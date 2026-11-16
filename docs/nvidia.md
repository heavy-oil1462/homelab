# NVIDIA driver and GPU containers

`modules/nvidia.nix` installs the proprietary NVIDIA driver
(`config.boot.kernelPackages.nvidiaPackages.stable`, open kernel modules).
The host must allow the unfree `nvidia-x11` and `nvidia-settings`, as
`examples/server.nix` does.

## GPU containers and the CDI spec

Containers get the GPU through the NVIDIA container toolkit's CDI spec
(`hardware.nvidia-container-toolkit.enable`), with `--device
nvidia.com/gpu=all` or podman's `--gpus all`. nixpkgs writes the spec,
`/run/cdi/nvidia-container-toolkit.json`, with
`nvidia-container-toolkit-cdi-generator`, a oneshot that runs once and stays
active. The spec names store paths: the driver's libraries, the toolkit's
hooks, glibc. The container also gets the host's `/run/opengl-driver`, whose
`libcuda.so.1` is a link into the driver's store path, and that path is in
the container only if the spec mounts it.

List the units of such containers in `homelab.nvidia.cdiCheck.units`:

```nix
hardware.nvidia-container-toolkit.enable = true;
homelab.nvidia.cdiCheck.units = [ "podman-frigate" ];
```

Each listed unit then:

- checks the spec before every start, as its first `ExecStartPre`: the spec
  must mount this system's driver, and every path it names, mounts and
  hooks, must exist (a spec from an older system can name paths the garbage
  collector has deleted since). When not, it runs this system's generator
  itself, logs why, and checks again. Still wrong, the start fails and the
  unit's own `Restart=` decides whether to try again.
- starts after, and requires, `nvidia-container-toolkit-cdi-generator`, so
  restarting the generator, by a switch or by hand, restarts it with the new
  spec.

The check is `nvidia-cdi-check` (`modules/nvidia-cdi-check.sh`), and the
flake's `nvidia-cdi-check` check runs it against stub specs. Why the
containers check rather than the generator is in
[ADR-0013](adr/0013-gpu-containers-check-the-cdi-spec.md).

## libcuda.so.1: cannot open shared object file

A GPU container fails at every start, and its journal says something like

```
libcuda.so.1: cannot open shared object file: No such file or directory
```

The CDI spec mounts another NVIDIA driver than the one `/run/opengl-driver`
leads to. It happened on a homelab host after a rebuild moved the driver to
a new store path at the same version: the container started with a spec
that still mounted the previous one, and `libcuda.so.1` was a dangling link
inside it.

With the unit in `homelab.nvidia.cdiCheck.units` the check writes the spec
again before the start and logs

```
podman-frigate: the CDI spec does not mount this system's driver, /nix/store/...-nvidia-x11-595.71.05; writing it again
```

so a rebuild needs nothing more. To see which driver each side has:

```bash
grep -o '/nix/store/[^"]*nvidia-x11[^"/]*' /run/cdi/nvidia-container-toolkit.json | sort -u
readlink -f /run/opengl-driver/lib/libcuda.so.1
```

Should it show up anyway, or on a unit that is not listed, write the spec
again and start the container (here Frigate):

```bash
sudo systemctl restart nvidia-container-toolkit-cdi-generator
sudo systemctl restart podman-frigate
```

A listed unit requires the generator, so the first command restarts it as
well; the second is for when it was not running.
