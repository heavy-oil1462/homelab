# Creates Forgejo's first admin inside the forgejo container, once.
#
#   forgejo-admin <name> <email> <sign in URL>
#
# Waits until Forgejo answers its health endpoint, then lists the admins. If
# there is none, it creates <name> with a random password that must be
# changed at first sign in, and prints one line with the name, the password
# and the sign in URL. That line, on stdout and so in the unit's journal, is
# the only place the password goes. If an admin exists it changes nothing.
#
# FORGEJO_ADMIN_TRIES (60) and FORGEJO_ADMIN_WAIT (5 seconds) set how long
# it waits for Forgejo.

if [ "$#" -ne 3 ]; then
  echo "usage: forgejo-admin <name> <email> <sign in URL>" >&2
  exit 2
fi
name=$1
email=$2
login_url=$3
tries=${FORGEJO_ADMIN_TRIES:-60}
delay=${FORGEJO_ADMIN_WAIT:-5}

# The rootless image is Alpine, whose busybox has wget; HTTP is not
# published on the host, so ask from inside the container.
try=1
until podman exec forgejo wget -q -O /dev/null http://127.0.0.1:3000/api/healthz >/dev/null 2>&1; do
  if [ "$try" -ge "$tries" ]; then
    echo "Forgejo did not answer on http://127.0.0.1:3000/api/healthz in the forgejo container after $tries tries; no admin created." >&2
    exit 1
  fi
  try=$((try + 1))
  sleep "$delay"
done

# Forgejo's own messages on stderr go to the journal as they are.
if ! admins=$(podman exec forgejo forgejo admin user list --admin); then
  echo "Listing Forgejo's admins failed; no admin created." >&2
  exit 1
fi

# The list is a header line and one line per admin.
count=$(printf '%s\n' "$admins" | tail -n +2 | grep -c . || true)
if [ "$count" -gt 0 ]; then
  echo "Forgejo already has an admin; nothing to do."
  exit 0
fi

# --random-password prints the password; keep the output to this script so
# it reaches the journal only in the line below.
if ! out=$(podman exec forgejo forgejo admin user create --admin \
  --username "$name" --email "$email" \
  --random-password --must-change-password 2>&1); then
  echo "Creating the Forgejo admin $name failed:" >&2
  printf '%s\n' "$out" | grep -iv password >&2 || true
  exit 1
fi

password=$(printf '%s\n' "$out" | sed -n "s/^generated random password is '\(.*\)'$/\1/p")
if [ -z "$password" ]; then
  echo "Created the Forgejo admin $name, but found no password in Forgejo's output; set one with forgejo admin user change-password." >&2
  exit 1
fi

echo "Forgejo admin $name created with one-time password $password. Sign in at $login_url; Forgejo asks for a new password at first sign in, after which a passkey can be added."
