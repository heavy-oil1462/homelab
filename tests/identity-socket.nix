# The caddy container can connect to nginx-auth's socket, on a fresh boot and
# after a switch (docs/adr/0003-tailscale-identity-for-sign-in.md,
# docs/adr/0014-containers-run-unprivileged.md). Pure evaluation of each
# host's config, which must have homelab.reverseProxy.tailscaleIdentity on:
#
# - the socket's group is the group the container runs as, by id, and its
#   mode gives that group read and write;
# - the directory systemd makes for it lets anyone through, and the caddy
#   container mounts it;
# - nginx-auth's service has the socket's settings as a restart trigger, so a
#   switch that changes them makes a new socket rather than keeping the old
#   one with its old group.
#
# It cannot connect for real: that needs a VM, and the flake has none. The
# README's "Containers run unprivileged" says how to check a host by hand.
{ lib, writeText, hosts }:

let
  # Whether an octal mode string grants `bit` (4 read, 2 write, 1 execute)
  # to the class at `digit` from the right (0 others, 1 group, 2 user).
  grants = mode: digit: bit:
    let
      digits = lib.stringToCharacters mode;
      d = lib.toInt (builtins.elemAt digits (builtins.length digits - 1 - digit));
    in
    lib.mod (d / bit) 2 == 1;

  hostProblems = host: config:
    let
      socket = config.systemd.sockets.tailscale-nginx-auth;
      sc = socket.socketConfig;
      path = config.services.tailscaleAuth.socketPath;
      dir = builtins.dirOf path;
      caddy = config.virtualisation.oci-containers.containers.caddy;
      m = builtins.match "([0-9]+):([0-9]+)" (toString caddy.user);
      gid = lib.toInt (builtins.elemAt m 1);
      # systemd's default when the unit sets none.
      dirMode = sc.DirectoryMode or "0755";
      groupGid = (config.users.groups.${sc.SocketGroup} or { gid = null; }).gid;
      trigger = builtins.toJSON { inherit (socket) listenStreams socketConfig; };
    in
    map (p: "${host}: ${p}") (
      lib.optional (!config.homelab.reverseProxy.tailscaleIdentity.enable)
        "homelab.reverseProxy.tailscaleIdentity is off; the check needs a host with it on"
      ++ lib.optional (m == null) "caddy runs as \"${toString caddy.user}\", not \"<uid>:<gid>\""
      ++ lib.optional (m != null && groupGid != gid)
        "the socket's group ${sc.SocketGroup} has gid ${toString groupGid}, caddy runs as gid ${toString gid}"
      ++ lib.optional (!(grants sc.SocketMode 1 4 && grants sc.SocketMode 1 2))
        "socket mode ${sc.SocketMode} does not let its group read and write"
      ++ lib.optional (!(grants dirMode 0 1))
        "directory mode ${dirMode} does not let caddy through ${dir}"
      ++ lib.optional (!(builtins.elem path socket.listenStreams))
        "the socket does not listen on ${path}"
      ++ lib.optional (!(builtins.elem "${dir}:${dir}" caddy.volumes))
        "the caddy container does not mount ${dir}"
      ++ lib.optional (!(builtins.elem trigger config.systemd.services.tailscale-nginx-auth.restartTriggers))
        "tailscale-nginx-auth.service lacks the socket's settings as a restart trigger, so a switch keeps the old socket"
    );

  problems = lib.concatLists (lib.mapAttrsToList hostProblems hosts);
in
if problems == [ ] then
  writeText "identity-socket" (lib.concatStringsSep "\n" (lib.attrNames hosts) + "\n")
else
  throw "Caddy cannot reach nginx-auth's socket:\n${lib.concatStringsSep "\n" problems}"
