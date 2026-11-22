# The example workstation's YubiKey prompts follow
# docs/adr/0025-yubikey-prompts-once-per-session.md:
#
# - pam_u2f asks for the PIN at login, greetd and hyprlock (pinverification=1
#   in their stack, or in the login stack they include), and not for sudo
#   (pinverification=0, userpresence=1);
# - sudo keeps its timestamp for 15 minutes;
# - yubikey-agent is gone, and nothing sets SSH_AUTH_SOCK;
# - ssh_config, read by ssh -G, shares one connection per listed host for
#   the owner's user, socket in /run/user/<uid>, persisting 4 hours, and
#   shares nothing for a host not listed or for another user.
#
# The PAM files and ssh_config are the texts NixOS writes to /etc, with
# their string context dropped so the check builds none of the modules
# they name. It cannot touch a key: that is tested by hand.
{ lib, runCommand, openssh, config }:

let
  text = builtins.unsafeDiscardStringContext;
  pam = name: text config.security.pam.services.${name}.text;
  services = [ "login" "greetd" ] ++ lib.optional (config.security.pam.services ? hyprlock) "hyprlock";
  u2fLines = name: lib.filter (l: lib.hasInfix "pam_u2f.so" l) (lib.splitString "\n" (pam name));
  includesLogin = name: builtins.match ".*auth (substack|include) login.*" (pam name) != null;
  hasArg = arg: name: lib.any (l: lib.elem arg (lib.splitString " " l)) (u2fLines name);

  problems =
    lib.concatMap
      (name:
        lib.optional (!(hasArg "pinverification=1" name) && !(name != "login" && includesLogin name))
          "${name}: pam_u2f without pinverification=1, and no login stack included")
      services
    ++ lib.optional (u2fLines "sudo" == [ ]) "sudo: no pam_u2f"
    ++ lib.optional (!hasArg "pinverification=0" "sudo") "sudo: pam_u2f without pinverification=0"
    ++ lib.optional (hasArg "pinverification=1" "sudo") "sudo: pam_u2f with pinverification=1"
    ++ lib.optional (!hasArg "userpresence=1" "sudo") "sudo: pam_u2f without userpresence=1"
    ++ lib.optional (!lib.hasInfix "Defaults timestamp_timeout=15" (text config.security.sudo.configFile))
      "sudoers: no timestamp_timeout=15"
    ++ lib.optional config.services.yubikey-agent.enable "yubikey-agent is enabled"
    ++ lib.optional (lib.hasInfix "SSH_AUTH_SOCK" (text config.environment.extraInit))
      "environment.extraInit sets SSH_AUTH_SOCK"
    ++ lib.optional (config.homelab.workstation.sshSharedHosts == [ ])
      "homelab.workstation.sshSharedHosts is empty; the check needs a host";

  sshConfig = text config.environment.etc."ssh/ssh_config".text;
  owner = config.homelab.username;
  shared = builtins.head config.homelab.workstation.sshSharedHosts;
in
if problems != [ ] then
  throw "The example workstation's YubiKey prompts break docs/adr/0025-yubikey-prompts-once-per-session.md:\n${lib.concatStringsSep "\n" problems}"
else
  runCommand "yubikey-prompts"
    {
      nativeBuildInputs = [ openssh ];
      inherit sshConfig owner shared;
      passAsFile = [ "sshConfig" ];
    } ''
    fail() { echo "ssh_config: $*" >&2; exit 1; }
    me=$(id -un)
    uid=$(id -u)

    # The build user stands in for the owner, and nobody for another user.
    sed "s/localuser $owner\$/localuser $me/" "$sshConfigPath" > as-owner
    sed "s/localuser $owner\$/localuser nobody/" "$sshConfigPath" > as-other
    grep -q "localuser $me\$" as-owner || fail "no Match for localuser $owner"

    ssh -G -F as-owner "$shared" > shared
    grep -qx 'controlmaster auto' shared || fail "$shared: ControlMaster is not auto"
    grep -qx 'controlpersist 14400' shared || fail "$shared: ControlPersist is not 4h"
    grep -Eqx "controlpath /run/user/$uid/ssh-[0-9a-f]+" shared \
      || fail "$shared: ControlPath is not in /run/user/<uid>: $(grep controlpath shared)"

    ssh -G -F as-owner unlisted.example.com > unlisted
    grep -qx 'controlmaster false' unlisted || fail "a host not listed shares its connection"
    ssh -G -F as-other "$shared" > other
    grep -qx 'controlmaster false' other || fail "another user shares the connection to $shared"

    touch "$out"
  ''
