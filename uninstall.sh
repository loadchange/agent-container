#!/bin/bash
set -euo pipefail

readonly INSTALL_MARKER_TEXT="managed by agent-container installer v1"
readonly STATE_MARKER_TEXT="managed by agent-container"

COMMANDS=(
  agent-container
  claude-container
  codex-container
  grok-container
)

die() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--purge] [--container-bin PATH]

Remove the shared launcher and whichever profile commands were installed.

Options:
  --purge               Also remove all per-profile credentials and state.
  --container-bin PATH  Use this Apple container CLI instead of "container".
  -h, --help            Show this help.

Examples:
  ./uninstall.sh
  ./uninstall.sh --purge
  ./uninstall.sh --container-bin /usr/local/bin/container --purge

Without --purge, all per-profile credentials and state are preserved.
EOF
}

usage_die() {
  echo "Error: $*" >&2
  echo "Try 'uninstall.sh --help' for usage." >&2
  exit 64
}

[ -z "${AGENT_CONTAINER_BIN+x}" ] \
  || usage_die "AGENT_CONTAINER_BIN is no longer supported; use --container-bin PATH."
[ -z "${AGENT_CONTAINER_STATE_DIR+x}" ] \
  || usage_die "AGENT_CONTAINER_STATE_DIR is unsupported; unset it. Agent state always uses HOME/.agent-container."

purge=false
purge_seen=false
container_bin=container
container_bin_seen=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --purge)
      [ "$purge_seen" = false ] \
        || usage_die "--purge may only be specified once."
      purge=true
      purge_seen=true
      shift
      ;;
    --container-bin)
      [ "$container_bin_seen" = false ] \
        || usage_die "--container-bin may only be specified once."
      [ "$#" -ge 2 ] \
        || usage_die "--container-bin requires a path."
      case "$2" in
        ''|-*) usage_die "--container-bin requires a path." ;;
        *$'\n'*|*$'\r'*|*$'\t'*)
          usage_die "--container-bin contains unsupported control characters."
          ;;
      esac
      container_bin="$2"
      container_bin_seen=true
      shift 2
      ;;
    --container-bin=*)
      [ "$container_bin_seen" = false ] \
        || usage_die "--container-bin may only be specified once."
      container_bin=${1#--container-bin=}
      [ -n "$container_bin" ] \
        || usage_die "--container-bin requires a path."
      case "$container_bin" in
        -*) usage_die "--container-bin requires a path." ;;
        *$'\n'*|*$'\r'*|*$'\t'*)
          usage_die "--container-bin contains unsupported control characters."
          ;;
      esac
      container_bin_seen=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      usage_die "Positional arguments are not supported."
      ;;
    -*|*)
      usage_die "Unknown argument '$1'."
      ;;
  esac
done
readonly container_bin

preflight_die() {
  die "$*; uninstall made no changes."
}

warn() {
  echo "Warning: $*" >&2
}

ignore_signals() {
  trap '' INT TERM HUP
}

restore_signal_traps() {
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

path_is_within() {
  local parent="$1"
  local child="$2"
  case "$child/" in
    "$parent/"*) return 0 ;;
    *) return 1 ;;
  esac
}

physical_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

canonical_safe_lookup_dir() {
  local requested="$1"
  local resolved
  case "$requested" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -d "$requested" ] || return 1
  resolved=$(physical_dir "$requested") || return 1
  [ "$resolved" != "$home_dir" ] || return 1
  path_is_within "$home_dir" "$resolved" || return 1
  printf '%s\n' "$resolved"
}

# Recursive roots are never accepted as final symlinks. This matches the
# launcher and prevents a last-component swap from expanding purge scope.
canonical_safe_root() {
  [ ! -L "$1" ] || return 1
  canonical_safe_lookup_dir "$1"
}

marker_matches() {
  local marker="$1"
  local expected="$2"
  [ -f "$marker" ] \
    && [ ! -L "$marker" ] \
    && cmp -s "$marker" <(printf '%s\n' "$expected")
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 127
  fi
}

