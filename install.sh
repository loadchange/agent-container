#!/bin/bash
set -euo pipefail

readonly INSTALL_MARKER_TEXT="managed by agent-container installer v1"
readonly BASE_URL="${AGENT_CONTAINER_INSTALL_BASE_URL:-https://raw.githubusercontent.com/loadchange/claude-docker/main}"

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
  agent-container
  claude-container
  codex-container
  grok-container
  Containerfile
  Containerfile.dockerignore
  entrypoint.sh
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
Usage: install.sh [--all | --profile PROFILE ...]

Install agent-container plus selected compatibility commands.

Options:
  --profile PROFILE   Install one profile (claude, codex, or grok).
                      May be repeated to install multiple profiles.
  --all               Install all profiles explicitly (the default).
  -h, --help          Show this help.

Examples:
  ./install.sh
  ./install.sh --all
  ./install.sh --profile grok
  ./install.sh --profile claude --profile codex

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
    agent-container|Containerfile|Containerfile.dockerignore|entrypoint.sh)
      return 0
      ;;
    *-container)
      asset_profile=${requested_asset%-container}
      profile_is_selected "$asset_profile"
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

is_recognized_regular_command() {
  local command_path="$1"
  local command_name="$2"

  [ -f "$command_path" ] && [ ! -L "$command_path" ] || return 1
  if cmp -s "$command_path" "$tmp_dir/$command_name"; then
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

selection_mode=default
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

  if [ "$lock_acquired" = true ] && [ -n "${install_lock:-}" ]; then
    rm -f -- "$install_lock/pid"
    rmdir -- "$install_lock" 2>/dev/null
  fi
  if [ "$transaction_complete" != true ] && [ -n "${asset_root:-}" ]; then
    [ "$releases_created" = false ] || rmdir -- "$asset_root/releases" 2>/dev/null
    [ "$root_created" = false ] || rmdir -- "$asset_root" 2>/dev/null
  fi
  [ -z "$tmp_dir" ] || rm -rf -- "$tmp_dir"
  exit "$status"
}
trap cleanup EXIT
restore_signal_traps

ignore_signals
tmp_dir=$(mktemp -d)
restore_signal_traps

echo "Installing profiles: ${SELECTED_PROFILES[*]}"

curl --fail --silent --show-error --location --retry 3 \
  "${BASE_URL%/}/release-manifest.sha256" \
  -o "$tmp_dir/release-manifest.sha256"
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
for ((asset_index = 0; asset_index < ${#ASSETS[@]}; asset_index++)); do
  asset=${ASSETS[$asset_index]}
  curl --fail --silent --show-error --location --retry 3 \
    "${BASE_URL%/}/$asset" -o "$tmp_dir/$asset"
  [ -s "$tmp_dir/$asset" ] || die "Downloaded asset is empty: $asset"
  actual_hash=$(sha256_file "$tmp_dir/$asset")
  [ "$actual_hash" = "${manifest_hashes[$asset_index]}" ] \
    || die "Downloaded asset does not match release manifest: $asset"
done

# A successful HTTP response can still be an error page. Validate every shell
# and JSON asset before any installed path is touched.
bash -n \
  "$tmp_dir/agent-container" \
  "$tmp_dir/claude-container" \
  "$tmp_dir/codex-container" \
  "$tmp_dir/grok-container" \
  "$tmp_dir/entrypoint.sh" \
  || die "A downloaded shell asset failed validation."
grep -Eq '^[[:space:]]*(ARG[[:space:]]+BASE_IMAGE|FROM[[:space:]])' "$tmp_dir/Containerfile" \
  || die "The downloaded Containerfile failed validation."
[ -f "$tmp_dir/Containerfile.dockerignore" ] \
  && grep -Fqx '**' "$tmp_dir/Containerfile.dockerignore" \
  && grep -Fqx '!entrypoint.sh' "$tmp_dir/Containerfile.dockerignore" \
  || die "The downloaded Containerfile.dockerignore failed validation."
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
ignore_signals
if ! mkdir -- "$install_lock" 2>/dev/null; then
  [ -d "$install_lock" ] && [ ! -L "$install_lock" ] \
    || die "Invalid installer lock at $install_lock"
  existing_pid=""
  if [ -f "$install_lock/pid" ] && [ ! -L "$install_lock/pid" ]; then
    existing_pid=$(sed -n '1p' "$install_lock/pid" 2>/dev/null || true)
  fi
  case "$existing_pid" in
    ''|0|*[!0-9]*)
      die "Installer lock has no valid owner PID; inspect and remove it manually if stale: $install_lock"
      ;;
  esac
  if kill -0 "$existing_pid" 2>/dev/null; then
    die "Another agent-container transaction is running (PID $existing_pid)."
  fi
  rm -f -- "$install_lock/pid"
  rmdir -- "$install_lock" 2>/dev/null \
    || die "Could not clear stale installer lock: $install_lock"
  mkdir -- "$install_lock"
fi
lock_acquired=true
printf '%s\n' "$$" > "$install_lock/pid"
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
  release_root_listing="$tmp_dir/existing-release-root-list"
  find "$release_dir" -mindepth 1 -maxdepth 1 -print \
    > "$release_root_listing" 2>/dev/null \
    || die "Could not safely enumerate the existing release: $release_dir"
  release_root_count=$(wc -l < "$release_root_listing" | tr -d '[:space:]')
  expected_root_count=$((7 + ${#SELECTED_PROFILES[@]}))
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
  for command_name in "${COMMANDS[@]}"; do
    install -m 0755 "$tmp_dir/$command_name" "$stage_dir/$command_name"
  done
  install -m 0644 "$tmp_dir/Containerfile" "$stage_dir/Containerfile"
  install -m 0644 \
    "$tmp_dir/Containerfile.dockerignore" \
    "$stage_dir/Containerfile.dockerignore"
  install -m 0755 "$tmp_dir/entrypoint.sh" "$stage_dir/entrypoint.sh"
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
  echo "Before the first run, start Apple container explicitly:"
  echo "  container system start"
  echo "  ${SELECTED_PROFILES[0]}-container"
else
  echo "Apple container is not installed. Get version 1.2.0 or newer from:"
  echo "  https://github.com/apple/container/releases"
fi
