#!/bin/bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
fixture_dir="$repo_root/tests/fixtures"
test_root=$(mktemp -d)
test_root=$(CDPATH= cd -- "$test_root" && pwd -P)
tests_run=0
background_pid=""

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  set +e
  if [ -n "$background_pid" ] && kill -0 "$background_pid" 2>/dev/null; then
    kill -TERM "$background_pid" 2>/dev/null
    wait "$background_pid" 2>/dev/null
  fi
  rm -rf -- "$test_root"
  exit "$status"
}
trap cleanup EXIT

fail() {
  echo "not ok $tests_run - $*" >&2
  exit 1
}

pass() {
  echo "ok $tests_run - $*"
}

assert_line() {
  local file="$1"
  local expected="$2"
  grep -Fqx -- "$expected" "$file" \
    || fail "expected exact line '$expected' in $file"
}

assert_no_line() {
  local file="$1"
  local unexpected="$2"
  if grep -Fqx -- "$unexpected" "$file"; then
    fail "did not expect exact line '$unexpected' in $file"
  fi
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" \
    || fail "expected '$expected' in $file"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "did not expect '$unexpected' in $file"
  fi
}

assert_secret_absent() {
  local file="$1"
  local secret_value="$2"
  local secret_name="$3"
  if grep -Fq -- "$secret_value" "$file"; then
    fail "$secret_name value was recorded in $file"
  fi
}

command_arguments() {
  local file="$1"
  local command_name="$2"
  awk -v marker="ARG=$command_name" '
    $0 == "CALL" {
      if (capture) exit
      next
    }
    !found && $0 == marker {
      capture = 1
      found = 1
      next
    }
    capture && /^ARG=/ { print }
  ' "$file"
}

reset_case_environment() {
  unset \
    AGENT_CONTAINER_ACCEPT_VIRTIOFS_RISK \
    AGENT_CONTAINER_ALLOW_CONCURRENT \
    AGENT_CONTAINER_ENABLE_EXPERIMENTAL \
    AGENT_CONTAINER_FORWARD_API_KEY \
    AGENT_CONTAINER_FORWARD_SSH_AGENT \
    AGENT_CONTAINER_FULL_GIT_CONFIG \
    AGENT_CONTAINER_HOST_BROKER_BIN \
    AGENT_CONTAINER_HOST_NODE_BIN \
    AGENT_CONTAINER_HTTP_PROXY \
    AGENT_CONTAINER_IMAGE \
    AGENT_CONTAINER_HTTPS_PROXY \
    AGENT_CONTAINER_ALL_PROXY \
    AGENT_CONTAINER_NO_PROXY \
    AGENT_CONTAINER_DNS1 \
    AGENT_CONTAINER_DNS2 \
    AGENT_CONTAINER_TZ \
    AGENT_CONTAINER_VERSION \
    AGENT_CONTAINER_FD_STOP_PERCENT \
    AGENT_CONTAINER_MAX_FILES \
    AGENT_CONTAINER_MOUNT_GH \
    AGENT_CONTAINER_MOUNT_SSH_CONFIG \
    ANTHROPIC_API_KEY \
    OPENAI_API_KEY \
    XAI_API_KEY \
    SSH_AUTH_SOCK \
    FAKE_BUILD_FAIL \
    FAKE_CAPTURE_GITCONFIG \
    FAKE_CAPTURE_HOST_STAGE_DIR \
    FAKE_CAPTURE_SSH_DIR \
    FAKE_CREATE_STARTED \
    FAKE_CREATE_FOREIGN_AFTER_SUCCESS \
    FAKE_CREATE_FOREIGN_COLLISION \
    FAKE_CONTAINER_VERSION \
    FAKE_CONTAINER_LIST_JSON \
    FAKE_CONTAINER_LIST_STATE \
    FAKE_CONTAINER_DELETE_ABSENT_RACE \
    FAKE_CONTAINER_DELETE_FAIL \
    FAKE_CONTAINER_INSPECT_OUTPUT \
    FAKE_IMAGE_INSPECT_OUTPUT \
    FAKE_IMAGE_PRESENT \
    FAKE_CLAUDE_LATEST_VERSION \
    FAKE_CODEX_LATEST_TAG \
    FAKE_GROK_LATEST_VERSION \
    FAKE_VERSION_LOOKUP_FAIL \
    FAKE_VERSION_RESPONSE_OVERRIDE \
    FAKE_POST_START_INSPECT_MODE \
    FAKE_RETAG_AFTER_INSPECT \
    FAKE_READ_STDIN \
    FAKE_RUN_OUTPUT \
    FAKE_RUN_SLEEP \
    FAKE_RUN_STATUS \
    FAKE_START_FAIL \
    FAKE_SYSTEM_RUNNING \
    TEST_RUNNER_PATH \
    2>/dev/null || true
}

new_case() {
  local name="$1"
  reset_case_environment
  case_dir="$test_root/$name"
  case_home="$case_dir/home"
  case_workspace="$case_dir/workspace"
  case_log="$case_dir/container.log"
  case_curl_log="$case_dir/curl.log"
  case_asset_dir="$repo_root"
  mkdir -p "$case_home" "$case_workspace"
  : > "$case_log"
  : > "$case_curl_log"
}