read_single_line() {
  local file="$1"
  local value
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  IFS= read -r value < "$file" || return 1
  [ -n "$value" ] || return 1
  # Comparing the complete byte stream rejects a second record, trailing bytes
  # without a newline, a missing final newline, and embedded NUL data.
  cmp -s "$file" <(printf '%s\n' "$value") || return 1
  printf '%s\n' "$value"
}

valid_lock_owner() {
  [ -n "$1" ] && [ "${#1}" -le 128 ] || return 1
  case "$1" in
    *[!A-Za-z0-9._:-]*) return 1 ;;
    *) return 0 ;;
  esac
}

lock_directory_has_only() {
  local lock_root="$1"
  local allowed_names="$2"
  local lock_entry lock_name

  for lock_entry in \
    "$lock_root"/* \
    "$lock_root"/.[!.]* \
    "$lock_root"/..?*; do
    [ -e "$lock_entry" ] || [ -L "$lock_entry" ] || continue
    lock_name=${lock_entry##*/}
    case " $allowed_names " in
      *" $lock_name "*) ;;
      *) return 1 ;;
    esac
  done
}

release_install_directory_lock() {
  local current_pid current_owner
  if [ "$lock_acquired" = true ] \
    && [ -n "${install_lock:-}" ] \
    && [ -d "$install_lock" ] \
    && [ ! -L "$install_lock" ]; then
    current_pid=$(read_single_line "$install_lock/pid" || true)
    current_owner=$(read_single_line "$install_lock/owner" || true)
    if [ "$current_pid" = "$$" ] \
      && [ -n "${install_lock_owner:-}" ] \
      && [ "$current_owner" = "$install_lock_owner" ] \
      && lock_directory_has_only "$install_lock" "pid owner"; then
      rm -f -- "$install_lock/pid" "$install_lock/owner"
      rmdir -- "$install_lock" 2>/dev/null || true
    fi
  fi
  lock_acquired=false
}

release_install_kernel_lock() {
  if [ "${install_kernel_lock_acquired:-false}" = true ]; then
    exec 9<&-
    install_kernel_lock_acquired=false
  fi
}

release_install_lock() {
  release_install_directory_lock
  release_install_kernel_lock
}

acquire_install_kernel_lock() {
  [ "${install_kernel_lock_acquired:-false}" = false ] || return 0
  [ -x /usr/bin/lockf ] \
    || die "macOS /usr/bin/lockf is required for installer serialization."
  exec 9< "$home_dir" \
    || die "Unable to open HOME for installer locking."
  if ! /usr/bin/lockf -t 0 9 2>/dev/null; then
    exec 9<&-
    die "Another agent-container transaction is running."
  fi
  install_kernel_lock_acquired=true
}

