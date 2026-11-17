# Every container of the example hosts runs as a host user that is not root,
# or is on the allowlist below, and every one runs with no-new-privileges and
# with all capabilities dropped, adding back only what it names
# (docs/adr/0014-containers-run-unprivileged.md). The example server enables
# every container module, so a new module, or a changed one, is held to it
# here. Pure evaluation: the check fails with the containers that break the
# rule and builds nothing.
{ lib, writeText, hosts }:

let
  # Containers that run as root. Each needs a reason in its module, next to
  # its capabilities, and is removed from here once it can run as a user.
  rootAllowed = [
    # Home Assistant's image runs as root under s6-overlay, with host
    # networking for the LAN's devices; it supports nothing else.
    "home-assistant"
    # Frigate's image runs as root under s6-overlay, with nginx and go2rtc;
    # it supports nothing else.
    "frigate"
    # The Nextcloud AIO mastercontainer only runs as root, and holds podman's
    # socket, which is root on the host anyway.
    "nextcloud-aio-mastercontainer"
    # The linuxserver UniFi image starts as root and drops to the unifi
    # user (PUID/PGID) for the controller itself.
    "unifi"
  ];

  # "<uid>:<gid>", both numbers and neither 0, and the uid a declared user's.
  # A name would be looked up in the image's /etc/passwd, not the host's.
  userProblem = config: c:
    let
      m = builtins.match "([0-9]+):([0-9]+)" (toString c.user);
      uid = lib.toInt (builtins.elemAt m 0);
      gid = lib.toInt (builtins.elemAt m 1);
      uids = lib.mapAttrsToList (_: u: u.uid) config.users.users;
    in
    if c.user == null then "runs as the image's user, root unless it says otherwise; set user = \"<uid>:<gid>\" or add it to the allowlist"
    else if m == null then "user is \"${c.user}\", not \"<uid>:<gid>\""
    else if uid == 0 || gid == 0 then "runs as root (${c.user})"
    else if !(builtins.elem uid uids) then "uid ${toString uid} is no declared user's"
    else null;

  hardeningProblems = c:
    let opts = c.extraOptions; in
    lib.optional (!(builtins.elem "--security-opt=no-new-privileges" opts))
      "lacks --security-opt=no-new-privileges"
    ++ lib.optional (!(builtins.elem "--cap-drop=ALL" opts || (c.capabilities.ALL or null) == false))
      "lacks --cap-drop=ALL"
    ++ lib.optional (c.privileged or false) "is privileged"
    ++ lib.optional (builtins.any (o: lib.hasPrefix "--privileged" o || lib.hasPrefix "--cap-add=ALL" o) opts)
      "adds every capability back";

  problems = lib.concatLists (lib.mapAttrsToList (host: config:
    let containers = config.virtualisation.oci-containers.containers; in
    lib.concatLists (lib.mapAttrsToList (name: c:
      map (p: "${host}: ${name} ${p}") (
        lib.optional (!(builtins.elem name rootAllowed) && userProblem config c != null)
          (userProblem config c)
        ++ hardeningProblems c)
    ) containers)
    # An allowlist entry no example runs would hide nothing, but it would no
    # longer say anything true either.
    ++ map (name: "${host}: ${name} is on the root allowlist but not a container")
      (lib.filter (name: !(containers ? ${name})) rootAllowed)
  ) hosts);
in
if problems == [ ] then
  writeText "container-hardening" (lib.concatStringsSep "\n" (lib.attrNames hosts) + "\n")
else
  throw "Containers that break docs/adr/0014-containers-run-unprivileged.md:\n${lib.concatStringsSep "\n" problems}"
