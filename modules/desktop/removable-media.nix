{ config, pkgs, ... }:

{
  # Mounting of USB sticks and other removable drives.
  #
  # udisks2 is the system daemon that does the actual mounting. Its default
  # polkit rules already allow the active local session to mount and unmount
  # removable drives without a password, so no extra rules are needed.
  # Dolphin talks to it directly; udiskie (started from hyprland.conf) sits
  # in the waybar tray, automounts anything plugged in under
  # /run/media/<user>/ and offers per-device unmount from its menu, which
  # also covers the terminal file manager since a mounted stick is just a
  # directory.
  services.udisks2.enable = true;

  # Userspace filesystems for the file managers on top of udisks2: MTP
  # phones, cameras, network shares, and the trash backend.
  services.gvfs.enable = true;

  environment.systemPackages = [ pkgs.udiskie ];
}
