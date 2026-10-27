#!/bin/bash
set -euo pipefail

# Exercises the full-host-access mirror logic of runtime/agent-workspace-session
# on Linux. The functions between the "host mirror functions begin/end"
# sentinels are extracted verbatim and run inside a private mount namespace
# against a scratch tree that stands in for the SSHFS mount of the host root
# and for the guest root (through the helper's host_mirror_guest_root seam).
#
# The helper itself only ever runs inside the Linux guest, so where unshare,
# bind mounts, or root are unavailable (macOS CI) this reports one TAP skip.

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
session_script="$repo_root/runtime/agent-workspace-session"

tests_passed=0
fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}
pass() {
  tests_passed=$((tests_passed + 1))
  printf 'ok %s - %s\n' "$tests_passed" "$*"
}
skip() {
  printf 'ok 1 - host mirror merge, cleanup, and start-cwd selection # SKIP %s\n' "$*"
  printf '1..1\n'
  exit 0
}

[ -f "$session_script" ] || fail 'agent-workspace-session is missing'
[ "$(uname -s)" = Linux ] || skip 'requires the Linux guest'
[ "$(id -u)" -eq 0 ] || skip 'requires root for bind mounts'
command -v unshare >/dev/null 2>&1 || skip 'requires unshare'
# The helper addresses its tools by the absolute paths the guest image has.
for required in mount umount mountpoint realpath mkdir chown ls rmdir; do
  [ -x "/usr/bin/$required" ] || skip "requires /usr/bin/$required"
done
unshare --mount --propagation private -- true 2>/dev/null \
  || skip 'requires a private mount namespace'

test_root=$(mktemp -d "${TMPDIR:-/tmp}/agent-container-host-mirrors.XXXXXX")
cleanup() {
  local status=$?
  trap - EXIT
  # Every mount made below lived in a private namespace that is gone now; only
  # the scratch directories remain.
  rm -rf -- "$test_root"
  exit "$status"
}
trap cleanup EXIT

functions_file="$test_root/mirror-functions.sh"
sed -n '/^# --- host mirror functions begin ---$/,/^# --- host mirror functions end ---$/p' \
  "$session_script" > "$functions_file"
for symbol in add_host_mirror create_host_mirrors remove_host_mirrors select_agent_start_cwd; do
  grep -Fq "$symbol() {" "$functions_file" \
    || fail "the sentinel region does not define $symbol"
done
pass 'the mirror functions are delimited by sentinels and extract verbatim'

cat > "$test_root/scenario.sh" <<'EOF'
set -euo pipefail
scratch=$1
functions=$2
host="$scratch/host"
guest="$scratch/guest"
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
warn() { printf '%s\n' "$*" >&2; }
is_mountpoint() { mountpoint -q -- "$1"; }

# The helper's globals the functions rely on.
runtime_uid=$(id -u)
runtime_gid=$(id -g)
workspace_root="$host"
host_full_access=true
host_mirror_spec=""
host_mirror_mounts=()
host_mirror_dirs=()
agent_start_cwd=
# shellcheck disable=SC1090
. "$functions"
host_mirror_guest_root="$guest"

# --- host side (what SSHFS shows under /host) ---
mkdir -p \
  "$host/Users/alice/project/src" \
  "$host/Users/alice/Documents" \
  "$host/Users/alice/.ssh" \
  "$host/Users/Shared" \
  "$host/Applications/Foo.app" \
  "$host/Volumes/SDK Files/platform-tools" \
  "$host/private/tmp" \
  "$host/opt/homebrew/bin" \
  "$host/usr/local/bin"
echo real-project > "$host/Users/alice/project/README"
echo host-private-key > "$host/Users/alice/.ssh/id_ed25519"
echo shared > "$host/Users/Shared/note"
echo loose > "$host/Users/alice/notes.txt"
ln -s "$scratch" "$host/Volumes/escape"

