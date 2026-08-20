#!/bin/bash
set -euo pipefail

readonly INSTALL_MARKER_TEXT="managed by agent-container installer v1"
readonly DEFAULT_BASE_URL="https://github.com/loadchange/agent-container/releases/latest/download"
readonly RELEASE_TARBALL="agent-container-darwin-arm64.tar.gz"
BASE_URL="$DEFAULT_BASE_URL"
BASE_URL_EXPLICIT=false
LOCAL_RELEASE_DIR=""

RELEASE_COMMANDS=(
  agent-container
  claude-container
  codex-container
  grok-container
)
AVAILABLE_PROFILES=(
  claude
  codex
  grok
)
COMMANDS=()
SELECTED_PROFILES=()
ASSETS=(
  agent-container-darwin-arm64
  agent-container-runtime
  Containerfile
  Containerfile.dockerignore
  entrypoint.sh
  host-exec-client
  host-exec-broker.mjs
  agent-workspace-connect
  agent-workspace-session
  profiles/claude.json
  profiles/codex.json
  profiles/grok.json
)

die() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install.sh [--all | --profile PROFILE ...] [--base-url URL]

Install agent-container plus selected compatibility commands.

Options:
  --profile PROFILE   Install one profile (claude, codex, or grok).
                      May be repeated to install multiple profiles.
  --all               Install all profiles explicitly (the default).
  --base-url URL      Download the release manifest and tarball from URL.
                      The URL must serve release-manifest.sha256 and
                      agent-container-darwin-arm64.tar.gz. Intended for an
                      internal mirror.
  -h, --help          Show this help.

Examples:
  ./install.sh
  ./install.sh --all
  ./install.sh --profile grok
  ./install.sh --profile claude --profile codex
  ./install.sh --profile claude --base-url "https://internal-mirror.example/agent-container"

By default the installer downloads the latest GitHub Release. From a source
checkout it automatically uses the dist/ layout produced by
scripts/build-release.sh when it is present.

The selected profiles are the desired managed set. Re-running with a different
selection removes only unselected commands that this project can prove it
owns. Unknown or user-owned files are never removed.
EOF
}

usage_die() {
  echo "Error: $*" >&2
  echo "Try 'install.sh --help' for usage." >&2
  exit 64
}

profile_is_available() {
  local requested_profile="$1"
  local available_profile
  for available_profile in "${AVAILABLE_PROFILES[@]}"; do
    [ "$available_profile" = "$requested_profile" ] && return 0
  done
  return 1
}

select_profile() {
  local requested_profile="$1"
  local selected_profile
  profile_is_available "$requested_profile" \
    || usage_die "Unknown profile '$requested_profile'; expected claude, codex, or grok."
  if [ "${#SELECTED_PROFILES[@]}" -gt 0 ]; then
    for selected_profile in "${SELECTED_PROFILES[@]}"; do
      [ "$selected_profile" = "$requested_profile" ] && return 0
    done
  fi
  SELECTED_PROFILES[${#SELECTED_PROFILES[@]}]="$requested_profile"
}

profile_is_selected() {
  local requested_profile="$1"
  local selected_profile
  for selected_profile in "${SELECTED_PROFILES[@]}"; do
    [ "$selected_profile" = "$requested_profile" ] && return 0
  done
  return 1
}

command_is_selected() {
  local requested_command="$1"
  local selected_profile
  [ "$requested_command" = agent-container ] && return 0
  for selected_profile in "${SELECTED_PROFILES[@]}"; do
    [ "$requested_command" = "$selected_profile-container" ] && return 0
  done
  return 1
}

asset_is_selected() {
  local requested_asset="$1"
  local asset_profile
  case "$requested_asset" in
    agent-container-darwin-arm64|agent-container-runtime|Containerfile|Containerfile.dockerignore|entrypoint.sh|host-exec-client|host-exec-broker.mjs|agent-workspace-connect|agent-workspace-session)
      return 0
      ;;
    profiles/*.json)
      asset_profile=${requested_asset#profiles/}
      asset_profile=${asset_profile%.json}
      profile_is_selected "$asset_profile"
      ;;
    *) return 1 ;;
  esac
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

marker_matches() {
  local marker="$1"
  [ -f "$marker" ] \
    && [ ! -L "$marker" ] \
    && cmp -s "$marker" <(printf '%s\n' "$INSTALL_MARKER_TEXT")
}

read_single_line() {
  local file="$1"
  local value
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  IFS= read -r value < "$file" || return 1
  [ -n "$value" ] || return 1
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
      || die "Invalid installer lock at $install_lock"
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

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "shasum or sha256sum is required."
  fi
}

sha256_stream() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    die "shasum or sha256sum is required."
  fi
}

discover_local_release() {
  local asset candidate_dir candidate_script

  candidate_script=$0
  case "$candidate_script" in
    /*) ;;
    *) candidate_script="$PWD/$candidate_script" ;;
  esac
  [ -f "$candidate_script" ] && [ ! -L "$candidate_script" ] || return 1
  candidate_dir=$(CDPATH= cd -- "$(dirname -- "$candidate_script")" && pwd -P) \
    || return 1
  candidate_script="$candidate_dir/${candidate_script##*/}"
  [ -f "$candidate_script" ] && [ ! -L "$candidate_script" ] || return 1

  # Source checkouts stage the complete flat release layout under dist/ with
  # scripts/build-release.sh; the native launcher is not tracked in git.
  candidate_dir="$candidate_dir/dist"
  [ -f "$candidate_dir/release-manifest.sha256" ] \
    && [ ! -L "$candidate_dir/release-manifest.sha256" ] \
    && [ -d "$candidate_dir/profiles" ] \
    && [ ! -L "$candidate_dir/profiles" ] \
    || return 1
  for asset in "${ASSETS[@]}"; do
    [ -f "$candidate_dir/$asset" ] && [ ! -L "$candidate_dir/$asset" ] \
      || return 1
  done
  LOCAL_RELEASE_DIR="$candidate_dir"
}

