#!/bin/bash
set -euo pipefail

runtime_uid="${HOST_UID:-1000}"
runtime_gid="${HOST_GID:-1000}"
runtime_home="${HOST_HOME:-}"

case "$runtime_uid:$runtime_gid" in
  *[!0-9:]*|:*|*:)
    echo "Error: HOST_UID and HOST_GID must be numeric." >&2
    exit 64
    ;;
esac
[ "$runtime_uid" -gt 0 ] && [ "$runtime_gid" -gt 0 ] || {
  echo "Error: refusing to run an Agent CLI as numeric root." >&2
  exit 64
}

case "$runtime_home" in
  /*) ;;
  *)
    echo "Error: HOST_HOME must be an absolute path." >&2
    exit 64
    ;;
esac
case "$runtime_home" in
  /|*:*|*$'\n'*|*$'\r'*)
    echo "Error: HOST_HOME is unsafe for a passwd entry: $runtime_home" >&2
    exit 64
    ;;
esac
[ -d "$runtime_home" ] || {
  echo "Error: isolated Agent HOME is not mounted: $runtime_home" >&2
  exit 66
}

# Add or safely adapt a passwd entry without recursively changing ownership.
# Bind mounts retain macOS numeric ownership under VirtioFS. If the base image
# already has the host UID, getpwuid consumers must still see the isolated
# shadow HOME.
if ! getent group "$runtime_gid" >/dev/null 2>&1; then
  printf 'agent-host:x:%s:\n' "$runtime_gid" >> /etc/group
fi
passwd_record_count=$(awk -F: -v wanted_uid="$runtime_uid" \
  '$3 == wanted_uid { count += 1 } END { print count + 0 }' /etc/passwd)
case "$passwd_record_count" in
  0)
  printf 'agent-host:x:%s:%s:Agent CLI:%s:/bin/bash\n' \
    "$runtime_uid" "$runtime_gid" "$runtime_home" >> /etc/passwd
    ;;
  1)
    passwd_tmp=$(mktemp /etc/.passwd.agent-container.XXXXXX)
    while IFS=: read -r \
      passwd_name passwd_secret passwd_uid passwd_gid \
      passwd_gecos passwd_home passwd_shell; do
      if [ "$passwd_uid" = "$runtime_uid" ]; then
        printf '%s:%s:%s:%s:%s:%s:%s\n' \
          "$passwd_name" \
          "$passwd_secret" \
          "$runtime_uid" \
          "$runtime_gid" \
          "$passwd_gecos" \
          "$runtime_home" \
          "${passwd_shell:-/bin/bash}"
      else
        printf '%s:%s:%s:%s:%s:%s:%s\n' \
          "$passwd_name" \
          "$passwd_secret" \
          "$passwd_uid" \
          "$passwd_gid" \
          "$passwd_gecos" \
          "$passwd_home" \
          "$passwd_shell"
      fi
    done < /etc/passwd > "$passwd_tmp"
    chmod 0644 "$passwd_tmp"
    mv -f "$passwd_tmp" /etc/passwd
    ;;
  *)
    echo "Error: base image contains duplicate passwd records for UID $runtime_uid." >&2
    exit 65
    ;;
esac

runtime_passwd_record=$(getent passwd "$runtime_uid" | head -n 1)
runtime_user=$(printf '%s\n' "$runtime_passwd_record" | cut -d: -f1)
runtime_passwd_gid=$(printf '%s\n' "$runtime_passwd_record" | cut -d: -f4)
runtime_passwd_home=$(printf '%s\n' "$runtime_passwd_record" | cut -d: -f6)
[ "$runtime_passwd_gid" = "$runtime_gid" ] \
  && [ "$runtime_passwd_home" = "$runtime_home" ] \
  || {
    echo "Error: failed to publish the host UID/GID and isolated HOME in /etc/passwd." >&2
    exit 65
  }

exec setpriv \
  --reuid="$runtime_uid" \
  --regid="$runtime_gid" \
  --clear-groups \
  --no-new-privs \
  env \
    HOME="$runtime_home" \
    USER="$runtime_user" \
    LOGNAME="$runtime_user" \
    SHELL=/bin/bash \
    "$@"
