#!/bin/bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
fixture_path="$repo_root/tests/install-fixtures:/usr/bin:/bin"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

ASSETS=(
  agent-container
  claude-container
  codex-container
  grok-container
  claude-docker
  Containerfile
  Containerfile.dockerignore
  entrypoint.sh
  profiles/claude.json
  profiles/codex.json
  profiles/grok.json
)
COMMANDS=(
  agent-container
  claude-container
  codex-container
  grok-container
  claude-docker
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
  write_manifest "$source_root"
}

run_install() {
  local source_root="$1"
  local case_home="$2"
  HOME="$case_home" \
    PATH="$fixture_path" \
    AGENT_CONTAINER_INSTALL_BASE_URL="file://$source_root" \
    bash "$repo_root/install.sh"
}

run_uninstall() {
  local case_home="$1"
  local container_log="$2"
  shift 2
  HOME="$case_home" \
    PATH="$fixture_path" \
    AGENT_CONTAINER_BIN=container \
    FAKE_CONTAINER_LOG="$container_log" \
    bash "$repo_root/uninstall.sh" "$@"
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

# Platform checks happen before even a release-manifest fetch.
for platform_case in non_darwin non_arm64 old_macos; do
  platform_home="$test_root/platform-$platform_case-home"
  mkdir -p "$platform_home"
  platform_err="$test_root/platform-$platform_case.err"
  case "$platform_case" in
    non_darwin)
      if HOME="$platform_home" PATH="$fixture_path" \
        FAKE_UNAME_SYSTEM=Linux \
        AGENT_CONTAINER_INSTALL_BASE_URL='file:///does-not-exist' \
        bash "$repo_root/install.sh" > /dev/null 2> "$platform_err"; then
        fail "installer accepted a non-macOS host"
      fi
      assert_contains "$platform_err" 'supported only on macOS'
      ;;
    non_arm64)
      if HOME="$platform_home" PATH="$fixture_path" \
        FAKE_UNAME_MACHINE=x86_64 \
        AGENT_CONTAINER_INSTALL_BASE_URL='file:///does-not-exist' \
        bash "$repo_root/install.sh" > /dev/null 2> "$platform_err"; then
        fail "installer accepted a non-Apple-silicon host"
      fi
      assert_contains "$platform_err" 'requires Apple silicon'
      ;;
    old_macos)
      if HOME="$platform_home" PATH="$fixture_path" \
        FAKE_MACOS_VERSION=15.6 \
        AGENT_CONTAINER_INSTALL_BASE_URL='file:///does-not-exist' \
        bash "$repo_root/install.sh" > /dev/null 2> "$platform_err"; then
        fail "installer accepted macOS older than 26"
      fi
      assert_contains "$platform_err" 'macOS 26 or newer'
      ;;
  esac
  [ ! -e "$platform_home/.local" ] \
    || fail "platform rejection mutated the install home"
done
pass "installer rejects unsupported hosts before downloads or install mutation"

# The manifest is an allowlist as well as a mixed-release integrity boundary.
manifest_home="$test_root/manifest-home"
manifest_source="$test_root/manifest-source"
mkdir -p "$manifest_home"
make_release_source "$manifest_source"
printf '%s\n' '# tampered after manifest publication' \
  >> "$manifest_source/entrypoint.sh"
if run_install "$manifest_source" "$manifest_home" \
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
for command_name in "${COMMANDS[@]}"; do
  command_path="$install_home/.local/bin/$command_name"
  [ -x "$command_path" ] || fail "$command_name is not executable"
  [ -L "$command_path" ] || fail "$command_name is not a stable symlink"
  [ "$(readlink "$command_path")" = "$asset_root/current/$command_name" ] \
    || fail "$command_name targets the wrong release root"
done
for wrapper_name in claude-container codex-container grok-container claude-docker; do
  [ -x "$(dirname -- "$(readlink "$install_home/.local/bin/$wrapper_name")")/agent-container" ] \
    || fail "$wrapper_name cannot find sibling agent-container"
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

# A failure while publishing the fifth stable command restores all prior files
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
  AGENT_CONTAINER_INSTALL_BASE_URL="file://$source_v2" \
  FAKE_MV_FAIL_DESTINATION="$rollback_bin/claude-docker" \
  FAKE_MV_ONCE_MARKER="$rollback_once" \
  bash "$repo_root/install.sh" \
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
pass "late five-command publication failure rolls back the whole install"

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
pass "installer rejects modified or symlink-substituted immutable releases"

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
  AGENT_CONTAINER_INSTALL_BASE_URL="file://$source_v1" \
  FAKE_MV_SLEEP_DESTINATION="$concurrent_root/current" \
  FAKE_MV_SLEEP_MARKER="$concurrent_pause" \
  FAKE_MV_WAIT_FILE="$concurrent_gate" \
  bash "$repo_root/install.sh" \
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
HOME="$code_only_home" PATH="/usr/bin:/bin" \
  AGENT_CONTAINER_BIN=definitely-missing-container \
  bash "$repo_root/uninstall.sh" \
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
if HOME="$inspect_home" PATH="$fixture_path" AGENT_CONTAINER_BIN=container \
  FAKE_CONTAINER_LOG="$inspect_log" \
  FAKE_IMAGE_INSPECT_FAIL_REF='agent-container-claude:latest' \
  bash "$repo_root/uninstall.sh" --purge \
  > "$test_root/inspect.out" 2> "$test_root/inspect.err"; then
  fail "uninstaller treated a transient inspect error as image absence"