download_release_file() {
  local destination="$2"
  local relative_path="$1"
  local source_path

  if [ -n "$LOCAL_RELEASE_DIR" ]; then
    source_path="$LOCAL_RELEASE_DIR/$relative_path"
    [ -f "$source_path" ] && [ ! -L "$source_path" ] \
      || die "Local release asset is unsafe or missing: $relative_path"
    /bin/cp -- "$source_path" "$destination" \
      || die "Could not copy local release asset: $relative_path"
    return
  fi

  curl --disable --fail --silent --show-error --location --retry 3 \
    "${BASE_URL%/}/$relative_path" -o "$destination"
}

validate_native_launcher() {
  local launcher_path="$1"
  local description="$2"
  local file_output

  [ -f "$launcher_path" ] \
    && [ ! -L "$launcher_path" ] \
    && [ -x "$launcher_path" ] \
    || die "$description is not a regular executable file."
  file_output=$(/usr/bin/file -b "$launcher_path" 2>/dev/null) \
    || die "$description could not be inspected as a native executable."
  [ "$file_output" = "Mach-O 64-bit executable arm64" ] \
    || die "$description is not a thin Mach-O 64-bit arm64 executable."
  /usr/bin/codesign --verify --strict "$launcher_path" >/dev/null 2>&1 \
    || die "$description does not have a valid code signature."
}

is_recognized_regular_command() {
  local command_path="$1"
  local command_name="$2"

  [ -f "$command_path" ] && [ ! -L "$command_path" ] || return 1
  if cmp -s "$command_path" "$tmp_dir/agent-container-darwin-arm64"; then
    return 0
  fi

  # Provenance for project launchers that predate the generic release layout.
  case "$command_name" in
    agent-container)
      grep -Fq 'readonly PROGRAM_NAME="agent-container"' "$command_path" \
        && grep -Fq 'com.loadchange.agent-container=true' "$command_path"
      ;;
    claude-container)
      grep -Fq 'apple/container/issues/1097' "$command_path" \
        && grep -Eq 'PROGRAM_NAME="(agent-container|claude-container)"' "$command_path"
      ;;
    *) return 1 ;;
  esac
}