copy_case_assets() {
  case_asset_dir="$case_dir/assets"
  mkdir -p "$case_asset_dir/profiles"
  cp \
    "$repo_root/Containerfile" \
    "$repo_root/Containerfile.dockerignore" \
    "$repo_root/entrypoint.sh" \
    "$repo_root/host-exec-broker.mjs" \
    "$repo_root/host-exec-client" \
    "$case_asset_dir/"
  cp "$repo_root"/profiles/*.json "$case_asset_dir/profiles/"
}

launch_exec() {
  local program="$1"
  shift
  local -a runner_env

  runner_env=(
    "HOME=$case_home"
    "PATH=${TEST_RUNNER_PATH:-$fixture_dir:/usr/bin:/bin}"
    "LANG=C"
    "TERM=xterm-256color"
    "AGENT_CONTAINER_BIN=$fixture_dir/container"
    "AGENT_CONTAINER_ASSET_DIR=$case_asset_dir"
    "AGENT_CONTAINER_DISABLE_FD_WATCHDOG=true"
    "AGENT_CONTAINER_ACCEPT_VIRTIOFS_RISK=${AGENT_CONTAINER_ACCEPT_VIRTIOFS_RISK:-false}"
    "AGENT_CONTAINER_ALLOW_CONCURRENT=${AGENT_CONTAINER_ALLOW_CONCURRENT:-false}"
    "AGENT_CONTAINER_ENABLE_EXPERIMENTAL=${AGENT_CONTAINER_ENABLE_EXPERIMENTAL:-false}"
    "AGENT_CONTAINER_FORWARD_API_KEY=${AGENT_CONTAINER_FORWARD_API_KEY:-false}"
    "AGENT_CONTAINER_FORWARD_SSH_AGENT=${AGENT_CONTAINER_FORWARD_SSH_AGENT:-false}"
    "AGENT_CONTAINER_FULL_GIT_CONFIG=${AGENT_CONTAINER_FULL_GIT_CONFIG:-false}"
    "AGENT_CONTAINER_HOST_BROKER_BIN=${AGENT_CONTAINER_HOST_BROKER_BIN:-}"
    "AGENT_CONTAINER_HOST_NODE_BIN=${AGENT_CONTAINER_HOST_NODE_BIN:-}"
    "AGENT_CONTAINER_HTTP_PROXY=${AGENT_CONTAINER_HTTP_PROXY:-}"
    "AGENT_CONTAINER_IMAGE=${AGENT_CONTAINER_IMAGE:-}"
    "AGENT_CONTAINER_HTTPS_PROXY=${AGENT_CONTAINER_HTTPS_PROXY:-}"
    "AGENT_CONTAINER_ALL_PROXY=${AGENT_CONTAINER_ALL_PROXY:-}"
    "AGENT_CONTAINER_NO_PROXY=${AGENT_CONTAINER_NO_PROXY:-}"
    "AGENT_CONTAINER_DNS1=${AGENT_CONTAINER_DNS1:-}"
    "AGENT_CONTAINER_DNS2=${AGENT_CONTAINER_DNS2:-}"
    "AGENT_CONTAINER_TZ=${AGENT_CONTAINER_TZ:-}"
    "AGENT_CONTAINER_VERSION=${AGENT_CONTAINER_VERSION:-}"
    "AGENT_CONTAINER_FD_STOP_PERCENT=${AGENT_CONTAINER_FD_STOP_PERCENT:-80}"
    "AGENT_CONTAINER_MAX_FILES=${AGENT_CONTAINER_MAX_FILES:-40000}"
    "AGENT_CONTAINER_MOUNT_GH=${AGENT_CONTAINER_MOUNT_GH:-false}"
    "AGENT_CONTAINER_MOUNT_SSH_CONFIG=${AGENT_CONTAINER_MOUNT_SSH_CONFIG:-false}"
    "FAKE_BUILD_FAIL=${FAKE_BUILD_FAIL:-false}"
    "FAKE_CAPTURE_GITCONFIG=${FAKE_CAPTURE_GITCONFIG:-}"
    "FAKE_CAPTURE_HOST_STAGE_DIR=${FAKE_CAPTURE_HOST_STAGE_DIR:-}"
    "FAKE_CAPTURE_SSH_DIR=${FAKE_CAPTURE_SSH_DIR:-}"
    "FAKE_CREATE_STARTED=${FAKE_CREATE_STARTED:-false}"
    "FAKE_CREATE_FOREIGN_AFTER_SUCCESS=${FAKE_CREATE_FOREIGN_AFTER_SUCCESS:-false}"
    "FAKE_CREATE_FOREIGN_COLLISION=${FAKE_CREATE_FOREIGN_COLLISION:-false}"
    "FAKE_CONTAINER_LOG=$case_log"
    "FAKE_CONTAINER_LIST_JSON=${FAKE_CONTAINER_LIST_JSON:-[]}"
    "FAKE_CONTAINER_LIST_STATE=${FAKE_CONTAINER_LIST_STATE:-}"
    "FAKE_CONTAINER_DELETE_ABSENT_RACE=${FAKE_CONTAINER_DELETE_ABSENT_RACE:-false}"
    "FAKE_CONTAINER_DELETE_FAIL=${FAKE_CONTAINER_DELETE_FAIL:-false}"
    "FAKE_CONTAINER_INSPECT_OUTPUT=${FAKE_CONTAINER_INSPECT_OUTPUT:-}"
    "FAKE_CREATED_CONTAINER_STATE=$case_home/fake-created-container.json"
    "FAKE_CURL_LOG=$case_curl_log"
    "FAKE_CONTAINER_VERSION=${FAKE_CONTAINER_VERSION:-1.2.0}"
    "FAKE_IMAGE_INSPECT_OUTPUT=${FAKE_IMAGE_INSPECT_OUTPUT:-}"
    "FAKE_IMAGE_PRESENT=${FAKE_IMAGE_PRESENT:-false}"
    "FAKE_IMAGE_STATE_DIR=$case_home/fake-images"
    "FAKE_CLAUDE_LATEST_VERSION=${FAKE_CLAUDE_LATEST_VERSION:-2.1.220}"
    "FAKE_CODEX_LATEST_TAG=${FAKE_CODEX_LATEST_TAG:-rust-v0.146.0}"
    "FAKE_GROK_LATEST_VERSION=${FAKE_GROK_LATEST_VERSION:-0.2.114}"
    "FAKE_VERSION_LOOKUP_FAIL=${FAKE_VERSION_LOOKUP_FAIL:-false}"
    "FAKE_VERSION_RESPONSE_OVERRIDE=${FAKE_VERSION_RESPONSE_OVERRIDE:-}"
    "FAKE_POST_START_INSPECT_MODE=${FAKE_POST_START_INSPECT_MODE:-}"
    "FAKE_RETAG_AFTER_INSPECT=${FAKE_RETAG_AFTER_INSPECT:-false}"
    "FAKE_READ_STDIN=${FAKE_READ_STDIN:-false}"
    "FAKE_RUN_OUTPUT=${FAKE_RUN_OUTPUT:-}"
    "FAKE_RUN_SLEEP=${FAKE_RUN_SLEEP:-}"
    "FAKE_RUN_STATUS=${FAKE_RUN_STATUS:-0}"
    "FAKE_START_FAIL=${FAKE_START_FAIL:-false}"
    "FAKE_SYSTEM_RUNNING=${FAKE_SYSTEM_RUNNING:-true}"
  )

  if [ -n "${ANTHROPIC_API_KEY+x}" ]; then
    runner_env+=("ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
  fi
  if [ -n "${OPENAI_API_KEY+x}" ]; then
    runner_env+=("OPENAI_API_KEY=$OPENAI_API_KEY")
  fi
  if [ -n "${XAI_API_KEY+x}" ]; then
    runner_env+=("XAI_API_KEY=$XAI_API_KEY")
  fi
  if [ -n "${SSH_AUTH_SOCK+x}" ]; then
    runner_env+=("SSH_AUTH_SOCK=$SSH_AUTH_SOCK")
  fi

  cd "$case_workspace"
  exec /usr/bin/env -i "${runner_env[@]}" /bin/bash "$program" "$@"
}

run_program() {
  (launch_exec "$@")
}

valid_fingerprint() {
  local value="$1"
  [ "${#value}" -eq 64 ] || return 1
  case "$value" in
    *[!0-9a-f]*) return 1 ;;
  esac
}

assert_native_installer_build_args() {
  local file="$1"
  local profile="$2"
  local installer_url="$3"
  local installer_shell="$4"
  local version_env="$5"
  local bin_dir_env="$6"
  local home_env="$7"
  local noninteractive_env="$8"
  local version="$9"
  local command="${10}"

  assert_line "$file" "ARG=AGENT_PROFILE=$profile"
  assert_line "$file" "ARG=AGENT_INSTALLER_URL=$installer_url"
  assert_line "$file" "ARG=AGENT_INSTALLER_SHELL=$installer_shell"
  assert_line "$file" "ARG=AGENT_INSTALLER_VERSION_ENV=$version_env"
  assert_line "$file" "ARG=AGENT_INSTALLER_BIN_DIR_ENV=$bin_dir_env"
  assert_line "$file" "ARG=AGENT_INSTALLER_HOME_ENV=$home_env"
  assert_line "$file" "ARG=AGENT_INSTALLER_NONINTERACTIVE_ENV=$noninteractive_env"
  assert_line "$file" "ARG=AGENT_VERSION=$version"
  assert_line "$file" "ARG=AGENT_COMMAND=$command"
  assert_line "$file" "ARG=--progress"
  assert_line "$file" "ARG=plain"
  assert_not_contains "$file" "AGENT_PACKAGE="
}

tests_run=$((tests_run + 1))
new_case profiles_list
run_program "$repo_root/agent-container" profiles \
  >"$case_dir/out" 2>"$case_dir/err"
grep -Eq '^claude[[:space:]]+preview[[:space:]]+Claude Code$' "$case_dir/out" \
  || fail "profiles did not list preview Claude"
grep -Eq '^codex[[:space:]]+preview[[:space:]]+Codex CLI$' "$case_dir/out" \
  || fail "profiles did not list preview Codex"
grep -Eq '^grok[[:space:]]+experimental[[:space:]]+Grok CLI$' "$case_dir/out" \
  || fail "profiles did not identify experimental Grok"
[ ! -s "$case_log" ] || fail "profile listing contacted the Apple runtime"
pass "profiles are listed from validated declarative metadata"

tests_run=$((tests_run + 1))
new_case unknown_profile
if run_program "$repo_root/agent-container" unknown-agent \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "unknown profile should be rejected"
fi
assert_contains "$case_dir/err" "Unknown or unsafe Agent profile 'unknown-agent'"
[ ! -s "$case_log" ] || fail "unknown profile contacted the Apple runtime"
pass "unknown profiles fail before runtime startup"

tests_run=$((tests_run + 1))
new_case oversized_profile_id
oversized_profile_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
if run_program "$repo_root/agent-container" "$oversized_profile_id" \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "an oversized profile id should be rejected"
fi
assert_contains "$case_dir/err" "Invalid profile id"
[ ! -e "$case_home/.agent-container" ] \
  || fail "oversized profile rejection occurred after state mutation"
[ ! -s "$case_log" ] || fail "oversized profile contacted the Apple runtime"
pass "profile ids stay within Apple container name limits"

tests_run=$((tests_run + 1))
new_case malformed_profile
copy_case_assets
printf '%s\n' '{"schema": 2, "id": "broken"' \
  > "$case_asset_dir/profiles/broken.json"
if run_program "$repo_root/agent-container" broken \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "malformed profile JSON should be rejected"
fi
assert_contains "$case_dir/err" "Agent profile 'broken' is not valid schema-2 JSON"
[ ! -s "$case_log" ] || fail "malformed profile contacted the Apple runtime"
pass "malformed profile JSON fails closed"

tests_run=$((tests_run + 1))
new_case unsupported_schema
copy_case_assets
sed 's/"schema": 2/"schema": 3/' "$repo_root/profiles/claude.json" \
  > "$case_asset_dir/profiles/schema.json"
sed 's/"id": "claude"/"id": "schema"/' \
  "$case_asset_dir/profiles/schema.json" > "$case_dir/schema-fixed-id.json"
mv "$case_dir/schema-fixed-id.json" "$case_asset_dir/profiles/schema.json"
if run_program "$repo_root/agent-container" schema \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "unsupported profile schema should be rejected"
fi
assert_contains "$case_dir/err" "Unsupported schema '3' in profile 'schema'"
[ ! -s "$case_log" ] || fail "unsupported schema contacted the Apple runtime"
pass "profile schema versions are enforced"

tests_run=$((tests_run + 1))
new_case mismatched_profile_id
copy_case_assets
cp "$repo_root/profiles/claude.json" "$case_asset_dir/profiles/alias.json"
if run_program "$repo_root/agent-container" alias \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "profile id/filename mismatch should be rejected"
fi
assert_contains "$case_dir/err" "does not match filename 'alias.json'"
[ ! -s "$case_log" ] || fail "mismatched profile id contacted the Apple runtime"
pass "profile identity is bound to its filename"

tests_run=$((tests_run + 1))
new_case empty_profile_field
copy_case_assets
{
  printf '%s\n' '{'
  printf '%s\n' '  "schema": 2,'
  printf '%s\n' '  "id": "envsplit",'
  printf '%s\n' '  "displayName": "Environment Split",'
  printf '%s\n' '  "status": "stable",'
  printf '%s\n' '  "installerKind": "native-script",'
  printf '%s\n' '  "installerUrl": "https://example.test/install.sh",'
  printf '%s\n' '  "installerShell": "sh",'
  printf '%s\n' '  "installerVersionUrl": "https://example.test/latest",'
  printf '%s\n' '  "installerVersionFormat": "plain-semver",'
  printf '%s\n' '  "installerVersionEnv": "",'
  printf '%s\n' '  "installerBinDirEnv": "",'
  printf '%s\n' '  "installerHomeEnv": "",'
  printf '%s\n' '  "installerNonInteractiveEnv": "",'
  printf '%s\n' '  "version": "1.0.0",'
  printf '%s\n' '  "command": "example-agent",'
  printf '%s\n' '  "probeArg": "--version",'
  printf '%s\n' '  "apiKeyEnv": "",'
  printf '%s\n' '  "disableAutoUpdateEnv": "NO_UPDATE"'
  printf '%s\n' '}'
} > "$case_asset_dir/profiles/envsplit.json"
if ! run_program "$repo_root/agent-container" envsplit --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "profile with an empty API-key field failed: $(sed -n '1p' "$case_dir/err")"
fi
assert_line "$case_log" "ARG=NO_UPDATE=1"
assert_no_line "$case_log" "ARG==1"
pass "empty optional profile fields retain their schema positions"

tests_run=$((tests_run + 1))
new_case malicious_profile
copy_case_assets
malicious_sentinel="$case_dir/json-was-executed"
malicious_installer_url='https://example.test/$(touch '"$malicious_sentinel"')'
{
  printf '%s\n' '{'
  printf '%s\n' '  "schema": 2,'
  printf '%s\n' '  "id": "evil",'
  printf '%s\n' '  "displayName": "Evil",'
  printf '%s\n' '  "status": "stable",'
  printf '%s\n' '  "installerKind": "native-script",'
  printf '  "installerUrl": "%s",\n' "$malicious_installer_url"
  printf '%s\n' '  "installerShell": "sh",'
  printf '%s\n' '  "installerVersionUrl": "https://example.test/latest",'
  printf '%s\n' '  "installerVersionFormat": "plain-semver",'
  printf '%s\n' '  "installerVersionEnv": "",'
  printf '%s\n' '  "installerBinDirEnv": "",'
  printf '%s\n' '  "installerHomeEnv": "",'
  printf '%s\n' '  "installerNonInteractiveEnv": "",'
  printf '%s\n' '  "version": "1.0.0",'
  printf '%s\n' '  "command": "evil",'
  printf '%s\n' '  "probeArg": "--version",'
  printf '%s\n' '  "apiKeyEnv": "",'
  printf '%s\n' '  "disableAutoUpdateEnv": ""'
  printf '%s\n' '}'
} > "$case_asset_dir/profiles/evil.json"
if run_program "$repo_root/agent-container" evil \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "unsafe native installer URL should be rejected"
fi
assert_contains "$case_dir/err" "Profile 'evil' has an unsafe installerUrl"
[ ! -e "$malicious_sentinel" ] \
  || fail "profile JSON was evaluated as shell code"
[ ! -s "$case_log" ] || fail "malicious profile contacted the Apple runtime"
pass "profile JSON remains inert data"

tests_run=$((tests_run + 1))
new_case wrapper_boundaries
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true
for wrapper_profile in \
  "claude-container claude" \
  "codex-container codex" \
  "grok-container grok"; do
  wrapper=${wrapper_profile%% *}
  profile=${wrapper_profile#* }
  : > "$case_log"
  run_program "$repo_root/$wrapper" -- "two words" "" '*' \
    >"$case_dir/$profile.out" 2>"$case_dir/$profile.err"
  expected_tail=$(printf 'ARG=%s\n' "$profile" '--' 'two words' '' '*')
  actual_tail=$(command_arguments "$case_log" create | tail -n 5)
  [ "$actual_tail" = "$expected_tail" ] \
    || fail "$wrapper changed profile or argument boundaries"
done
pass "all compatibility wrappers preserve exact argument boundaries"

tests_run=$((tests_run + 1))
new_case legacy_wrapper_runtime_words
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true
legacy_share="$case_dir/not-mounted"
mkdir "$legacy_share"
run_program "$repo_root/grok-container" \
  --share-ro "$legacy_share" -- "two words" "" '*' \
  >"$case_dir/out" 2>"$case_dir/err"
expected_tail=$(printf 'ARG=%s\n' \
  grok --share-ro "$legacy_share" -- 'two words' '' '*')
actual_tail=$(command_arguments "$case_log" create | tail -n 7)
[ "$actual_tail" = "$expected_tail" ] \
  || fail "legacy wrapper invocation consumed new runtime words"
assert_no_line "$case_log" "ARG=$legacy_share:$legacy_share:ro"
pass "runtime words remain ordinary Agent arguments without an explicit run subcommand"

tests_run=$((tests_run + 1))
new_case generic_run_read_only_share
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
FAKE_CAPTURE_HOST_STAGE_DIR="$case_dir/captured-host-stage"
read_only_share="$case_dir/read only sibling"
mkdir "$read_only_share"
run_program "$repo_root/agent-container" run grok \
  --share-ro "$read_only_share" -- "two words" "" '*' \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_log" "ARG=$read_only_share:$read_only_share:ro"
expected_tail=$(printf 'ARG=%s\n' grok 'two words' '' '*')
actual_tail=$(command_arguments "$case_log" create | tail -n 4)
[ "$actual_tail" = "$expected_tail" ] \
  || fail "generic run changed Agent argument boundaries"
awk -F '\t' '
  $1 == "first" && $2 == "git" && $3 ~ /^\// { matches += 1 }
  END { exit matches == 1 ? 0 : 1 }
' "$case_dir/captured-host-stage/host-commands.tsv" \
  || {
    awk -F '\t' '$2 == "git" { print "observed Git manifest: " $0 }' \
      "$case_dir/captured-host-stage/host-commands.tsv" >&2
    fail "run mode did not stage exactly one absolute host-first Git command"
  }
assert_contains "$repo_root/entrypoint.sh" \
  'runtime_path="$host_first_dir:$runtime_path:$host_fallback_dir"'
assert_contains "$repo_root/entrypoint.sh" 'PATH="$runtime_path"'
assert_line "$case_dir/captured-host-stage/host-roots.tsv" \
  "$(printf 'ro\t%s' "$read_only_share")"
grep -Eq '^[0-9a-f]{64}$' \
  "$case_dir/captured-host-stage/host-exec-token" \
  || fail "run mode did not stage one 256-bit host-exec token"
assert_line "$case_dir/captured-host-stage/host-exec-endpoint" \
  '192.168.64.1:54321'
assert_line "$case_dir/captured-host-stage/fake-host-broker-args" \
  'ARG=--session-dir'
assert_line "$case_dir/captured-host-stage/fake-host-broker-args" \
  'ARG=--sandbox-bin'
assert_line "$case_dir/captured-host-stage/fake-host-broker-args" \
  'ARG=/usr/bin/sandbox-exec'
pass "generic run stages host-first Git and one read-only extra share"

tests_run=$((tests_run + 1))
new_case unsafe_host_node_bootstrap
unsafe_node="$case_workspace/node"
unsafe_node_sentinel="$case_dir/unsafe-node-executed"
{
  printf '%s\n' '#!/bin/bash'
  printf 'printf executed > %q\n' "$unsafe_node_sentinel"
  printf '%s\n' 'printf /usr/bin/node'
} > "$unsafe_node"
chmod 0755 "$unsafe_node"
AGENT_CONTAINER_HOST_NODE_BIN="$unsafe_node"
if run_program "$repo_root/agent-container" run codex -- --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "an Agent-writable host Node bootstrap should be rejected"
fi
assert_contains "$case_dir/err" \
  "Refusing to execute host Node.js from an Agent-writable root"
[ ! -e "$unsafe_node_sentinel" ] \
  || fail "the Agent-writable host Node shim executed outside the sandbox"
assert_no_line "$case_log" "ARG=create"
pass "run rejects an Agent-writable Node before unsandboxed bootstrap"

tests_run=$((tests_run + 1))
new_case cross_root_host_command_symlink
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
FAKE_CAPTURE_HOST_STAGE_DIR="$case_dir/captured-host-stage"
poison_bin="$case_dir/poison-bin"
poison_target_dir="$case_dir/poison-target"
mkdir "$poison_bin" "$poison_target_dir"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$poison_target_dir/poison-tool"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$poison_bin/safe-tool"
chmod 0755 "$poison_target_dir/poison-tool" "$poison_bin/safe-tool"
ln -s "$poison_target_dir/poison-tool" "$poison_bin/poison-tool"
TEST_RUNNER_PATH="$poison_bin:$fixture_dir:/usr/bin:/bin"
if ! run_program "$repo_root/agent-container" run grok -- --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a cross-root PATH symlink poisoned run startup: $(sed -n '1p' "$case_dir/err")"
fi
if awk -F '\t' '$2 == "poison-tool" { found = 1 } END { exit !found }' \
  "$case_dir/captured-host-stage/host-commands.tsv"; then
  fail "a cross-root executable symlink entered the host command manifest"
fi
assert_line "$case_dir/captured-host-stage/host-commands.tsv" \
  "$(printf 'fallback\tsafe-tool\t%s' "$poison_bin/safe-tool")"
pass "run skips cross-root executable symlinks without poisoning the session"

tests_run=$((tests_run + 1))
new_case wrapper_run_read_write_share
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
FAKE_CAPTURE_HOST_STAGE_DIR="$case_dir/captured-host-stage"
read_write_share="$case_dir/writable sibling"
mkdir "$read_write_share"
if ! run_program "$repo_root/grok-container" run \
  --share-rw "$read_write_share" -- exec "argument with spaces" \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "wrapper run failed: $(sed -n '1p' "$case_dir/err")"
fi
assert_line "$case_log" "ARG=$read_write_share:$read_write_share"
assert_no_line "$case_log" "ARG=$read_write_share:$read_write_share:ro"
expected_tail=$(printf 'ARG=%s\n' grok exec 'argument with spaces')
actual_tail=$(command_arguments "$case_log" create | tail -n 3)
[ "$actual_tail" = "$expected_tail" ] \
  || fail "wrapper run changed Agent argument boundaries"
assert_line "$case_dir/captured-host-stage/host-roots.tsv" \
  "$(printf 'rw\t%s' "$read_write_share")"
pass "compatibility wrappers expose explicit run mode with read-write shares"

tests_run=$((tests_run + 1))
new_case run_guest_git_override
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
FAKE_CAPTURE_HOST_STAGE_DIR="$case_dir/captured-host-stage"
if ! run_program "$repo_root/agent-container" run codex \
  --no-host-exec git -- --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "run with guest Git override failed: $(sed -n '1p' "$case_dir/err")"
fi
if awk -F '\t' '$2 == "git" { found = 1 } END { exit !found }' \
  "$case_dir/captured-host-stage/host-commands.tsv"; then
  fail "--no-host-exec git left Git in the host command manifest"
fi
expected_tail=$(printf 'ARG=%s\n' codex --version)
actual_tail=$(command_arguments "$case_log" create | tail -n 2)
[ "$actual_tail" = "$expected_tail" ] \
  || fail "--no-host-exec changed Agent argument boundaries"
pass "a run can force Git back to the verified guest image"

tests_run=$((tests_run + 1))
new_case invalid_broker_endpoints
for endpoint_case in zero overflow suffix huge; do
  new_case "broker_endpoint_$endpoint_case"
  AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
  if run_program "$repo_root/agent-container" run codex \
    -- --version \
    >"$case_dir/out" 2>"$case_dir/err"; then
    fail "the broker endpoint case '$endpoint_case' should be rejected"
  fi
  assert_contains "$case_dir/err" \
    "did not publish a valid session endpoint"
  assert_no_line "$case_log" "ARG=create"
done
pass "broker endpoints require one numeric TCP port in the range 1 through 65535"

tests_run=$((tests_run + 1))
new_case unsafe_extra_shares
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
if run_program "$repo_root/agent-container" run codex \
  --share-ro / -- --version \
  >"$case_dir/root.out" 2>"$case_dir/root.err"; then
  fail "sharing the host filesystem root should be rejected"
fi
assert_no_line "$case_log" "ARG=create"

new_case unsafe_extra_home
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
if run_program "$repo_root/agent-container" run codex \
  --share-ro "$case_home" -- --version \
  >"$case_dir/home.out" 2>"$case_dir/home.err"; then
  fail "sharing the complete real host HOME should be rejected"
fi
assert_no_line "$case_log" "ARG=create"

new_case unsafe_extra_state
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
mkdir "$case_home/.agent-container"
if run_program "$repo_root/agent-container" run codex \
  --share-ro "$case_home/.agent-container" -- --version \
  >"$case_dir/state.out" 2>"$case_dir/state.err"; then
  fail "sharing private agent-container state should be rejected"
fi
assert_no_line "$case_log" "ARG=create"

new_case unsafe_extra_colon
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
colon_share="$case_dir/extra:share"
mkdir "$colon_share"
if run_program "$repo_root/agent-container" run codex \
  --share-ro "$colon_share" -- --version \
  >"$case_dir/colon.out" 2>"$case_dir/colon.err"; then
  fail "an Apple-incompatible extra-share path should be rejected"
fi
assert_contains "$case_dir/colon.err" \
  "cannot bind-mount a macOS path containing ':'"
assert_no_line "$case_log" "ARG=create"
pass "extra shares reject filesystem root, real HOME, private state, and colon paths"

tests_run=$((tests_run + 1))
new_case extra_share_virtiofs_budget
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
budget_share="$case_dir/budget-share"
mkdir "$budget_share"
touch \
  "$budget_share/one" \
  "$budget_share/two" \
  "$budget_share/three"
AGENT_CONTAINER_MAX_FILES=10
if run_program "$repo_root/agent-container" run codex \
  --share-ro "$budget_share" -- --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "extra shares should count against the VirtioFS file budget"
fi
assert_contains "$case_dir/err" "Projected VirtioFS shares"
assert_no_line "$case_log" "ARG=create"
pass "extra shares participate in the fail-closed VirtioFS budget"

tests_run=$((tests_run + 1))
new_case profile_isolation
run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/claude.out" 2>"$case_dir/claude.err"
assert_contains "$case_dir/claude.err" "Resolved Claude Code latest channel to 2.1.220"
assert_line "$case_curl_log" "URL=https://downloads.claude.ai/claude-code-releases/latest"
assert_native_installer_build_args \
  "$case_log" \
  claude \
  https://claude.ai/install.sh \
  bash \
  '' \
  '' \
  '' \
  '' \
  2.1.220 \
  claude
assert_line "$case_log" "ARG=AGENT_PROBE_ARG=--version"
assert_line "$case_log" "ARG=agent-container-claude:latest"
assert_line "$case_log" "ARG=claude"
assert_line "$case_log" "ARG=$case_home/.agent-container/profiles/claude/home:$case_home"
assert_line "$case_log" "ARG=$case_workspace:$case_workspace"
assert_line "$case_log" "ARG=--workdir"
assert_line "$case_log" "ARG=$case_workspace"
assert_line "$case_log" "ARG=GIT_CONFIG_GLOBAL=/run/agent-host/gitconfig"
assert_no_line "$case_log" "ARG=$case_home:$case_home"
if grep -Fq -- "ARG=$case_home:" "$case_log"; then
  fail "the real host HOME was used as a volume source"
fi

claude_meta="$case_home/.agent-container/profiles/claude/meta"
claude_shadow_home="$case_home/.agent-container/profiles/claude/home"
assert_line "$claude_meta/image-ref" "agent-container-claude:latest"
claude_build_id=$(sed -n '1p' "$claude_meta/image-build-id")
claude_fingerprint=${claude_build_id#agent-container-claude:latest:}
[ "$claude_fingerprint" != "$claude_build_id" ] \
  && valid_fingerprint "$claude_fingerprint" \
  || fail "Claude build metadata lacks a valid recipe fingerprint"
claude_identity=$(sed -n '1p' "$claude_meta/image-identity")
valid_fingerprint "$claude_identity" \
  || fail "Claude image identity is not a SHA-256 value"
printf '%s\n' 'claude-only' > "$claude_shadow_home/profile-sentinel"

: > "$case_log"
run_program "$repo_root/agent-container" codex exec "argument with spaces" \
  >"$case_dir/codex.out" 2>"$case_dir/codex.err"
assert_line "$case_log" "ARG=build"
assert_contains "$case_dir/codex.err" "Resolved Codex CLI latest channel to 0.146.0"
assert_line "$case_curl_log" "URL=https://releases.openai.com/codex/channels/latest"
assert_native_installer_build_args \
  "$case_log" \
  codex \
  https://chatgpt.com/codex/install.sh \
  sh \
  CODEX_RELEASE \
  CODEX_INSTALL_DIR \
  CODEX_HOME \
  CODEX_NON_INTERACTIVE \
  0.146.0 \
  codex
assert_line "$case_log" "ARG=agent-container-codex:latest"
assert_line "$case_log" "ARG=codex"
assert_line "$case_log" "ARG=argument with spaces"
assert_line "$case_log" "ARG=$case_home/.agent-container/profiles/codex/home:$case_home"
codex_meta="$case_home/.agent-container/profiles/codex/meta"
codex_shadow_home="$case_home/.agent-container/profiles/codex/home"
assert_line "$codex_meta/image-ref" "agent-container-codex:latest"
codex_build_id=$(sed -n '1p' "$codex_meta/image-build-id")
codex_fingerprint=${codex_build_id#agent-container-codex:latest:}
[ "$codex_fingerprint" != "$codex_build_id" ] \
  && valid_fingerprint "$codex_fingerprint" \
  || fail "Codex build metadata lacks a valid recipe fingerprint"
codex_identity=$(sed -n '1p' "$codex_meta/image-identity")
valid_fingerprint "$codex_identity" \
  || fail "Codex image identity is not a SHA-256 value"
[ "$claude_identity" != "$codex_identity" ] \
  || fail "fake runtime collapsed distinct profile image identities"
[ ! -e "$codex_shadow_home/profile-sentinel" ] \
  || fail "Claude shadow HOME leaked into Codex"

: > "$case_log"
run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/claude-warm.out" 2>"$case_dir/claude-warm.err"
assert_no_line "$case_log" "ARG=build"
assert_line "$case_log" "ARG=claude"
[ -f "$claude_shadow_home/profile-sentinel" ] \
  || fail "warm Claude run lost its isolated shadow HOME"
pass "official native channels, installer metadata, images, and shadow HOMEs remain isolated"

tests_run=$((tests_run + 1))
new_case profile_scoped_image_ref
AGENT_CONTAINER_IMAGE='shared-agent-image:latest'
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "an arbitrary image reference should be rejected"
fi
assert_contains "$case_dir/err" "Image references are profile-scoped"
[ ! -e "$case_home/.agent-container" ] \
  || fail "image-reference rejection occurred after state mutation"
[ ! -s "$case_log" ] || fail "an arbitrary image reference contacted the Apple runtime"
pass "profile-scoped image references prevent cross-profile provenance collisions"

tests_run=$((tests_run + 1))
new_case default_secret_boundary
mkdir -p "$case_home/.ssh" "$case_home/.config/gh" "$case_home/.config/git"
printf '%s\n' 'Host *' '  IdentityFile ~/.ssh/id_test' \
  > "$case_home/.ssh/config"
printf '%s\n' 'github.com:' '  oauth_token: GH_SECRET_DO_NOT_LOG' \
  > "$case_home/.config/gh/hosts.yml"
printf '%s\n' '[credential]' '  helper = osxkeychain' \
  > "$case_home/.config/git/config"
printf '%s\n' \
  '[user]' \
  '  name = Agent Test' \
  '  email = agent@example.test' \
  '[credential]' \
  '  helper = store --file=/tmp/SECRET_CREDENTIAL_FILE' \
  '[http "https://example.test/"]' \
  '  extraHeader = Authorization: Bearer GIT_SECRET_DO_NOT_LOG' \
  > "$case_home/.gitconfig"
printf '%s\n' 'not-a-real-socket' > "$case_home/ssh-agent.sock"

ANTHROPIC_API_KEY='ANTHROPIC_SECRET_DO_NOT_LOG'
OPENAI_API_KEY='OPENAI_SECRET_DO_NOT_LOG'
XAI_API_KEY='XAI_SECRET_DO_NOT_LOG'
SSH_AUTH_SOCK="$case_home/ssh-agent.sock"
FAKE_CAPTURE_GITCONFIG="$case_dir/staged.gitconfig"
run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"

for api_name in ANTHROPIC_API_KEY OPENAI_API_KEY XAI_API_KEY; do
  assert_no_line "$case_log" "ARG=$api_name"
done
assert_secret_absent "$case_log" "$ANTHROPIC_API_KEY" ANTHROPIC_API_KEY
assert_secret_absent "$case_log" "$OPENAI_API_KEY" OPENAI_API_KEY
assert_secret_absent "$case_log" "$XAI_API_KEY" XAI_API_KEY
assert_secret_absent "$case_log" GH_SECRET_DO_NOT_LOG GH
assert_secret_absent "$case_log" GIT_SECRET_DO_NOT_LOG Git
assert_no_line "$case_log" "ARG=--ssh"
assert_not_contains "$case_log" "$case_home/.ssh:ro"
assert_not_contains "$case_log" "$case_home/.config/gh:ro"
assert_not_contains "$case_log" "$case_home/.config/git:ro"
if grep -Fq -- "ARG=$case_home:" "$case_log"; then
  fail "the real host HOME was mounted while testing secret defaults"
fi
[ -f "$case_dir/staged.gitconfig" ] \
  || fail "fake runtime did not capture generic /run/agent-host staging"
[ "$(/usr/bin/git config --file "$case_dir/staged.gitconfig" --get user.name)" = "Agent Test" ] \
  || fail "minimal staged Git config lost user.name"
if /usr/bin/git config --file "$case_dir/staged.gitconfig" \
  --get-regexp '^(credential|http|url|include|includeIf)\.' >/dev/null 2>&1; then
  fail "default staging copied credential-bearing Git configuration"
fi
assert_not_contains "$case_dir/staged.gitconfig" "SECRET"
pass "default runtime boundary excludes API keys, SSH, GH, and full Git config"

tests_run=$((tests_run + 1))
new_case explicit_profile_api_key
ANTHROPIC_API_KEY='ANTHROPIC_VALUE_MUST_NOT_BE_LOGGED'
OPENAI_API_KEY='OPENAI_VALUE_MUST_NOT_BE_LOGGED'
XAI_API_KEY='XAI_VALUE_MUST_NOT_BE_LOGGED'
AGENT_CONTAINER_FORWARD_API_KEY=true
run_program "$repo_root/agent-container" codex --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_log" "ARG=OPENAI_API_KEY"
assert_no_line "$case_log" "ARG=ANTHROPIC_API_KEY"
assert_no_line "$case_log" "ARG=XAI_API_KEY"
assert_secret_absent "$case_log" "$ANTHROPIC_API_KEY" ANTHROPIC_API_KEY
assert_secret_absent "$case_log" "$OPENAI_API_KEY" OPENAI_API_KEY
assert_secret_absent "$case_log" "$XAI_API_KEY" XAI_API_KEY
pass "API-key opt-in forwards only the active profile variable name"

tests_run=$((tests_run + 1))
new_case experimental_grok
if run_program "$repo_root/grok-container" --version \
  >"$case_dir/disabled.out" 2>"$case_dir/disabled.err"; then
  fail "experimental Grok should require an explicit gate"
fi
assert_contains "$case_dir/disabled.err" "Profile 'grok' is experimental"
[ ! -s "$case_log" ] || fail "disabled Grok contacted the Apple runtime"
[ ! -s "$case_curl_log" ] || fail "disabled Grok contacted its version channel"

AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true
run_program "$repo_root/grok-container" "argument with spaces" \
  >"$case_dir/enabled.out" 2>"$case_dir/enabled.err"
assert_contains "$case_dir/enabled.err" "Resolved Grok CLI latest channel to 0.2.114"
assert_line "$case_curl_log" "URL=https://x.ai/cli/stable"
assert_native_installer_build_args \
  "$case_log" \
  grok \
  https://x.ai/cli/install.sh \
  bash \
  '' \
  GROK_BIN_DIR \
  '' \
  '' \
  0.2.114 \
  grok
assert_line "$case_log" "ARG=agent-container-grok:latest"
assert_line "$case_log" "ARG=grok"
assert_line "$case_log" "ARG=argument with spaces"
pass "experimental Grok gates its official native channel and installer metadata"

tests_run=$((tests_run + 1))
new_case floating_native_latest
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true
FAKE_GROK_LATEST_VERSION=0.2.114
run_program "$repo_root/grok-container" --version \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
assert_contains "$case_dir/first.err" "Resolved Grok CLI latest channel to 0.2.114"
assert_line "$case_curl_log" "URL=https://x.ai/cli/stable"
assert_line "$case_log" "ARG=AGENT_VERSION=0.2.114"

: > "$case_log"
: > "$case_curl_log"
run_program "$repo_root/grok-container" --version \
  >"$case_dir/warm.out" 2>"$case_dir/warm.err"
assert_line "$case_curl_log" "URL=https://x.ai/cli/stable"
assert_no_line "$case_log" "ARG=build"

: > "$case_log"
: > "$case_curl_log"
FAKE_GROK_LATEST_VERSION=0.2.115
run_program "$repo_root/grok-container" --version \
  >"$case_dir/updated.out" 2>"$case_dir/updated.err"
assert_contains "$case_dir/updated.err" "Resolved Grok CLI latest channel to 0.2.115"
assert_line "$case_curl_log" "URL=https://x.ai/cli/stable"
assert_line "$case_log" "ARG=build"
assert_line "$case_log" "ARG=AGENT_VERSION=0.2.115"
pass "an unchanged native latest channel is warm and a moved channel rebuilds"

tests_run=$((tests_run + 1))
new_case malicious_plain_version_response
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true
malicious_version_sentinel="$case_dir/version-response-was-executed"
FAKE_VERSION_RESPONSE_OVERRIDE='0.2.114;touch '"$malicious_version_sentinel"
if run_program "$repo_root/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a malicious native version response should fail closed"
fi
assert_contains "$case_dir/err" "version channel returned an invalid exact version"
assert_line "$case_curl_log" "URL=https://x.ai/cli/stable"
[ ! -e "$malicious_version_sentinel" ] \
  || fail "native version metadata was evaluated as shell code"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=start"
pass "plain native version metadata is validated as inert data"

tests_run=$((tests_run + 1))
new_case malformed_rust_version_response
FAKE_VERSION_RESPONSE_OVERRIDE='{"tag_name":"rust-v0.146.0"'
if run_program "$repo_root/codex-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "malformed Codex release JSON should fail closed"
fi
assert_contains "$case_dir/err" "version channel returned an invalid exact version"
assert_line "$case_curl_log" "URL=https://releases.openai.com/codex/channels/latest"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=start"
pass "Codex rust-v release JSON must satisfy the exact channel format"

tests_run=$((tests_run + 1))
new_case native_latest_lookup_failure
FAKE_VERSION_LOOKUP_FAIL=true
if run_program "$repo_root/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a failed native latest lookup should fail closed"
fi
assert_contains "$case_dir/err" "Unable to resolve the Claude Code latest channel"
assert_line "$case_curl_log" "URL=https://downloads.claude.ai/claude-code-releases/latest"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=start"
pass "native channel fetch failures stop before image or Agent execution"

tests_run=$((tests_run + 1))
new_case exact_version_override
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true
AGENT_CONTAINER_VERSION=0.2.110
FAKE_VERSION_LOOKUP_FAIL=true
run_program "$repo_root/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"
[ ! -s "$case_curl_log" ] \
  || fail "an exact version override still contacted the floating channel"
assert_line "$case_log" "ARG=AGENT_VERSION=0.2.110"
assert_line "$case_log" "ARG=AGENT_INSTALLER_URL=https://x.ai/cli/install.sh"
pass "an exact native version bypasses channel lookup for rollback and offline use"

tests_run=$((tests_run + 1))
new_case unsupported_version_tag
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true
AGENT_CONTAINER_VERSION=beta
if run_program "$repo_root/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "an unsupported native version tag should be rejected"
fi
assert_contains "$case_dir/err" "must be 'latest' or an exact native CLI version"
[ ! -s "$case_curl_log" ] \
  || fail "an invalid explicit version contacted the floating channel"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=start"
pass "only the official latest channel or an exact native version is accepted"

tests_run=$((tests_run + 1))
new_case global_profile_lock
first_log="$case_log"
FAKE_RUN_SLEEP=30
launch_exec "$repo_root/claude-container" --version \
  >"$case_dir/claude.out" 2>"$case_dir/claude.err" &
launcher_pid=$!
background_pid="$launcher_pid"
attempt=0
while ! grep -Fqx 'ARG=start' "$first_log"; do
  if ! kill -0 "$launcher_pid" 2>/dev/null; then
    wait "$launcher_pid" || true
    fail "Claude session exited before acquiring the global lock"
  fi
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] \
    || fail "Claude session did not reach the fake runtime"
  sleep 0.05
done
[ "$(sed -n '1p' "$case_home/.agent-container/session.lock/profile")" = claude ] \
  || fail "global lock did not record the owning profile"

case_log="$case_dir/codex-container.log"
: > "$case_log"
FAKE_RUN_SLEEP=""
if run_program "$repo_root/codex-container" --version \
  >"$case_dir/codex.out" 2>"$case_dir/codex.err"; then
  kill -TERM "$launcher_pid" 2>/dev/null || true
  wait "$launcher_pid" || true
  fail "Codex bypassed an active Claude global lock"
fi
assert_contains "$case_dir/codex.err" "Another managed Agent VM is active"
assert_no_line "$case_log" "ARG=start"

case_log="$first_log"
kill -TERM "$launcher_pid"
set +e
wait "$launcher_pid"
term_status=$?
set -e
background_pid=""
[ "$term_status" -ne 0 ] \
  || fail "TERM unexpectedly produced a successful launcher status"
assert_line "$first_log" "ARG=stop"
[ ! -d "$case_home/.agent-container/session.lock" ] \
  || fail "global session lock survived TERM cleanup"
pass "one global lock spans profiles and TERM stops the named VM"

tests_run=$((tests_run + 1))
new_case sigkill_recovery
stale_pid=900000
while kill -0 "$stale_pid" 2>/dev/null; do
  stale_pid=$((stale_pid + 1))
done
stale_container="agent-claude-$(id -u)-$stale_pid"
state_dir="$case_home/.agent-container"
mkdir -p \
  "$state_dir/session.lock" \
  "$state_dir/sessions/session-$stale_pid" \
  "$state_dir/profiles/claude/session.lock"
printf '%s\n' 'managed by agent-container' \
  > "$state_dir/.agent-container-owned"
for stale_registration in \
  "$state_dir/session.lock" \
  "$state_dir/sessions/session-$stale_pid" \
  "$state_dir/profiles/claude/session.lock"; do
  printf '%s\n' "$stale_pid" > "$stale_registration/pid"
  printf '%s\n' claude > "$stale_registration/profile"
done
printf '%s\n' stale-sensitive-staging \
  > "$state_dir/sessions/session-$stale_pid/credential-sentinel"
FAKE_CONTAINER_LIST_STATE="$case_dir/native-containers.json"
printf '%s\n' \
  "[{\"id\":\"$stale_container\",\"configuration\":{\"id\":\"$stale_container\",\"labels\":{\"com.loadchange.agent-container\":\"true\",\"com.loadchange.agent-container.profile\":\"claude\",\"com.loadchange.agent-container.host-uid\":\"$(id -u)\",\"com.loadchange.agent-container.launcher-pid\":\"$stale_pid\"}},\"status\":{\"state\":\"running\"}}]" \
  > "$FAKE_CONTAINER_LIST_STATE"
run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"
command_arguments "$case_log" list > "$case_dir/list.args"
assert_line "$case_dir/list.args" "ARG=--all"
assert_line "$case_dir/list.args" "ARG=--format"
assert_line "$case_dir/list.args" "ARG=json"
assert_line "$case_log" "ARG=delete"
assert_line "$case_log" "ARG=--force"
assert_line "$case_log" "ARG=$stale_container"
assert_line "$case_log" "ARG=start"
assert_contains "$case_dir/err" "Removing orphaned Agent VM"
[ ! -e "$state_dir/sessions/session-$stale_pid" ] \
  || fail "SIGKILL recovery left sensitive stale session staging"
[ ! -d "$state_dir/session.lock" ] \
  && [ ! -d "$state_dir/profiles/claude/session.lock" ] \
  || fail "SIGKILL recovery left a stale session lock"
pass "SIGKILL recovery removes only proven orphan VMs and staging"

tests_run=$((tests_run + 1))
new_case native_list_fail_closed
FAKE_CONTAINER_LIST_JSON='{"not":"an array"}'
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/invalid.out" 2>"$case_dir/invalid.err"; then
  fail "invalid Apple container-list JSON should fail closed"
fi
assert_contains "$case_dir/invalid.err" "did not match the expected JSON contract"
assert_no_line "$case_log" "ARG=delete"
assert_no_line "$case_log" "ARG=start"

new_case reserved_native_name
foreign_pid=910000
while kill -0 "$foreign_pid" 2>/dev/null; do
  foreign_pid=$((foreign_pid + 1))
done
foreign_container="agent-claude-$(id -u)-$foreign_pid"
FAKE_CONTAINER_LIST_JSON="[{\"id\":\"$foreign_container\",\"configuration\":{\"id\":\"$foreign_container\",\"labels\":{}},\"status\":{\"state\":\"stopped\"}}]"
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/foreign.out" 2>"$case_dir/foreign.err"; then
  fail "a reserved native name without ownership labels should fail closed"
fi
assert_contains "$case_dir/foreign.err" "lacks project ownership labels"
assert_no_line "$case_log" "ARG=delete"
assert_no_line "$case_log" "ARG=start"

new_case stopping_native_orphan
stopping_pid=920000
while kill -0 "$stopping_pid" 2>/dev/null; do
  stopping_pid=$((stopping_pid + 1))
done
stopping_container="agent-codex-$(id -u)-$stopping_pid"
FAKE_CONTAINER_DELETE_FAIL=true
FAKE_CONTAINER_LIST_JSON="[{\"id\":\"$stopping_container\",\"configuration\":{\"id\":\"$stopping_container\",\"labels\":{\"com.loadchange.agent-container\":\"true\",\"com.loadchange.agent-container.profile\":\"codex\",\"com.loadchange.agent-container.host-uid\":\"$(id -u)\",\"com.loadchange.agent-container.launcher-pid\":\"$stopping_pid\"}},\"status\":{\"state\":\"stopping\"}}]"
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/stopping.out" 2>"$case_dir/stopping.err"; then
  fail "an Apple stopping-state delete failure should block a new VM"
fi
assert_contains "$case_dir/stopping.err" "Unable to remove orphaned managed Agent VM"
assert_line "$case_log" "ARG=delete"
assert_no_line "$case_log" "ARG=start"
pass "native-list corruption, ambiguous names, and stopping cleanup fail closed"

tests_run=$((tests_run + 1))
new_case same_profile_concurrency
AGENT_CONTAINER_ACCEPT_VIRTIOFS_RISK=true
AGENT_CONTAINER_ALLOW_CONCURRENT=true
FAKE_RUN_SLEEP=30
first_log="$case_log"
launch_exec "$repo_root/claude-container" --version \
  >"$case_dir/first.out" 2>"$case_dir/first.err" &
launcher_pid=$!
background_pid="$launcher_pid"
attempt=0
while ! grep -Fqx 'ARG=start' "$first_log"; do
  if ! kill -0 "$launcher_pid" 2>/dev/null; then
    wait "$launcher_pid" || true
    fail "first concurrent session exited before reaching the runtime"
  fi
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || fail "first concurrent session did not start"
  sleep 0.05
done

case_log="$case_dir/same-profile.log"
: > "$case_log"
FAKE_RUN_SLEEP=""
if run_program "$repo_root/claude-container" --version \
  >"$case_dir/same.out" 2>"$case_dir/same.err"; then
  fail "a second same-profile session bypassed image serialization"
fi
assert_contains "$case_dir/same.err" "Same-profile sessions are serialized"
assert_no_line "$case_log" "ARG=start"

case_log="$case_dir/other-profile.log"
: > "$case_log"
run_program "$repo_root/codex-container" --version \
  >"$case_dir/other.out" 2>"$case_dir/other.err"
assert_line "$case_log" "ARG=start"

kill -TERM "$launcher_pid"
set +e
wait "$launcher_pid"
set -e
background_pid=""
case_log="$first_log"
pass "explicit concurrency allows distinct profiles but serializes one profile"

tests_run=$((tests_run + 1))
new_case non_tty_stdin
FAKE_READ_STDIN=true
if ! printf '%s\n' 'pipe-input' \
  | run_program "$repo_root/claude-container" --version \
      >"$case_dir/out" 2>"$case_dir/err"; then
  fail "non-TTY stdin run failed"
fi
assert_line "$case_log" "STDIN_TTY=false"
assert_line "$case_log" "READ=pipe-input"
command_arguments "$case_log" start > "$case_dir/start.args"
command_arguments "$case_log" create > "$case_dir/create.args"
assert_line "$case_dir/start.args" "ARG=--attach"
assert_line "$case_dir/start.args" "ARG=--interactive"
assert_no_line "$case_dir/create.args" "ARG=--attach"
assert_no_line "$case_dir/create.args" "ARG=--interactive"
assert_no_line "$case_log" "ARG=--tty"
pass "create and attached start split terminal and interactive responsibilities"

tests_run=$((tests_run + 1))
new_case piped_stdin_tty_stdout
run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/warm.out" 2>"$case_dir/warm.err"
: > "$case_log"
(
  cd "$case_workspace"
  exec /usr/bin/env -i \
    HOME="$case_home" \
    PATH="$fixture_dir:/usr/bin:/bin" \
    LANG=C \
    TERM=xterm-256color \
    AGENT_CONTAINER_BIN="$fixture_dir/container" \
    AGENT_CONTAINER_ASSET_DIR="$repo_root" \
    AGENT_CONTAINER_DISABLE_FD_WATCHDOG=true \
    FAKE_CONTAINER_LOG="$case_log" \
    FAKE_CREATED_CONTAINER_STATE="$case_home/fake-created-container.json" \
    FAKE_IMAGE_STATE_DIR="$case_home/fake-images" \
    FAKE_READ_STDIN=true \
    /usr/bin/python3 "$repo_root/tests/pty-run.py" --pipe-stdin \
      /bin/bash "$repo_root/agent-container" claude --version
) >"$case_dir/pty.out" 2>"$case_dir/pty.err"
assert_line "$case_log" "ARG=--interactive"
assert_no_line "$case_log" "ARG=--tty"
assert_line "$case_log" "STDIN_TTY=false"
assert_line "$case_log" "READ=pipe-to-terminal-output"
pass "piped stdin with terminal stdout avoids Apple ProcessIO ENOTTY"

tests_run=$((tests_run + 1))
new_case exit_status
FAKE_RUN_STATUS=37
set +e
run_program "$repo_root/codex-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"
agent_status=$?
set -e
[ "$agent_status" -eq 37 ] \
  || fail "launcher returned $agent_status instead of the Agent status 37"
[ ! -d "$case_home/.agent-container/session.lock" ] \
  || fail "session lock survived non-zero Agent exit"
pass "Agent exit status is preserved while session state is cleaned"

tests_run=$((tests_run + 1))
new_case virtiofs_gate
touch "$case_workspace/one" "$case_workspace/two" "$case_workspace/three"
AGENT_CONTAINER_MAX_FILES=2
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "VirtioFS file-count threshold should fail closed"
fi
assert_contains "$case_dir/err" "Apple VirtioFS issue #1097"
assert_no_line "$case_log" "ARG=start"
pass "VirtioFS issue #1097 retains a fail-closed workspace gate"

tests_run=$((tests_run + 1))
new_case service_preflight
FAKE_SYSTEM_RUNNING=false
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a stopped Apple container service should be rejected"
fi
assert_contains "$case_dir/err" "container system start"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=start"
pass "stopped Apple services fail before build with actionable guidance"

tests_run=$((tests_run + 1))
new_case version_preflight
FAKE_CONTAINER_VERSION=1.1.9
if run_program "$repo_root/agent-container" codex --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "an old Apple container CLI should be rejected"
fi
assert_contains "$case_dir/err" "1.2.0 or newer"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=start"
pass "minimum Apple container version is enforced"

tests_run=$((tests_run + 1))
new_case explicit_network_settings
AGENT_CONTAINER_HTTP_PROXY='http://proxy.example.test:8080'
AGENT_CONTAINER_NO_PROXY='localhost,127.0.0.1,example.test'
AGENT_CONTAINER_DNS1='1.1.1.1'
AGENT_CONTAINER_TZ='Asia/Singapore'
run_program "$repo_root/agent-container" codex --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_log" "ARG=HTTP_PROXY=http://proxy.example.test:8080"
assert_line "$case_log" "ARG=http_proxy=http://proxy.example.test:8080"
assert_line "$case_log" "ARG=NO_PROXY=localhost,127.0.0.1,example.test"
assert_line "$case_log" "ARG=--dns"
assert_line "$case_log" "ARG=1.1.1.1"
assert_line "$case_log" "ARG=TZ=Asia/Singapore"
pass "proxy, DNS, and timezone enter only through explicit generic settings"

tests_run=$((tests_run + 1))
new_case docker_proxy_rejected
AGENT_CONTAINER_HTTP_PROXY='http://host.docker.internal:7890'
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "Docker-only host name should be rejected"
fi
assert_contains "$case_dir/err" "host.docker.internal is Docker-specific"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=start"
pass "Docker-only proxy configuration cannot leak into the Apple runtime"

tests_run=$((tests_run + 1))
new_case explicit_host_capabilities
mkdir -p "$case_home/.config/git" "$case_home/.config/gh" "$case_home/.ssh"
printf '%s\n' '[credential]' '  helper = osxkeychain' \
  > "$case_home/.gitconfig"
printf '%s\n' '[safe]' '  directory = *' \
  > "$case_home/.config/git/config"
printf '%s\n' 'github.com:' '  oauth_token: EXPLICIT_GH_TOKEN' \
  > "$case_home/.config/gh/hosts.yml"
printf '%s\n' 'Host example.test' '  User git' \
  > "$case_home/.ssh/config"
printf '%s\n' 'example.test ssh-ed25519 AAAATEST' \
  > "$case_home/.ssh/known_hosts"
printf '%s\n' 'PRIVATE_KEY_MUST_NOT_COPY' \
  > "$case_home/.ssh/id_ed25519"
AGENT_CONTAINER_FULL_GIT_CONFIG=true
AGENT_CONTAINER_MOUNT_GH=true
AGENT_CONTAINER_MOUNT_SSH_CONFIG=true
FAKE_CAPTURE_GITCONFIG="$case_dir/full.gitconfig"
FAKE_CAPTURE_SSH_DIR="$case_dir/staged-ssh"
run_program "$repo_root/agent-container" codex --version \
  >"$case_dir/out" 2>"$case_dir/err"
cmp -s "$case_home/.gitconfig" "$case_dir/full.gitconfig" \
  || fail "full Git opt-in did not stage the requested file"
assert_line "$case_log" "ARG=$case_home/.config/git:$case_home/.config/git:ro"
assert_line "$case_log" "ARG=$case_home/.config/gh:$case_home/.config/gh:ro"
assert_contains "$case_log" ":$case_home/.ssh:ro"
[ -f "$case_dir/staged-ssh/config" ] \
  && [ -f "$case_dir/staged-ssh/known_hosts" ] \
  || fail "SSH metadata opt-in did not stage its allowlisted files"
[ ! -e "$case_dir/staged-ssh/id_ed25519" ] \
  || fail "the launcher copied an SSH private key"
if find "$case_home/.agent-container/sessions" -mindepth 1 -print -quit \
  | grep -q .; then
  fail "credential-capable session staging survived exit"
fi
pass "Git, GH, and SSH metadata capabilities remain explicit and ephemeral"

tests_run=$((tests_run + 1))
new_case lifecycle_gate
mkdir -p "$case_home/.local/share/.agent-container.install.lock"
printf '%s\n' "$$" \
  > "$case_home/.local/share/.agent-container.install.lock/pid"
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "launcher should not race an active install/uninstall transaction"
fi
assert_contains "$case_dir/err" "session, install, or uninstall is running"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=start"
[ ! -e "$case_home/.agent-container" ] \
  || fail "lifecycle-gate rejection occurred after state mutation"
pass "launcher registration is atomic with install and uninstall"

tests_run=$((tests_run + 1))
new_case exact_lifecycle_lock
mkdir -p "$case_home/.local/share/.agent-container.install.lock"
printf '%s\n' "$$" 'unexpected trailing record' \
  > "$case_home/.local/share/.agent-container.install.lock/pid"
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a lifecycle lock PID with trailing content should be rejected"
fi
assert_contains "$case_dir/err" "lifecycle lock has an invalid PID"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=start"
[ ! -e "$case_home/.agent-container" ] \
  || fail "malformed lifecycle lock was rejected after state mutation"
pass "lifecycle lock ownership requires one exact PID record"

tests_run=$((tests_run + 1))
new_case exact_state_marker
mkdir "$case_home/.agent-container"
printf '%s\n' 'managed by agent-container' 'unexpected trailing record' \
  > "$case_home/.agent-container/.agent-container-owned"
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "an ownership marker with trailing content should be rejected"
fi
assert_contains "$case_dir/err" "invalid agent-container ownership marker"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=start"
pass "state ownership markers require exact complete contents"

tests_run=$((tests_run + 1))
new_case exact_image_metadata
run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
profile_meta="$case_home/.agent-container/profiles/claude/meta"
printf '%s\n' 'unexpected trailing record' \
  >> "$profile_meta/image-build-id"
: > "$case_log"
run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/second.out" 2>"$case_dir/second.err"
assert_line "$case_log" "ARG=build"
assert_line "$case_log" "ARG=start"

printf '%s\n' 'do not replace through symlink' > "$case_dir/metadata-target"
rm -f "$profile_meta/image-ref"
ln -s "$case_dir/metadata-target" "$profile_meta/image-ref"
: > "$case_log"
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/third.out" 2>"$case_dir/third.err"; then
  fail "a symlink at an image metadata path should be rejected"
fi
assert_contains "$case_dir/third.err" "Refusing to replace an unsafe state file"
assert_no_line "$case_log" "ARG=start"
assert_line "$case_dir/metadata-target" "do not replace through symlink"
pass "image metadata is exact, atomically replaced, and symlink-safe"

tests_run=$((tests_run + 1))
new_case unsafe_paths
mkdir "$case_home/state-target"
ln -s "$case_home/state-target" "$case_home/.agent-container"
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/symlink.out" 2>"$case_dir/symlink.err"; then
  fail "state-root symlink should be rejected"
fi
assert_contains "$case_dir/symlink.err" "Refusing a symlink as the Agent container state root"
assert_no_line "$case_log" "ARG=start"

new_case home_workspace_rejected
case_workspace="$case_home"
if run_program "$repo_root/agent-container" codex --version \
  >"$case_dir/home.out" 2>"$case_dir/home.err"; then
  fail "mounting the complete host HOME should be rejected"
fi
assert_contains "$case_dir/home.err" "Refusing overlap between shared workspace"
assert_no_line "$case_log" "ARG=start"
pass "private state cannot be reached through symlink or whole-HOME mounts"

tests_run=$((tests_run + 1))
new_case colon_mount_path
case_workspace="$case_dir/work:space"
mkdir "$case_workspace"
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "Apple-incompatible colon path should be rejected"
fi
assert_contains "$case_dir/err" "cannot bind-mount a macOS path containing ':'"
assert_no_line "$case_log" "ARG=start"
pass "Apple volume-parser path limitations fail before runtime mutation"

tests_run=$((tests_run + 1))
malformed_digest_64=$(printf '%064d' 0)
malformed_digest_63=${malformed_digest_64%?}
malformed_digest_upper=$(printf '%s' "$malformed_digest_64" | tr 0 A)
for malformed_contract in \
  non_array \
  empty_array \
  multiple_records \
  missing_descriptor \
  uppercase_digest \
  short_digest \
  nonhex_digest; do
  new_case "malformed_image_inspect_$malformed_contract"
  FAKE_IMAGE_PRESENT=true
  case "$malformed_contract" in
    non_array)
      FAKE_IMAGE_INSPECT_OUTPUT='{}'
      ;;
    empty_array)
      FAKE_IMAGE_INSPECT_OUTPUT='[]'
      ;;
    multiple_records)
      FAKE_IMAGE_INSPECT_OUTPUT='[{},{}]'
      ;;
    missing_descriptor)
      FAKE_IMAGE_INSPECT_OUTPUT='[{"configuration":{}}]'
      ;;
    uppercase_digest)
      FAKE_IMAGE_INSPECT_OUTPUT="[{\"configuration\":{\"descriptor\":{\"digest\":\"sha256:$malformed_digest_upper\"}}}]"
      ;;
    short_digest)
      FAKE_IMAGE_INSPECT_OUTPUT="[{\"configuration\":{\"descriptor\":{\"digest\":\"sha256:$malformed_digest_63\"}}}]"
      ;;
    nonhex_digest)
      FAKE_IMAGE_INSPECT_OUTPUT="[{\"configuration\":{\"descriptor\":{\"digest\":\"sha256:${malformed_digest_63}g\"}}}]"
      ;;
  esac
  if run_program "$repo_root/agent-container" claude --version \
    >"$case_dir/out" 2>"$case_dir/err"; then
    fail "malformed image-inspect contract '$malformed_contract' was accepted"
  fi
  assert_contains "$case_dir/err" "invalid or ambiguous descriptor"
  assert_no_line "$case_log" "ARG=build"
  assert_no_line "$case_log" "ARG=create"
  assert_no_line "$case_log" "ARG=start"
  assert_no_line "$case_log" "ARG=delete"
done
pass "image inspection requires one array record with one lowercase sha256 descriptor"

tests_run=$((tests_run + 1))
new_case external_image_retag
run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
: > "$case_log"
retagged_image_state=$(find "$case_home/fake-images" \
  -mindepth 1 -maxdepth 1 -type f -print -quit)
[ -n "$retagged_image_state" ] \
  || fail "fake image state was unavailable for retag simulation"
printf '%s\n' \
  '[{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","configuration":{"creationDate":"2026-07-29T00:00:00Z","name":"agent-container-claude:latest","descriptor":{"digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","mediaType":"application/vnd.oci.image.index.v1+json","size":123}},"variants":[]}]' \
  > "$retagged_image_state"
run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/second.out" 2>"$case_dir/second.err"
assert_line "$case_log" "ARG=build"
assert_line "$case_log" "ARG=start"
pass "an externally retargeted image tag invalidates the warm cache"

tests_run=$((tests_run + 1))
new_case create_digest_verification
FAKE_RETAG_AFTER_INSPECT=true
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a tag changed between image inspection and create should not start"
fi
assert_contains "$case_dir/err" "failed image, state, or terminal verification"
assert_line "$case_log" "ARG=create"
assert_no_line "$case_log" "ARG=start"
assert_line "$case_log" "ARG=delete"
[ ! -e "$case_home/fake-created-container.json" ] \
  || fail "a proven stopped container with the wrong image digest survived cleanup"
pass "create-before-start proves the frozen image digest before Agent execution"

tests_run=$((tests_run + 1))
new_case foreign_create_collision
FAKE_CREATE_FOREIGN_COLLISION=true
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a foreign container-name collision should stop the launch"
fi
assert_contains "$case_dir/err" "could not create the verified Agent container"
assert_line "$case_log" "ARG=create"
assert_no_line "$case_log" "ARG=start"
assert_no_line "$case_log" "ARG=delete"
[ -f "$case_home/fake-created-container.json" ] \
  || fail "the launcher removed a foreign container after create failed"
pass "create failure never deletes an unproven name collision"

tests_run=$((tests_run + 1))
new_case foreign_create_inspection
FAKE_CREATE_FOREIGN_AFTER_SUCCESS=true
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a successful create returning foreign inspect provenance should stop the launch"
fi
assert_contains "$case_dir/err" "provenance could not be proven"
assert_line "$case_log" "ARG=create"
assert_line "$case_log" "ARG=inspect"
assert_no_line "$case_log" "ARG=start"
assert_no_line "$case_log" "ARG=delete"
assert_contains "$case_home/fake-created-container.json" '"labels":{}'
assert_contains "$case_home/fake-created-container.json" '"reference":"foreign:latest"'
pass "successful create with foreign inspect provenance is retained fail-closed"

tests_run=$((tests_run + 1))
new_case created_container_already_started
FAKE_CREATE_STARTED=true
if run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a container with a non-empty startedDate should not start"
fi
assert_contains "$case_dir/err" "failed image, state, or terminal verification"
assert_line "$case_log" "ARG=create"
assert_no_line "$case_log" "ARG=start"
assert_line "$case_log" "ARG=delete"
[ ! -e "$case_home/fake-created-container.json" ] \
  || fail "the proven project container with a prior startedDate survived cleanup"
pass "pre-start verification rejects every non-empty startedDate"

tests_run=$((tests_run + 1))
new_case failed_start_cleanup
FAKE_START_FAIL=true
set +e
run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"
start_status=$?
set -e
[ "$start_status" -eq 73 ] \
  || fail "failed Apple start status was not preserved: $start_status"
assert_line "$case_log" "ARG=start"
assert_line "$case_log" "ARG=delete"
[ ! -e "$case_home/fake-created-container.json" ] \
  || fail "a verified stopped container survived failed-start cleanup"
pass "failed attached start removes only the reverified stopped container"

tests_run=$((tests_run + 1))
new_case successful_auto_remove
run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/warm.out" 2>"$case_dir/warm.err"
: > "$case_log"
FAKE_RUN_OUTPUT='agent-output-only'
run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"
created_container_name=$(command_arguments "$case_log" create | awk '
  $0 == "ARG=--name" {
    if (getline > 0) {
      sub(/^ARG=/, "")
      print
      exit
    }
  }
')
[ -n "$created_container_name" ] \
  || fail "could not resolve the fake create container name"
assert_line "$case_dir/out" "agent-output-only"
[ "$(wc -l < "$case_dir/out" | tr -d ' ')" = 1 ] \
  || fail "create output leaked into the Agent stdout stream"
assert_not_contains "$case_dir/out" "$created_container_name"
assert_no_line "$case_log" "ARG=delete"
assert_not_contains "$case_dir/err" "Could not determine whether"
[ ! -e "$case_home/fake-created-container.json" ] \
  || fail "successful --rm workload left fake container state"
awk '
  $0 == "ARG=start" { saw_start = 1; next }
  saw_start && $0 == "ARG=inspect" { saw_post_inspect = 1 }
  END { exit saw_post_inspect ? 0 : 1 }
' "$case_log" \
  || fail "launcher did not confirm normal post-start auto-removal"
pass "normal --rm absence is quiet and create IDs never leak to Agent stdout"

tests_run=$((tests_run + 1))
new_case post_start_auto_remove_race
FAKE_POST_START_INSPECT_MODE=retain
FAKE_CONTAINER_DELETE_ABSENT_RACE=true
run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_log" "ARG=delete"
assert_line "$case_log" "ARG=list"
assert_not_contains "$case_dir/err" "Could not remove stopped"
[ ! -e "$case_home/fake-created-container.json" ] \
  || fail "auto-remove race left fake container state"
pass "post-start delete race is quiet after --rm already removed the container"

tests_run=$((tests_run + 1))
new_case post_start_inspect_indeterminate
FAKE_POST_START_INSPECT_MODE=indeterminate
FAKE_RUN_STATUS=41
set +e
run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"
indeterminate_status=$?
set -e
[ "$indeterminate_status" -eq 41 ] \
  || fail "indeterminate post-start inspect changed Agent status: $indeterminate_status"
assert_contains "$case_dir/err" "Could not determine whether"
assert_no_line "$case_log" "ARG=delete"
[ -f "$case_home/fake-created-container.json" ] \
  && [ -f "$case_home/fake-created-container.json.inspect-error" ] \
  || fail "indeterminate post-start inspect did not retain retryable state"
indeterminate_container_name=$(command_arguments "$case_log" create | awk '
  $0 == "ARG=--name" {
    if (getline > 0) {
      sub(/^ARG=/, "")
      print
      exit
    }
  }
')
assert_contains \
  "$case_home/fake-created-container.json" \
  "\"id\":\"$indeterminate_container_name\""
awk '
  $0 == "ARG=start" { saw_start = 1; next }
  saw_start && $0 == "ARG=list" { saw_post_list = 1 }
  saw_post_list && $0 == "ARG=--all" { saw_all = 1 }
  saw_post_list && $0 == "ARG=--format" { saw_format = 1 }
  saw_post_list && $0 == "ARG=json" { saw_json = 1 }
  END { exit saw_post_list && saw_all && saw_format && saw_json ? 0 : 1 }
' "$case_log" \
  || fail "indeterminate post-start inspect did not trigger structured --all reconciliation"
pass "indeterminate post-start inspection warns and retains provenance"

tests_run=$((tests_run + 1))
new_case post_start_foreign_replacement
FAKE_POST_START_INSPECT_MODE=foreign
FAKE_RUN_STATUS=42
set +e
run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"
foreign_status=$?
set -e
[ "$foreign_status" -eq 42 ] \
  || fail "foreign post-start replacement changed Agent status: $foreign_status"
assert_contains "$case_dir/err" "no longer matches its verified stopped state"
assert_no_line "$case_log" "ARG=delete"
assert_contains "$case_home/fake-created-container.json" '"labels":{}'
assert_contains "$case_home/fake-created-container.json" '"reference":"foreign:latest"'
pass "post-start foreign name reuse is warned, retained, and never deleted"

tests_run=$((tests_run + 1))
new_case linked_worktree
main_repo="$case_dir/main repo"
case_workspace="$case_dir/linked worktree/subdir"
mkdir "$main_repo"
/usr/bin/git -C "$main_repo" init -q
/usr/bin/git -C "$main_repo" config user.email test@example.test
/usr/bin/git -C "$main_repo" config user.name Test
printf '%s\n' base > "$main_repo/file.txt"
/usr/bin/git -C "$main_repo" add file.txt
/usr/bin/git -C "$main_repo" commit -qm base
/usr/bin/git -C "$main_repo" worktree add -q "$case_dir/linked worktree" -b linked
mkdir "$case_workspace"
run_program "$repo_root/agent-container" codex --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_log" "ARG=$case_dir/linked worktree:$case_dir/linked worktree"
assert_line "$case_log" "ARG=$main_repo/.git:$main_repo/.git"
assert_line "$case_log" "ARG=$case_workspace"
pass "linked worktrees preserve workdir and external Git common-directory mounts"

tests_run=$((tests_run + 1))
new_case real_pty
run_program "$repo_root/agent-container" claude --version \
  >"$case_dir/warm.out" 2>"$case_dir/warm.err"
: > "$case_log"
(
  cd "$case_workspace"
  exec /usr/bin/env -i \
    HOME="$case_home" \
    PATH="$fixture_dir:/usr/bin:/bin" \
    LANG=C \
    TERM=xterm-256color \
    AGENT_CONTAINER_BIN="$fixture_dir/container" \
    AGENT_CONTAINER_ASSET_DIR="$repo_root" \
    AGENT_CONTAINER_DISABLE_FD_WATCHDOG=true \
    FAKE_CONTAINER_LOG="$case_log" \
    FAKE_CREATED_CONTAINER_STATE="$case_home/fake-created-container.json" \
    FAKE_IMAGE_STATE_DIR="$case_home/fake-images" \
    FAKE_READ_STDIN=true \
    /usr/bin/python3 "$repo_root/tests/pty-run.py" \
      /bin/bash "$repo_root/agent-container" claude --version
) >"$case_dir/pty.out" 2>"$case_dir/pty.err"
assert_line "$case_log" "ARG=--interactive"
assert_line "$case_log" "ARG=--tty"
assert_line "$case_log" "STDIN_TTY=true"
assert_line "$case_log" "READ=terminal-input"
pass "a real PTY reaches the Apple CLI with input and terminal mode intact"

echo "1..$tests_run"
