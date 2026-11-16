{ config, lib, pkgs, ... }:

# The proprietary NVIDIA driver, and with homelab.nvidia.cdiCheck.units a
# check of the container toolkit's CDI spec before each listed GPU container
# starts (docs/nvidia.md, docs/adr/0013-gpu-containers-check-the-cdi-spec.md).
#
# The spec, /run/cdi/nvidia-container-toolkit.json, is written once by
# nixpkgs' nvidia-container-toolkit-cdi-generator, a oneshot that stays
# active, and names store paths: the driver's libraries, the toolkit's
# hooks, glibc. A container gets the host's /run/opengl-driver, whose
# libcuda.so.1 links into the driver's store path, and that path is in the
# container only if the spec mounts it. When a rebuild moves the driver and
# the spec still names the previous one, the container fails with
# "libcuda.so.1: cannot open shared object file".

let
  cfg = config.homelab.nvidia.cdiCheck;

  check = pkgs.callPackage ./nvidia-cdi-check.nix { };
  spec = "/run/cdi/nvidia-container-toolkit.json";
  driver = "${lib.getLib config.hardware.nvidia.package}";
  generatorUnit = "nvidia-container-toolkit-cdi-generator.service";
  # Only there with hardware.nvidia-container-toolkit.enable, which an
  # assertion below asks for.
  generator = config.systemd.services.nvidia-container-toolkit-cdi-generator.serviceConfig.ExecStart or "";

  checkUnit = unit: {
    after = [ generatorUnit ];
    requires = [ generatorUnit ];
    # Ahead of everything else the unit runs before it starts, podman's own
    # pre-start included. Still wrong after writing it again, the start
    # fails, and the unit's Restart= decides whether to try again.
    serviceConfig.ExecStartPre = lib.mkBefore [
      (lib.escapeShellArgs [ (lib.getExe check) unit spec driver generator ])
    ];
  };
in
{
  imports = [ ./options.nix ];

  config = lib.mkMerge [
    {
      services.xserver.videoDrivers = [ "nvidia" ];
      hardware = {
        graphics.enable = true;
        nvidia = {
          modesetting.enable = true;
          powerManagement.enable = true;
          powerManagement.finegrained = false;
          open = true;
          nvidiaSettings = true;
          package = config.boot.kernelPackages.nvidiaPackages.stable;
        };
      };
    }

    (lib.mkIf (cfg.units != [ ]) {
      assertions = [{
        assertion = config.hardware.nvidia-container-toolkit.enable;
        message = "homelab.nvidia.cdiCheck.units checks the NVIDIA container toolkit's CDI spec; set hardware.nvidia-container-toolkit.enable.";
      }] ++ map (unit: {
        # A name with no service behind it would make a unit of the check
        # alone.
        assertion = config.systemd.services.${unit}.serviceConfig ? ExecStart;
        message = "homelab.nvidia.cdiCheck.units names ${unit}, which is no service with an ExecStart on this host.";
      }) cfg.units;
      systemd.services = lib.genAttrs cfg.units checkUnit;
    })
  ];
}