current_release_selects_profile() {
  local requested_profile="$1"
  local current_link current_release_id current_release profiles_dir
  local selected_profile_file

  [ -L "$asset_root/current" ] || return 1
  current_link=$(readlink "$asset_root/current") || return 1
  case "$current_link" in
    releases/*) current_release_id=${current_link#releases/} ;;
    *) return 1 ;;
  esac
  [ "${#current_release_id}" -eq 64 ] || return 1
  case "$current_release_id" in
    *[!0-9a-f]*) return 1 ;;
  esac

  current_release="$asset_root/releases/$current_release_id"
  [ -d "$current_release" ] && [ ! -L "$current_release" ] || return 1
  [ "$(physical_dir "$current_release" || true)" = "$current_release" ] \
    || return 1
  [ "$(read_single_line "$current_release/.agent-container-release" || true)" \
      = "$current_release_id" ] \
    || return 1
  profiles_dir="$current_release/profiles"
  [ -d "$profiles_dir" ] && [ ! -L "$profiles_dir" ] || return 1
  selected_profile_file="$profiles_dir/$requested_profile.json"
  [ -f "$selected_profile_file" ] && [ ! -L "$selected_profile_file" ]
}

guard_profile_singleton_before_removal() {
  local requested_profile="$1"
  local container_bin osascript_bin list_file singleton_state

  container_bin=container
  command -v "$container_bin" >/dev/null 2>&1 \
    || die "Cannot remove profile '$requested_profile' because the Apple container CLI is unavailable. Stop its managed singleton first with: agent-container singleton stop $requested_profile"
  osascript_bin=$(command -v osascript || true)
  [ -n "$osascript_bin" ] \
    || die "Cannot remove profile '$requested_profile' because macOS JavaScriptCore is unavailable to verify singleton absence."

  list_file="$tmp_dir/$requested_profile-singleton-list.json"
  if ! "$container_bin" list --all --format json > "$list_file" 2>/dev/null; then
    die "Cannot remove profile '$requested_profile' because Apple container state could not be enumerated. Start the service and stop its managed singleton first with: agent-container singleton stop $requested_profile"
  fi
  if ! singleton_state=$("$osascript_bin" -l JavaScript - \
    "$list_file" "$(id -u)" "$requested_profile" 2>/dev/null <<'JXA'
ObjC.import('Foundation');

function run(argv) {
  const error = Ref();
  const source = $.NSString.stringWithContentsOfFileEncodingError(
    argv[0],
    $.NSUTF8StringEncoding,
    error
  );
  if (!source) throw new Error('container list is not readable UTF-8');
  const containers = JSON.parse(ObjC.unwrap(source));
  if (!Array.isArray(containers)) throw new Error('container list must be an array');

  const hostUID = argv[1];
  const profile = argv[2];
  if (!/^(?:claude|codex|grok)$/.test(profile)) {
    throw new Error('profile is not supported');
  }
  const expectedID = 'agent-' + profile + '-' + hostUID + '-singleton';
  let match = null;
  for (const container of containers) {
    if (container === null || typeof container !== 'object' || Array.isArray(container)) {
      throw new Error('container list contains a non-object record');
    }
    const id = container.id;
    if (typeof id !== 'string' || /[\t\r\n]/.test(id)) {
      throw new Error('container id is not a single-line string');
    }
    if (id !== expectedID) continue;
    if (match !== null) throw new Error('singleton identity is duplicated');

    const configuration = container.configuration;
    if (configuration === null || typeof configuration !== 'object'
        || Array.isArray(configuration) || configuration.id !== expectedID) {
      throw new Error('singleton configuration identity mismatch');
    }
    const labels = configuration.labels;
    const launcherPID = labels && labels['com.loadchange.agent-container.launcher-pid'];
    const configHash = labels
      && labels['com.loadchange.agent-container.config-sha256'];
    if (labels === null || typeof labels !== 'object' || Array.isArray(labels)
        || labels['com.loadchange.agent-container'] !== 'true'
        || labels['com.loadchange.agent-container.profile'] !== profile
        || labels['com.loadchange.agent-container.host-uid'] !== hostUID
        || labels['com.loadchange.agent-container.mode'] !== 'singleton'
        || typeof launcherPID !== 'string' || !/^[0-9]+$/.test(launcherPID)
        || Number(launcherPID) < 2
        || typeof configHash !== 'string' || !/^[0-9a-f]{64}$/.test(configHash)) {
      throw new Error('reserved singleton identity has invalid provenance labels');
    }
    const state = container.status && typeof container.status === 'object'
      && !Array.isArray(container.status)
      ? container.status.state
      : null;
    if (!['unknown', 'stopped', 'running', 'stopping'].includes(state)) {
      throw new Error('singleton has an invalid runtime state');
    }
    match = state;
  }
  return match === null ? 'absent' : match;
}
JXA
  ); then
    die "Cannot remove profile '$requested_profile' because its reserved singleton identity or Apple container state could not be verified safely. Stop it first with: agent-container singleton stop $requested_profile"
  fi

  [ "$singleton_state" = absent ] \
    || die "Cannot remove profile '$requested_profile' while its managed singleton exists in state '$singleton_state'. Stop it first with: agent-container singleton stop $requested_profile"
}

selection_mode=default
[ -z "${AGENT_CONTAINER_INSTALL_BASE_URL+x}" ] \
  || usage_die "AGENT_CONTAINER_INSTALL_BASE_URL is no longer a public interface; use --base-url URL."
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      [ "$selection_mode" != profiles ] \
        || usage_die "--all cannot be combined with --profile."
      selection_mode=all
      shift
      ;;
    --profile)
      [ "$selection_mode" != all ] \
        || usage_die "--profile cannot be combined with --all."
      [ "$#" -ge 2 ] || usage_die "--profile requires a profile name."
      selection_mode=profiles
      select_profile "$2"
      shift 2
      ;;
    --profile=*)
      [ "$selection_mode" != all ] \
        || usage_die "--profile cannot be combined with --all."
      profile_value=${1#--profile=}
      [ -n "$profile_value" ] || usage_die "--profile requires a profile name."
      selection_mode=profiles
      select_profile "$profile_value"
      shift
      ;;
    --base-url)
      [ "$#" -ge 2 ] || usage_die "--base-url requires a URL."
      BASE_URL="$2"
      BASE_URL_EXPLICIT=true
      shift 2
      ;;
    --base-url=*)
      BASE_URL=${1#--base-url=}
      [ -n "$BASE_URL" ] || usage_die "--base-url requires a URL."
      BASE_URL_EXPLICIT=true
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

if [ "$BASE_URL_EXPLICIT" = false ]; then
  discover_local_release || true
fi

case "$BASE_URL" in
  https://*|file:///*) ;;
  *) usage_die "--base-url must use https:// or an absolute file:/// URL." ;;
esac
case "$BASE_URL" in
  *$'\n'*|*$'\r'*|*$'\t'*)
    usage_die "--base-url contains unsupported control characters."
    ;;
esac
readonly BASE_URL

if [ "$selection_mode" != profiles ]; then
  for profile_id in "${AVAILABLE_PROFILES[@]}"; do
    select_profile "$profile_id"
  done
fi

# Canonical profile order makes the same set reuse the same immutable release
# regardless of argument order or duplicate --profile flags.
ORDERED_PROFILES=()
for profile_id in "${AVAILABLE_PROFILES[@]}"; do
  if profile_is_selected "$profile_id"; then
    ORDERED_PROFILES[${#ORDERED_PROFILES[@]}]="$profile_id"
  fi
done
SELECTED_PROFILES=("${ORDERED_PROFILES[@]}")

COMMANDS=(agent-container)
for profile_id in "${SELECTED_PROFILES[@]}"; do
  COMMANDS[${#COMMANDS[@]}]="$profile_id-container"
done

# Refuse unsupported hosts before downloads, temporary directories, locks, or
# installed paths are created. The Apple container package/service itself may
# be installed and started after this script completes.
[ "$(uname -s 2>/dev/null || true)" = "Darwin" ] \
  || die "agent-container is supported only on macOS."
[ "$(uname -m 2>/dev/null || true)" = "arm64" ] \
  || die "agent-container requires Apple silicon."
macos_version=$(sw_vers -productVersion 2>/dev/null || true)
macos_major=${macos_version%%.*}
case "$macos_major" in
  ''|*[!0-9]*) die "Could not determine the macOS version." ;;
esac
[ "$macos_major" -ge 26 ] \
  || die "macOS 26 or newer is required by the supported Apple container release."

home_input="${HOME:?HOME is not set}"
[ -d "$home_input" ] || die "HOME is not a directory: $home_input"
home_dir=$(physical_dir "$home_input")
[ "$home_dir" != "/" ] || die "Refusing to install with HOME set to /."

install_dir_input="$home_input/.local/bin"
asset_root_input="$home_input/.local/share/agent-container"

# BSD mv needs -h to replace a symlink to a directory; GNU mv expresses the
# same no-follow operation as -T. Both publish through rename(2).
if mv --help 2>&1 | grep -Fq -- '--no-target-directory'; then
  mv_style=gnu
else
  mv_style=bsd
fi

atomic_replace() {
  if [ "$mv_style" = gnu ]; then
    mv -fT -- "$1" "$2"
  else
    mv -fh -- "$1" "$2"
  fi
}

tmp_dir=""
stage_dir=""
stage_created=false
release_dir=""
release_created=false
root_created=false
marker_created=false
releases_created=false
lock_acquired=false
install_lock_owner=""
install_kernel_lock_acquired=false
transaction_complete=false

current_path=""
current_tmp=""
current_backup=""
current_backed_up=false
current_switched=false
current_was_symlink=false
current_original_link=""

command_paths=()
command_tmps=()
command_backups=()
command_backed_up=()
command_switched=()
command_actions=()

cleanup() {
  local status=$?
  local i
  trap - EXIT INT TERM HUP
  set +e

  if [ "$transaction_complete" != true ]; then
    i=$((${#RELEASE_COMMANDS[@]} - 1))
    while [ "$i" -ge 0 ]; do
      if [ "${command_switched[$i]:-false}" = true ]; then
        rm -f -- "${command_paths[$i]}"
      fi
      if [ "${command_backed_up[$i]:-false}" = true ] \
        && path_exists "${command_backups[$i]}"; then
        mv -- "${command_backups[$i]}" "${command_paths[$i]}"
      fi
      if [ -n "${command_tmps[$i]:-}" ]; then
        rm -f -- "${command_tmps[$i]}"
      fi
      i=$((i - 1))
    done

    if [ "$current_switched" = true ]; then
      if [ "$current_was_symlink" = true ]; then
        rm -f -- "$current_tmp"
        ln -s "$current_original_link" "$current_tmp"
        atomic_replace "$current_tmp" "$current_path"
      else
        rm -f -- "$current_path"
        if [ "$current_backed_up" = true ] && path_exists "$current_backup"; then
          mv -- "$current_backup" "$current_path"
        fi
      fi
    elif [ "$current_backed_up" = true ] && path_exists "$current_backup"; then
      mv -- "$current_backup" "$current_path"
    fi

    [ -n "$current_tmp" ] && rm -f -- "$current_tmp"
    if [ "$stage_created" = true ] && [ -n "$stage_dir" ]; then
      rm -rf -- "$stage_dir"
    fi
    if [ "$release_created" = true ] && [ -n "$release_dir" ]; then
      rm -rf -- "$release_dir"
    fi
    if [ "$marker_created" = true ] && [ -n "${asset_root:-}" ]; then
      rm -f -- "$asset_root/.agent-container-install-owned"
    fi
  fi

  if [ "$transaction_complete" != true ] && [ -n "${asset_root:-}" ]; then
    [ "$releases_created" = false ] || rmdir -- "$asset_root/releases" 2>/dev/null
    [ "$root_created" = false ] || rmdir -- "$asset_root" 2>/dev/null
  fi
  release_install_lock
  [ -z "$tmp_dir" ] || rm -rf -- "$tmp_dir"
  exit "$status"
}
trap cleanup EXIT
restore_signal_traps

ignore_signals
tmp_dir=$(mktemp -d)
restore_signal_traps

echo "Installing profiles: ${SELECTED_PROFILES[*]}"

download_release_file \
  release-manifest.sha256 \
  "$tmp_dir/release-manifest.sha256"
[ -s "$tmp_dir/release-manifest.sha256" ] \
  || die "Downloaded release manifest is empty."
[ -f "$tmp_dir/release-manifest.sha256" ] \
  && [ ! -L "$tmp_dir/release-manifest.sha256" ] \
  || die "Downloaded release manifest is unsafe."

manifest_hashes=()
manifest_index=0
while IFS= read -r manifest_line || [ -n "$manifest_line" ]; do
  [ "$manifest_index" -lt "${#ASSETS[@]}" ] \
    || die "Release manifest contains unexpected entries."
  manifest_hash=${manifest_line%% *}
  manifest_suffix=${manifest_line#"$manifest_hash"}
  [ "$manifest_suffix" = "  ${ASSETS[$manifest_index]}" ] \
    || die "Release manifest entry $((manifest_index + 1)) is invalid or out of order."
  case "$manifest_hash" in
    *[!0-9a-f]*) die "Release manifest contains an invalid SHA-256 digest." ;;
  esac
  [ "${#manifest_hash}" -eq 64 ] \
    || die "Release manifest contains an invalid SHA-256 digest."
  manifest_hashes[$manifest_index]="$manifest_hash"
  manifest_index=$((manifest_index + 1))
done < "$tmp_dir/release-manifest.sha256"
[ "$manifest_index" -eq "${#ASSETS[@]}" ] \
  || die "Release manifest is incomplete."

mkdir -- "$tmp_dir/profiles"
if [ -n "$LOCAL_RELEASE_DIR" ]; then
  for ((asset_index = 0; asset_index < ${#ASSETS[@]}; asset_index++)); do
    asset=${ASSETS[$asset_index]}
    download_release_file "$asset" "$tmp_dir/$asset"
    [ -s "$tmp_dir/$asset" ] || die "Local release asset is empty: $asset"
  done
else
  # GitHub Release assets are flat, so the per-file release layout ships
  # inside one tarball. Extract only the expected members by name: a
  # malicious or corrupted archive can neither traverse outside the staging
  # directory nor introduce unexpected files, and every extracted member is
  # re-checked below as a regular, non-symlink file against the manifest.
  download_release_file "$RELEASE_TARBALL" "$tmp_dir/$RELEASE_TARBALL"
  [ -s "$tmp_dir/$RELEASE_TARBALL" ] \
    || die "The downloaded release tarball is empty."
  if ! tar -xzf "$tmp_dir/$RELEASE_TARBALL" -C "$tmp_dir" "${ASSETS[@]}"; then
    die "The release tarball is incomplete or could not be extracted."
  fi
fi
for ((asset_index = 0; asset_index < ${#ASSETS[@]}; asset_index++)); do
  asset=${ASSETS[$asset_index]}
  [ -f "$tmp_dir/$asset" ] && [ ! -L "$tmp_dir/$asset" ] \
    || die "Release asset is missing or unsafe: $asset"
  [ -s "$tmp_dir/$asset" ] || die "Release asset is empty: $asset"
  actual_hash=$(sha256_file "$tmp_dir/$asset")
  [ "$actual_hash" = "${manifest_hashes[$asset_index]}" ] \
    || die "Release asset does not match release manifest: $asset"
done

# curl creates downloads without execute permissions. Set the launcher's final
# mode before native validation so the staged artifact is exactly what runs.
chmod 0755 "$tmp_dir/agent-container-darwin-arm64"
validate_native_launcher \
  "$tmp_dir/agent-container-darwin-arm64" \
  "The downloaded agent-container launcher"

# A successful HTTP response can still be an error page. Validate every shell
# and JSON asset before any installed path is touched.
bash -n \
  "$tmp_dir/agent-container-runtime" \
  "$tmp_dir/entrypoint.sh" \
  "$tmp_dir/host-exec-client" \
  "$tmp_dir/agent-workspace-connect" \
  "$tmp_dir/agent-workspace-session" \
  || die "A downloaded shell asset failed validation."
grep -Eq '^[[:space:]]*(ARG[[:space:]]+BASE_IMAGE|FROM[[:space:]])' "$tmp_dir/Containerfile" \
  || die "The downloaded Containerfile failed validation."
[ -f "$tmp_dir/Containerfile.dockerignore" ] \
  && grep -Fqx '**' "$tmp_dir/Containerfile.dockerignore" \
  && grep -Fqx '!entrypoint.sh' "$tmp_dir/Containerfile.dockerignore" \
  && grep -Fqx '!host-exec-client' "$tmp_dir/Containerfile.dockerignore" \
  && grep -Fqx '!agent-workspace-connect' "$tmp_dir/Containerfile.dockerignore" \
  && grep -Fqx '!agent-workspace-session' "$tmp_dir/Containerfile.dockerignore" \
  || die "The downloaded Containerfile.dockerignore failed validation."
grep -Fq 'createServer' "$tmp_dir/host-exec-broker.mjs" \
  || die "The downloaded host-exec broker failed validation."
plutil_bin=$(command -v plutil || true)
[ -n "$plutil_bin" ] || die "macOS plutil is required to validate Agent profiles."
for profile_id in claude codex grok; do
  "$plutil_bin" -convert json -o - "$tmp_dir/profiles/$profile_id.json" >/dev/null 2>&1 \
    || die "Downloaded profile is not valid JSON: $profile_id"
  grep -Eq '"id"[[:space:]]*:[[:space:]]*"'"$profile_id"'"' \
    "$tmp_dir/profiles/$profile_id.json" \
    || die "Downloaded profile has the wrong id: $profile_id"
done

release_id=$(
  {
    for ((asset_index = 0; asset_index < ${#ASSETS[@]}; asset_index++)); do
      printf '%s  %s\n' "${manifest_hashes[$asset_index]}" "${ASSETS[$asset_index]}"
    done
    for profile_id in "${SELECTED_PROFILES[@]}"; do
      printf 'selected-profile  %s\n' "$profile_id"
    done
  } | sha256_stream
)
case "$release_id" in
  *[!0-9a-f]*) die "Could not calculate a valid release fingerprint." ;;
esac
[ "${#release_id}" -eq 64 ] \
  || die "Could not calculate a valid release fingerprint."

ignore_signals
acquire_install_kernel_lock

local_root_input="$home_input/.local"
if ! path_exists "$local_root_input"; then
  mkdir -- "$local_root_input"
fi
[ -d "$local_root_input" ] \
  || die "Local install root is not a directory: $local_root_input"
local_root=$(physical_dir "$local_root_input")
path_is_within "$home_dir" "$local_root" \
  || die "Local install root resolves outside HOME: $local_root_input -> $local_root"

mkdir -p -- "$install_dir_input"
install_dir=$(physical_dir "$install_dir_input")
path_is_within "$home_dir" "$install_dir" \
  || die "Install directory resolves outside HOME: $install_dir_input -> $install_dir"
[ "$install_dir" != "$home_dir" ] \
  || die "Refusing to use the entire home directory as the install directory."

share_dir_input="$home_input/.local/share"
if ! path_exists "$share_dir_input"; then
  mkdir -- "$share_dir_input"
fi
[ -d "$share_dir_input" ] \
  || die "Local share path is not a directory: $share_dir_input"
share_dir=$(physical_dir "$share_dir_input")
path_is_within "$home_dir" "$share_dir" \
  || die "Local share path resolves outside HOME: $share_dir_input -> $share_dir"

# The installer and uninstaller hold this lock through their whole publish or
# removal transaction. A pidless/malformed lock fails closed because it may be
# in the tiny owner-publication window.
install_lock="$share_dir/.agent-container.install.lock"
acquire_install_lock
restore_signal_traps

asset_root="$share_dir/agent-container"
if [ -L "$asset_root_input" ]; then
  die "Refusing a symlink as the managed asset root: $asset_root_input"
fi
if [ ! -e "$asset_root_input" ]; then
  root_created=true
  mkdir -- "$asset_root_input"
elif [ ! -d "$asset_root_input" ]; then
  die "Managed asset path is not a directory: $asset_root_input"
fi
asset_root=$(physical_dir "$asset_root_input")
path_is_within "$home_dir" "$asset_root" \
  || die "Managed asset root resolves outside HOME: $asset_root_input -> $asset_root"
[ "$asset_root" != "$home_dir" ] \
  || die "Refusing to use the entire home directory as the managed asset root."

install_marker="$asset_root/.agent-container-install-owned"
if path_exists "$install_marker"; then
  marker_matches "$install_marker" \
    || die "Managed asset root has an invalid ownership marker: $asset_root"
else
  asset_listing="$tmp_dir/asset-root-list"
  if ! find "$asset_root" -mindepth 1 -maxdepth 1 -print -quit > "$asset_listing" 2>/dev/null; then
    die "Could not safely enumerate the unowned asset root: $asset_root"
  fi
  [ ! -s "$asset_listing" ] \
    || die "Refusing to adopt a non-empty asset root without an ownership marker: $asset_root"
  marker_created=true
  printf '%s\n' "$INSTALL_MARKER_TEXT" > "$install_marker"
  chmod 0600 "$install_marker"
fi

# Removing a profile's launch record must never strand its persistent
# container. Enumerate every deselected fixed identity while the HOME
# transaction lock is held, before switching the current release or commands.
for profile_id in "${AVAILABLE_PROFILES[@]}"; do
  if ! profile_is_selected "$profile_id" \
    && { current_release_selects_profile "$profile_id" \
      || path_exists "$home_dir/.agent-container/profiles/$profile_id/singleton"; }; then
    guard_profile_singleton_before_removal "$profile_id"
  fi
done

releases_dir="$asset_root/releases"
if path_exists "$releases_dir"; then
  [ -d "$releases_dir" ] && [ ! -L "$releases_dir" ] \
    || die "Managed releases path is not a directory: $releases_dir"
  resolved_releases_dir=$(physical_dir "$releases_dir")
  path_is_within "$asset_root" "$resolved_releases_dir" \
    || die "Managed releases path resolves outside the asset root: $releases_dir"
else
  releases_created=true
  mkdir -- "$releases_dir"
fi
release_dir="$releases_dir/$release_id"

if path_exists "$release_dir"; then
  [ -d "$release_dir" ] && [ ! -L "$release_dir" ] \
    || die "Release path is not a managed directory: $release_dir"
  [ -f "$release_dir/.agent-container-release" ] \
    && [ ! -L "$release_dir/.agent-container-release" ] \
    && cmp -s "$release_dir/.agent-container-release" <(printf '%s\n' "$release_id") \
    || die "Existing release has an invalid marker: $release_dir"
  [ -f "$release_dir/release-manifest.sha256" ] \
    && [ ! -L "$release_dir/release-manifest.sha256" ] \
    && cmp -s "$tmp_dir/release-manifest.sha256" "$release_dir/release-manifest.sha256" \
    || die "Existing release is incomplete or modified: $release_dir"
  [ -d "$release_dir/profiles" ] && [ ! -L "$release_dir/profiles" ] \
    || die "Existing release has an unsafe profiles directory: $release_dir"
  for asset in "${ASSETS[@]}"; do
    if asset_is_selected "$asset"; then
      [ -f "$release_dir/$asset" ] \
        && [ ! -L "$release_dir/$asset" ] \
        && cmp -s "$tmp_dir/$asset" "$release_dir/$asset" \
        || die "Existing release is incomplete or modified: $release_dir"
    else
      ! path_exists "$release_dir/$asset" \
        || die "Existing release contains an unselected asset: $release_dir/$asset"
    fi
  done
  validate_native_launcher \
    "$release_dir/agent-container-darwin-arm64" \
    "The installed agent-container launcher"
  for executable_asset in \
    agent-container-runtime \
    entrypoint.sh \
    host-exec-client \
    agent-workspace-connect \
    agent-workspace-session; do
    [ -f "$release_dir/$executable_asset" ] \
      && [ ! -L "$release_dir/$executable_asset" ] \
      && [ -x "$release_dir/$executable_asset" ] \
      || die "Existing release has a non-executable runtime asset: $release_dir/$executable_asset"
  done
  for command_name in "${RELEASE_COMMANDS[@]}"; do
    [ -L "$release_dir/$command_name" ] \
      && [ "$(readlink "$release_dir/$command_name")" = agent-container-darwin-arm64 ] \
      || die "Existing release has an invalid command alias: $release_dir/$command_name"
  done
  release_root_listing="$tmp_dir/existing-release-root-list"
  find "$release_dir" -mindepth 1 -maxdepth 1 -print \
    > "$release_root_listing" 2>/dev/null \
    || die "Could not safely enumerate the existing release: $release_dir"
  release_root_count=$(wc -l < "$release_root_listing" | tr -d '[:space:]')
  # Nine shared regular assets, four command aliases, the profiles directory,
  # release manifest, and ownership marker.
  expected_root_count=16
  [ "$release_root_count" = "$expected_root_count" ] \
    || die "Existing release contains unexpected root entries: $release_dir"
  release_profile_listing="$tmp_dir/existing-release-profile-list"
  find "$release_dir/profiles" -mindepth 1 -maxdepth 1 -print \
    > "$release_profile_listing" 2>/dev/null \
    || die "Could not safely enumerate the existing profiles: $release_dir"
  release_profile_count=$(wc -l < "$release_profile_listing" | tr -d '[:space:]')
  [ "$release_profile_count" = "${#SELECTED_PROFILES[@]}" ] \
    || die "Existing release contains unexpected profile entries: $release_dir"
else
  ignore_signals
  stage_dir=$(mktemp -d "$releases_dir/.staging.XXXXXX")
  stage_created=true
  mkdir -- "$stage_dir/profiles"
  restore_signal_traps
  install -m 0755 \
    "$tmp_dir/agent-container-darwin-arm64" \
    "$stage_dir/agent-container-darwin-arm64"
  install -m 0755 \
    "$tmp_dir/agent-container-runtime" \
    "$stage_dir/agent-container-runtime"
  for command_name in "${RELEASE_COMMANDS[@]}"; do
    ln -s agent-container-darwin-arm64 "$stage_dir/$command_name"
  done
  install -m 0644 "$tmp_dir/Containerfile" "$stage_dir/Containerfile"
  install -m 0644 \
    "$tmp_dir/Containerfile.dockerignore" \
    "$stage_dir/Containerfile.dockerignore"
  install -m 0755 "$tmp_dir/entrypoint.sh" "$stage_dir/entrypoint.sh"
  install -m 0755 "$tmp_dir/host-exec-client" "$stage_dir/host-exec-client"
  install -m 0644 "$tmp_dir/host-exec-broker.mjs" "$stage_dir/host-exec-broker.mjs"
  install -m 0755 \
    "$tmp_dir/agent-workspace-connect" \
    "$stage_dir/agent-workspace-connect"
  install -m 0755 \
    "$tmp_dir/agent-workspace-session" \
    "$stage_dir/agent-workspace-session"
  for profile_id in "${SELECTED_PROFILES[@]}"; do
    install -m 0644 "$tmp_dir/profiles/$profile_id.json" "$stage_dir/profiles/$profile_id.json"
  done
  install -m 0444 "$tmp_dir/release-manifest.sha256" "$stage_dir/release-manifest.sha256"
  printf '%s\n' "$release_id" > "$stage_dir/.agent-container-release"
  chmod 0444 "$stage_dir/.agent-container-release"
  release_created=true
  mv -- "$stage_dir" "$release_dir"
  stage_dir=""
  stage_created=false
fi

current_path="$asset_root/current"
current_tmp="$asset_root/.current.new.$$"
current_backup="$asset_root/.current.rollback.$$"

for ((command_index = 0; command_index < ${#RELEASE_COMMANDS[@]}; command_index++)); do
  command_name=${RELEASE_COMMANDS[$command_index]}
  command_paths[$command_index]="$install_dir/$command_name"
  command_tmps[$command_index]="$install_dir/.$command_name.new.$$"
  command_backups[$command_index]="$install_dir/.$command_name.rollback.$$"
  command_backed_up[$command_index]=false
  command_switched[$command_index]=false
  command_actions[$command_index]=ignore
done

for reserved_path in "$current_tmp" "$current_backup"; do
  ! path_exists "$reserved_path" \
    || die "Refusing to overwrite a transaction path: $reserved_path"
done
for ((command_index = 0; command_index < ${#RELEASE_COMMANDS[@]}; command_index++)); do
  for reserved_path in "${command_tmps[$command_index]}" "${command_backups[$command_index]}"; do
    ! path_exists "$reserved_path" \
      || die "Refusing to overwrite a transaction path: $reserved_path"
  done

  command_name=${RELEASE_COMMANDS[$command_index]}
  command_path=${command_paths[$command_index]}
  if command_is_selected "$command_name"; then
    command_actions[$command_index]=switch
    if [ -L "$command_path" ] \
      && [ "$(readlink "$command_path")" = "$asset_root/current/$command_name" ]; then
      command_actions[$command_index]=keep
    elif path_exists "$command_path"; then
      [ -f "$command_path" ] \
        && [ ! -L "$command_path" ] \
        && is_recognized_regular_command "$command_path" "$command_name" \
        || die "Refusing to replace an unrecognized command: $command_path"
    fi
  elif [ -L "$command_path" ] \
    && [ "$(readlink "$command_path")" = "$asset_root/current/$command_name" ]; then
    command_actions[$command_index]=remove
  elif [ -f "$command_path" ] \
    && [ ! -L "$command_path" ] \
    && is_recognized_regular_command "$command_path" "$command_name"; then
    command_actions[$command_index]=remove
  fi
done

ln -s "releases/$release_id" "$current_tmp"
for ((command_index = 0; command_index < ${#RELEASE_COMMANDS[@]}; command_index++)); do
  if [ "${command_actions[$command_index]}" = switch ]; then
    ln -s "$asset_root/current/${RELEASE_COMMANDS[$command_index]}" \
      "${command_tmps[$command_index]}"
  fi
done

# The only version switch is current. Stable command symlinks make upgrades
# atomic; backups make first install and known-project migrations rollback-safe.
if [ -L "$current_path" ]; then
  current_was_symlink=true
  current_original_link=$(readlink "$current_path")
elif path_exists "$current_path"; then
  current_backed_up=true
  mv -- "$current_path" "$current_backup"
fi
current_switched=true
atomic_replace "$current_tmp" "$current_path"

for ((command_index = 0; command_index < ${#RELEASE_COMMANDS[@]}; command_index++)); do
  if [ "${command_actions[$command_index]}" = switch ]; then
    if path_exists "${command_paths[$command_index]}"; then
      command_backed_up[$command_index]=true
      mv -- "${command_paths[$command_index]}" "${command_backups[$command_index]}"
    fi
    command_switched[$command_index]=true
    atomic_replace "${command_tmps[$command_index]}" "${command_paths[$command_index]}"
  elif [ "${command_actions[$command_index]}" = remove ]; then
    command_backed_up[$command_index]=true
    mv -- "${command_paths[$command_index]}" "${command_backups[$command_index]}"
  fi
done

transaction_complete=true

if path_exists "$current_backup"; then
  rm -rf -- "$current_backup" \
    || warn "Could not remove the previous current-release backup: $current_backup"
fi
for ((command_index = 0; command_index < ${#RELEASE_COMMANDS[@]}; command_index++)); do
  if path_exists "${command_backups[$command_index]}"; then
    rm -f -- "${command_backups[$command_index]}" \
      || warn "Could not remove the previous command backup: ${command_backups[$command_index]}"
  fi
done

if ! echo "$PATH" | tr ':' '\n' | grep -Fqx "$install_dir"; then
  echo ""
  echo "Warning: $install_dir is not in your PATH."
  echo "Add the following to your shell profile (~/.zshrc, ~/.bashrc, etc.):"
  echo ""
  echo "  export PATH=\"$install_dir:\$PATH\""
  echo ""
fi

echo "Installed commands:       ${COMMANDS[*]}"
echo "Installed release:        $release_id"
echo "Installed assets:         $asset_root/current"
echo ""
if command -v container >/dev/null 2>&1; then
  echo "Apple container services will be started automatically when needed:"
  echo "  ${SELECTED_PROFILES[0]}-container"
else
  echo "Apple container is not installed. Install version 1.2.0 or newer with:"
  echo "  brew install container"
  echo "or download the signed package from:"
  echo "  https://github.com/apple/container/releases"
fi
