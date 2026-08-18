#!/bin/bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
fixture_path="$repo_root/tests/install-fixtures:/usr/bin:/bin"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

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
COMMANDS=(
  agent-container
  claude-container
  codex-container
  grok-container
)

passes=0

fail() {
  echo "not ok - $*" >&2
  exit 1
}

pass() {
  passes=$((passes + 1))
  echo "ok $passes - $*"
}

assert_contains() {
  grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"
}

assert_not_contains() {
  if grep -Fq -- "$2" "$1"; then
    fail "unexpected '$2' in $1"
  fi
}

assert_path_absent() {
  [ ! -e "$1" ] && [ ! -L "$1" ] \
    || fail "expected path to be absent: $1"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

sha256_stream() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

write_manifest() {
  local source_root="$1"
  local asset
  : > "$source_root/release-manifest.sha256"
  for asset in "${ASSETS[@]}"; do
    printf '%s  %s\n' "$(sha256_file "$source_root/$asset")" "$asset" \
      >> "$source_root/release-manifest.sha256"
  done
}

make_release_source() {
  local source_root="$1"
  local asset
  mkdir -p "$source_root/profiles"
  for asset in "${ASSETS[@]}"; do
    cp "$repo_root/$asset" "$source_root/$asset"
  done
  chmod 0755 \
    "$source_root/agent-container-darwin-arm64" \
    "$source_root/agent-container-runtime" \
    "$source_root/entrypoint.sh" \
    "$source_root/host-exec-client" \
    "$source_root/agent-workspace-connect" \
    "$source_root/agent-workspace-session"
  write_manifest "$source_root"
}

run_install() {
  local source_root="$1"
  local case_home="$2"
  shift 2
  HOME="$case_home" \
    PATH="$fixture_path" \
    FAKE_CONTAINER_LOG="${FAKE_CONTAINER_LOG:-$test_root/install-container.log}" \
    bash "$repo_root/install.sh" --base-url "file://$source_root" "$@"
}

run_uninstall() {
  local case_home="$1"
  local container_log="$2"
  shift 2
  HOME="$case_home" \
    PATH="$fixture_path" \
    FAKE_CONTAINER_LOG="$container_log" \
    bash "$repo_root/uninstall.sh" "$@" --container-bin container
}

default_inspect_identity() {
  printf '{"reference":"%s","digest":"sha256:test-owned"}\n' "$1" | sha256_stream
}

make_owned_state() {
  local case_home="$1"
  mkdir -p "$case_home/.agent-container"
  printf '%s\n' 'managed by agent-container' \
    > "$case_home/.agent-container/.agent-container-owned"
}

add_profile_state() {
  local case_home="$1"
  local profile_id="$2"
  local image_ref="$3"
  local expected_identity="${4:-}"
  local profile_root="$case_home/.agent-container/profiles/$profile_id"
  local fingerprint
  fingerprint=$(printf '%064d' 0)
  [ -n "$expected_identity" ] \
    || expected_identity=$(default_inspect_identity "$image_ref")
  mkdir -p "$profile_root/home" "$profile_root/meta"
  printf '%s\n' "$image_ref" > "$profile_root/meta/image-ref"
  printf '%s:%s\n' "$image_ref" "$fingerprint" \
    > "$profile_root/meta/image-build-id"
  printf '%s\n' "$expected_identity" > "$profile_root/meta/image-identity"
}

assert_install_intact() {
  local case_home="$1"
  local command_name
  [ -d "$case_home/.local/share/agent-container" ] \
    || fail "managed asset root was unexpectedly removed"
  for command_name in "${COMMANDS[@]}"; do
    [ -x "$case_home/.local/bin/$command_name" ] \
      || fail "$command_name was unexpectedly removed"
  done
}

source_v1="$test_root/source-v1"
make_release_source "$source_v1"

# Help and selection errors are resolved before platform checks, downloads, or
# install-path mutation, so curl-piped and scripted installs fail predictably.
argument_home="$test_root/argument-home"
mkdir -p "$argument_home"
HOME="$argument_home" PATH="/usr/bin:/bin" \
  bash "$repo_root/install.sh" --help \
  > "$test_root/help.out" 2> "$test_root/help.err"
assert_contains "$test_root/help.out" 'Usage: install.sh [--all | --profile PROFILE ...]'
assert_contains "$test_root/help.out" './install.sh --profile grok'

checkout_home="$test_root/checkout-home"
mkdir -p "$checkout_home"
HOME="$checkout_home" \
  PATH="$fixture_path" \
  FAKE_CONTAINER_LOG="$test_root/checkout-container.log" \
  bash "$repo_root/install.sh" --profile claude \
  > "$test_root/checkout-install.out" \
  2> "$test_root/checkout-install.err"
assert_contains "$test_root/checkout-install.out" \
  'Installed commands:       agent-container claude-container'
[ -x "$checkout_home/.local/bin/agent-container" ] \
  && [ -x "$checkout_home/.local/bin/claude-container" ] \
  || fail "source checkout did not install the selected commands"
assert_path_absent "$checkout_home/.local/bin/codex-container"
assert_path_absent "$checkout_home/.local/bin/grok-container"
pass "source checkout automatically uses its adjacent release"

if run_install "$source_v1" "$argument_home" --profile unknown \
  > "$test_root/unknown-profile.out" 2> "$test_root/unknown-profile.err"; then
  fail "installer accepted an unknown profile"
fi
assert_contains "$test_root/unknown-profile.err" "Unknown profile 'unknown'"
if run_install "$source_v1" "$argument_home" --profile \
  > "$test_root/missing-profile.out" 2> "$test_root/missing-profile.err"; then
  fail "installer accepted --profile without a value"
fi
assert_contains "$test_root/missing-profile.err" '--profile requires a profile name'
if run_install "$source_v1" "$argument_home" --all --profile grok \
  > "$test_root/mixed-selection.out" 2> "$test_root/mixed-selection.err"; then
  fail "installer accepted conflicting selection modes"
fi
assert_contains "$test_root/mixed-selection.err" '--profile cannot be combined with --all'
if run_install "$source_v1" "$argument_home" unexpected \
  > "$test_root/positional.out" 2> "$test_root/positional.err"; then
  fail "installer accepted a positional argument"
fi
assert_contains "$test_root/positional.err" "Unknown argument 'unexpected'"
[ ! -e "$argument_home/.local" ] \
  || fail "argument rejection mutated the install home"
pass "installer help and profile-selection errors are deterministic and pre-mutation"

for legacy_base_case in value empty; do
  case "$legacy_base_case" in
    value)
      legacy_base_assignment='AGENT_CONTAINER_INSTALL_BASE_URL=https://legacy.invalid'
      ;;
    empty)
      legacy_base_assignment='AGENT_CONTAINER_INSTALL_BASE_URL='
      ;;
  esac
  if env HOME="$argument_home" PATH="/usr/bin:/bin" \
    "$legacy_base_assignment" \
    bash "$repo_root/install.sh" \
      --base-url 'file:///does-not-exist' --profile claude \
    > "$test_root/install-base-env-$legacy_base_case.out" \
    2> "$test_root/install-base-env-$legacy_base_case.err"; then
    fail "installer accepted legacy base URL environment case $legacy_base_case"
  fi
  assert_contains "$test_root/install-base-env-$legacy_base_case.err" \
    'AGENT_CONTAINER_INSTALL_BASE_URL is no longer a public interface; use --base-url URL'
  [ ! -e "$argument_home/.local" ] \
    || fail "legacy base URL rejection mutated the install home"
done
pass "installer rejects set and empty legacy base URL environment values"

# Uninstall runtime selection is explicit CLI state. Legacy environment knobs
# fail before path creation, including when they are present with empty values.
HOME="$argument_home" PATH="/usr/bin:/bin" \
  bash "$repo_root/uninstall.sh" --help \
  > "$test_root/uninstall-help.out" 2> "$test_root/uninstall-help.err"
assert_contains "$test_root/uninstall-help.out" \
  'Usage: uninstall.sh [--purge] [--container-bin PATH]'
assert_contains "$test_root/uninstall-help.out" \
  '--container-bin PATH'

