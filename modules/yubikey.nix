{ config, pkgs, ... }:

{
  imports = [ ./options.nix ];

  services = {
    yubikey-agent = {
      enable = true;
    };
    pcscd.enable = true;
    udev.packages = [ pkgs.yubikey-personalization pkgs.libfido2 ];
  };

  security.pam.u2f = {
    enable = true;
    settings = {
      pinverification = 1;
      cue = true;
      authfile = "/etc/u2f_keys";
      # Pin the U2F origin/appid to a fixed, host-independent value. Without
      # this, pam_u2f defaults both to pam://<hostname>, so a key enrolled on
      # one host (the credential is cryptographically bound to the appid) will
      # not authenticate on another and login silently falls back to password.
      # With a shared value the same enrollment works on every host and adding
      # a new host needs no re-enroll. Changing this REQUIRES re-enrolling each
      # key with the matching origin/appid.
      origin = "pam://yubikey";
      appid = "pam://yubikey";
    };
  };

  security.pam.services = {
    login.u2fAuth = true;
    sudo.u2fAuth = true;
    su.u2fAuth = true;
    sddm.u2fAuth = true;
    greetd.u2fAuth = true;
  };

  environment.etc."u2f_keys".source = config.homelab.yubikey.u2fKeysFile;

  # Ensure the pam_u2f package is available for the pamu2fcfg CLI tool
  environment.systemPackages = [ pkgs.pam_u2f ];
}