acquire_install_lock() {
  local existing_pid existing_owner existing_owner_present
  local reap_dir reap_pid reap_owner quarantine retry

  install_lock_owner="$$.$RANDOM.$RANDOM"
  valid_lock_owner "$install_lock_owner" \
    || die "Unable to generate a safe installer lock owner token."
  acquire_install_kernel_lock
  retry=0
  while ! mkdir -- "$install_lock" 2>/dev/null; do
    retry=$((retry + 1))
    [ "$retry" -le 20 ] \
      || die "Could not acquire the installer lock after repeated concurrent changes: $install_lock"
    if ! path_exists "$install_lock"; then
      continue
    fi
    [ -d "$install_lock" ] && [ ! -L "$install_lock" ] \
      || die "Unsafe installer lock path: $install_lock"
    existing_pid=$(read_single_line "$install_lock/pid" || true)
    case "$existing_pid" in
      ''|0|*[!0-9]*)
        die "Installer lock has no valid owner PID; inspect and remove it manually if stale: $install_lock"
        ;;
    esac
    if kill -0 "$existing_pid" 2>/dev/null; then
      die "Another agent-container transaction is running (PID $existing_pid)."
    fi

    existing_owner=""
    existing_owner_present=false
    if path_exists "$install_lock/owner"; then
      [ -f "$install_lock/owner" ] && [ ! -L "$install_lock/owner" ] \
        || die "The stale installer lock has an unsafe owner record: $install_lock"
      existing_owner=$(read_single_line "$install_lock/owner" || true)
      valid_lock_owner "$existing_owner" \
        || die "The stale installer lock has an invalid owner record: $install_lock"
      existing_owner_present=true
    fi
    [ "$existing_owner_present" = true ] \
      || die "A stale legacy installer lock cannot be reclaimed safely while older launchers may still be running. Verify PID $existing_pid is dead, then remove only: $install_lock"

    reap_dir="$install_lock/.reap"
    if ! mkdir -- "$reap_dir" 2>/dev/null; then
      path_exists "$install_lock" || continue
      [ -d "$reap_dir" ] && [ ! -L "$reap_dir" ] \
        || die "The stale installer lock has an unsafe recovery claim: $install_lock"
      lock_directory_has_only "$reap_dir" "pid owner" \
        || die "The stale installer lock recovery claim contains unexpected entries."
      reap_pid=$(read_single_line "$reap_dir/pid" || true)
      reap_owner=$(read_single_line "$reap_dir/owner" || true)
      if case "$reap_pid" in
          ''|0|*[!0-9]*) false ;;
          *) true ;;
        esac \
        && valid_lock_owner "$reap_owner" \
        && kill -0 "$reap_pid" 2>/dev/null; then
        die "Another agent-container transaction is reclaiming a stale installer lock (PID $reap_pid)."
      fi
      rm -f -- "$reap_dir/pid" "$reap_dir/owner"
      rmdir -- "$reap_dir" 2>/dev/null \
        || die "Could not clear an abandoned installer recovery claim."
      mkdir -- "$reap_dir" \
        || die "Could not replace an abandoned installer recovery claim."
    fi
    chmod 0700 "$reap_dir"
    if ! printf '%s\n' "$$" > "$reap_dir/pid" \
      || ! printf '%s\n' "$install_lock_owner" > "$reap_dir/owner"; then
      rm -f -- "$reap_dir/pid" "$reap_dir/owner"
      rmdir -- "$reap_dir" 2>/dev/null || true
      die "Unable to publish the installer lock recovery claim."
    fi

    [ "$(read_single_line "$install_lock/pid" || true)" = "$existing_pid" ] \
      || die "The stale installer lock changed while it was being reclaimed."
    if [ "$existing_owner_present" = true ]; then
      [ "$(read_single_line "$install_lock/owner" || true)" = "$existing_owner" ] \
        || die "The stale installer lock owner changed while it was being reclaimed."
    else
      ! path_exists "$install_lock/owner" \
        || die "The stale installer lock gained an owner while it was being reclaimed."
    fi
    if kill -0 "$existing_pid" 2>/dev/null; then
      rm -f -- "$reap_dir/pid" "$reap_dir/owner"
      rmdir -- "$reap_dir" 2>/dev/null || true
      die "The installer lock owner PID $existing_pid became active during recovery."
    fi
    lock_directory_has_only "$install_lock" "pid owner .reap" \
      && lock_directory_has_only "$reap_dir" "pid owner" \
      || die "The stale installer lock contains unexpected entries; refusing to reclaim it."

    quarantine="$install_lock.reaped.$install_lock_owner"
    ! path_exists "$quarantine" \
      || die "The installer lock recovery quarantine already exists: $quarantine"
    mv -- "$install_lock" "$quarantine" \
      || die "Could not atomically quarantine the stale installer lock: $install_lock"
    [ "$(read_single_line "$quarantine/.reap/pid" || true)" = "$$" ] \
      && [ "$(read_single_line "$quarantine/.reap/owner" || true)" = "$install_lock_owner" ] \
      || die "Installer lock recovery ownership changed after quarantine."
    rm -f -- \
      "$quarantine/pid" \
      "$quarantine/owner" \
      "$quarantine/.reap/pid" \
      "$quarantine/.reap/owner"
    rmdir -- "$quarantine/.reap" \
      && rmdir -- "$quarantine" \
      || die "Could not clear the quarantined stale installer lock: $quarantine"
  done
  chmod 0700 "$install_lock"
  if ! printf '%s\n' "$$" > "$install_lock/pid" \
    || ! printf '%s\n' "$install_lock_owner" > "$install_lock/owner"; then
    rm -f -- "$install_lock/pid" "$install_lock/owner"
    rmdir -- "$install_lock" 2>/dev/null || true
    die "Unable to publish installer lock ownership."
  fi
  lock_acquired=true
}