if HOME="$argument_home" PATH="/usr/bin:/bin" \
  bash "$repo_root/uninstall.sh" --container-bin --purge \
  > "$test_root/uninstall-bin-missing.out" \
  2> "$test_root/uninstall-bin-missing.err"; then
  fail "uninstaller accepted --container-bin without a value"
fi
assert_contains "$test_root/uninstall-bin-missing.err" \
  '--container-bin requires a path'
if HOME="$argument_home" PATH="/usr/bin:/bin" \
  bash "$repo_root/uninstall.sh" --container-bin= \
  > "$test_root/uninstall-bin-empty.out" \
  2> "$test_root/uninstall-bin-empty.err"; then
  fail "uninstaller accepted an empty --container-bin value"
fi
assert_contains "$test_root/uninstall-bin-empty.err" \
  '--container-bin requires a path'
if HOME="$argument_home" PATH="/usr/bin:/bin" \
  bash "$repo_root/uninstall.sh" \
    --container-bin container --container-bin=container \
  > "$test_root/uninstall-bin-duplicate.out" \
  2> "$test_root/uninstall-bin-duplicate.err"; then
  fail "uninstaller accepted duplicate --container-bin options"
fi
assert_contains "$test_root/uninstall-bin-duplicate.err" \
  '--container-bin may only be specified once'
if HOME="$argument_home" PATH="/usr/bin:/bin" \
  bash "$repo_root/uninstall.sh" --purge --purge \
  > "$test_root/uninstall-purge-duplicate.out" \
  2> "$test_root/uninstall-purge-duplicate.err"; then
  fail "uninstaller accepted duplicate --purge options"
fi
assert_contains "$test_root/uninstall-purge-duplicate.err" \
  '--purge may only be specified once'

for legacy_env_case in bin bin_empty state state_empty; do
  case "$legacy_env_case" in
    bin) legacy_env_assignment='AGENT_CONTAINER_BIN=container' ;;
    bin_empty) legacy_env_assignment='AGENT_CONTAINER_BIN=' ;;
    state) legacy_env_assignment="AGENT_CONTAINER_STATE_DIR=$argument_home/.agent-container" ;;
    state_empty) legacy_env_assignment='AGENT_CONTAINER_STATE_DIR=' ;;
  esac
  if env HOME="$argument_home" PATH="/usr/bin:/bin" \
    "$legacy_env_assignment" \
    bash "$repo_root/uninstall.sh" --container-bin container \
    > "$test_root/uninstall-env-$legacy_env_case.out" \
    2> "$test_root/uninstall-env-$legacy_env_case.err"; then
    fail "uninstaller accepted legacy environment case $legacy_env_case"
  fi
  case "$legacy_env_case" in
    bin*)
      assert_contains "$test_root/uninstall-env-$legacy_env_case.err" \
        'AGENT_CONTAINER_BIN is no longer supported; use --container-bin PATH'
      ;;
    state*)
      assert_contains "$test_root/uninstall-env-$legacy_env_case.err" \
        'AGENT_CONTAINER_STATE_DIR is unsupported; unset it'
      ;;
  esac
done
[ ! -e "$argument_home/.local" ] \
  || fail "uninstaller argument or environment rejection mutated HOME"
pass "uninstaller CLI validates runtime selection and rejects legacy environment knobs"

# Platform checks happen before even a release-manifest fetch.
for platform_case in non_darwin non_arm64 old_macos; do
  platform_home="$test_root/platform-$platform_case-home"
  mkdir -p "$platform_home"
  platform_err="$test_root/platform-$platform_case.err"
  case "$platform_case" in
    non_darwin)
      if HOME="$platform_home" PATH="$fixture_path" \
        FAKE_UNAME_SYSTEM=Linux \
        bash "$repo_root/install.sh" --base-url 'file:///does-not-exist' \
        > /dev/null 2> "$platform_err"; then
        fail "installer accepted a non-macOS host"
      fi
      assert_contains "$platform_err" 'supported only on macOS'
      ;;
    non_arm64)
      if HOME="$platform_home" PATH="$fixture_path" \
        FAKE_UNAME_MACHINE=x86_64 \
        bash "$repo_root/install.sh" --base-url 'file:///does-not-exist' \
        > /dev/null 2> "$platform_err"; then
        fail "installer accepted a non-Apple-silicon host"
      fi
      assert_contains "$platform_err" 'requires Apple silicon'
      ;;
    old_macos)
      if HOME="$platform_home" PATH="$fixture_path" \
        FAKE_MACOS_VERSION=15.6 \
        bash "$repo_root/install.sh" --base-url 'file:///does-not-exist' \
        > /dev/null 2> "$platform_err"; then
        fail "installer accepted macOS older than 26"
      fi
      assert_contains "$platform_err" 'macOS 26 or newer'
      ;;
  esac
  [ ! -e "$platform_home/.local" ] \
    || fail "platform rejection mutated the install home"
done
pass "installer rejects unsupported hosts before downloads or install mutation"

# The installer owns its transfer policy. A user curl configuration must not
# silently disable the reviewed file:// release source used by this test (or
# alter proxy/TLS behavior for a real HTTPS release).
curlrc_home="$test_root/curlrc-home"
mkdir -p "$curlrc_home"
printf '%s\n' 'proto =https' > "$curlrc_home/.curlrc"
run_install "$source_v1" "$curlrc_home" --profile claude \
  > "$test_root/curlrc.out" 2> "$test_root/curlrc.err"
[ -x "$curlrc_home/.local/bin/claude-container" ] \
  || fail "installer did not publish Claude while ignoring the ambient .curlrc"
pass "installer ignores ambient curl configuration"

# The manifest is an allowlist as well as a mixed-release integrity boundary.
manifest_home="$test_root/manifest-home"
manifest_source="$test_root/manifest-source"
mkdir -p "$manifest_home"
make_release_source "$manifest_source"
printf '%s\n' '# tampered after manifest publication' \
  >> "$manifest_source/entrypoint.sh"
if run_install "$manifest_source" "$manifest_home" --profile grok \
  > "$test_root/manifest.out" 2> "$test_root/manifest.err"; then
  fail "installer accepted a manifest hash mismatch"
fi
assert_contains "$test_root/manifest.err" 'does not match release manifest: entrypoint.sh'
[ ! -e "$manifest_home/.local" ] \
  || fail "manifest mismatch published install paths"

make_release_source "$manifest_source"
printf '%064d  %s\n' 0 unexpected-file \
  >> "$manifest_source/release-manifest.sha256"
if run_install "$manifest_source" "$manifest_home" \
  > "$test_root/manifest-extra.out" 2> "$test_root/manifest-extra.err"; then
  fail "installer accepted an extra manifest entry"
fi
assert_contains "$test_root/manifest-extra.err" 'unexpected entries'
[ ! -e "$manifest_home/.local" ] \
  || fail "extra manifest entry published install paths"
pass "release manifest is strict and hash mismatches fail before publication"

# Manifest integrity does not make an arbitrary payload a trusted launcher.
# Require the published binary to be the expected thin signed Apple artifact.
native_format_home="$test_root/native-format-home"
native_format_source="$test_root/native-format-source"
mkdir -p "$native_format_home"
make_release_source "$native_format_source"
printf '%s\n' '#!/bin/bash' 'exit 0' \
  > "$native_format_source/agent-container-darwin-arm64"
chmod 0755 "$native_format_source/agent-container-darwin-arm64"
write_manifest "$native_format_source"
if run_install "$native_format_source" "$native_format_home" --profile claude \
  > "$test_root/native-format.out" 2> "$test_root/native-format.err"; then
  fail "installer accepted a signed-manifest shell script as the native launcher"
fi
assert_contains "$test_root/native-format.err" \
  'is not a thin Mach-O 64-bit arm64 executable'
[ ! -e "$native_format_home/.local" ] \
  || fail "native-format rejection published install paths"

signature_home="$test_root/signature-home"
signature_source="$test_root/signature-source"
mkdir -p "$signature_home"
make_release_source "$signature_source"
/usr/bin/codesign --remove-signature \
  "$signature_source/agent-container-darwin-arm64"
