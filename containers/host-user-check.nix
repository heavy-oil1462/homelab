# Run before a container starts that runs as a host user by number
# (user = "<uid>:<gid>") and shares files with the host by that user's name:
# secrets a tmpfiles rule or another unit makes for it, a socket's group, a
# certificate's group. The module declares the user with a static id, but
# NixOS keeps the id of a user that already exists on the host, so on such a
# host the container's number and the host's name could differ and the
# container would lose access to those files without saying why. The check
# fails the start instead and names the setting that fixes it
# (docs/adr/0014-containers-run-unprivileged.md).
{ writeShellApplication, coreutils, getent }:

writeShellApplication {
  name = "host-user-check";
  runtimeInputs = [ coreutils getent ];
  text = ''
    # host-user-check <user> <uid> <gid>; the group has the user's name.
    name=$1 want_uid=$2 want_gid=$3
    uid=$(id -u "$name")
    gid=$(getent group "$name" | cut -d: -f3)
    if [ "$uid" != "$want_uid" ] || [ "$gid" != "$want_gid" ]; then
      echo "The container runs as $want_uid:$want_gid, but on this host user $name has uid $uid and group $name gid $gid. NixOS keeps the ids of a user that already exists; set users.users.$name.uid = $uid and users.groups.$name.gid = $gid in the host's config." >&2
      exit 1
    fi
  '';
}
