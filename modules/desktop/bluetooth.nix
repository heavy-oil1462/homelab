{ pkgs, ... }:

{
  # Bluetooth controller support. powerOnBoot keeps the adapter up after a
  # reboot so paired devices (headphones, mouse) reconnect without manual
  # intervention.
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        # Expose battery levels for supported devices and improve A2DP audio
        # device handling.
        Experimental = true;
      };
    };
  };

  # blueman-manager provides the pairing GUI and a tray applet. The applet
  # lands in the waybar tray; waybar's bluetooth module launches
  # blueman-manager on click.
  services.blueman.enable = true;
}