[ "$(/usr/bin/file -b "$signature_source/agent-container-darwin-arm64")" = \
  'Mach-O 64-bit executable arm64' ] \
  || fail "unsigned launcher fixture stopped being a thin arm64 Mach-O"
if /usr/bin/codesign --verify --strict \
  "$signature_source/agent-container-darwin-arm64" >/dev/null 2>&1; then
  fail "launcher signature-removal fixture remained signed"
fi
write_manifest "$signature_source"
if run_install "$signature_source" "$signature_home" --profile claude \
  > "$test_root/signature.out" 2> "$test_root/signature.err"; then
  fail "installer accepted an unsigned launcher with a matching manifest"
fi
assert_contains "$test_root/signature.err" \
  'does not have a valid code signature'
[ ! -e "$signature_home/.local" ] \
  || fail "signature rejection published install paths"
pass "launcher publication requires thin arm64 Mach-O format and a valid signature"

# A profile selection is the complete desired managed set. Releases contain
# all command aliases plus only the selected profiles, and changing the set
# removes only top-level commands whose project provenance is known.
selective_home="$test_root/selective-home"
mkdir -p "$selective_home"
run_install "$source_v1" "$selective_home" --profile grok \
  > "$test_root/selective-grok.out" 2> "$test_root/selective-grok.err"
selective_root=$(CDPATH= cd -- "$selective_home/.local/share/agent-container" && pwd -P)
selective_grok_link=$(readlink "$selective_root/current")
selective_grok_release="$selective_root/$selective_grok_link"
for command_name in agent-container grok-container; do
  [ -L "$selective_home/.local/bin/$command_name" ] \
    || fail "single-profile install omitted $command_name"
done
for command_name in claude-container codex-container; do
  assert_path_absent "$selective_home/.local/bin/$command_name"
done
for asset in \
  agent-container-darwin-arm64 agent-container-runtime \
  Containerfile Containerfile.dockerignore entrypoint.sh host-exec-client \
  host-exec-broker.mjs agent-workspace-connect agent-workspace-session \
  profiles/grok.json; do
  [ -f "$selective_grok_release/$asset" ] \
    && [ ! -L "$selective_grok_release/$asset" ] \
    || fail "single-profile release omitted $asset"
done
for command_name in "${COMMANDS[@]}"; do
  [ -L "$selective_grok_release/$command_name" ] \
    && [ "$(readlink "$selective_grok_release/$command_name")" = \
      agent-container-darwin-arm64 ] \
    || fail "single-profile release has an invalid $command_name alias"
done
for asset in profiles/claude.json profiles/codex.json; do
  assert_path_absent "$selective_grok_release/$asset"
done
[ -f "$selective_grok_release/release-manifest.sha256" ] \
  || fail "single-profile release omitted its verified manifest"

# Duplicates and argument order describe a set, not a distinct release.
run_install "$source_v1" "$selective_home" \
  --profile=grok --profile grok \
  > "$test_root/selective-repeat.out" 2> "$test_root/selective-repeat.err"
[ "$(readlink "$selective_root/current")" = "$selective_grok_link" ] \
  || fail "duplicate profile selection created a distinct release"

run_install "$source_v1" "$selective_home" \
  --profile codex --profile claude \
  > "$test_root/selective-multiple.out" 2> "$test_root/selective-multiple.err"
selective_multiple_link=$(readlink "$selective_root/current")
[ "$selective_multiple_link" != "$selective_grok_link" ] \
  || fail "changed profile set reused the wrong release"
selective_multiple_release="$selective_root/$selective_multiple_link"
for command_name in agent-container claude-container codex-container; do
  [ -L "$selective_home/.local/bin/$command_name" ] \
    || fail "multi-profile install omitted $command_name"
done
assert_path_absent "$selective_home/.local/bin/grok-container"
for command_name in "${COMMANDS[@]}"; do
  [ -L "$selective_multiple_release/$command_name" ] \
    && [ "$(readlink "$selective_multiple_release/$command_name")" = \
      agent-container-darwin-arm64 ] \
    || fail "multi-profile release has an invalid $command_name alias"
done
for asset in profiles/claude.json profiles/codex.json; do
  [ -f "$selective_multiple_release/$asset" ] \
    || fail "multi-profile release omitted $asset"
done
assert_path_absent "$selective_multiple_release/profiles/grok.json"

run_install "$source_v1" "$selective_home" --all \
  > "$test_root/selective-all.out" 2> "$test_root/selective-all.err"
for command_name in "${COMMANDS[@]}"; do
  [ -L "$selective_home/.local/bin/$command_name" ] \
    || fail "explicit --all omitted $command_name"
done

# An unknown file in an unselected command slot is retained, while another
# omitted command with exact managed provenance is removed.
rm -f "$selective_home/.local/bin/codex-container"
printf '%s\n' 'echo user-owned codex command' \
  > "$selective_home/.local/bin/codex-container"
chmod 0755 "$selective_home/.local/bin/codex-container"
run_install "$source_v1" "$selective_home" --profile grok \
  > "$test_root/selective-replace.out" 2> "$test_root/selective-replace.err"
[ "$(readlink "$selective_root/current")" = "$selective_grok_link" ] \
  || fail "returning to the grok set did not reuse its release"
assert_path_absent "$selective_home/.local/bin/claude-container"
assert_contains "$selective_home/.local/bin/codex-container" 'echo user-owned codex command'

selective_uninstall_log="$test_root/selective-uninstall.log"
: > "$selective_uninstall_log"
HOME="$selective_home" PATH="/usr/bin:/bin" \
  bash "$repo_root/uninstall.sh" \
    --container-bin definitely-missing-container \
  > "$test_root/selective-uninstall.out" 2> "$test_root/selective-uninstall.err"
for command_name in agent-container claude-container grok-container; do
  assert_path_absent "$selective_home/.local/bin/$command_name"
done
assert_path_absent "$selective_root"
assert_contains "$selective_home/.local/bin/codex-container" 'echo user-owned codex command'
pass "single, multiple, all, replacement, and selective uninstall sets are exact"

# A profile-set replacement must retain a profile command until its fixed
# singleton resource is absent. Both a running and a stopped VM still occupy
# the managed identity and therefore block deselection.
singleton_hash=$(printf '%064d' 0)
for singleton_state in running stopped; do
  singleton_guard_home="$test_root/singleton-guard-$singleton_state-home"
  singleton_guard_log="$test_root/singleton-guard-$singleton_state.log"
  mkdir -p "$singleton_guard_home"
  : > "$singleton_guard_log"
  run_install "$source_v1" "$singleton_guard_home" --profile grok \
    > "$test_root/singleton-guard-$singleton_state-install.out" \
    2> "$test_root/singleton-guard-$singleton_state-install.err"
  singleton_guard_root="$singleton_guard_home/.local/share/agent-container"
  singleton_guard_current=$(readlink "$singleton_guard_root/current")
  singleton_guard_json="[{\"id\":\"agent-grok-$(id -u)-singleton\",\"configuration\":{\"id\":\"agent-grok-$(id -u)-singleton\",\"labels\":{\"com.loadchange.agent-container\":\"true\",\"com.loadchange.agent-container.profile\":\"grok\",\"com.loadchange.agent-container.host-uid\":\"$(id -u)\",\"com.loadchange.agent-container.launcher-pid\":\"$$\",\"com.loadchange.agent-container.mode\":\"singleton\",\"com.loadchange.agent-container.workspace-roots-sha256\":\"$singleton_hash\",\"com.loadchange.agent-container.config-sha256\":\"$singleton_hash\"}},\"status\":{\"state\":\"$singleton_state\"}}]"

  if FAKE_CONTAINER_LOG="$singleton_guard_log" \
    FAKE_CONTAINER_LIST_JSON="$singleton_guard_json" \
    run_install "$source_v1" "$singleton_guard_home" --profile claude \
    > "$test_root/singleton-guard-$singleton_state.out" \
    2> "$test_root/singleton-guard-$singleton_state.err"; then
    fail "$singleton_state Grok singleton did not block profile replacement"
  fi
  assert_contains "$test_root/singleton-guard-$singleton_state.err" \
    "managed singleton exists in state '$singleton_state'"
  assert_contains "$test_root/singleton-guard-$singleton_state.err" \
    'agent-container singleton stop grok'
  [ "$(readlink "$singleton_guard_root/current")" = "$singleton_guard_current" ] \
    || fail "$singleton_state singleton guard switched the current release"
  [ -L "$singleton_guard_home/.local/bin/grok-container" ] \
    || fail "$singleton_state singleton guard removed grok-container"
  assert_path_absent "$singleton_guard_home/.local/bin/claude-container"
  assert_contains "$singleton_guard_log" 'ARG=--all'