fi
assert_not_contains "$inspect_log" 'ARG=delete'
assert_install_intact "$inspect_home"
[ -d "$inspect_home/.agent-container" ] \
  || fail "inspect failure removed provenance state"

: > "$inspect_log"
if HOME="$inspect_home" PATH="$fixture_path" AGENT_CONTAINER_BIN=container \
  FAKE_CONTAINER_LOG="$inspect_log" \
  FAKE_IMAGE_EMPTY_REF='agent-container-claude:latest' \
  bash "$repo_root/uninstall.sh" --purge \
  > "$test_root/inspect-empty.out" 2> "$test_root/inspect-empty.err"; then
  fail "uninstaller accepted empty successful image-inspect output"
fi
assert_not_contains "$inspect_log" 'ARG=delete'
assert_install_intact "$inspect_home"
[ -d "$inspect_home/.agent-container" ] \
  || fail "empty inspect output removed provenance state"
pass "incomplete or transient image provenance fails closed and stays retryable"

# An explicit Apple 'image not found' is the sole safe absence result.
missing_home="$test_root/missing-home"
mkdir -p "$missing_home"
run_install "$source_v1" "$missing_home" \
  > "$test_root/missing-install.out" 2> "$test_root/missing-install.err"
make_owned_state "$missing_home"
add_profile_state "$missing_home" claude 'agent-container-claude:latest'
missing_log="$test_root/missing-container.log"
: > "$missing_log"
HOME="$missing_home" PATH="$fixture_path" AGENT_CONTAINER_BIN=container \
  FAKE_CONTAINER_LOG="$missing_log" \
  FAKE_IMAGE_MISSING_REF='agent-container-claude:latest' \
  bash "$repo_root/uninstall.sh" --purge \
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
if HOME="$retag_home" PATH="$fixture_path" AGENT_CONTAINER_BIN=container \
  FAKE_CONTAINER_LOG="$retag_log" \
  FAKE_CONTAINER_STATE_DIR="$retag_state" \
  FAKE_IMAGE_RETAG_REF='agent-container-claude:latest' \
  bash "$repo_root/uninstall.sh" --purge \
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
if HOME="$delete_fail_home" PATH="$fixture_path" AGENT_CONTAINER_BIN=container \
  FAKE_CONTAINER_LOG="$delete_fail_log" \
  FAKE_IMAGE_DELETE_FAIL_REF='agent-container-claude:latest' \
  bash "$repo_root/uninstall.sh" --purge \
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
  if env HOME="$active_home" PATH="$fixture_path" AGENT_CONTAINER_BIN=container \
    FAKE_CONTAINER_LOG="$active_log" \
    FAKE_ACTIVE_LABELED_CONTAINER="$active_label" \
    bash "$repo_root/uninstall.sh" --purge \
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
if HOME="$list_fail_home" PATH="$fixture_path" AGENT_CONTAINER_BIN=container \
  FAKE_CONTAINER_LOG="$list_fail_log" FAKE_LIST_FAIL=true \
  bash "$repo_root/uninstall.sh" \
  > "$test_root/list-fail.out" 2> "$test_root/list-fail.err"; then
  fail "uninstaller treated container-list failure as an empty list"
fi
assert_install_intact "$list_fail_home"
[ -d "$list_fail_home/.agent-container" ] \
  || fail "list failure removed state"

: > "$list_fail_log"
if HOME="$list_fail_home" PATH="$fixture_path" AGENT_CONTAINER_BIN=container \
  FAKE_CONTAINER_LOG="$list_fail_log" FAKE_LIST_INVALID_JSON=true \
  bash "$repo_root/uninstall.sh" --purge \
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
if HOME="$overlap_home" PATH="$fixture_path" AGENT_CONTAINER_BIN=container \
  AGENT_CONTAINER_STATE_DIR="$overlap_state" \
  FAKE_CONTAINER_LOG="$overlap_log" \
  bash "$repo_root/uninstall.sh" --purge \
  > "$test_root/overlap.out" 2> "$test_root/overlap.err"; then
  fail "uninstaller accepted a custom Agent state root"
fi
assert_install_intact "$overlap_home"
[ -d "$overlap_state" ] || fail "custom-root rejection removed state"
assert_contains "$test_root/overlap.err" 'Custom AGENT_CONTAINER_STATE_DIR is unsupported'

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
HOME="$race_home" PATH="$fixture_path" AGENT_CONTAINER_BIN=container \
  FAKE_CONTAINER_LOG="$race_log" \
  FAKE_LIST_SLEEP_MARKER="$race_pause" FAKE_LIST_WAIT_FILE="$race_gate" \
  bash "$repo_root/uninstall.sh" \
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
  AGENT_CONTAINER_BIN=definitely-missing-container \
  bash "$repo_root/uninstall.sh" \
  > "$test_root/lifecycle.out" 2> "$test_root/lifecycle.err"; then
  fail "uninstaller ignored a lifecycle lock held by an Agent session"
fi
assert_contains "$test_root/lifecycle.err" 'Another agent-container transaction is running'
assert_install_intact "$lifecycle_home"
rm -f "$lifecycle_lock/pid"
rmdir "$lifecycle_lock"
pass "shared registration gate closes launcher/uninstaller start races"

# The native-only uninstaller never invokes Docker runtime management.
if rg -n 'docker (image|volume|info)|docker[[:space:]]+(image|volume)' \
  "$repo_root/uninstall.sh" > "$test_root/docker-runtime.matches"; then
  fail "uninstaller still contains Docker runtime management"
fi
pass "uninstaller contains no Docker image or volume management"

echo "1..$passes"
