{ config, pkgs, ... }:

# A freshly installed host joins the tailnet on its own when a Tailscale auth
# key is waiting in keyFile. The installer puts it there (nixos-anywhere
# --extra-files); use a one-off, pre-approved key carrying the host's tags.
# Servers allow SSH on the tailnet only and nobody has a console password, so
# without this a bare metal install cannot be reached at all.
#
# The key is deleted once the node runs, and without the file the unit is
# skipped, so hosts that are already logged in never touch it and a used key
# never leaves a failed unit at a later boot.

let
  keyFile = "/var/lib/secrets/tailscale-authkey";
in
{
  services.tailscale = {
    enable = true;
    extraUpFlags = [ "--ssh" ];
    authKeyFile = keyFile;
  };

  systemd.services.tailscaled-autoconnect = {
    unitConfig.ConditionPathExists = keyFile;
    serviceConfig.ExecStartPost = "${pkgs.coreutils}/bin/rm -f ${keyFile}";
  };
}