# --- guest side ---
# /Users/alice is the profile's shadow HOME: a separate mount carrying the
# Agent's persistent Linux state. It already has a non-empty Documents.
mkdir -p "$guest/Users/alice" "$guest/opt/image-provided" "$scratch/shadow-home/.claude" \
  "$scratch/shadow-home/Documents"
echo linux-state > "$scratch/shadow-home/.claude/state"
echo guest-doc > "$scratch/shadow-home/Documents/guestfile"
mount --bind "$scratch/shadow-home" "$guest/Users/alice"
echo image-file > "$guest/opt/image-provided/tool"
# A pre-existing EMPTY directory must be covered, and covering it must leave
# add_host_mirror's status at 0 (this script runs under set -e).
mkdir "$guest/Applications"

workspace_cwd="$host/Users/alice/project"
# Explicit entries that an automatic mirror already covers ("SDK Files" and
# /private/tmp) must not nest redundant binds, a protected tree is refused, a
# non-empty guest tree is descended into, and malformed entries are ignored.
host_mirror_spec="/Volumes/SDK Files,/private/tmp,/usr/local,/opt/homebrew,relative,/Volumes/escape"
create_host_mirrors
mounts_after_first=${#host_mirror_mounts[@]}
# A repeated call is a no-op: everything is already covered.
create_host_mirrors
[ "${#host_mirror_mounts[@]}" -eq "$mounts_after_first" ] \
  || fail "a repeated create_host_mirrors added mirrors ($mounts_after_first -> ${#host_mirror_mounts[@]})"
select_agent_start_cwd

# Merge into the shadow HOME.
[ "$(cat "$guest/Users/alice/project/README")" = real-project ] \
  || fail 'the project was not merged into the shadow HOME'
is_mountpoint "$guest/Users/alice/project" || fail 'the project mirror is not a mount'
[ ! -e "$guest/Users/alice/.ssh" ] || fail 'a host dotfile directory was mirrored into the shadow HOME'
[ "$(cat "$guest/Users/alice/.claude/state")" = linux-state ] \
  || fail 'the shadow HOME state was disturbed'
[ ! -e "$guest/Users/alice/notes.txt" ] || fail 'a loose home file was mirrored'
[ "$(cat "$guest/Users/Shared/note")" = shared ] || fail '/Users/Shared was not mirrored'
is_mountpoint "$guest/Users/alice" || fail 'the shadow HOME mount itself was replaced'
# The depth bound: Documents collides at depth 2 and is left alone.
[ "$(cat "$guest/Users/alice/Documents/guestfile")" = guest-doc ] \
  || fail 'a non-empty directory at the depth bound was covered'
is_mountpoint "$guest/Users/alice/Documents" && fail 'the depth bound was exceeded'
echo "MERGE_OK"

# Empty pre-existing target, created targets, spaces, explicit list, refusals.
[ -d "$guest/Applications/Foo.app" ] || fail 'an empty existing directory was not covered'
[ -d "$guest/Volumes/SDK Files/platform-tools" ] || fail 'a path with a space was not mirrored'
[ -d "$guest/private/tmp" ] || fail 'an explicit path was not mirrored'
[ ! -e "$guest/usr" ] || fail 'a protected guest tree was mirrored'
[ ! -e "$guest/relative" ] || fail 'a relative entry was mirrored'
# A symlink inside a mirrored tree is carried as the symlink it is on the host;
# it must never become a mirror root of its own (which would bind its target).
[ -L "$guest/Volumes/escape" ] || fail 'host symlink content was not preserved as a symlink'
is_mountpoint "$guest/Volumes/escape" && fail 'a symlink was used as a mirror root'
[ "$(cat "$guest/opt/image-provided/tool")" = image-file ] \
  || fail 'a non-empty image tree was covered'
[ -d "$guest/opt/homebrew/bin" ] || fail 'the merge did not descend into a non-empty guest tree'
for mounted in "${host_mirror_mounts[@]}"; do
  is_mountpoint "$mounted" || fail "recorded mirror is not mounted: $mounted"
done
echo "MOUNTS=${#host_mirror_mounts[@]}"
echo "DIRS=${#host_mirror_dirs[@]}"

# Start-cwd selection prefers the mirrored real path.
[ "$agent_start_cwd" = "$guest/Users/alice/project" ] \
  || fail "start cwd was $agent_start_cwd"
workspace_cwd="$host/usr/local/bin"
select_agent_start_cwd
[ "$agent_start_cwd" = "$host/usr/local/bin" ] \
  || fail 'an unmirrored cwd did not fall back to the /host form'
workspace_cwd="$host/Users/alice/project"
host_full_access=false
select_agent_start_cwd
[ "$agent_start_cwd" = "$workspace_cwd" ] || fail 'sandboxed mode changed the cwd'
host_full_access=true
echo "CWD_OK"

# Reverse unwind: every mirror gone, only created placeholders removed, the
# shadow HOME and the pre-existing empty directory untouched.
remove_host_mirrors
[ "${#host_mirror_mounts[@]}" -eq 0 ] && [ "${#host_mirror_dirs[@]}" -eq 0 ] \
  || fail 'the mirror stacks were not cleared'
for leftover in "$guest/Users/alice/project" "$guest/Users/Shared" "$guest/Volumes" \
  "$guest/private" "$guest/opt/homebrew"; do
  [ ! -e "$leftover" ] || fail "created mirror point was left behind: $leftover"
done
[ -d "$guest/Applications" ] && [ -z "$(ls -A "$guest/Applications")" ] \
  || fail 'the pre-existing empty directory was removed or still covered'
is_mountpoint "$guest/Users/alice" || fail 'cleanup unmounted the shadow HOME'
[ "$(cat "$guest/Users/alice/.claude/state")" = linux-state ] \
  || fail 'cleanup disturbed the shadow HOME state'
[ "$(cat "$guest/opt/image-provided/tool")" = image-file ] || fail 'cleanup disturbed /opt'
umount "$guest/Users/alice"
echo "CLEANUP_OK"
EOF

scenario_output=$(unshare --mount --propagation private -- \
  bash "$test_root/scenario.sh" "$test_root" "$functions_file" 2>&1) \
  || fail "the mirror scenario failed:
$scenario_output"
case "$scenario_output" in
  *MERGE_OK*) ;;
  *) fail "merge assertions did not complete:
