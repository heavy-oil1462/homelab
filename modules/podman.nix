{ config, pkgs, ... }:

{
  virtualisation = {
    podman = {
      enable = true;
      dockerCompat = true;
      defaultNetwork.settings.dns_enabled = true;
    };
  };

  # dhcpcd runs on every interface by default, tries DHCP on the host side
  # of each podman veth pair, and falls back to assigning a useless IPv4
  # link-local address (169.254.x.x) when nothing answers. Host-networked
  # containers that enumerate interfaces to pick an address to advertise
  # (the UniFi controller does) can then grab one of those instead of the
  # LAN address. Keep dhcpcd off container plumbing entirely.
  networking.dhcpcd.denyInterfaces = [ "podman*" "veth*" ];
}