done
pass "running and stopped Grok singletons block profile replacement before mutation"

# All generic assets and compatibility commands publish through one release.
install_home="$test_root/install-home"
mkdir -p "$install_home"
run_install "$source_v1" "$install_home" \
  > "$test_root/install.out" 2> "$test_root/install.err"
asset_root=$(CDPATH= cd -- "$install_home/.local/share/agent-container" && pwd -P)
[ -L "$asset_root/current" ] || fail "current release is not a symlink"
release_link=$(readlink "$asset_root/current")
case "$release_link" in
  releases/*) ;;
  *) fail "current release target is outside releases: $release_link" ;;
esac
release_dir="$asset_root/$release_link"
for asset in "${ASSETS[@]}"; do
  [ -f "$release_dir/$asset" ] && [ ! -L "$release_dir/$asset" ] \
    || fail "release is missing regular asset $asset"
done
[ -f "$release_dir/release-manifest.sha256" ] \
  || fail "release does not retain its verified manifest"
release_launcher="$release_dir/agent-container-darwin-arm64"
[ -f "$release_launcher" ] \
  && [ ! -L "$release_launcher" ] \
  && [ -x "$release_launcher" ] \
  || fail "release launcher is not a regular executable"
[ "$(/usr/bin/file -b "$release_launcher")" = \
  'Mach-O 64-bit executable arm64' ] \
  || fail "release launcher is not a thin arm64 Mach-O"
/usr/bin/codesign --verify --strict "$release_launcher" >/dev/null 2>&1 \
  || fail "release launcher does not have a valid code signature"
launcher_identity=$(/usr/bin/stat -L -f '%d:%i' "$release_launcher")
for command_name in "${COMMANDS[@]}"; do
  release_command="$release_dir/$command_name"
  [ -L "$release_command" ] \
    || fail "$command_name is not a release alias"
  [ "$(readlink "$release_command")" = agent-container-darwin-arm64 ] \
    || fail "$command_name has the wrong release alias target"
  [ "$(/usr/bin/stat -L -f '%d:%i' "$release_command")" = \
    "$launcher_identity" ] \
    || fail "$command_name does not resolve to the shared launcher inode"
  cmp -s "$release_launcher" "$release_command" \
    || fail "$command_name does not resolve to the shared launcher content"

  command_path="$install_home/.local/bin/$command_name"
  [ -x "$command_path" ] || fail "$command_name is not executable"
  [ -L "$command_path" ] || fail "$command_name is not a stable symlink"
  [ "$(readlink "$command_path")" = "$asset_root/current/$command_name" ] \
    || fail "$command_name targets the wrong release root"
  [ "$(/usr/bin/stat -L -f '%d:%i' "$command_path")" = \
    "$launcher_identity" ] \
    || fail "$command_name does not resolve through current to the shared launcher"
done
release_count=$(find "$asset_root/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')
[ "$release_count" = 1 ] || fail "fresh install created multiple releases"

run_install "$source_v1" "$install_home" \
  > "$test_root/reinstall.out" 2> "$test_root/reinstall.err"
release_count=$(find "$asset_root/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')
[ "$release_count" = 1 ] || fail "identical reinstall did not reuse its release"

source_v2="$test_root/source-v2"
make_release_source "$source_v2"
printf '%s\n' '# second release' >> "$source_v2/Containerfile"
write_manifest "$source_v2"
run_install "$source_v2" "$install_home" \
  > "$test_root/upgrade.out" 2> "$test_root/upgrade.err"
new_release_link=$(readlink "$asset_root/current")
[ "$new_release_link" != "$release_link" ] \
  || fail "changed manifest did not switch current release"
[ -d "$release_dir" ] || fail "upgrade destroyed the previous immutable release"
release_count=$(find "$asset_root/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')
[ "$release_count" = 2 ] || fail "upgrade did not retain exactly two releases"
pass "one content-addressed release atomically carries every generic asset"

# A failure while publishing the fourth stable command restores all prior files
# and the previous current release.
rollback_home="$test_root/rollback-home"
mkdir -p "$rollback_home"
run_install "$source_v1" "$rollback_home" \
  > "$test_root/rollback-install.out" 2> "$test_root/rollback-install.err"
rollback_root=$(CDPATH= cd -- "$rollback_home/.local/share/agent-container" && pwd -P)
rollback_bin=$(CDPATH= cd -- "$rollback_home/.local/bin" && pwd -P)
rollback_old_link=$(readlink "$rollback_root/current")
rollback_old_release="$rollback_root/$rollback_old_link"
for command_name in "${COMMANDS[@]}"; do
  rm -f "$rollback_home/.local/bin/$command_name"
  cp "$rollback_old_release/$command_name" "$rollback_home/.local/bin/$command_name"
  chmod 0755 "$rollback_home/.local/bin/$command_name"
  cp "$rollback_home/.local/bin/$command_name" \
    "$test_root/rollback-before-$command_name"
done
rollback_once="$test_root/rollback-once"
if HOME="$rollback_home" \
  PATH="$fixture_path" \
  FAKE_MV_FAIL_DESTINATION="$rollback_bin/grok-container" \
  FAKE_MV_ONCE_MARKER="$rollback_once" \
  bash "$repo_root/install.sh" --base-url "file://$source_v2" \
  > "$test_root/rollback.out" 2> "$test_root/rollback.err"; then
  fail "late command publication failure was hidden"
fi
[ "$(readlink "$rollback_root/current")" = "$rollback_old_link" ] \
  || fail "late failure did not restore current"
for command_name in "${COMMANDS[@]}"; do
  [ ! -L "$rollback_home/.local/bin/$command_name" ] \
    && cmp -s "$test_root/rollback-before-$command_name" \
      "$rollback_home/.local/bin/$command_name" \
    || fail "late failure did not restore $command_name"
done
release_count=$(find "$rollback_root/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')
[ "$release_count" = 1 ] || fail "failed release survived rollback"
[ ! -e "$rollback_home/.local/share/.agent-container.install.lock" ] \
  || fail "transaction lock survived rollback"
pass "late four-command publication failure rolls back the whole install"

# A late failure while replacing the managed profile set restores commands
# removed earlier in the same transaction as well as the previous current link.
selection_rollback_home="$test_root/selection-rollback-home"
mkdir -p "$selection_rollback_home"
run_install "$source_v1" "$selection_rollback_home" \
  > "$test_root/selection-rollback-install.out" \
  2> "$test_root/selection-rollback-install.err"
selection_rollback_root=$(CDPATH= cd -- \
  "$selection_rollback_home/.local/share/agent-container" && pwd -P)
selection_rollback_bin=$(CDPATH= cd -- \
  "$selection_rollback_home/.local/bin" && pwd -P)
selection_rollback_link=$(readlink "$selection_rollback_root/current")
selection_rollback_release="$selection_rollback_root/$selection_rollback_link"
rm -f "$selection_rollback_bin/grok-container"
cp "$selection_rollback_release/grok-container" \
  "$selection_rollback_bin/grok-container"
chmod 0755 "$selection_rollback_bin/grok-container"
cp "$selection_rollback_bin/grok-container" \
  "$test_root/selection-rollback-grok-before"
selection_rollback_once="$test_root/selection-rollback-once"
if HOME="$selection_rollback_home" \
  PATH="$fixture_path" \
  FAKE_MV_FAIL_DESTINATION="$selection_rollback_bin/grok-container" \
  FAKE_MV_ONCE_MARKER="$selection_rollback_once" \
  bash "$repo_root/install.sh" --base-url "file://$source_v2" --profile grok \
  > "$test_root/selection-rollback.out" \
  2> "$test_root/selection-rollback.err"; then
  fail "late profile-set replacement failure was hidden"
fi
[ "$(readlink "$selection_rollback_root/current")" = "$selection_rollback_link" ] \
  || fail "profile-set rollback did not restore current"
for command_name in agent-container claude-container codex-container; do
  [ -L "$selection_rollback_bin/$command_name" ] \
    && [ "$(readlink "$selection_rollback_bin/$command_name")" = \
      "$selection_rollback_root/current/$command_name" ] \
    || fail "profile-set rollback did not restore $command_name"
done
[ ! -L "$selection_rollback_bin/grok-container" ] \
  && cmp -s "$test_root/selection-rollback-grok-before" \
    "$selection_rollback_bin/grok-container" \
  || fail "profile-set rollback did not restore regular grok-container"
release_count=$(find "$selection_rollback_root/releases" \
  -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')
[ "$release_count" = 1 ] \
  || fail "failed selective release survived profile-set rollback"
pass "late replacement failure restores removed managed profile commands"

# Unknown and special-file command collisions are never read or replaced.
collision_home="$test_root/collision-home"
mkdir -p "$collision_home/.local/bin"
printf '%s\n' 'echo user-owned command' \
  > "$collision_home/.local/bin/codex-container"
chmod 0755 "$collision_home/.local/bin/codex-container"
if run_install "$source_v1" "$collision_home" \
  > "$test_root/collision.out" 2> "$test_root/collision.err"; then
  fail "installer overwrote an unknown command"
fi
assert_contains "$collision_home/.local/bin/codex-container" 'echo user-owned command'
[ ! -e "$collision_home/.local/share/agent-container" ] \
  || fail "collision failure left a managed asset root"

fifo_home="$test_root/fifo-home"
mkdir -p "$fifo_home/.local/bin"
mkfifo "$fifo_home/.local/bin/grok-container"
if run_install "$source_v1" "$fifo_home" \
  > "$test_root/fifo.out" 2> "$test_root/fifo.err"; then
  fail "installer replaced a FIFO command"
fi
[ -p "$fifo_home/.local/bin/grok-container" ] \
  || fail "FIFO command collision was mutated"
pass "installer rejects unknown and special command collisions without reading them"

# Existing release files must stay regular and immutable.
release_symlink_home="$test_root/release-symlink-home"
mkdir -p "$release_symlink_home"
run_install "$source_v1" "$release_symlink_home" \
  > "$test_root/release-symlink-install.out" 2> "$test_root/release-symlink-install.err"
release_symlink_root="$release_symlink_home/.local/share/agent-container"
release_symlink_dir="$release_symlink_root/$(readlink "$release_symlink_root/current")"
rm -f "$release_symlink_dir/profiles/codex.json"
ln -s "$source_v1/profiles/codex.json" "$release_symlink_dir/profiles/codex.json"
if run_install "$source_v1" "$release_symlink_home" \
  > "$test_root/release-symlink.out" 2> "$test_root/release-symlink.err"; then
  fail "installer accepted a symlink inside an existing release"
fi
assert_contains "$test_root/release-symlink.err" 'Existing release is incomplete or modified'
[ -L "$release_symlink_dir/profiles/codex.json" ] \
  || fail "failed validation mutated the substituted release asset"

rm -f "$release_symlink_dir/profiles/codex.json"
cp "$source_v1/profiles/codex.json" \
  "$release_symlink_dir/profiles/codex.json"
rm -f "$release_symlink_dir/codex-container"
ln -s agent-container-runtime "$release_symlink_dir/codex-container"
if run_install "$source_v1" "$release_symlink_home" \
  > "$test_root/release-command-link.out" \
  2> "$test_root/release-command-link.err"; then
  fail "installer accepted a retargeted command alias in an existing release"
fi
assert_contains "$test_root/release-command-link.err" \
  'Existing release has an invalid command alias'
[ "$(readlink "$release_symlink_dir/codex-container")" = \
  agent-container-runtime ] \
  || fail "failed validation mutated the retargeted command alias"
pass "installer rejects modified assets and retargeted immutable command aliases"

# Two first installs serialize before adopting the asset root.
concurrent_home="$test_root/concurrent-home"
mkdir -p "$concurrent_home"
concurrent_home_physical=$(CDPATH= cd -- "$concurrent_home" && pwd -P)
concurrent_root="$concurrent_home_physical/.local/share/agent-container"
concurrent_pause="$test_root/concurrent-pause"
concurrent_gate="$test_root/concurrent-gate"
: > "$concurrent_gate"
HOME="$concurrent_home" \
  PATH="$fixture_path" \
  FAKE_MV_SLEEP_DESTINATION="$concurrent_root/current" \
  FAKE_MV_SLEEP_MARKER="$concurrent_pause" \
  FAKE_MV_WAIT_FILE="$concurrent_gate" \
  bash "$repo_root/install.sh" --base-url "file://$source_v1" \
  > "$test_root/concurrent-first.out" 2> "$test_root/concurrent-first.err" &
first_installer_pid=$!
wait_step=0
while [ "$wait_step" -lt 150 ]; do
  [ -e "$concurrent_pause" ] && break
  sleep 0.2
  wait_step=$((wait_step + 1))
done
[ -e "$concurrent_pause" ] || fail "first installer never reached publish pause"
set +e
run_install "$source_v1" "$concurrent_home" \
  > "$test_root/concurrent-second.out" 2> "$test_root/concurrent-second.err"
second_install_status=$?
set -e
rm -f "$concurrent_gate"
[ "$second_install_status" -ne 0 ] \
  || fail "concurrent installer stole the active transaction"
assert_contains "$test_root/concurrent-second.err" 'Another agent-container transaction is running'
wait "$first_installer_pid" || fail "winning concurrent installer failed"
[ -f "$concurrent_root/.agent-container-install-owned" ] \
  || fail "losing installer removed winning ownership marker"
printf '%s\n' 'trailing-marker-tamper' \
  >> "$concurrent_root/.agent-container-install-owned"
if run_install "$source_v1" "$concurrent_home" \
  > "$test_root/marker-reinstall.out" 2> "$test_root/marker-reinstall.err"; then
  fail "installer accepted an ownership marker with trailing content"
fi
assert_contains "$test_root/marker-reinstall.err" 'invalid ownership marker'
assert_install_intact "$concurrent_home"
pass "concurrent first installs share one fail-closed transaction lock"

# Default uninstall deletes every verified Apple image and installed release,
# while preserving the entire generic state tree.
uninstall_home="$test_root/uninstall-home"
mkdir -p "$uninstall_home"
run_install "$source_v1" "$uninstall_home" \
  > "$test_root/uninstall-install.out" 2> "$test_root/uninstall-install.err"
make_owned_state "$uninstall_home"
add_profile_state "$uninstall_home" claude 'agent-container-claude:latest'
add_profile_state "$uninstall_home" codex 'agent-container-codex:latest'
add_profile_state "$uninstall_home" grok 'agent-container-grok:latest'
uninstall_log="$test_root/uninstall-container.log"
: > "$uninstall_log"
run_uninstall "$uninstall_home" "$uninstall_log" \
  > "$test_root/uninstall.out" 2> "$test_root/uninstall.err"
for command_name in "${COMMANDS[@]}"; do
  [ ! -e "$uninstall_home/.local/bin/$command_name" ] \
    || fail "$command_name survived default uninstall"
done
[ ! -e "$uninstall_home/.local/share/agent-container" ] \
  || fail "installed assets survived default uninstall"
[ -d "$uninstall_home/.agent-container" ] \
  || fail "default uninstall removed Agent state"
delete_count=$(grep -c '^ARG=delete$' "$uninstall_log" || true)
[ "$delete_count" = 3 ] || fail "default uninstall did not delete all three profile images"
pass "default uninstall removes verified runtime/install assets and preserves all state"

# Explicit purge removes the one marked state root only after runtime cleanup.
purge_home="$test_root/purge-home"
mkdir -p "$purge_home"
run_install "$source_v1" "$purge_home" \
  > "$test_root/purge-install.out" 2> "$test_root/purge-install.err"
make_owned_state "$purge_home"
add_profile_state "$purge_home" claude 'agent-container-claude:latest'
purge_log="$test_root/purge-container.log"
: > "$purge_log"
run_uninstall "$purge_home" "$purge_log" --purge \
  > "$test_root/purge.out" 2> "$test_root/purge.err"
[ ! -e "$purge_home/.agent-container" ] \
  || fail "successful --purge retained marked Agent state"
[ ! -e "$purge_home/.local/share/agent-container" ] \
  || fail "successful --purge retained installed assets"
pass "--purge removes the whole marked state only after successful cleanup"

# A never-run installation has no runtime provenance to inspect. It remains
# removable before the Apple package is installed or its service is started.
code_only_home="$test_root/code-only-home"
mkdir -p "$code_only_home"
run_install "$source_v1" "$code_only_home" \
  > "$test_root/code-only-install.out" 2> "$test_root/code-only-install.err"
code_only_root="$code_only_home/.local/share/agent-container"
code_only_release="$code_only_root/$(readlink "$code_only_root/current")"
rm -f "$code_only_home/.local/bin/grok-container"
cp "$code_only_release/agent-container-darwin-arm64" \
  "$code_only_home/.local/bin/grok-container"
chmod 0755 "$code_only_home/.local/bin/grok-container"
HOME="$code_only_home" PATH="/usr/bin:/bin" \
  bash "$repo_root/uninstall.sh" \
    --container-bin definitely-missing-container \
  > "$test_root/code-only.out" 2> "$test_root/code-only.err"
[ ! -e "$code_only_home/.local/share/agent-container" ] \
  || fail "code-only uninstall required an unavailable Apple runtime"
for command_name in "${COMMANDS[@]}"; do
  [ ! -e "$code_only_home/.local/bin/$command_name" ] \
    || fail "code-only uninstall retained $command_name"
done
pass "never-run code/assets uninstall without Apple CLI or service"

# One mismatched profile blocks every mutation, including deletion of other
# profiles whose provenance was valid.
mismatch_home="$test_root/mismatch-home"
mkdir -p "$mismatch_home"
run_install "$source_v1" "$mismatch_home" \
  > "$test_root/mismatch-install.out" 2> "$test_root/mismatch-install.err"
make_owned_state "$mismatch_home"
add_profile_state "$mismatch_home" claude 'agent-container-claude:latest'
add_profile_state "$mismatch_home" codex 'agent-container-codex:latest'
add_profile_state "$mismatch_home" grok 'agent-container-grok:latest' "$(printf '%064d' 9)"
mismatch_log="$test_root/mismatch-container.log"
: > "$mismatch_log"
if run_uninstall "$mismatch_home" "$mismatch_log" --purge \
  > "$test_root/mismatch.out" 2> "$test_root/mismatch.err"; then
  fail "uninstaller accepted mismatched profile provenance"
fi
assert_contains "$test_root/mismatch.err" 'identity no longer matches recorded provenance'
assert_not_contains "$mismatch_log" 'ARG=delete'
assert_install_intact "$mismatch_home"
[ -d "$mismatch_home/.agent-container" ] \
  || fail "provenance mismatch removed Agent state"
pass "any profile identity mismatch aborts the entire uninstall pre-mutation"

# Incomplete provenance and transient inspection errors retain attribution.
incomplete_home="$test_root/incomplete-home"
mkdir -p "$incomplete_home"
run_install "$source_v1" "$incomplete_home" \
  > "$test_root/incomplete-install.out" 2> "$test_root/incomplete-install.err"
make_owned_state "$incomplete_home"
add_profile_state "$incomplete_home" claude 'agent-container-claude:latest'
rm -f "$incomplete_home/.agent-container/profiles/claude/meta/image-identity"
incomplete_log="$test_root/incomplete-container.log"
: > "$incomplete_log"
if run_uninstall "$incomplete_home" "$incomplete_log" --purge \
  > "$test_root/incomplete.out" 2> "$test_root/incomplete.err"; then
  fail "uninstaller accepted incomplete image provenance"
fi
assert_not_contains "$incomplete_log" 'ARG=delete'
assert_install_intact "$incomplete_home"
[ -d "$incomplete_home/.agent-container" ] \
  || fail "incomplete provenance removed state"

trailing_identity=$(default_inspect_identity 'agent-container-claude:latest')
printf '%s\n%s' "$trailing_identity" 'trailing-tamper-without-newline' \
  > "$incomplete_home/.agent-container/profiles/claude/meta/image-identity"
: > "$incomplete_log"
if run_uninstall "$incomplete_home" "$incomplete_log" --purge \
  > "$test_root/trailing.out" 2> "$test_root/trailing.err"; then
  fail "uninstaller ignored trailing bytes in image provenance"
fi
assert_not_contains "$incomplete_log" 'ARG=delete'
assert_install_intact "$incomplete_home"
[ -d "$incomplete_home/.agent-container" ] \
  || fail "trailing provenance bytes removed state"

inspect_home="$test_root/inspect-home"
mkdir -p "$inspect_home"
run_install "$source_v1" "$inspect_home" \
  > "$test_root/inspect-install.out" 2> "$test_root/inspect-install.err"
make_owned_state "$inspect_home"
add_profile_state "$inspect_home" claude 'agent-container-claude:latest'
inspect_log="$test_root/inspect-container.log"
: > "$inspect_log"
if HOME="$inspect_home" PATH="$fixture_path" \
  FAKE_CONTAINER_LOG="$inspect_log" \
  FAKE_IMAGE_INSPECT_FAIL_REF='agent-container-claude:latest' \
  bash "$repo_root/uninstall.sh" --purge --container-bin container \
  > "$test_root/inspect.out" 2> "$test_root/inspect.err"; then
  fail "uninstaller treated a transient inspect error as image absence"
fi
assert_not_contains "$inspect_log" 'ARG=delete'
assert_install_intact "$inspect_home"
[ -d "$inspect_home/.agent-container" ] \
  || fail "inspect failure removed provenance state"

: > "$inspect_log"
if HOME="$inspect_home" PATH="$fixture_path" \
  FAKE_CONTAINER_LOG="$inspect_log" \
  FAKE_IMAGE_EMPTY_REF='agent-container-claude:latest' \
  bash "$repo_root/uninstall.sh" --purge --container-bin container \
  > "$test_root/inspect-empty.out" 2> "$test_root/inspect-empty.err"; then
  fail "uninstaller accepted empty successful image-inspect output"
fi
assert_not_contains "$inspect_log" 'ARG=delete'
assert_install_intact "$inspect_home"
[ -d "$inspect_home/.agent-container" ] \
  || fail "empty inspect output removed provenance state"
pass "incomplete or transient image provenance fails closed and stays retryable"

# Native container discovery is independent of image metadata. A crash can
# leave a labeled container before the profile meta directory is created, and
# label corruption must not make a reserved singleton name safe to ignore.
missing_meta_home="$test_root/missing-meta-home"
mkdir -p "$missing_meta_home"
run_install "$source_v1" "$missing_meta_home" \
  > "$test_root/missing-meta-install.out" \
  2> "$test_root/missing-meta-install.err"
make_owned_state "$missing_meta_home"
mkdir -p "$missing_meta_home/.agent-container/profiles/claude/home"
missing_meta_log="$test_root/missing-meta-container.log"
: > "$missing_meta_log"
if HOME="$missing_meta_home" PATH="$fixture_path" \
  FAKE_CONTAINER_LOG="$missing_meta_log" \
  FAKE_ACTIVE_LABELED_CONTAINER=true \
  bash "$repo_root/uninstall.sh" --purge --container-bin container \
  > "$test_root/missing-meta.out" 2> "$test_root/missing-meta.err"; then
  fail "missing metadata bypassed a labeled native Agent container"
fi
assert_contains "$test_root/missing-meta.err" \
  'a stopped or running labeled Agent container still exists'
assert_contains "$missing_meta_log" 'ARG=--all'
assert_not_contains "$missing_meta_log" 'ARG=delete'
assert_install_intact "$missing_meta_home"
[ -d "$missing_meta_home/.agent-container" ] \
  || fail "labeled container with missing metadata lost Agent state"

empty_meta_home="$test_root/empty-meta-home"
mkdir -p "$empty_meta_home"
run_install "$source_v1" "$empty_meta_home" \
  > "$test_root/empty-meta-install.out" \
  2> "$test_root/empty-meta-install.err"
make_owned_state "$empty_meta_home"
mkdir -p "$empty_meta_home/.agent-container/profiles/grok/home" \
  "$empty_meta_home/.agent-container/profiles/grok/meta"
empty_meta_log="$test_root/empty-meta-container.log"
reserved_singleton="agent-grok-$(id -u)-singleton"
reserved_singleton_json=$(printf \
  '[{"id":"%s","configuration":{"id":"%s","labels":{}},"status":{"state":"running"}}]' \
  "$reserved_singleton" "$reserved_singleton")
: > "$empty_meta_log"
if HOME="$empty_meta_home" PATH="$fixture_path" \
  FAKE_CONTAINER_LOG="$empty_meta_log" \
  FAKE_CONTAINER_LIST_JSON="$reserved_singleton_json" \
  bash "$repo_root/uninstall.sh" --purge --container-bin container \
  > "$test_root/empty-meta.out" 2> "$test_root/empty-meta.err"; then
  fail "empty metadata bypassed a reserved singleton container name"
fi
assert_contains "$test_root/empty-meta.err" \
  'occupies a reserved Agent singleton name'
assert_contains "$empty_meta_log" 'ARG=--all'
assert_not_contains "$empty_meta_log" 'ARG=delete'
assert_install_intact "$empty_meta_home"
[ -d "$empty_meta_home/.agent-container" ] \
  || fail "reserved singleton with empty metadata lost Agent state"
pass "missing or empty image metadata cannot bypass native singleton discovery"

# An explicit Apple 'image not found' is the sole safe absence result.
missing_home="$test_root/missing-home"
mkdir -p "$missing_home"
run_install "$source_v1" "$missing_home" \
  > "$test_root/missing-install.out" 2> "$test_root/missing-install.err"
make_owned_state "$missing_home"
add_profile_state "$missing_home" claude 'agent-container-claude:latest'
missing_log="$test_root/missing-container.log"
: > "$missing_log"
HOME="$missing_home" PATH="$fixture_path" \
  FAKE_CONTAINER_LOG="$missing_log" \
  FAKE_IMAGE_MISSING_REF='agent-container-claude:latest' \
  bash "$repo_root/uninstall.sh" --purge --container-bin container \
  > "$test_root/missing.out" 2> "$test_root/missing.err"
assert_not_contains "$missing_log" 'ARG=delete'
[ ! -e "$missing_home/.agent-container" ] \
  || fail "explicitly absent image blocked safe purge"
pass "only explicit Apple image-not-found is accepted as safe absence"

# Retagging between global preflight and delete is caught by the immediate
# identity recheck; delete failures likewise retain all attribution.
retag_home="$test_root/retag-home"
mkdir -p "$retag_home"
run_install "$source_v1" "$retag_home" \
  > "$test_root/retag-install.out" 2> "$test_root/retag-install.err"
make_owned_state "$retag_home"
add_profile_state "$retag_home" claude 'agent-container-claude:latest'
retag_log="$test_root/retag-container.log"
retag_state="$test_root/retag-fixture-state"
: > "$retag_log"
if HOME="$retag_home" PATH="$fixture_path" \
  FAKE_CONTAINER_LOG="$retag_log" \
  FAKE_CONTAINER_STATE_DIR="$retag_state" \
  FAKE_IMAGE_RETAG_REF='agent-container-claude:latest' \
  bash "$repo_root/uninstall.sh" --purge --container-bin container \
  > "$test_root/retag.out" 2> "$test_root/retag.err"; then
  fail "uninstaller deleted a tag retargeted after preflight"
fi
assert_not_contains "$retag_log" 'ARG=delete'
assert_install_intact "$retag_home"
[ -d "$retag_home/.agent-container" ] \
  || fail "retag race removed provenance state"

delete_fail_home="$test_root/delete-fail-home"
mkdir -p "$delete_fail_home"
run_install "$source_v1" "$delete_fail_home" \
  > "$test_root/delete-fail-install.out" 2> "$test_root/delete-fail-install.err"
make_owned_state "$delete_fail_home"
add_profile_state "$delete_fail_home" claude 'agent-container-claude:latest'
delete_fail_log="$test_root/delete-fail-container.log"
: > "$delete_fail_log"
if HOME="$delete_fail_home" PATH="$fixture_path" \
  FAKE_CONTAINER_LOG="$delete_fail_log" \
  FAKE_IMAGE_DELETE_FAIL_REF='agent-container-claude:latest' \
  bash "$repo_root/uninstall.sh" --purge --container-bin container \
  > "$test_root/delete-fail.out" 2> "$test_root/delete-fail.err"; then
  fail "uninstaller hid an Apple image delete failure"
fi
assert_not_contains "$test_root/delete-fail.out" 'Removed Apple image: agent-container-claude:latest'
assert_install_intact "$delete_fail_home"
[ -d "$delete_fail_home/.agent-container" ] \
  || fail "delete failure removed retry provenance"
pass "retag races and delete failures never discard retry provenance"

# Global lock, concurrent session directories, and runtime labels each stop the
# whole uninstall before any destructive command.
for active_kind in global concurrent label pidless; do
  active_home="$test_root/active-$active_kind-home"
  mkdir -p "$active_home"
  run_install "$source_v1" "$active_home" \
    > "$test_root/active-$active_kind-install.out" \
    2> "$test_root/active-$active_kind-install.err"
  make_owned_state "$active_home"
  active_log="$test_root/active-$active_kind-container.log"
  : > "$active_log"
  active_label=false
  case "$active_kind" in
    global)
      mkdir -p "$active_home/.agent-container/session.lock"
      printf '%s\n' "$$" > "$active_home/.agent-container/session.lock/pid"
      printf '%s\n' claude > "$active_home/.agent-container/session.lock/profile"
      ;;
    concurrent)
      mkdir -p "$active_home/.agent-container/sessions/session-$$"
      printf '%s\n' "$$" > "$active_home/.agent-container/sessions/session-$$/pid"
      printf '%s\n' codex > "$active_home/.agent-container/sessions/session-$$/profile"
      ;;
    label)
      add_profile_state "$active_home" claude 'agent-container-claude:latest'
      active_label=true
      ;;
    pidless)
      mkdir -p "$active_home/.agent-container/session.lock"
      printf '%s\n' claude > "$active_home/.agent-container/session.lock/profile"
      ;;
  esac
  if env HOME="$active_home" PATH="$fixture_path" \
    FAKE_CONTAINER_LOG="$active_log" \
    FAKE_ACTIVE_LABELED_CONTAINER="$active_label" \
    bash "$repo_root/uninstall.sh" --purge --container-bin container \
    > "$test_root/active-$active_kind.out" \
    2> "$test_root/active-$active_kind.err"; then
    fail "$active_kind activity did not block uninstall"
  fi
  assert_not_contains "$active_log" 'ARG=delete'
  assert_install_intact "$active_home"
  [ -d "$active_home/.agent-container" ] \
    || fail "$active_kind activity removed Agent state"
  if [ "$active_kind" = label ]; then
    assert_contains "$active_log" 'ARG=--all'
  fi
done
pass "global, concurrent, stopped/running labeled, and indeterminate sessions abort all mutation"

# Runtime list/service failures are indeterminate, not equivalent to no
# stopped or running containers.
list_fail_home="$test_root/list-fail-home"
mkdir -p "$list_fail_home"
run_install "$source_v1" "$list_fail_home" \
  > "$test_root/list-fail-install.out" 2> "$test_root/list-fail-install.err"
make_owned_state "$list_fail_home"
add_profile_state "$list_fail_home" claude 'agent-container-claude:latest'
list_fail_log="$test_root/list-fail-container.log"
: > "$list_fail_log"
if HOME="$list_fail_home" PATH="$fixture_path" \
  FAKE_CONTAINER_LOG="$list_fail_log" FAKE_LIST_FAIL=true \
  bash "$repo_root/uninstall.sh" --container-bin container \
  > "$test_root/list-fail.out" 2> "$test_root/list-fail.err"; then
  fail "uninstaller treated container-list failure as an empty list"
fi
assert_install_intact "$list_fail_home"
[ -d "$list_fail_home/.agent-container" ] \
  || fail "list failure removed state"

: > "$list_fail_log"
if HOME="$list_fail_home" PATH="$fixture_path" \
  FAKE_CONTAINER_LOG="$list_fail_log" FAKE_LIST_INVALID_JSON=true \
  bash "$repo_root/uninstall.sh" --purge --container-bin container \
  > "$test_root/list-json.out" 2> "$test_root/list-json.err"; then
  fail "uninstaller accepted invalid container-list JSON"
fi
assert_not_contains "$list_fail_log" 'ARG=delete'
assert_install_intact "$list_fail_home"
[ -d "$list_fail_home/.agent-container" ] \
  || fail "invalid container-list JSON removed state"

printf '%s\n' 'trailing-marker-tamper' \
  >> "$list_fail_home/.agent-container/.agent-container-owned"
: > "$list_fail_log"
if run_uninstall "$list_fail_home" "$list_fail_log" --purge \
  > "$test_root/state-marker.out" 2> "$test_root/state-marker.err"; then
  fail "uninstaller accepted a state marker with trailing content"
fi
assert_not_contains "$list_fail_log" 'ARG=delete'
assert_install_intact "$list_fail_home"
[ -d "$list_fail_home/.agent-container" ] \
  || fail "invalid state marker removed state"
pass "Apple CLI/service/list unavailability fails closed before cleanup"

# Custom roots and final state symlinks cannot widen recursive removal.
overlap_home="$test_root/overlap-home"
mkdir -p "$overlap_home"
run_install "$source_v1" "$overlap_home" \
  > "$test_root/overlap-install.out" 2> "$test_root/overlap-install.err"
overlap_state="$overlap_home/.local/share/agent-container/persistent-state"
mkdir -p "$overlap_state"
printf '%s\n' 'managed by agent-container' > "$overlap_state/.agent-container-owned"
overlap_log="$test_root/overlap-container.log"
: > "$overlap_log"
if HOME="$overlap_home" PATH="$fixture_path" \
  AGENT_CONTAINER_STATE_DIR="$overlap_state" \
  FAKE_CONTAINER_LOG="$overlap_log" \
  bash "$repo_root/uninstall.sh" --purge --container-bin container \
  > "$test_root/overlap.out" 2> "$test_root/overlap.err"; then
  fail "uninstaller accepted a custom Agent state root"
fi
assert_install_intact "$overlap_home"
[ -d "$overlap_state" ] || fail "custom-root rejection removed state"
assert_contains "$test_root/overlap.err" \
  'AGENT_CONTAINER_STATE_DIR is unsupported; unset it'

symlink_home="$test_root/symlink-home"
outside_state="$test_root/outside-state"
mkdir -p "$symlink_home" "$outside_state"
run_install "$source_v1" "$symlink_home" \
  > "$test_root/symlink-install.out" 2> "$test_root/symlink-install.err"
printf '%s\n' 'managed by agent-container' > "$outside_state/.agent-container-owned"
ln -s "$outside_state" "$symlink_home/.agent-container"
symlink_log="$test_root/symlink-container.log"
: > "$symlink_log"
if run_uninstall "$symlink_home" "$symlink_log" --purge \
  > "$test_root/symlink.out" 2> "$test_root/symlink.err"; then
  fail "uninstaller accepted a symlink as recursive state root"
fi
assert_install_intact "$symlink_home"
[ -f "$outside_state/.agent-container-owned" ] \
  || fail "unsafe state symlink escaped recursive deletion"
pass "Agent state is fixed, canonical, marked, and non-symlinked"

# Installer and uninstaller use the same lock in both race directions.
race_home="$test_root/race-home"
mkdir -p "$race_home"
run_install "$source_v1" "$race_home" \
  > "$test_root/race-install.out" 2> "$test_root/race-install.err"
make_owned_state "$race_home"
add_profile_state "$race_home" claude 'agent-container-claude:latest'
race_log="$test_root/race-container.log"
race_pause="$test_root/race-pause"
race_gate="$test_root/race-gate"
: > "$race_log"
: > "$race_gate"
HOME="$race_home" PATH="$fixture_path" \
  FAKE_CONTAINER_LOG="$race_log" \
  FAKE_LIST_SLEEP_MARKER="$race_pause" FAKE_LIST_WAIT_FILE="$race_gate" \
  bash "$repo_root/uninstall.sh" --container-bin container \
  > "$test_root/race-uninstall.out" 2> "$test_root/race-uninstall.err" &
uninstaller_pid=$!
for wait_step in 1 2 3 4 5 6 7 8 9 10; do
  [ -e "$race_pause" ] && break
  sleep 0.2
done
[ -e "$race_pause" ] || fail "uninstaller never reached locked list preflight"
set +e
run_install "$source_v1" "$race_home" \
  > "$test_root/race-second.out" 2> "$test_root/race-second.err"
race_install_status=$?
set -e
rm -f "$race_gate"
[ "$race_install_status" -ne 0 ] \
  || fail "installer raced a lock-owning uninstaller"
assert_contains "$test_root/race-second.err" 'Another agent-container transaction is running'
wait "$uninstaller_pid" || fail "lock-owning uninstaller failed"
[ ! -e "$race_home/.local/share/agent-container" ] \
  || fail "racing install republished assets during uninstall"
pass "install and uninstall serialize on one bidirectional transaction lock"

# A launcher holds the same transaction lock while publishing its registration,
# so uninstall cannot acquire its transaction gate during that critical window.
lifecycle_home="$test_root/lifecycle-home"
mkdir -p "$lifecycle_home"
run_install "$source_v1" "$lifecycle_home" \
  > "$test_root/lifecycle-install.out" 2> "$test_root/lifecycle-install.err"
lifecycle_lock="$lifecycle_home/.local/share/.agent-container.install.lock"
mkdir "$lifecycle_lock"
printf '%s\n' "$$" > "$lifecycle_lock/pid"
if HOME="$lifecycle_home" PATH="/usr/bin:/bin" \
  bash "$repo_root/uninstall.sh" \
    --container-bin definitely-missing-container \
  > "$test_root/lifecycle.out" 2> "$test_root/lifecycle.err"; then
  fail "uninstaller ignored a lifecycle lock held by an Agent session"
fi
assert_contains "$test_root/lifecycle.err" 'Another agent-container transaction is running'
assert_install_intact "$lifecycle_home"
rm -f "$lifecycle_lock/pid"
rmdir "$lifecycle_lock"

# The directory record is diagnostic provenance; the canonical HOME inode is
# the non-replaceable mutex shared with launchers. Hold it without publishing a
# directory record and prove uninstall still stops before runtime mutation.
lifecycle_kernel_log="$test_root/lifecycle-kernel-container.log"
: > "$lifecycle_kernel_log"
exec 8< "$lifecycle_home"
/usr/bin/lockf -t 0 8 \
  || fail "test could not acquire the canonical HOME lifecycle lock"
set +e
(
  exec 8<&-
  run_uninstall "$lifecycle_home" "$lifecycle_kernel_log"
) > "$test_root/lifecycle-kernel.out" \
  2> "$test_root/lifecycle-kernel.err"
lifecycle_kernel_status=$?
set -e
exec 8<&-
[ "$lifecycle_kernel_status" -ne 0 ] \
  || fail "uninstaller bypassed a launcher-style HOME inode lock"
assert_contains "$test_root/lifecycle-kernel.err" \
  'Another agent-container transaction is running'
assert_install_intact "$lifecycle_home"
[ ! -s "$lifecycle_kernel_log" ] \
  || fail "HOME-lock rejection reached native runtime mutation"
pass "directory provenance and the shared HOME inode both close uninstall races"

# The native-only uninstaller never invokes Docker runtime management.
if rg -n 'docker (image|volume|info)|docker[[:space:]]+(image|volume)' \
  "$repo_root/uninstall.sh" > "$test_root/docker-runtime.matches"; then
  fail "uninstaller still contains Docker runtime management"
fi
pass "uninstaller contains no Docker image or volume management"

echo "1..$passes"