$scenario_output" ;;
esac
pass 'host home directories merge into the shadow HOME without touching dotfiles, bounded by depth'
mount_count=$(printf '%s\n' "$scenario_output" | sed -n 's/^MOUNTS=//p')
dir_count=$(printf '%s\n' "$scenario_output" | sed -n 's/^DIRS=//p')
# Mirrors: /Users/alice/project and /Users/Shared (merged into the shadow
# HOME), /Volumes, /Applications (pre-existing empty, so no placeholder),
# /private, and /opt/homebrew (descended into the non-empty image /opt). The
# explicit "SDK Files" and /private/tmp are already covered by /Volumes and
# /private and add nothing. The exact counts are asserted so an accidental
# extra or missing mirror is noticed.
[ "$mount_count" = 6 ] || fail "expected 6 mirrors, recorded $mount_count:
$scenario_output"
[ "$dir_count" = 5 ] || fail "expected 5 created placeholders, recorded $dir_count:
$scenario_output"
pass 'empty targets are covered, paths with spaces work, and protected or escaping paths are refused'
case "$scenario_output" in
  *CWD_OK*) ;;
  *) fail "start-cwd assertions did not complete:
$scenario_output" ;;
esac
pass 'the Agent starts in the mirrored real host path and falls back to /host otherwise'
case "$scenario_output" in
  *CLEANUP_OK*) ;;
  *) fail "cleanup assertions did not complete:
$scenario_output" ;;
esac
pass 'cleanup unwinds every mirror in reverse and removes only its own placeholders'

printf '1..%s\n' "$tests_passed"
