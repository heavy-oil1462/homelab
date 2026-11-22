{ config, lib, pkgs, ... }:

# YubiKey login: pam_u2f with PIN and touch at login and screen lock, touch
# only for sudo (docs/adr/0025-yubikey-prompts-once-per-session.md). SSH uses
# the key's FIDO2 sk keys directly; there is no agent.
{
  imports = [ ./options.nix ];

  services = {
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
    # sudo takes a touch without the PIN; the session behind it was opened
    # with both. pinverification=0 turns the PIN off only if the key was
    # enrolled without -N: a "+pin" credential in u2f_keys asks for it
    # anyway. userpresence=1 keeps the touch whatever the key's default.
    sudo.rules.auth.u2f.settings = {
      pinverification = lib.mkForce 0;
      userpresence = 1;
    };
  };

  # A burst of sudo in one terminal is one touch.
  security.sudo.extraConfig = ''
    Defaults timestamp_timeout=15
  '';

  environment.etc."u2f_keys".source = config.homelab.yubikey.u2fKeysFile;

  # Ensure the pam_u2f package is available for the pamu2fcfg CLI tool
  environment.systemPackages = [ pkgs.pam_u2f ];
}