valid_profile_id() {
  [ "${#1}" -le 32 ] || return 1
  case "$1" in
    ''|*[!a-z0-9-]*|[0-9-]*) return 1 ;;
    *) return 0 ;;
  esac
}

valid_sha256() {
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
    *) return 0 ;;
  esac
}

resolve_current_release() {
  local current_link release_id release_dir

  [ -n "$owned_asset_root" ] || return 1
  [ -L "$owned_asset_root/current" ] || return 1
  current_link=$(readlink "$owned_asset_root/current") || return 1
  case "$current_link" in
    releases/*) release_id=${current_link#releases/} ;;
    *) return 1 ;;
  esac
  valid_sha256 "$release_id" || return 1
  release_dir="$owned_asset_root/releases/$release_id"
  [ -d "$release_dir" ] && [ ! -L "$release_dir" ] || return 1
  [ "$(physical_dir "$release_dir" || true)" = "$release_dir" ] || return 1
  [ "$(read_single_line "$release_dir/.agent-container-release" || true)" = \
    "$release_id" ] \
    || return 1
  printf '%s\n' "$release_dir"
}

is_project_command() {
  local command_path="$1"
  local command_name="$2"
  local expected_target expected_release_dir expected_launcher

  [ -n "${owned_current_release:-}" ] || return 1
  expected_release_dir="$owned_current_release"
  expected_target="$expected_release_dir/$command_name"
  if [ -L "$command_path" ] \
    && [ "$(readlink "$command_path")" = \
      "$owned_asset_root/current/$command_name" ]; then
    return 0
  fi
  if [ -f "$command_path" ] \
    && [ ! -L "$command_path" ] \
    && [ -f "$expected_target" ] \
    && [ ! -L "$expected_target" ] \
    && cmp -s "$command_path" "$expected_target"; then
    return 0
  fi

  # New releases expose every command as the same exact relative alias. This
  # branch recognizes a copied regular launcher during migration without
  # trusting an arbitrary symlink target inside the managed release.
  expected_launcher="$expected_release_dir/agent-container-darwin-arm64"
  if [ -f "$command_path" ] \
    && [ ! -L "$command_path" ] \
    && [ -L "$expected_target" ] \
    && [ "$(readlink "$expected_target")" = agent-container-darwin-arm64 ] \
    && [ -f "$expected_launcher" ] \
    && [ ! -L "$expected_launcher" ] \
    && cmp -s "$command_path" "$expected_launcher"; then
    return 0
  fi
  return 1
}

current_release_publishes_command() {
  local command_name="$1"
  local profile_id profile_path

  [ "$command_name" = agent-container ] && return 0
  profile_id=${command_name%-container}
  profile_path="$owned_current_release/profiles/$profile_id.json"
  path_exists "$profile_path"
}

check_session_directory() {
  local session_dir="$1"
  local description="$2"
  local session_pid session_profile

  [ -d "$session_dir" ] && [ ! -L "$session_dir" ] \
    || preflight_die "$description has an unsafe path: $session_dir"
  session_pid=$(read_single_line "$session_dir/pid" || true)
  case "$session_pid" in
    ''|0|*[!0-9]*)
      preflight_die "$description has no valid owner PID: $session_dir"
      ;;
  esac
  session_profile=$(read_single_line "$session_dir/profile" || true)
  valid_profile_id "$session_profile" \
    || preflight_die "$description has no valid profile: $session_dir"
  if kill -0 "$session_pid" 2>/dev/null; then
    preflight_die "active Agent session PID $session_pid (profile $session_profile)"
  fi
}

had_error=false
home_input="${HOME:?HOME is not set}"
[ -d "$home_input" ] || die "HOME is not a directory: $home_input"
home_dir=$(physical_dir "$home_input")
[ "$home_dir" != "/" ] || die "Refusing to uninstall with HOME set to /."

install_dir_input="$home_input/.local/bin"
asset_root_input="$home_input/.local/share/agent-container"
state_root_input="$home_dir/.agent-container"

local_root_created=false
share_dir_created=false
lock_acquired=false
install_lock_owner=""
install_kernel_lock_acquired=false
tmp_dir=""
local_root=""
share_dir=""
cleanup() {
  local status=$?
  local cleanup_root
  trap - EXIT INT TERM HUP
  set +e
  [ -z "$tmp_dir" ] || rm -rf -- "$tmp_dir"
  release_install_directory_lock
  if [ "$share_dir_created" = true ]; then
    cleanup_root="${share_dir:-${share_dir_input:-}}"
    [ -z "$cleanup_root" ] || rmdir -- "$cleanup_root" 2>/dev/null
  fi
  if [ "$local_root_created" = true ]; then
    cleanup_root="${local_root:-${local_root_input:-}}"
    [ -z "$cleanup_root" ] || rmdir -- "$cleanup_root" 2>/dev/null
  fi
  release_install_kernel_lock
  exit "$status"
}
trap cleanup EXIT
restore_signal_traps

# Acquire the same transaction lock as install.sh and keep it through EXIT.
ignore_signals
acquire_install_kernel_lock

local_root_input="$home_input/.local"
if ! path_exists "$local_root_input"; then
  mkdir -- "$local_root_input"
  local_root_created=true
fi
[ -d "$local_root_input" ] \
  || die "Unsafe local install root: $local_root_input"
local_root=$(physical_dir "$local_root_input")
path_is_within "$home_dir" "$local_root" \
  || die "Local install root resolves outside HOME: $local_root_input"

share_dir_input="$home_input/.local/share"
if ! path_exists "$share_dir_input"; then
  mkdir -- "$share_dir_input"
  share_dir_created=true
fi
[ -d "$share_dir_input" ] \
  || die "Unsafe local share path: $share_dir_input"
share_dir=$(physical_dir "$share_dir_input")
path_is_within "$home_dir" "$share_dir" \
  || die "Local share path resolves outside HOME: $share_dir_input"

install_lock="$share_dir/.agent-container.install.lock"
acquire_install_lock
restore_signal_traps

ignore_signals
tmp_dir=$(mktemp -d)
restore_signal_traps
echo "Uninstalling agent-container..."

# ----- Complete read-only provenance and activity preflight -----
owned_asset_root=""
owned_current_release=""
if path_exists "$asset_root_input"; then
  owned_asset_root=$(canonical_safe_root "$asset_root_input" || true)
  [ -n "$owned_asset_root" ] \
    || preflight_die "unsafe managed-asset path: $asset_root_input"
  marker_matches "$owned_asset_root/.agent-container-install-owned" "$INSTALL_MARKER_TEXT" \
    || preflight_die "managed-asset root has no valid ownership marker: $owned_asset_root"
  owned_current_release=$(resolve_current_release || true)
  [ -n "$owned_current_release" ] \
    || preflight_die "managed-asset root has no valid current release: $owned_asset_root"
fi

resolved_install_dir=""
if [ -d "$install_dir_input" ]; then
  resolved_install_dir=$(canonical_safe_lookup_dir "$install_dir_input" || true)
  [ -n "$resolved_install_dir" ] \
    || preflight_die "install directory resolves outside HOME: $install_dir_input"
elif path_exists "$install_dir_input"; then
  preflight_die "install path is not a directory: $install_dir_input"
fi

command_paths=()
command_owned=()
for ((command_index = 0; command_index < ${#COMMANDS[@]}; command_index++)); do
  command_name=${COMMANDS[$command_index]}
  command_paths[$command_index]=""
  command_owned[$command_index]=false
  [ -n "$resolved_install_dir" ] || continue
  command_path="$resolved_install_dir/$command_name"
  command_paths[$command_index]="$command_path"
  if path_exists "$command_path"; then
    if is_project_command "$command_path" "$command_name"; then
      command_owned[$command_index]=true
    elif [ -z "$owned_asset_root" ] \
      || current_release_publishes_command "$command_name"; then
      preflight_die "unrecognized command was kept: $command_path"
    fi
  fi
done

owned_state_root=""
if path_exists "$state_root_input"; then
  owned_state_root=$(canonical_safe_root "$state_root_input" || true)
  [ -n "$owned_state_root" ] \
    || preflight_die "unsafe Agent state path: $state_root_input"
  marker_matches "$owned_state_root/.agent-container-owned" "$STATE_MARKER_TEXT" \
    || preflight_die "Agent state has no valid ownership marker: $owned_state_root"
fi

if [ -n "$owned_asset_root" ] && [ -n "$owned_state_root" ]; then
  if path_is_within "$owned_asset_root" "$owned_state_root" \
    || path_is_within "$owned_state_root" "$owned_asset_root"; then
    preflight_die "installed assets overlap persistent Agent state: $owned_state_root"
  fi
fi

# Check both serialized and explicitly concurrent sessions. Malformed paths,
# missing pid/profile files, or unreadable contents are indeterminate and stop
# the entire uninstall before images, commands, assets, or state are touched.
if [ -n "$owned_state_root" ]; then
  global_session_lock="$owned_state_root/session.lock"
  if path_exists "$global_session_lock"; then
    check_session_directory "$global_session_lock" "Agent session lock"
  fi

  sessions_root="$owned_state_root/sessions"
  if path_exists "$sessions_root"; then
    [ -d "$sessions_root" ] && [ ! -L "$sessions_root" ] \
      || preflight_die "unsafe Agent sessions path: $sessions_root"
    for session_dir in "$sessions_root"/session-*; do
      path_exists "$session_dir" || continue
      session_name=$(basename -- "$session_dir")
      session_number=${session_name#session-}
      case "$session_number" in
        ''|0|*[!0-9]*)
          preflight_die "Agent session has an invalid directory name: $session_dir"
          ;;
      esac
      check_session_directory "$session_dir" "Agent concurrent session"
    done
  fi
fi

# Enumerate native containers whenever managed state exists, independently of
# image metadata.  A singleton can survive a crash before (or while) its image
# provenance is published, so missing profile metadata must never turn native
# container discovery into an optional step.
#
# Apple container list emits ManagedContainer JSON whose raw labels live at
# configuration.labels. Include stopped records because SIGKILL can land after
# verified create but before attached start. A reserved singleton name is also
# treated as active/indeterminate even if its labels were lost or corrupted;
# adopting or ignoring a name-only resource would both be unsafe.
if [ -n "$owned_state_root" ]; then
  command -v "$container_bin" >/dev/null 2>&1 \
    || preflight_die "Apple container CLI is unavailable, so active sessions cannot be determined"
  all_containers="$tmp_dir/all-containers.json"
  if ! "$container_bin" list --all --format json > "$all_containers" 2> "$tmp_dir/container-list.err"; then
    preflight_die "Apple container service/list is unavailable, so active sessions cannot be determined"
  fi
  plutil_bin=$(command -v plutil || true)
  [ -n "$plutil_bin" ] \
    || preflight_die "macOS plutil is unavailable, so container-list JSON cannot be validated"
  "$plutil_bin" -convert json -o - "$all_containers" >/dev/null 2>&1 \
    || preflight_die "Apple container list returned invalid JSON"
  if grep -Eq '"com\.loadchange\.agent-container"[[:space:]]*:[[:space:]]*"true"' \
    "$all_containers"; then
    preflight_die "a stopped or running labeled Agent container still exists"
  fi
  if grep -Eq '"id"[[:space:]]*:[[:space:]]*"agent-(claude|codex|grok)-[0-9]+-singleton"' \
    "$all_containers"; then
    preflight_die "a stopped or running container occupies a reserved Agent singleton name"
  fi
fi

# Collect and validate every profile's image provenance before contacting the
# image store. An empty/incomplete meta directory can represent a build
# interrupted before provenance publication, so it fails closed instead of
# guessing.
image_refs=()
image_identities=()
image_present=()
if [ -n "$owned_state_root" ]; then
  profiles_root="$owned_state_root/profiles"
  if path_exists "$profiles_root"; then
    [ -d "$profiles_root" ] && [ ! -L "$profiles_root" ] \
      || preflight_die "unsafe Agent profiles path: $profiles_root"
    for profile_root in "$profiles_root"/*; do
      path_exists "$profile_root" || continue
      [ -d "$profile_root" ] && [ ! -L "$profile_root" ] \
        || preflight_die "unsafe Agent profile path: $profile_root"
      profile_id=$(basename -- "$profile_root")
      valid_profile_id "$profile_id" \
        || preflight_die "invalid Agent profile directory: $profile_root"
      profile_meta="$profile_root/meta"
      [ -d "$profile_meta" ] && [ ! -L "$profile_meta" ] \
        || preflight_die "profile '$profile_id' has unsafe or incomplete image metadata"

      image_ref=$(read_single_line "$profile_meta/image-ref" || true)
      image_build_id=$(read_single_line "$profile_meta/image-build-id" || true)
      expected_identity=$(read_single_line "$profile_meta/image-identity" || true)
      case "$image_ref" in
        ''|-*|*[!A-Za-z0-9._:/-]*)
          preflight_die "profile '$profile_id' has an invalid image reference"
          ;;
      esac
      image_fingerprint=${image_build_id#"$image_ref:"}
      [ "$image_fingerprint" != "$image_build_id" ] \
        && valid_sha256 "$image_fingerprint" \
        || preflight_die "profile '$profile_id' has an invalid image build id"
      valid_sha256 "$expected_identity" \
        || preflight_die "profile '$profile_id' has an invalid image identity"

      duplicate_index=""
      for ((image_index = 0; image_index < ${#image_refs[@]}; image_index++)); do
        if [ "${image_refs[$image_index]}" = "$image_ref" ]; then
          duplicate_index=$image_index
          break
        fi
      done
      if [ -n "$duplicate_index" ]; then
        [ "${image_identities[$duplicate_index]}" = "$expected_identity" ] \
          || preflight_die "profiles record conflicting provenance for image: $image_ref"
      else
        image_refs[${#image_refs[@]}]="$image_ref"
        image_identities[${#image_identities[@]}]="$expected_identity"
      fi
    done
  fi
fi

for ((image_index = 0; image_index < ${#image_refs[@]}; image_index++)); do
  image_ref=${image_refs[$image_index]}
  inspect_output="$tmp_dir/image-inspect.$image_index.json"
  inspect_error="$tmp_dir/image-inspect.$image_index.err"
  if "$container_bin" image inspect "$image_ref" > "$inspect_output" 2> "$inspect_error"; then
    [ -s "$inspect_output" ] \
      || preflight_die "Apple image inspect returned empty output: $image_ref"
    current_identity=$(sha256_file "$inspect_output" || true)
    [ "$current_identity" = "${image_identities[$image_index]}" ] \
      || preflight_die "Apple image identity no longer matches recorded provenance: $image_ref"
    image_present[$image_index]=true
  elif grep -Fq "image not found: $image_ref" "$inspect_error"; then
    image_present[$image_index]=false
  else
    preflight_die "Apple image could not be inspected; provenance was retained for retry: $image_ref"
  fi
done

# ----- Mutations begin only after every preflight above succeeds -----
runtime_failed=false
for ((image_index = 0; image_index < ${#image_refs[@]}; image_index++)); do
  [ "${image_present[$image_index]}" = true ] || continue
  image_ref=${image_refs[$image_index]}
  inspect_output="$tmp_dir/image-delete-recheck.$image_index.json"
  inspect_error="$tmp_dir/image-delete-recheck.$image_index.err"

  # Reinspect immediately before deletion to narrow the tag-retargeting race.
  if "$container_bin" image inspect "$image_ref" > "$inspect_output" 2> "$inspect_error"; then
    if [ ! -s "$inspect_output" ]; then
      warn "Apple image re-inspection returned empty output; retained provenance for retry: $image_ref"
      runtime_failed=true
      continue
    fi
    current_identity=$(sha256_file "$inspect_output" || true)
    if [ "$current_identity" != "${image_identities[$image_index]}" ]; then
      warn "Kept Apple image because its tag was retargeted after preflight: $image_ref"
      runtime_failed=true
      continue
    fi
  elif grep -Fq "image not found: $image_ref" "$inspect_error"; then
    continue
  else
    warn "Could not re-inspect Apple image; retained provenance for retry: $image_ref"
    runtime_failed=true
    continue
  fi

  if "$container_bin" image delete --force "$image_ref" >/dev/null 2>&1; then
    echo "Removed Apple image: $image_ref"
  else
    warn "Could not remove Apple image: $image_ref"
    runtime_failed=true
  fi
done

if [ "$runtime_failed" = true ]; then
  warn "Kept commands, installed assets, and all Agent state so runtime cleanup remains retryable."
  exit 1
fi

command_removal_failed=false
for ((command_index = 0; command_index < ${#COMMANDS[@]}; command_index++)); do
  [ "${command_owned[$command_index]}" = true ] || continue
  command_path=${command_paths[$command_index]}
  if rm -f -- "$command_path"; then
    echo "Removed executable: $command_path"
  else
    warn "Could not remove executable: $command_path"
    command_removal_failed=true
    had_error=true
  fi
done

asset_removal_succeeded=true
if [ -n "$owned_asset_root" ]; then
  if [ "$command_removal_failed" = true ]; then
    warn "Kept installed assets because command removal was incomplete: $owned_asset_root"
    asset_removal_succeeded=false
  else
    current_asset_root=$(canonical_safe_root "$asset_root_input" || true)
    if [ "$current_asset_root" != "$owned_asset_root" ] \
      || ! marker_matches "$owned_asset_root/.agent-container-install-owned" "$INSTALL_MARKER_TEXT"; then
      warn "Kept installed assets because their path or ownership changed after preflight: $asset_root_input"
      asset_removal_succeeded=false
      had_error=true
    else
      asset_root_removed=false
      ignore_signals
      if rm -rf -- "$owned_asset_root"; then
        asset_root_removed=true
      fi
      restore_signal_traps
      if [ "$asset_root_removed" = true ]; then
        echo "Removed installed assets: $owned_asset_root"
      else
        warn "Could not remove installed assets: $owned_asset_root"
        asset_removal_succeeded=false
        had_error=true
      fi
    fi
  fi
fi

if [ "$purge" = true ] && [ -n "$owned_state_root" ]; then
  if [ "$command_removal_failed" = true ] || [ "$asset_removal_succeeded" = false ]; then
    warn "Kept all Agent state because installation cleanup was incomplete: $owned_state_root"
    had_error=true
  else
    current_state_root=$(canonical_safe_root "$state_root_input" || true)
    if [ "$current_state_root" != "$owned_state_root" ] \
      || ! marker_matches "$owned_state_root/.agent-container-owned" "$STATE_MARKER_TEXT"; then
      warn "Kept all Agent state because its path or ownership changed after preflight: $state_root_input"
      had_error=true
    else
      state_root_removed=false
      ignore_signals
      if rm -rf -- "$owned_state_root"; then
        state_root_removed=true
      fi
      restore_signal_traps
      if [ "$state_root_removed" = true ]; then
        echo "Removed all Agent state: $owned_state_root"
      else
        warn "Could not remove all Agent state: $owned_state_root"
        had_error=true
      fi
    fi
  fi
elif [ "$purge" = false ] && [ -n "$owned_state_root" ]; then
  echo "Kept all per-profile credentials and state. Re-run with --purge to remove it."
fi

if [ "$had_error" = true ]; then
  echo "Uninstall completed with warnings." >&2
  exit 1
fi
echo "Uninstall complete."
