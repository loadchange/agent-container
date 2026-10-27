#!/bin/bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
fixture_dir="$repo_root/tests/fixtures"
test_launcher_override=${AGENT_CONTAINER_TEST_LAUNCHER:-}
if [ -n "$test_launcher_override" ]; then
  case "$test_launcher_override" in
    /*) ;;
    *) printf 'launcher override must be absolute\n' >&2; exit 64 ;;
  esac
  [ -f "$test_launcher_override" ] \
    && [ ! -L "$test_launcher_override" ] \
    && [ -x "$test_launcher_override" ] \
    || { printf 'launcher override is not a safe executable\n' >&2; exit 64; }
  test_launcher_binary=$test_launcher_override
else
  command -v cargo >/dev/null 2>&1 \
    || { printf 'cargo is required for launcher tests\n' >&2; exit 69; }
  cargo build --quiet --locked --offline --release \
    --manifest-path "$repo_root/Cargo.toml"
  test_launcher_binary="$repo_root/target/release/agent-container-launcher"
fi
test_root=$(mktemp -d /tmp/agent-container-test.XXXXXX)
test_root=$(CDPATH= cd -- "$test_root" && pwd -P)
tests_run=0
background_pid=""
secondary_background_pid=""

test_forward_env_names=(
  _ANTHROPIC_API_PROVIDER
  ANTHROPIC_BASE_URL
  ANTHROPIC_MODEL
  ANTHROPIC_SMALL_FAST_MODEL
  CLAUDE_CODE_EFFORT_LEVEL
  CLAUDE_CODE_NO_FLICKER
  CLAUDE_CODE_OAUTH_TOKEN
  ANTHROPIC_WEBHOOK_SIGNING_KEY
  DISABLE_AUTOUPDATER
  TEST_EXPLICIT_ENV
  TEST_EMPTY_ENV
)

# The production curl fixture intentionally models only response parsing. This
# wrapper records and removes the host-policy options before delegating so the
# runtime contract can also prove curl configuration and proxy isolation.
curl_wrapper_dir="$test_root/curl-wrapper"
mkdir "$curl_wrapper_dir"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'first_argument=${1-}'
  printf '%s\n' 'proxy_set=false'
  printf '%s\n' 'proxy_value='
  printf '%s\n' 'noproxy_set=false'
  printf '%s\n' 'noproxy_value='
  printf '%s\n' 'resolve_count=0'
  printf '%s\n' 'resolve_value='
  printf '%s\n' 'remaining=()'
  printf '%s\n' 'while [ "$#" -gt 0 ]; do'
  printf '%s\n' '  case "$1" in'
  printf '%s\n' '    --disable) shift ;;'
  printf '%s\n' '    --proxy)'
  printf '%s\n' '      [ "$#" -ge 2 ] || exit 64'
  printf '%s\n' '      proxy_set=true'
  printf '%s\n' '      proxy_value=$2'
  printf '%s\n' '      shift 2'
  printf '%s\n' '      ;;'
  printf '%s\n' '    --resolve)'
  printf '%s\n' '      [ "$#" -ge 2 ] || exit 64'
  printf '%s\n' '      resolve_count=$((resolve_count + 1))'
  printf '%s\n' '      resolve_value=$2'
  printf '%s\n' '      shift 2'
  printf '%s\n' '      ;;'
  printf '%s\n' '    --noproxy)'
  printf '%s\n' '      [ "$#" -ge 2 ] || exit 64'
  printf '%s\n' '      noproxy_set=true'
  printf '%s\n' '      noproxy_value=$2'
  printf '%s\n' '      shift 2'
  printf '%s\n' '      ;;'
  printf '%s\n' '    *) remaining+=("$1"); shift ;;'
  printf '%s\n' '  esac'
  printf '%s\n' 'done'
  printf '%s\n' 'if [ -n "${FAKE_CURL_LOG:-}" ]; then'
  printf '%s\n' '  printf "FIRST_ARG=%s\n" "$first_argument" >> "$FAKE_CURL_LOG"'
  printf '%s\n' '  printf "PROXY_SET=%s\n" "$proxy_set" >> "$FAKE_CURL_LOG"'
  printf '%s\n' '  printf "PROXY=%s\n" "$proxy_value" >> "$FAKE_CURL_LOG"'
  printf '%s\n' '  printf "NOPROXY_SET=%s\n" "$noproxy_set" >> "$FAKE_CURL_LOG"'
  printf '%s\n' '  printf "NOPROXY=%s\n" "$noproxy_value" >> "$FAKE_CURL_LOG"'
  printf '%s\n' '  printf "RESOLVE_COUNT=%s\n" "$resolve_count" >> "$FAKE_CURL_LOG"'
  printf '%s\n' '  if [ "$resolve_count" -gt 0 ]; then'
  printf '%s\n' '    printf "RESOLVE=%s\n" "$resolve_value" >> "$FAKE_CURL_LOG"'
  printf '%s\n' '  fi'
  printf '%s\n' 'fi'
  printf 'exec %q "${remaining[@]}"\n' "$fixture_dir/curl"
} > "$curl_wrapper_dir/curl"
chmod 0755 "$curl_wrapper_dir/curl"

cleanup() {
  local status=$?
  local cleanup_pid
  trap - EXIT INT TERM HUP
  set +e
  for cleanup_pid in "$background_pid" "$secondary_background_pid"; do
    if [ -n "$cleanup_pid" ] && kill -0 "$cleanup_pid" 2>/dev/null; then
      kill -TERM "$cleanup_pid" 2>/dev/null
      wait "$cleanup_pid" 2>/dev/null
    fi
  done
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

assert_command_count() {
  local file="$1"
  local command_name="$2"
  local expected_count="$3"
  local actual_count
  actual_count=$(awk -v marker="ARG=$command_name" '
    previous == "CALL" && $0 == marker { count++ }
    { previous = $0 }
    END { print count + 0 }
  ' "$file")
  [ "$actual_count" -eq "$expected_count" ] \
    || fail "expected $expected_count '$command_name' calls in $file, found $actual_count"
}

call_arguments_containing() {
  local file="$1"
  local required_argument="$2"
  awk -v required="ARG=$required_argument" '
    function clear_arguments(  argument_index) {
      for (argument_index in arguments) delete arguments[argument_index]
      argument_count = 0
      matched = 0
    }
    function emit_arguments(  argument_index) {
      for (argument_index = 1; argument_index <= argument_count; argument_index++) {
        print arguments[argument_index]
      }
      emitted = 1
    }
    $0 == "CALL" {
      if (matched) {
        emit_arguments()
        exit
      }
      clear_arguments()
      next
    }
    /^ARG=/ {
      arguments[++argument_count] = $0
      if ($0 == required) matched = 1
    }
    END {
      if (!emitted && matched) emit_arguments()
    }
  ' "$file"
}

assert_create_env_name() {
  local file="$1"
  local env_name="$2"
  command_arguments "$file" create | awk -v expected="ARG=$env_name" '
    previous == "ARG=--env" && $0 == expected { found = 1 }
    { previous = $0 }
    END { exit !found }
  ' || fail "expected create to pass --env followed by $env_name"
}

reset_case_environment() {
  unset \
    AGENT_CONTAINER_ACCEPT_VIRTIOFS_RISK \
    AGENT_CONTAINER_ALLOW_CONCURRENT \
    AGENT_CONTAINER_BASE_IMAGE \
    AGENT_CONTAINER_BUILD_CPUS \
    AGENT_CONTAINER_BUILD_MEMORY \
    AGENT_CONTAINER_ENABLE_EXPERIMENTAL \
    AGENT_CONTAINER_FORWARD_ENV \
    AGENT_CONTAINER_FORWARD_API_KEY \
    AGENT_CONTAINER_FORWARD_SSH_AGENT \
    AGENT_CONTAINER_FULL_GIT_CONFIG \
    AGENT_CONTAINER_FULL_HOST_ACCESS \
    AGENT_CONTAINER_HOST_FORWARD_PORTS \
    AGENT_CONTAINER_HOST_MIRROR \
    ANDROID_HOME \
    AGENT_CONTAINER_HOST_BROKER_BIN \
    AGENT_CONTAINER_HOST_EXEC_DENY \
    AGENT_CONTAINER_HOST_EXEC_FIRST \
    AGENT_CONTAINER_HOST_ALIAS \
    AGENT_CONTAINER_BLOCK_HOST \
    AGENT_CONTAINER_HOST_GATEWAY \
    AGENT_CONTAINER_HOST_NODE_BIN \
    AGENT_CONTAINER_HOST_SSH_AGENT \
    AGENT_CONTAINER_HOST_TOOLS \
    AGENT_CONTAINER_HTTP_PROXY \
    AGENT_CONTAINER_IMAGE \
    AGENT_CONTAINER_HTTPS_PROXY \
    AGENT_CONTAINER_ALL_PROXY \
    AGENT_CONTAINER_CPUS \
    AGENT_CONTAINER_NO_PROXY \
    AGENT_CONTAINER_DNS1 \
    AGENT_CONTAINER_DNS2 \
    AGENT_CONTAINER_DEBIAN_MIRROR \
    AGENT_CONTAINER_EXTRA_CA_CERTS \
    AGENT_CONTAINER_OPENSSL_BIN \
    AGENT_CONTAINER_SECURITY_BIN \
    AGENT_CONTAINER_REBUILD \
    AGENT_CONTAINER_SKIP_BUILD \
    AGENT_CONTAINER_TZ \
    AGENT_CONTAINER_VERSION \
    AGENT_CONTAINER_WORKSPACE_ROOT \
    AGENT_CONTAINER_FD_STOP_PERCENT \
    AGENT_CONTAINER_MAX_FILES \
    AGENT_CONTAINER_MEMORY \
    AGENT_CONTAINER_MOUNT_GH \
    AGENT_CONTAINER_MOUNT_SSH_CONFIG \
    ANTHROPIC_API_KEY \
    ANTHROPIC_AUTH_TOKEN \
    OPENAI_API_KEY \
    XAI_API_KEY \
    SSH_AUTH_SOCK \
    FAKE_BUILD_FAIL \
    FAKE_CAPTURE_GITCONFIG \
    FAKE_CAPTURE_BUILD_CA \
    FAKE_CAPTURE_HOST_STAGE_DIR \
    FAKE_CAPTURE_SSH_DIR \
    FAKE_CREATE_FAILURE_MODE \
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
    FAKE_GROW_DIRECTORY_AFTER_STOPPED_INSPECT \
    FAKE_GROW_DIRECTORY_ENTRY_COUNT \
    FAKE_REPLACE_DIRECTORY_ON_SYSCTL \
    FAKE_REPLACE_DIRECTORY_ON_SYSCTL_SNAPSHOT \
    FAKE_REPLACE_DIRECTORY_AFTER_DELETE \
    FAKE_REPLACEMENT_SINGLETON_RECORDS \
    FAKE_RUN_OUTPUT \
    FAKE_RUN_SLEEP \
    FAKE_RUN_STATUS \
    FAKE_SECURITY_FAIL \
    FAKE_SECURITY_CHAIN_FORMAT \
    FAKE_SECURITY_INSTALLER_ANCHOR_BODY \
    FAKE_SECURITY_VERSION_ANCHOR_BODY \
    FAKE_START_FAIL \
    FAKE_SYSTEM_START_FAIL \
    FAKE_SYSTEM_START_OUTPUT \
    FAKE_SYSTEM_READY_AFTER_START \
    FAKE_SYSTEM_STATUS_FAILURES_AFTER_START \
    FAKE_SYSTEM_RUNNING \
    FAKE_NUM_FILES \
    FAKE_MAX_FILES \
    FAKE_MAX_FILES_PER_PROC \
    FAKE_MAX_VNODES \
    FAKE_FREE_VNODES \
    GROK_SANDBOX \
    TEST_CONTAINER_BIN \
    TEST_FAKE_BUILD_GATE \
    TEST_FAKE_BUILD_MARKER \
    TEST_FAKE_CONTAINER_REAL \
    TEST_SINGLETON_LAUNCH \
    TEST_LAUNCH_CWD \
    TEST_RUNNER_PATH \
    2>/dev/null || true
  unset "${test_forward_env_names[@]}" 2>/dev/null || true
  # Suite default: the singleton host git/gh channel stays off so existing
  # cases keep proving the guest-only contract. Dedicated host-tool cases
  # opt back in; an empty value exercises the built-in default.
  AGENT_CONTAINER_HOST_TOOLS=false
}

new_case() {
  local name="$1"
  reset_case_environment
  case_dir="$test_root/$name"
  case_home="$case_dir/home"
  case_workspace="$case_dir/workspace"
  case_log="$case_dir/container.log"
  case_curl_log="$case_dir/curl.log"
  case_security_log="$case_dir/security.log"
  case_openssl_log="$case_dir/openssl.log"
  case_asset_dir=${test_override_asset_dir:-"$repo_root/runtime"}
  mkdir -p "$case_home" "$case_workspace"
  : > "$case_log"
  : > "$case_curl_log"
  : > "$case_security_log"
  : > "$case_openssl_log"
}

stage_case_assets() {
  local destination=$1

  mkdir -p "$destination/profiles"
  cp \
    "$repo_root/runtime/Containerfile" \
    "$repo_root/runtime/Containerfile.dockerignore" \
    "$repo_root/runtime/image-setup.sh" \
    "$repo_root/runtime/entrypoint.sh" \
    "$repo_root/runtime/host-exec-broker.mjs" \
    "$repo_root/runtime/host-exec-client" \
    "$repo_root/runtime/agent-host-tunnel" \
    "$repo_root/runtime/agent-workspace-connect" \
    "$repo_root/runtime/agent-workspace-session" \
    "$destination/"
  cp "$repo_root"/runtime/profiles/*.json "$destination/profiles/"
  if [ -n "$test_launcher_override" ]; then
    {
      printf '%s\n' '#!/bin/bash'
      printf '%s\n' 'set -euo pipefail'
      printf 'exec %q "$@"\n' "$test_launcher_override"
    } > "$destination/agent-container-darwin-arm64"
    chmod 0755 "$destination/agent-container-darwin-arm64"
  fi
}

copy_case_assets() {
  case_asset_dir="$case_dir/assets"
  stage_case_assets "$case_asset_dir"
}

test_override_asset_dir=
if [ -n "$test_launcher_override" ]; then
  test_override_asset_dir="$test_root/launcher-override-assets"
  stage_case_assets "$test_override_asset_dir"
  ln -s "$test_launcher_override" "$test_root/agent-container"
fi

launch_exec() {
  local program="$1"
  shift
  local launcher_argv0 program_name requested_test_profile
  local -a runner_env launcher_options program_arguments

  program_arguments=("$@")
  program_name=${program##*/}
  if [ "${TEST_SINGLETON_LAUNCH:-false}" != true ]; then
    case "$program_name" in
      agent-container)
        case "${program_arguments[0]:-}" in
          run|profiles|singleton|-h|--help|'') ;;
          *)
            requested_test_profile=${program_arguments[0]}
            program_arguments=(
              run "$requested_test_profile" -- "${program_arguments[@]:1}"
            )
            ;;
        esac
        ;;
      claude-container|codex-container|grok-container)
        [ "${program_arguments[0]:-}" = run ] \
          || program_arguments=(run -- "${program_arguments[@]}")
        ;;
    esac
  fi

  # The test process still uses shell variables as fixture controls, but the
  # program under test receives every container setting through the public
  # Rust launcher arguments. No AGENT_CONTAINER_* configuration leaks into
  # its inherited environment.
  launcher_options=(
    --container-bin "${TEST_CONTAINER_BIN:-$fixture_dir/container}"
    --container-assets "$case_asset_dir"
    --container-openssl "$fixture_dir/openssl"
    --container-security "$fixture_dir/security"
    --container-disable-fd-watchdog
  )

  [ -z "${AGENT_CONTAINER_CPUS:-}" ] \
    || launcher_options+=(--container-cpus "$AGENT_CONTAINER_CPUS")
  [ -z "${AGENT_CONTAINER_MEMORY:-}" ] \
    || launcher_options+=(--container-memory "$AGENT_CONTAINER_MEMORY")
  [ -z "${AGENT_CONTAINER_BUILD_CPUS:-}" ] \
    || launcher_options+=(--container-build-cpus "$AGENT_CONTAINER_BUILD_CPUS")
  [ -z "${AGENT_CONTAINER_BUILD_MEMORY:-}" ] \
    || launcher_options+=(--container-build-memory "$AGENT_CONTAINER_BUILD_MEMORY")
  [ -z "${AGENT_CONTAINER_VERSION:-}" ] \
    || launcher_options+=(--container-version "$AGENT_CONTAINER_VERSION")
  [ -z "${AGENT_CONTAINER_BASE_IMAGE:-}" ] \
    || launcher_options+=(--container-base-image "$AGENT_CONTAINER_BASE_IMAGE")
  [ -z "${AGENT_CONTAINER_HTTP_PROXY:-}" ] \
    || launcher_options+=(--container-http-proxy "$AGENT_CONTAINER_HTTP_PROXY")
  [ -z "${AGENT_CONTAINER_HTTPS_PROXY:-}" ] \
    || launcher_options+=(--container-https-proxy "$AGENT_CONTAINER_HTTPS_PROXY")
  [ -z "${AGENT_CONTAINER_ALL_PROXY:-}" ] \
    || launcher_options+=(--container-all-proxy "$AGENT_CONTAINER_ALL_PROXY")
  [ -z "${AGENT_CONTAINER_NO_PROXY:-}" ] \
    || launcher_options+=(--container-no-proxy "$AGENT_CONTAINER_NO_PROXY")
  [ -z "${AGENT_CONTAINER_EXTRA_CA_CERTS:-}" ] \
    || launcher_options+=(--container-extra-ca "$AGENT_CONTAINER_EXTRA_CA_CERTS")
  [ -z "${AGENT_CONTAINER_DNS1:-}" ] \
    || launcher_options+=(--container-dns1 "$AGENT_CONTAINER_DNS1")
  [ -z "${AGENT_CONTAINER_DNS2:-}" ] \
    || launcher_options+=(--container-dns2 "$AGENT_CONTAINER_DNS2")
  [ -z "${AGENT_CONTAINER_TZ:-}" ] \
    || launcher_options+=(--container-timezone "$AGENT_CONTAINER_TZ")
  [ -z "${AGENT_CONTAINER_DEBIAN_MIRROR:-}" ] \
    || launcher_options+=(
      --container-debian-mirror "$AGENT_CONTAINER_DEBIAN_MIRROR"
    )
  [ -z "${AGENT_CONTAINER_HOST_ALIAS:-}" ] \
    || launcher_options+=(--container-host-alias "$AGENT_CONTAINER_HOST_ALIAS")
  [ -z "${AGENT_CONTAINER_BLOCK_HOST:-}" ] \
    || launcher_options+=(--container-block-host "$AGENT_CONTAINER_BLOCK_HOST")
  [ -z "${AGENT_CONTAINER_FORWARD_ENV:-}" ] \
    || launcher_options+=(--container-forward-env "$AGENT_CONTAINER_FORWARD_ENV")
  [ -z "${AGENT_CONTAINER_WORKSPACE_ROOT:-}" ] \
    || launcher_options+=(
      --container-workspace-root "$AGENT_CONTAINER_WORKSPACE_ROOT"
    )
  if [ -n "${AGENT_CONTAINER_FORWARD_API_KEY+x}" ]; then
    case "$AGENT_CONTAINER_FORWARD_API_KEY" in
      1|true|TRUE|yes|YES|on|ON)
        launcher_options+=(--container-forward-api-key)
        ;;
      0|false|FALSE|no|NO|off|OFF)
        launcher_options+=(--no-container-forward-api-key)
        ;;
      *)
        # Only malformed-mode tests use this value-bearing legacy shape.
        launcher_options+=(
          "--container-forward-api-key=$AGENT_CONTAINER_FORWARD_API_KEY"
        )
        ;;
    esac
  fi
  [ -z "${AGENT_CONTAINER_MAX_FILES:-}" ] \
    || launcher_options+=(--container-max-files "$AGENT_CONTAINER_MAX_FILES")
  [ -z "${AGENT_CONTAINER_FD_STOP_PERCENT:-}" ] \
    || launcher_options+=(
      --container-fd-stop-percent "$AGENT_CONTAINER_FD_STOP_PERCENT"
    )
  [ -z "${AGENT_CONTAINER_HOST_EXEC_DENY:-}" ] \
    || launcher_options+=(
      --container-host-exec-deny "$AGENT_CONTAINER_HOST_EXEC_DENY"
    )
  [ -z "${AGENT_CONTAINER_HOST_EXEC_FIRST:-}" ] \
    || launcher_options+=(
      --container-host-exec-first "$AGENT_CONTAINER_HOST_EXEC_FIRST"
    )
  if [ -n "${AGENT_CONTAINER_HOST_BROKER_BIN:-}" ]; then
    launcher_options+=(
      --container-host-broker "$AGENT_CONTAINER_HOST_BROKER_BIN"
    )
  elif [ -n "${AGENT_CONTAINER_HOST_NODE_BIN:-}" ]; then
    launcher_options+=(--container-host-node "$AGENT_CONTAINER_HOST_NODE_BIN")
  elif [ "${TEST_SINGLETON_LAUNCH:-false}" != true ]; then
    launcher_options+=(--container-host-broker "$fixture_dir/host-exec-broker")
  fi
  if [ -n "${AGENT_CONTAINER_HOST_GATEWAY:-}" ]; then
    launcher_options+=(--container-host-gateway "$AGENT_CONTAINER_HOST_GATEWAY")
  elif [ "${TEST_SINGLETON_LAUNCH:-false}" = true ]; then
    # Singleton tests start the real Rust workspace broker on the host. The
    # Apple bridge address is not assigned on every development machine, so
    # keep the test listener on loopback; the fake guest never connects to it.
    launcher_options+=(--container-host-gateway 127.0.0.1)
  fi

  [ "${AGENT_CONTAINER_ENABLE_EXPERIMENTAL:-false}" != true ] \
    || launcher_options+=(--container-enable-experimental)
  [ "${AGENT_CONTAINER_REBUILD:-false}" != true ] \
    || launcher_options+=(--container-rebuild)
  [ "${AGENT_CONTAINER_SKIP_BUILD:-false}" != true ] \
    || launcher_options+=(--container-skip-build)
  [ "${AGENT_CONTAINER_FULL_GIT_CONFIG:-false}" != true ] \
    || launcher_options+=(--container-full-git-config)
  [ "${AGENT_CONTAINER_MOUNT_GH:-false}" != true ] \
    || launcher_options+=(--container-mount-gh)
  if [ -n "${AGENT_CONTAINER_HOST_SSH_AGENT+x}" ]; then
    case "$AGENT_CONTAINER_HOST_SSH_AGENT" in
      true) launcher_options+=(--container-host-ssh-agent) ;;
      false) launcher_options+=(--no-container-host-ssh-agent) ;;
      *)
        launcher_options+=(
          "--container-host-ssh-agent=$AGENT_CONTAINER_HOST_SSH_AGENT"
        )
        ;;
    esac
  fi
  [ "${AGENT_CONTAINER_FORWARD_SSH_AGENT:-false}" != true ] \
    || launcher_options+=(--container-forward-ssh-agent)
  [ "${AGENT_CONTAINER_MOUNT_SSH_CONFIG:-false}" != true ] \
    || launcher_options+=(--container-mount-ssh-config)
  [ "${AGENT_CONTAINER_ACCEPT_VIRTIOFS_RISK:-false}" != true ] \
    || launcher_options+=(--container-accept-virtiofs-risk)
  [ "${AGENT_CONTAINER_ALLOW_CONCURRENT:-false}" != true ] \
    || launcher_options+=(--container-allow-concurrent)
  if [ -n "${AGENT_CONTAINER_HOST_TOOLS:-}" ]; then
    if [ "$AGENT_CONTAINER_HOST_TOOLS" = true ]; then
      launcher_options+=(--container-host-tools)
    else
      launcher_options+=(--no-container-host-tools)
    fi
  fi
  [ "${AGENT_CONTAINER_FULL_HOST_ACCESS:-false}" != true ] \
    || launcher_options+=(--container-full-host-access)
  [ -z "${AGENT_CONTAINER_HOST_FORWARD_PORTS:-}" ] \
    || launcher_options+=(
      --container-host-forward-ports "$AGENT_CONTAINER_HOST_FORWARD_PORTS"
    )
  [ -z "${AGENT_CONTAINER_HOST_MIRROR:-}" ] \
    || launcher_options+=(--container-host-mirror "$AGENT_CONTAINER_HOST_MIRROR")

  runner_env=(
    "HOME=$case_home"
    "PATH=$curl_wrapper_dir:${TEST_RUNNER_PATH:-$fixture_dir:/usr/bin:/bin}"
    "LANG=C"
    "TERM=xterm-256color"
    "FAKE_BUILD_FAIL=${FAKE_BUILD_FAIL:-false}"
    "FAKE_CAPTURE_GITCONFIG=${FAKE_CAPTURE_GITCONFIG:-}"
    "FAKE_CAPTURE_BUILD_CA=${FAKE_CAPTURE_BUILD_CA:-}"
    "FAKE_CAPTURE_HOST_STAGE_DIR=${FAKE_CAPTURE_HOST_STAGE_DIR:-}"
    "FAKE_CAPTURE_SSH_DIR=${FAKE_CAPTURE_SSH_DIR:-}"
    "FAKE_CREATE_FAILURE_MODE=${FAKE_CREATE_FAILURE_MODE:-}"
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
    "FAKE_GROW_DIRECTORY_AFTER_STOPPED_INSPECT=${FAKE_GROW_DIRECTORY_AFTER_STOPPED_INSPECT:-}"
    "FAKE_GROW_DIRECTORY_ENTRY_COUNT=${FAKE_GROW_DIRECTORY_ENTRY_COUNT:-0}"
    "FAKE_GROW_DIRECTORY_MARKER=$case_home/fake-grow-directory-marker"
    "FAKE_REPLACE_DIRECTORY_ON_SYSCTL=${FAKE_REPLACE_DIRECTORY_ON_SYSCTL:-}"
    "FAKE_REPLACE_DIRECTORY_ON_SYSCTL_SNAPSHOT=${FAKE_REPLACE_DIRECTORY_ON_SYSCTL_SNAPSHOT:-0}"
    "FAKE_SYSCTL_SNAPSHOT_STATE=$case_home/fake-sysctl-snapshot-count"
    "FAKE_REPLACE_DIRECTORY_AFTER_DELETE=${FAKE_REPLACE_DIRECTORY_AFTER_DELETE:-}"
    "FAKE_REPLACEMENT_SINGLETON_RECORDS=${FAKE_REPLACEMENT_SINGLETON_RECORDS:-false}"
    "FAKE_RUN_OUTPUT=${FAKE_RUN_OUTPUT:-}"
    "FAKE_RUN_SLEEP=${FAKE_RUN_SLEEP:-}"
    "FAKE_RUN_STATUS=${FAKE_RUN_STATUS:-0}"
    "FAKE_SECURITY_FAIL=${FAKE_SECURITY_FAIL:-false}"
    "FAKE_SECURITY_CHAIN_FORMAT=${FAKE_SECURITY_CHAIN_FORMAT:-nul-cr}"
    "FAKE_SECURITY_INSTALLER_ANCHOR_BODY=${FAKE_SECURITY_INSTALLER_ANCHOR_BODY:-}"
    "FAKE_SECURITY_LOG=$case_security_log"
    "FAKE_SECURITY_VERSION_ANCHOR_BODY=${FAKE_SECURITY_VERSION_ANCHOR_BODY:-}"
    "FAKE_OPENSSL_LOG=$case_openssl_log"
    "FAKE_START_FAIL=${FAKE_START_FAIL:-false}"
    "FAKE_SYSTEM_START_FAIL=${FAKE_SYSTEM_START_FAIL:-false}"
    "FAKE_SYSTEM_START_OUTPUT=${FAKE_SYSTEM_START_OUTPUT:-}"
    "FAKE_SYSTEM_READY_AFTER_START=${FAKE_SYSTEM_READY_AFTER_START:-true}"
    "FAKE_SYSTEM_STATUS_FAILURES_AFTER_START=${FAKE_SYSTEM_STATUS_FAILURES_AFTER_START:-0}"
    "FAKE_SYSTEM_STATUS_COUNT_STATE=$case_home/fake-system-status-count"
    "FAKE_SYSTEM_RUNNING=${FAKE_SYSTEM_RUNNING:-true}"
    "FAKE_SYSTEM_STARTED_STATE=$case_home/fake-system-started"
    "FAKE_NUM_FILES=${FAKE_NUM_FILES:-1000}"
    "FAKE_MAX_FILES=${FAKE_MAX_FILES:-100000}"
    "FAKE_MAX_FILES_PER_PROC=${FAKE_MAX_FILES_PER_PROC:-60000}"
    "FAKE_MAX_VNODES=${FAKE_MAX_VNODES:-200000}"
    "FAKE_FREE_VNODES=${FAKE_FREE_VNODES:-150000}"
    "TEST_FAKE_BUILD_GATE=${TEST_FAKE_BUILD_GATE:-}"
    "TEST_FAKE_BUILD_MARKER=${TEST_FAKE_BUILD_MARKER:-}"
    "TEST_FAKE_CONTAINER_REAL=${TEST_FAKE_CONTAINER_REAL:-}"
  )

  if [ -n "${AGENT_CONTAINER_IMAGE:-}" ]; then
    # Removed settings are intentionally injected only by their migration
    # tests so the Rust launcher can prove they fail closed.
    runner_env+=("AGENT_CONTAINER_IMAGE=$AGENT_CONTAINER_IMAGE")
  fi
  if [ -n "${ANTHROPIC_API_KEY+x}" ]; then
    runner_env+=("ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
  fi
  if [ -n "${ANTHROPIC_AUTH_TOKEN+x}" ]; then
    runner_env+=("ANTHROPIC_AUTH_TOKEN=$ANTHROPIC_AUTH_TOKEN")
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
  # A representative operator variable: full host access must hand it to the
  # host-tool broker, the sandboxed channel must not.
  if [ -n "${ANDROID_HOME+x}" ]; then
    runner_env+=("ANDROID_HOME=$ANDROID_HOME")
  fi
  for test_env_name in "${test_forward_env_names[@]}"; do
    if printenv "$test_env_name" >/dev/null 2>&1; then
      runner_env+=("$test_env_name=$(printenv "$test_env_name")")
    fi
  done

  cd "${TEST_LAUNCH_CWD:-$case_workspace}"
  if [ -n "$test_launcher_override" ]; then
    case "$program" in
      "$repo_root/bin/agent-container") launcher_argv0=agent-container ;;
      "$repo_root/bin/claude-container") launcher_argv0=claude-container ;;
      "$repo_root/bin/codex-container") launcher_argv0=codex-container ;;
      "$repo_root/bin/grok-container") launcher_argv0=grok-container ;;
      *) launcher_argv0= ;;
    esac
    if [ -n "$launcher_argv0" ]; then
      exec /usr/bin/env -i "${runner_env[@]}" \
        /bin/bash -c '
          launcher_argv0=$1
          launcher=$2
          shift 2
          exec -a "$launcher_argv0" "$launcher" "$@"
        ' test-launcher-dispatch \
        "$launcher_argv0" "$test_launcher_override" \
        "${launcher_options[@]}" "${program_arguments[@]}"
    fi
  fi
  exec /usr/bin/env -i "${runner_env[@]}" \
    /bin/bash "$program" "${launcher_options[@]}" "${program_arguments[@]}"
}

run_program() {
  (launch_exec "$@")
}

run_program_from() {
  local launch_directory="$1"
  shift
  (TEST_LAUNCH_CWD="$launch_directory" launch_exec "$@")
}

write_build_gated_container() {
  local helper_path="$1"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' ': "${TEST_FAKE_CONTAINER_REAL:?}"'
    printf '%s\n' 'if [ "${1:-}" = build ] && [ -n "${TEST_FAKE_BUILD_MARKER:-}" ]; then'
    printf '%s\n' '  printf "%s\n" "$$" >> "$TEST_FAKE_BUILD_MARKER"'
    printf '%s\n' '  while [ -e "${TEST_FAKE_BUILD_GATE:-}" ]; do sleep 0.02; done'
    printf '%s\n' 'fi'
    printf '%s\n' 'exec "$TEST_FAKE_CONTAINER_REAL" "$@"'
  } > "$helper_path"
  chmod 0755 "$helper_path"
}

valid_fingerprint() {
  local value="$1"
  [ "${#value}" -eq 64 ] || return 1
  case "$value" in
    *[!0-9a-f]*) return 1 ;;
  esac
}

write_test_certificate() {
  local destination="$1"
  local body="$2"

  printf '%s\n' \
    '-----BEGIN CERTIFICATE-----' \
    "$body" \
    '-----END CERTIFICATE-----' \
    > "$destination"
}

test_sha256_file() {
  local source="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$source" | awk '{print $1}'
  else
    sha256sum "$source" | awk '{print $1}'
  fi
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
  assert_line "$file" "ARG=auto"
  assert_not_contains "$file" "AGENT_PACKAGE="
}

tests_run=$((tests_run + 1))
new_case profiles_list
run_program "$repo_root/bin/agent-container" profiles \
  >"$case_dir/out" 2>"$case_dir/err"
grep -Eq '^claude[[:space:]]+preview[[:space:]]+Claude Code$' "$case_dir/out" \
  || fail "profiles did not list preview Claude"
grep -Eq '^codex[[:space:]]+preview[[:space:]]+Codex CLI$' "$case_dir/out" \
  || fail "profiles did not list preview Codex"
grep -Eq '^grok[[:space:]]+preview[[:space:]]+Grok CLI$' "$case_dir/out" \
  || fail "profiles did not list preview Grok"
[ ! -s "$case_log" ] || fail "profile listing contacted the Apple runtime"
pass "profiles are listed from validated declarative metadata"

tests_run=$((tests_run + 1))
new_case guest_pnpm_storage
containerfile="$repo_root/runtime/Containerfile"
containerignore="$repo_root/runtime/Containerfile.dockerignore"
image_setup="$repo_root/runtime/image-setup.sh"
entrypoint="$repo_root/runtime/entrypoint.sh"
workspace_session="$repo_root/runtime/agent-workspace-session"
runtime="$repo_root/runtime/agent-container-runtime"
containerfile_bytes=$(wc -c < "$containerfile" | tr -d '[:space:]')
case "$containerfile_bytes" in
  ''|*[!0-9]*) fail "Containerfile size was not numeric" ;;
esac
[ "$containerfile_bytes" -le 10000 ] \
  || fail "Containerfile exceeds the Apple builder shim's safe 10 KB input budget"
[ -f "$image_setup" ] && [ ! -L "$image_setup" ] && [ -x "$image_setup" ] \
  || fail "image setup must be a regular executable build asset"
assert_line "$containerignore" '!image-setup.sh'
assert_line "$containerfile" 'COPY image-setup.sh /tmp/agent-image-setup'
[ "$(grep -Fxc -- 'COPY image-setup.sh /tmp/agent-image-setup' "$containerfile")" -eq 1 ] \
  || fail "Containerfile should copy image setup exactly once"
assert_contains "$containerfile" '/tmp/agent-image-setup ca'
assert_contains "$containerfile" '/tmp/agent-image-setup toolchain'
assert_contains "$containerfile" 'rm -f /tmp/agent-image-setup'
assert_line "$containerfile" 'ENV COREPACK_HOME=/usr/local/lib/agent-corepack'
assert_contains "$containerfile" 'ARG PNPM_VERSION=11.7.0'
assert_contains "$containerfile" 'COREPACK_ENABLE_NETWORK=0'
assert_contains "$image_setup" 'setup_ca()'
assert_contains "$image_setup" 'setup_toolchain()'
assert_contains "$image_setup" 'ca_secret=/run/secrets/agent_ca_bundle'
assert_contains "$image_setup" 'update-ca-certificates'
assert_contains "$image_setup" 'chmod -R a-w "$COREPACK_HOME"'
assert_contains "$image_setup" '/usr/bin/setpriv'
assert_contains "$image_setup" 'XDG_CACHE_HOME="$probe_home/.cache"'
assert_contains "$image_setup" '[ ! -e "$probe_home/.cache/node/corepack" ]'
assert_contains "$repo_root/install.sh" '/bin/sh -n "$tmp_dir/image-setup.sh"'
assert_contains "$repo_root/scripts/build-release.sh" \
  '/bin/sh -n "$dist_dir/image-setup.sh"'
assert_not_contains "$image_setup" 'COREPACK_HOME=/root'
assert_not_contains "$containerfile" 'COREPACK_HOME=/root'
for pnpm_setting in STORE CACHE STATE; do
  assert_contains "$containerfile" \
    "PNPM_CONFIG_${pnpm_setting}_DIR=/var/lib/agent-container/pnpm/"
  assert_contains "$entrypoint" \
    "PNPM_CONFIG_${pnpm_setting}_DIR=\"\$pnpm_"
  assert_contains "$workspace_session" \
    "PNPM_CONFIG_${pnpm_setting}_DIR=/var/lib/agent-container/pnpm/"
  assert_contains "$runtime" "PNPM_CONFIG_${pnpm_setting}_DIR"
done
assert_contains "$entrypoint" 'chown 0:0 "$pnpm_data_parent"'
assert_contains "$entrypoint" 'chmod 0700 "$pnpm_data_dir"'
pass "guest pnpm bootstrap and mutable data stay off every VirtioFS-backed HOME"

tests_run=$((tests_run + 1))
new_case unknown_profile
if run_program "$repo_root/bin/agent-container" unknown-agent \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "unknown profile should be rejected"
fi
assert_contains "$case_dir/err" "Unknown or unsafe Agent profile 'unknown-agent'"
[ ! -s "$case_log" ] || fail "unknown profile contacted the Apple runtime"
pass "unknown profiles fail before runtime startup"

tests_run=$((tests_run + 1))
new_case oversized_profile_id
oversized_profile_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
if run_program "$repo_root/bin/agent-container" "$oversized_profile_id" \
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
if run_program "$repo_root/bin/agent-container" broken \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "malformed profile JSON should be rejected"
fi
assert_contains "$case_dir/err" "Agent profile 'broken' is not valid schema-2 JSON"
[ ! -s "$case_log" ] || fail "malformed profile contacted the Apple runtime"
pass "malformed profile JSON fails closed"

tests_run=$((tests_run + 1))
new_case unsupported_schema
copy_case_assets
sed 's/"schema": 2/"schema": 3/' "$repo_root/runtime/profiles/claude.json" \
  > "$case_asset_dir/profiles/schema.json"
sed 's/"id": "claude"/"id": "schema"/' \
  "$case_asset_dir/profiles/schema.json" > "$case_dir/schema-fixed-id.json"
mv "$case_dir/schema-fixed-id.json" "$case_asset_dir/profiles/schema.json"
if run_program "$repo_root/bin/agent-container" schema \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "unsupported profile schema should be rejected"
fi
assert_contains "$case_dir/err" "Unsupported schema '3' in profile 'schema'"
[ ! -s "$case_log" ] || fail "unsupported schema contacted the Apple runtime"
pass "profile schema versions are enforced"

tests_run=$((tests_run + 1))
new_case mismatched_profile_id
copy_case_assets
cp "$repo_root/runtime/profiles/claude.json" "$case_asset_dir/profiles/alias.json"
if run_program "$repo_root/bin/agent-container" alias \
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
if ! run_program "$repo_root/bin/agent-container" envsplit --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "profile with an empty API-key field failed: $(sed -n '1p' "$case_dir/err")"
fi
assert_line "$case_log" "ARG=NO_UPDATE=1"
assert_no_line "$case_log" "ARG==1"
pass "empty optional profile fields retain their schema positions"

tests_run=$((tests_run + 1))
new_case unsafe_profile_environment_fields
copy_case_assets

sed \
  -e 's/"id": "claude"/"id": "unsafe-api"/' \
  -e 's/"apiKeyEnv": "ANTHROPIC_API_KEY"/"apiKeyEnv": "SSH_AUTH_SOCK"/' \
  "$repo_root/runtime/profiles/claude.json" \
  > "$case_asset_dir/profiles/unsafe-api.json"
if run_program "$repo_root/bin/agent-container" unsafe-api --version \
  >"$case_dir/api.out" 2>"$case_dir/api.err"; then
  fail "profile apiKeyEnv accepted a launcher-managed socket name"
fi
assert_contains "$case_dir/api.err" "unsafe apiKeyEnv"

sed \
  -e 's/"id": "claude"/"id": "unsafe-update"/' \
  -e 's/"disableAutoUpdateEnv": "DISABLE_AUTOUPDATER"/"disableAutoUpdateEnv": "PATH"/' \
  "$repo_root/runtime/profiles/claude.json" \
  > "$case_asset_dir/profiles/unsafe-update.json"
if run_program "$repo_root/bin/agent-container" unsafe-update --version \
  >"$case_dir/update.out" 2>"$case_dir/update.err"; then
  fail "profile disableAutoUpdateEnv accepted a launcher-managed path name"
fi
assert_contains "$case_dir/update.err" "unsafe disableAutoUpdateEnv"

sed \
  -e 's/"id": "claude"/"id": "unsafe-installer"/' \
  -e 's/"installerVersionEnv": ""/"installerVersionEnv": "HOME"/' \
  "$repo_root/runtime/profiles/claude.json" \
  > "$case_asset_dir/profiles/unsafe-installer.json"
if run_program "$repo_root/bin/agent-container" unsafe-installer --version \
  >"$case_dir/installer.out" 2>"$case_dir/installer.err"; then
  fail "profile installerVersionEnv accepted a launcher-managed home name"
fi
assert_contains "$case_dir/installer.err" "unsafe installerVersionEnv"

sed \
  -e 's/"id": "claude"/"id": "unsafe-reuse"/' \
  -e 's/"apiKeyEnv": "ANTHROPIC_API_KEY"/"apiKeyEnv": "PROFILE_SETTING"/' \
  -e 's/"disableAutoUpdateEnv": "DISABLE_AUTOUPDATER"/"disableAutoUpdateEnv": "PROFILE_SETTING"/' \
  "$repo_root/runtime/profiles/claude.json" \
  > "$case_asset_dir/profiles/unsafe-reuse.json"
if run_program "$repo_root/bin/agent-container" unsafe-reuse --version \
  >"$case_dir/reuse.out" 2>"$case_dir/reuse.err"; then
  fail "profile reused one environment name for credentials and update control"
fi
assert_contains "$case_dir/reuse.err" \
  "reuses one environment name for credentials and update control"

sed \
  -e 's/"id": "claude"/"id": "dynamic-update"/' \
  -e 's/"disableAutoUpdateEnv": "DISABLE_AUTOUPDATER"/"disableAutoUpdateEnv": "PROFILE_UPDATE"/' \
  "$repo_root/runtime/profiles/claude.json" \
  > "$case_asset_dir/profiles/dynamic-update.json"
AGENT_CONTAINER_FORWARD_ENV=PROFILE_UPDATE
if run_program "$repo_root/bin/agent-container" dynamic-update --version \
  >"$case_dir/dynamic.out" 2>"$case_dir/dynamic.err"; then
  fail "profile update-control environment name was explicitly forwarded"
fi
assert_contains "$case_dir/dynamic.err" \
  "launcher-managed name: PROFILE_UPDATE"
[ ! -s "$case_log" ] \
  || fail "unsafe profile environment metadata contacted the Apple runtime"
pass "profile environment metadata and dynamic update controls stay launcher-managed"

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
if run_program "$repo_root/bin/agent-container" evil \
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
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true
for wrapper_profile in \
  "claude-container claude" \
  "codex-container codex" \
  "grok-container grok"; do
  wrapper=${wrapper_profile%% *}
  profile=${wrapper_profile#* }
  : > "$case_log"
  if ! run_program "$repo_root/bin/$wrapper" -- "two words" "" '*' \
    >"$case_dir/$profile.out" 2>"$case_dir/$profile.err"; then
    sed -n '1,120p' "$case_dir/$profile.err" >&2
    fail "$wrapper failed before its argument boundary could be checked"
  fi
  expected_tail=$(printf 'ARG=%s\n' "$profile" 'two words' '' '*')
  actual_tail=$(call_arguments_containing \
    "$case_log" /usr/local/bin/agent-workspace-session | tail -n 4)
  [ "$actual_tail" = "$expected_tail" ] \
    || fail "$wrapper changed profile or argument boundaries"
done
pass "all compatibility wrappers preserve exact argument boundaries"

tests_run=$((tests_run + 1))
new_case legacy_wrapper_runtime_words
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true
legacy_share="$case_dir/not-mounted"
mkdir "$legacy_share"
run_program "$repo_root/bin/grok-container" \
  --share-ro "$legacy_share" -- "two words" "" '*' \
  >"$case_dir/out" 2>"$case_dir/err"
expected_tail=$(printf 'ARG=%s\n' \
  grok --share-ro "$legacy_share" -- 'two words' '' '*')
actual_tail=$(call_arguments_containing \
  "$case_log" /usr/local/bin/agent-workspace-session | tail -n 7)
[ "$actual_tail" = "$expected_tail" ] \
  || fail "legacy wrapper invocation consumed new runtime words"
assert_no_line "$case_log" "ARG=$legacy_share:$legacy_share:ro"
pass "runtime words remain ordinary Agent arguments without an explicit run subcommand"

tests_run=$((tests_run + 1))
new_case singleton_host_tools_default_staging
TEST_SINGLETON_LAUNCH=true
singleton_host_tools_bin="$case_dir/host-tools-bin"
mkdir "$singleton_host_tools_bin"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$singleton_host_tools_bin/gh"
chmod 0755 "$singleton_host_tools_bin/gh"
TEST_RUNNER_PATH="$singleton_host_tools_bin:$fixture_dir:/usr/bin:/bin"
singleton_capture_broker="$case_dir/capture-host-broker"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'session_dir='
  printf '%s\n' 'previous='
  printf '%s\n' 'for argument in "$@"; do'
  printf '%s\n' '  [ "$previous" != --session-dir ] || session_dir=$argument'
  printf '%s\n' '  previous=$argument'
  printf '%s\n' 'done'
  printf '%s\n' '[ -n "$session_dir" ] || exit 66'
  printf 'cp -R "$session_dir" %q\n' "$case_dir/captured-session"
  printf 'exec %q "$@"\n' "$fixture_dir/host-exec-broker"
} > "$singleton_capture_broker"
chmod 0755 "$singleton_capture_broker"
AGENT_CONTAINER_HOST_BROKER_BIN="$singleton_capture_broker"
# An empty value skips the launcher flag entirely, so this case proves the
# built-in host-tools default rather than an explicit opt-in.
AGENT_CONTAINER_HOST_TOOLS=
run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_log" 'ARG=AGENT_WORKSPACE_HOST_EXEC_ENDPOINT'
assert_line "$case_log" 'ARG=AGENT_WORKSPACE_HOST_EXEC_TOKEN'
assert_no_line "$case_log" 'ARG=AGENT_WORKSPACE_HOST_EXEC_COMMANDS'
# The launcher stages the frozen catalog specification; the broker expands it
# into the command manifest and serves the guest catalog request itself.
assert_contains "$case_dir/captured-session/host-catalog.json" \
  '"first":["git","gh"]'
assert_contains "$case_dir/captured-session/host-catalog.json" \
  "\"$singleton_host_tools_bin\""
assert_contains "$case_dir/captured-session/host-catalog.json" \
  '"deny":["grok","agent-container","agent-host-exec","host-exec","claude-container","codex-container","grok-container","container","sudo"]'
assert_line "$case_dir/captured-session/host-roots.tsv" \
  "$(printf 'rw\t%s' "$case_workspace")"
awk -F '\t' '
  $1 == "rw" { writable += 1 }
  $1 == "ro" { readable += 1 }
  END { exit (writable == 1 && readable == 0) ? 0 : 1 }
' "$case_dir/captured-session/host-roots.tsv" \
  || fail "the singleton client staged more than the one writable workspace root"
grep -Eq '^[0-9a-f]{64}$' \
  "$case_dir/captured-session/host-exec-token" \
  || fail "the singleton client did not stage one 256-bit host-exec token"
singleton_staged_token=$(sed -n '1p' \
  "$case_dir/captured-session/host-exec-token")
assert_secret_absent "$case_log" "$singleton_staged_token" host-exec-token
assert_line "$case_dir/captured-session/mode" 'singleton-client'
assert_not_contains "$case_dir/err" 'Host tool proxying is disabled'
pass "singleton clients stage the full host-tool catalog and hand the channel over by name only"

tests_run=$((tests_run + 1))
new_case singleton_explicit_workspace_root
TEST_SINGLETON_LAUNCH=true
workspace_scope="$test_root/explicit-workspace-scope"
workspace_project="$workspace_scope/sample-app"
workspace_dependency="$workspace_scope/shared-harness"
mkdir -p "$workspace_project" "$workspace_dependency"
printf '%s\n' dependency > "$workspace_dependency/visible-from-common-root"
printf '%s\n' \
  '{"private":true,"devDependencies":{"@example/harness":"link:../shared-harness"}}' \
  > "$workspace_project/package.json"
AGENT_CONTAINER_WORKSPACE_ROOT="$workspace_scope"
scope_capture_broker="$case_dir/capture-host-broker"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'session_dir='
  printf '%s\n' 'previous='
  printf '%s\n' 'for argument in "$@"; do'
  printf '%s\n' '  [ "$previous" != --session-dir ] || session_dir=$argument'
  printf '%s\n' '  previous=$argument'
  printf '%s\n' 'done'
  printf '%s\n' '[ -n "$session_dir" ] || exit 66'
  printf 'cp -R "$session_dir" %q\n' "$case_dir/captured-session"
  printf 'exec %q "$@"\n' "$fixture_dir/host-exec-broker"
} > "$scope_capture_broker"
chmod 0755 "$scope_capture_broker"
AGENT_CONTAINER_HOST_BROKER_BIN="$scope_capture_broker"
AGENT_CONTAINER_HOST_TOOLS=
run_program_from "$workspace_project" \
  "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_dir/captured-session/host-roots.tsv" \
  "$(printf 'rw\t%s' "$workspace_scope")"
session_arguments=$(call_arguments_containing \
  "$case_log" /usr/local/bin/agent-workspace-session)
printf '%s\n' "$session_arguments" > "$case_dir/session.args"
assert_line "$case_dir/session.args" "ARG=$workspace_scope"
assert_line "$case_dir/session.args" "ARG=$workspace_project"
assert_no_line "$case_dir/captured-session/host-roots.tsv" \
  "$(printf 'rw\t%s' "$workspace_project")"
pass "an explicit singleton workspace root admits sibling dependencies through one SFTP and host-tool scope"

tests_run=$((tests_run + 1))
new_case singleton_workspace_root_allows_colon
TEST_SINGLETON_LAUNCH=true
colon_scope="$case_dir/workspace:scope"
colon_project="$colon_scope/project"
mkdir -p "$colon_project"
AGENT_CONTAINER_WORKSPACE_ROOT="$colon_scope"
run_program_from "$colon_project" \
  "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"
session_arguments=$(call_arguments_containing \
  "$case_log" /usr/local/bin/agent-workspace-session)
printf '%s\n' "$session_arguments" > "$case_dir/session.args"
assert_line "$case_dir/session.args" "ARG=$colon_scope"
assert_line "$case_dir/session.args" "ARG=$colon_project"
pass "SFTP-only singleton roots are not rejected by Apple volume path syntax"

tests_run=$((tests_run + 1))
new_case singleton_workspace_root_must_contain_cwd
TEST_SINGLETON_LAUNCH=true
unrelated_scope="$test_root/unrelated-workspace-scope"
mkdir "$unrelated_scope"
AGENT_CONTAINER_WORKSPACE_ROOT="$unrelated_scope"
if run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a workspace root outside the launch directory should fail"
fi
assert_contains "$case_dir/err" "does not contain the launch directory"
assert_no_line "$case_log" 'ARG=system'
assert_no_line "$case_log" 'ARG=create'
pass "an explicit workspace root cannot silently redirect the launch to another tree"

tests_run=$((tests_run + 1))
new_case singleton_workspace_root_must_contain_git_root
TEST_SINGLETON_LAUNCH=true
git_scope="$case_dir/git-scope"
git_child="$git_scope/nested/child"
mkdir -p "$git_child"
/usr/bin/git -C "$git_scope" init -q
AGENT_CONTAINER_WORKSPACE_ROOT="$git_child"
if run_program_from "$git_child" \
  "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a workspace root containing cwd but excluding its Git root should fail"
fi
assert_contains "$case_dir/err" "does not contain the detected Git root"
assert_contains "$case_dir/err" "$git_scope"
assert_no_line "$case_log" 'ARG=system'
assert_no_line "$case_log" 'ARG=create'
pass "an explicit workspace root must preserve the complete detected Git repository"

tests_run=$((tests_run + 1))
new_case singleton_workspace_root_rejects_home
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_WORKSPACE_ROOT="$case_home"
if run_program_from "$case_home" \
  "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "the real host HOME should not be accepted as a workspace root"
fi
assert_contains "$case_dir/err" "contains the real host HOME"
assert_no_line "$case_log" 'ARG=system'
assert_no_line "$case_log" 'ARG=create'
pass "workspace-root expansion never exposes the complete real HOME"

tests_run=$((tests_run + 1))
new_case legacy_run_rejects_workspace_root
AGENT_CONTAINER_WORKSPACE_ROOT="$case_workspace"
if run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "legacy run should reject the singleton-only workspace-root option"
fi
assert_contains "$case_dir/err" "supported only by the default persistent singleton"
assert_no_line "$case_log" 'ARG=system'
assert_no_line "$case_log" 'ARG=create'
pass "legacy run keeps its separate explicit-share vocabulary"

tests_run=$((tests_run + 1))
new_case singleton_host_tools_disabled
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_HOST_TOOLS=false
run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_no_line "$case_log" 'ARG=AGENT_WORKSPACE_HOST_EXEC_ENDPOINT'
assert_no_line "$case_log" 'ARG=AGENT_WORKSPACE_HOST_EXEC_TOKEN'
assert_no_line "$case_log" 'ARG=AGENT_WORKSPACE_HOST_EXEC_COMMANDS'
assert_not_contains "$case_dir/err" 'Host tool proxying'
pass "--no-container-host-tools launches without a host-tool channel or warning"

tests_run=$((tests_run + 1))
new_case singleton_host_tools_strict_failure
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_HOST_TOOLS=true
AGENT_CONTAINER_HOST_NODE_BIN=/nonexistent-agent-container-node
if run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "explicit --container-host-tools with a missing broker runtime should fail"
fi
assert_contains "$case_dir/err" 'no-container-host-tools'
assert_no_line "$case_log" 'ARG=create'
pass "an explicit host-tools opt-in fails closed before any native mutation"

tests_run=$((tests_run + 1))
new_case singleton_host_tools_graceful_fallback
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_HOST_TOOLS=
AGENT_CONTAINER_HOST_NODE_BIN=/nonexistent-agent-container-node
run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_contains "$case_dir/err" 'Host tool proxying is disabled'
assert_no_line "$case_log" 'ARG=AGENT_WORKSPACE_HOST_EXEC_ENDPOINT'
assert_line "$case_log" 'ARG=/usr/local/bin/agent-workspace-session'
pass "the default host-tools channel degrades to guest binaries with one warning"

tests_run=$((tests_run + 1))
new_case singleton_host_exec_policy_options
TEST_SINGLETON_LAUNCH=true
policy_capture_broker="$case_dir/capture-host-broker"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'session_dir='
  printf '%s\n' 'previous='
  printf '%s\n' 'for argument in "$@"; do'
  printf '%s\n' '  [ "$previous" != --session-dir ] || session_dir=$argument'
  printf '%s\n' '  previous=$argument'
  printf '%s\n' 'done'
  printf '%s\n' '[ -n "$session_dir" ] || exit 66'
  printf 'cp -R "$session_dir" %q\n' "$case_dir/captured-session"
  printf 'exec %q "$@"\n' "$fixture_dir/host-exec-broker"
} > "$policy_capture_broker"
chmod 0755 "$policy_capture_broker"
AGENT_CONTAINER_HOST_BROKER_BIN="$policy_capture_broker"
AGENT_CONTAINER_HOST_TOOLS=
AGENT_CONTAINER_HOST_EXEC_DENY=curl,wget
AGENT_CONTAINER_HOST_EXEC_FIRST=python3,git
run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_log" 'ARG=AGENT_WORKSPACE_HOST_EXEC_ENDPOINT'
assert_contains "$case_dir/captured-session/host-catalog.json" \
  ',"sudo","curl","wget"]'
# The built-in git/gh host-first defaults absorb duplicate requests.
assert_contains "$case_dir/captured-session/host-catalog.json" \
  '"first":["git","gh","python3"]'
pass "launcher deny/first list options reach the shared host-tool catalog"

tests_run=$((tests_run + 1))
new_case singleton_full_host_access_contract
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
FAKE_CAPTURE_HOST_STAGE_DIR="$case_dir/captured-host-stage"
AGENT_CONTAINER_FULL_HOST_ACCESS=true
AGENT_CONTAINER_HOST_FORWARD_PORTS=5037,8081
AGENT_CONTAINER_HOST_MIRROR=/Volumes/Devices
ANDROID_HOME=/opt/test-android
run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"
full_physical_workspace=$(cd "$case_workspace" && pwd -P)
# The host-tool broker runs unsandboxed with the loopback tunnel, never with
# the sandbox profile or the isolated execution home.
assert_line "$case_dir/captured-host-stage/fake-host-broker-args" 'ARG=--access'
assert_line "$case_dir/captured-host-stage/fake-host-broker-args" 'ARG=full'
assert_line "$case_dir/captured-host-stage/fake-host-broker-args" 'ARG=--tunnel-ports'
assert_line "$case_dir/captured-host-stage/fake-host-broker-args" 'ARG=5037,8081'
assert_no_line "$case_dir/captured-host-stage/fake-host-broker-args" 'ARG=--sandbox-bin'
assert_no_line "$case_dir/captured-host-stage/fake-host-broker-args" 'ARG=--exec-home'
# The operator's own exported environment reaches host commands; the private
# launcher protocol never does.
assert_line "$case_dir/captured-host-stage/fake-host-broker-env" \
  'ENV=ANDROID_HOME=/opt/test-android'
assert_not_contains "$case_dir/captured-host-stage/fake-host-broker-env" \
  'ENV=AGENT_CONTAINER_'
assert_not_contains "$case_dir/captured-host-stage/fake-host-broker-env" \
  'ENV=AGENT_WORKSPACE_'
# The guest session mounts the host filesystem at /host, starts below it,
# and receives the full-access handoff by name only.
assert_line "$case_log" 'ARG=/usr/local/bin/agent-workspace-session'
assert_line "$case_log" 'ARG=/host'
assert_line "$case_log" "ARG=/host$full_physical_workspace"
assert_line "$case_log" 'ARG=AGENT_WORKSPACE_FULL_ACCESS'
assert_line "$case_log" 'ARG=AGENT_WORKSPACE_HOST_MIRROR'
assert_no_line "$case_log" 'ARG=AGENT_WORKSPACE_FULL_ACCESS=1'
assert_no_line "$case_log" 'ARG=AGENT_WORKSPACE_HOST_MIRROR=/Volumes/Devices'
assert_contains "$case_dir/err" 'FULL HOST ACCESS is enabled'
assert_contains "$case_dir/err" 'agent-container singleton stop grok'
pass "full host access runs the broker unsandboxed with the operator environment and mounts the host at /host"

tests_run=$((tests_run + 1))
new_case singleton_sandboxed_env_is_unchanged_by_full_access_support
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
FAKE_CAPTURE_HOST_STAGE_DIR="$case_dir/captured-host-stage"
AGENT_CONTAINER_HOST_TOOLS=
ANDROID_HOME=/opt/test-android
run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_dir/captured-host-stage/fake-host-broker-args" 'ARG=--sandbox-bin'
assert_no_line "$case_dir/captured-host-stage/fake-host-broker-args" 'ARG=--access'
assert_not_contains "$case_dir/captured-host-stage/fake-host-broker-env" \
  'ENV=ANDROID_HOME='
assert_no_line "$case_log" 'ARG=/host'
assert_no_line "$case_log" 'ARG=AGENT_WORKSPACE_FULL_ACCESS'
assert_not_contains "$case_dir/err" 'FULL HOST ACCESS'
pass "the default sandboxed channel still withholds the operator environment and the /host mount"

tests_run=$((tests_run + 1))
new_case full_host_access_rejects_no_host_tools
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_FULL_HOST_ACCESS=true
AGENT_CONTAINER_HOST_TOOLS=false
if run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "full host access without the host-tool channel should fail closed"
fi
assert_contains "$case_dir/err" 'do not combine it with --no-container-host-tools'
assert_no_line "$case_log" 'ARG=create'
pass "full host access refuses to run without its host-tool channel"

tests_run=$((tests_run + 1))
new_case full_host_access_options_require_the_mode
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_HOST_FORWARD_PORTS=5037
if run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "--container-host-forward-ports without full host access should fail"
fi
assert_contains "$case_dir/err" 'requires --container-full-host-access'
AGENT_CONTAINER_HOST_FORWARD_PORTS=
AGENT_CONTAINER_HOST_MIRROR=/Volumes/Devices
if run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "--container-host-mirror without full host access should fail"
fi
assert_contains "$case_dir/err" 'requires --container-full-host-access'
assert_no_line "$case_log" 'ARG=create'
pass "the forward-ports and mirror options are rejected without full host access"

tests_run=$((tests_run + 1))
new_case full_host_access_rejects_workspace_root_and_bad_ports
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_FULL_HOST_ACCESS=true
AGENT_CONTAINER_WORKSPACE_ROOT="$case_dir"
if run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "full host access with --container-workspace-root should fail"
fi
assert_contains "$case_dir/err" '--container-workspace-root is not accepted with it'
AGENT_CONTAINER_WORKSPACE_ROOT=
AGENT_CONTAINER_HOST_FORWARD_PORTS=70000
if run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "an out-of-range forwarded port should fail"
fi
assert_contains "$case_dir/err" 'out-of-range port: 70000'
AGENT_CONTAINER_HOST_FORWARD_PORTS=5037,
if run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a malformed forwarded-port list should fail"
fi
assert_contains "$case_dir/err" 'comma-separated list of TCP ports'
assert_no_line "$case_log" 'ARG=create'
pass "full host access validates its scope and port options before any native mutation"

tests_run=$((tests_run + 1))
new_case full_host_access_rejects_legacy_run
AGENT_CONTAINER_FULL_HOST_ACCESS=true
if run_program "$repo_root/bin/agent-container" run grok -- --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "full host access on legacy run should fail"
fi
assert_contains "$case_dir/err" 'supported only on the default persistent singleton path'
assert_no_line "$case_log" 'ARG=create'
pass "full host access is refused on the legacy run path"

tests_run=$((tests_run + 1))
new_case singleton_host_exec_policy_rejects_unsafe_names
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_HOST_TOOLS=
AGENT_CONTAINER_HOST_EXEC_DENY='rm -rf'
if run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "an unsafe --container-host-exec-deny name should fail closed"
fi
assert_contains "$case_dir/err" 'unsafe command name'
assert_no_line "$case_log" 'ARG=create'
pass "unsafe host-exec policy names fail before any native mutation"

tests_run=$((tests_run + 1))
new_case generic_run_read_only_share
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
FAKE_CAPTURE_HOST_STAGE_DIR="$case_dir/captured-host-stage"
read_only_share="$case_dir/read only sibling"
mkdir "$read_only_share"
# Whether the ambient machine provides gh (and where) varies between CI
# runners and developer hosts, while the program under test only sees the
# controlled PATH below. Stage a private host gh on that PATH so host-first
# staging is proven identically everywhere.
run_host_gh_bin="$case_dir/host-gh-bin"
mkdir "$run_host_gh_bin"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$run_host_gh_bin/gh"
chmod 0755 "$run_host_gh_bin/gh"
TEST_RUNNER_PATH="$run_host_gh_bin:$fixture_dir:/usr/bin:/bin"
if ! run_program "$repo_root/bin/agent-container" run grok \
  --share-ro "$read_only_share" -- "two words" "" '*' \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "generic run-mode launch failed: $(tr '\n' ' ' < "$case_dir/err")"
fi
assert_line "$case_log" "ARG=$read_only_share:$read_only_share:ro"
expected_tail=$(printf 'ARG=%s\n' grok 'two words' '' '*')
actual_tail=$(command_arguments "$case_log" create | tail -n 4)
[ "$actual_tail" = "$expected_tail" ] \
  || fail "generic run changed Agent argument boundaries"
# Run mode stages the same frozen catalog specification as singleton clients;
# the broker owns manifest expansion for both launch modes.
assert_contains "$case_dir/captured-host-stage/host-catalog.json" \
  '"first":["git","gh"]'
assert_contains "$case_dir/captured-host-stage/host-catalog.json" \
  "\"$run_host_gh_bin\""
assert_contains "$case_dir/captured-host-stage/host-catalog.json" \
  '"deny":["grok","agent-container","agent-host-exec","host-exec","claude-container","codex-container","grok-container","container","sudo"]'
assert_contains "$repo_root/runtime/entrypoint.sh" \
  'runtime_path="$host_first_dir:$runtime_path:$host_fallback_dir"'
assert_contains "$repo_root/runtime/entrypoint.sh" 'PATH="$runtime_path"'
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
pass "generic run stages the shared host-tool catalog and one read-only extra share"

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
if run_program "$repo_root/bin/agent-container" run codex -- --version \
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
if ! run_program "$repo_root/bin/agent-container" run grok -- --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a cross-root PATH symlink poisoned run startup: $(sed -n '1p' "$case_dir/err")"
fi
# The launcher freezes only the directory list; the broker's catalog builder
# owns the cross-root symlink skip, which tests/test-host-exec.sh proves
# against the real Node.js broker.
assert_contains "$case_dir/captured-host-stage/host-catalog.json" \
  "\"$poison_bin\""
pass "run freezes PATH directories and defers command selection to the broker"

tests_run=$((tests_run + 1))
new_case wrapper_run_read_write_share
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
FAKE_CAPTURE_HOST_STAGE_DIR="$case_dir/captured-host-stage"
read_write_share="$case_dir/writable sibling"
mkdir "$read_write_share"
if ! run_program "$repo_root/bin/grok-container" run \
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
if ! run_program "$repo_root/bin/agent-container" run codex \
  --no-host-exec git -- --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "run with guest Git override failed: $(sed -n '1p' "$case_dir/err")"
fi
assert_contains "$case_dir/captured-host-stage/host-catalog.json" \
  ',"sudo","git"]'
assert_contains "$case_dir/captured-host-stage/host-catalog.json" \
  '"first":["gh"]'
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
  if run_program "$repo_root/bin/agent-container" run codex \
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
if run_program "$repo_root/bin/agent-container" run codex \
  --share-ro / -- --version \
  >"$case_dir/root.out" 2>"$case_dir/root.err"; then
  fail "sharing the host filesystem root should be rejected"
fi
assert_no_line "$case_log" "ARG=create"

new_case unsafe_extra_home
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
if run_program "$repo_root/bin/agent-container" run codex \
  --share-ro "$case_home" -- --version \
  >"$case_dir/home.out" 2>"$case_dir/home.err"; then
  fail "sharing the complete real host HOME should be rejected"
fi
assert_no_line "$case_log" "ARG=create"

new_case unsafe_extra_state
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
mkdir "$case_home/.agent-container"
if run_program "$repo_root/bin/agent-container" run codex \
  --share-ro "$case_home/.agent-container" -- --version \
  >"$case_dir/state.out" 2>"$case_dir/state.err"; then
  fail "sharing private agent-container state should be rejected"
fi
assert_no_line "$case_log" "ARG=create"

new_case unsafe_extra_colon
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
colon_share="$case_dir/extra:share"
mkdir "$colon_share"
if run_program "$repo_root/bin/agent-container" run codex \
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
for generated_index in $(seq 1 12); do
  touch "$budget_share/generated-$generated_index"
done
AGENT_CONTAINER_MAX_FILES=30
if run_program "$repo_root/bin/agent-container" run codex \
  --share-ro "$budget_share" -- --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "extra shares should count against the VirtioFS file budget"
fi
assert_contains "$case_dir/err" "Projected VirtioFS shares"
assert_contains "$case_dir/err" "additional legacy share"
assert_contains "$case_dir/err" "--share-ro/--share-rw"
assert_not_contains "$case_dir/err" "--container-workspace-root prevents"
assert_no_line "$case_log" "ARG=create"
pass "extra shares receive their own fail-closed VirtioFS remediation"

tests_run=$((tests_run + 1))
new_case combined_virtiofs_budget_names_largest_exact_tree
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
for generated_index in $(seq 1 10); do
  touch "$case_workspace/workspace-$generated_index"
done
combined_share="$case_dir/combined-share"
mkdir "$combined_share"
touch \
  "$combined_share/share-one" \
  "$combined_share/share-two" \
  "$combined_share/share-three"
combined_state="$case_home/.agent-container"
combined_shadow_home="$combined_state/profiles/codex/home"
mkdir -p "$combined_shadow_home"
printf '%s\n' 'managed by agent-container' \
  > "$combined_state/.agent-container-owned"
touch \
  "$combined_shadow_home/shadow-one" \
  "$combined_shadow_home/shadow-two"
AGENT_CONTAINER_MAX_FILES=33
if run_program "$repo_root/bin/agent-container" run codex \
  --share-ro "$combined_share" -- --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "several individually safe trees should still obey the combined budget"
fi
assert_contains "$case_dir/err" \
  "The largest counted tree is the legacy workspace at '$case_workspace' (10 entries)."
assert_not_contains "$case_dir/err" \
  "largest counted tree is the persistent 'codex' shadow HOME"
assert_no_line "$case_log" "ARG=create"
pass "combined-budget diagnostics compare every exact VirtioFS source"

tests_run=$((tests_run + 1))
new_case profile_isolation
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/claude.out" 2>"$case_dir/claude.err"
assert_contains "$case_dir/claude.err" "Resolved Claude Code latest channel to 2.1.220"
assert_line "$case_curl_log" "URL=https://downloads.claude.ai/claude-code-releases/latest"
assert_line "$case_curl_log" "FIRST_ARG=--disable"
assert_line "$case_curl_log" "PROXY_SET=true"
assert_line "$case_curl_log" "PROXY="
assert_line "$case_curl_log" "NOPROXY_SET=true"
assert_line "$case_curl_log" "NOPROXY=localhost,127.0.0.1"
assert_line "$case_security_log" \
  "ARG=https://downloads.claude.ai/claude-code-releases/bootstrap.sh"
assert_no_line "$case_security_log" "ARG=https://claude.ai/install.sh"
assert_native_installer_build_args \
  "$case_log" \
  claude \
  https://downloads.claude.ai/claude-code-releases/bootstrap.sh \
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
run_program "$repo_root/bin/agent-container" codex exec "argument with spaces" \
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
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/claude-warm.out" 2>"$case_dir/claude-warm.err"
assert_no_line "$case_log" "ARG=build"
assert_line "$case_log" "ARG=claude"
[ -f "$claude_shadow_home/profile-sentinel" ] \
  || fail "warm Claude run lost its isolated shadow HOME"
pass "official native channels, installer metadata, images, and shadow HOMEs remain isolated"

tests_run=$((tests_run + 1))
new_case profile_scoped_image_ref
AGENT_CONTAINER_IMAGE='shared-agent-image:latest'
if run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "an arbitrary image reference should be rejected"
fi
assert_contains "$case_dir/err" "custom image references are unsupported"
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
ANTHROPIC_AUTH_TOKEN='ANTHROPIC_AUTH_SECRET_DO_NOT_LOG'
OPENAI_API_KEY='OPENAI_SECRET_DO_NOT_LOG'
XAI_API_KEY='XAI_SECRET_DO_NOT_LOG'
export CLAUDE_CODE_OAUTH_TOKEN='CLAUDE_OAUTH_SECRET_DO_NOT_LOG'
export ANTHROPIC_WEBHOOK_SIGNING_KEY='WEBHOOK_SECRET_DO_NOT_LOG'
SSH_AUTH_SOCK="$case_home/ssh-agent.sock"
FAKE_CAPTURE_GITCONFIG="$case_dir/staged.gitconfig"
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"

for api_name in \
  ANTHROPIC_API_KEY \
  ANTHROPIC_AUTH_TOKEN \
  OPENAI_API_KEY \
  XAI_API_KEY \
  CLAUDE_CODE_OAUTH_TOKEN \
  ANTHROPIC_WEBHOOK_SIGNING_KEY; do
  assert_no_line "$case_log" "ARG=$api_name"
done
assert_secret_absent "$case_log" "$ANTHROPIC_API_KEY" ANTHROPIC_API_KEY
assert_secret_absent "$case_log" "$ANTHROPIC_AUTH_TOKEN" ANTHROPIC_AUTH_TOKEN
assert_secret_absent "$case_log" "$OPENAI_API_KEY" OPENAI_API_KEY
assert_secret_absent "$case_log" "$XAI_API_KEY" XAI_API_KEY
assert_secret_absent "$case_log" "$CLAUDE_CODE_OAUTH_TOKEN" CLAUDE_CODE_OAUTH_TOKEN
assert_secret_absent "$case_log" "$ANTHROPIC_WEBHOOK_SIGNING_KEY" ANTHROPIC_WEBHOOK_SIGNING_KEY
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
pass "default runtime boundary excludes credentials, prefix-only variables, SSH, GH, and full Git config"

tests_run=$((tests_run + 1))
new_case claude_environment_requires_explicit_names
claude_setting_value='runtime value with spaces = opus[1M] MUST_NOT_BE_LOGGED'
claude_setting_names=(
  _ANTHROPIC_API_PROVIDER
  ANTHROPIC_BASE_URL
  ANTHROPIC_MODEL
  ANTHROPIC_SMALL_FAST_MODEL
  CLAUDE_CODE_EFFORT_LEVEL
  CLAUDE_CODE_NO_FLICKER
)
for claude_setting_name in "${claude_setting_names[@]}"; do
  export "$claude_setting_name=$claude_setting_value"
done
export DISABLE_AUTOUPDATER=0
export CLAUDE_CODE_OAUTH_TOKEN='PREFIX_SECRET_MUST_NOT_BE_LOGGED'
export ANTHROPIC_WEBHOOK_SIGNING_KEY='ANTHROPIC_PREFIX_SECRET_MUST_NOT_BE_LOGGED'
ANTHROPIC_API_KEY='DEFAULT_API_KEY_MUST_NOT_BE_LOGGED'
ANTHROPIC_AUTH_TOKEN='DEFAULT_AUTH_TOKEN_MUST_NOT_BE_LOGGED'
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/default.out" 2>"$case_dir/default.err"
for claude_setting_name in "${claude_setting_names[@]}"; do
  assert_no_line "$case_log" "ARG=$claude_setting_name"
done
assert_line "$case_log" "ARG=DISABLE_AUTOUPDATER=1"
assert_no_line "$case_log" "ARG=DISABLE_AUTOUPDATER=0"
assert_no_line "$case_log" "ARG=ANTHROPIC_API_KEY"
assert_no_line "$case_log" "ARG=ANTHROPIC_AUTH_TOKEN"
assert_no_line "$case_log" "ARG=CLAUDE_CODE_OAUTH_TOKEN"
assert_no_line "$case_log" "ARG=ANTHROPIC_WEBHOOK_SIGNING_KEY"

: > "$case_log"
AGENT_CONTAINER_FORWARD_ENV='_ANTHROPIC_API_PROVIDER,ANTHROPIC_BASE_URL,ANTHROPIC_MODEL,ANTHROPIC_SMALL_FAST_MODEL,CLAUDE_CODE_EFFORT_LEVEL,CLAUDE_CODE_NO_FLICKER,_ANTHROPIC_API_PROVIDER'
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/explicit.out" 2>"$case_dir/explicit.err"
for claude_setting_name in "${claude_setting_names[@]}"; do
  [ "$(grep -Fxc -- "ARG=$claude_setting_name" "$case_log")" -eq 1 ] \
    || fail "explicit Claude setting $claude_setting_name was not forwarded exactly once"
done
assert_secret_absent "$case_log" "$claude_setting_value" "Claude setting"
assert_secret_absent "$case_log" "$ANTHROPIC_API_KEY" ANTHROPIC_API_KEY
assert_secret_absent "$case_log" "$ANTHROPIC_AUTH_TOKEN" ANTHROPIC_AUTH_TOKEN
assert_secret_absent "$case_log" "$CLAUDE_CODE_OAUTH_TOKEN" CLAUDE_CODE_OAUTH_TOKEN
assert_secret_absent "$case_log" "$ANTHROPIC_WEBHOOK_SIGNING_KEY" ANTHROPIC_WEBHOOK_SIGNING_KEY
pass "Claude endpoints, models, and settings require exact name-only forwarding"

tests_run=$((tests_run + 1))
new_case custom_provider_requires_explicit_names
export _ANTHROPIC_API_PROVIDER='custom-provider'
export ANTHROPIC_BASE_URL='https://provider.example.test/anthropic'
export ANTHROPIC_MODEL='provider-model'
ANTHROPIC_AUTH_TOKEN='PROVIDER_AUTH_MUST_NOT_BE_LOGGED'
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/default.out" 2>"$case_dir/default.err"
for provider_env_name in \
  _ANTHROPIC_API_PROVIDER ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_AUTH_TOKEN; do
  assert_no_line "$case_log" "ARG=$provider_env_name"
done

: > "$case_log"
AGENT_CONTAINER_FORWARD_ENV='_ANTHROPIC_API_PROVIDER,ANTHROPIC_BASE_URL,ANTHROPIC_MODEL,ANTHROPIC_AUTH_TOKEN'
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/explicit.out" 2>"$case_dir/explicit.err"
for provider_env_name in \
  _ANTHROPIC_API_PROVIDER ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_AUTH_TOKEN; do
  assert_line "$case_log" "ARG=$provider_env_name"
done
assert_create_env_name "$case_log" ANTHROPIC_AUTH_TOKEN
assert_secret_absent "$case_log" "$ANTHROPIC_AUTH_TOKEN" ANTHROPIC_AUTH_TOKEN
assert_secret_absent "$case_dir/explicit.out" "$ANTHROPIC_AUTH_TOKEN" ANTHROPIC_AUTH_TOKEN
assert_secret_absent "$case_dir/explicit.err" "$ANTHROPIC_AUTH_TOKEN" ANTHROPIC_AUTH_TOKEN
pass "custom providers require every endpoint, model, provider, and token name explicitly"

tests_run=$((tests_run + 1))
new_case api_key_forward_boolean_modes
ANTHROPIC_API_KEY='BOOLEAN_API_KEY_MUST_NOT_BE_LOGGED'
AGENT_CONTAINER_FORWARD_API_KEY=false
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/false.out" 2>"$case_dir/false.err"
assert_no_line "$case_log" "ARG=ANTHROPIC_API_KEY"

: > "$case_log"
AGENT_CONTAINER_FORWARD_API_KEY=true
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/true.out" 2>"$case_dir/true.err"
assert_line "$case_log" "ARG=ANTHROPIC_API_KEY"
assert_create_env_name "$case_log" ANTHROPIC_API_KEY
assert_secret_absent "$case_log" "$ANTHROPIC_API_KEY" ANTHROPIC_API_KEY

: > "$case_log"
AGENT_CONTAINER_FORWARD_API_KEY=auto
if run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/auto.out" 2>"$case_dir/auto.err"; then
  fail "the removed auto credential mode should fail"
fi
assert_contains "$case_dir/auto.err" \
  "forward-api-key"
assert_secret_absent "$case_dir/auto.out" "$ANTHROPIC_API_KEY" ANTHROPIC_API_KEY
assert_secret_absent "$case_dir/auto.err" "$ANTHROPIC_API_KEY" ANTHROPIC_API_KEY
[ ! -s "$case_log" ] \
  || fail "removed auto credential mode contacted the Apple runtime"
pass "API-key forwarding defaults off, uses public boolean flags, and rejects auto"

tests_run=$((tests_run + 1))
new_case explicit_profile_api_key
ANTHROPIC_API_KEY='ANTHROPIC_VALUE_MUST_NOT_BE_LOGGED'
OPENAI_API_KEY='OPENAI_VALUE_MUST_NOT_BE_LOGGED'
XAI_API_KEY='XAI_VALUE_MUST_NOT_BE_LOGGED'
AGENT_CONTAINER_FORWARD_API_KEY=true
run_program "$repo_root/bin/agent-container" codex --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_log" "ARG=OPENAI_API_KEY"
assert_no_line "$case_log" "ARG=ANTHROPIC_API_KEY"
assert_no_line "$case_log" "ARG=XAI_API_KEY"
assert_secret_absent "$case_log" "$ANTHROPIC_API_KEY" ANTHROPIC_API_KEY
assert_secret_absent "$case_log" "$OPENAI_API_KEY" OPENAI_API_KEY
assert_secret_absent "$case_log" "$XAI_API_KEY" XAI_API_KEY
pass "API-key opt-in forwards only the active profile variable name"

tests_run=$((tests_run + 1))
new_case profile_json_is_only_api_key_authority
ANTHROPIC_API_KEY='CLAUDE_API_KEY_MUST_NOT_BE_LOGGED'
ANTHROPIC_AUTH_TOKEN='CLAUDE_AUTH_VALUE_MUST_NOT_BE_LOGGED'
AGENT_CONTAINER_FORWARD_API_KEY=true
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_log" "ARG=ANTHROPIC_API_KEY"
assert_no_line "$case_log" "ARG=ANTHROPIC_AUTH_TOKEN"
assert_secret_absent "$case_log" "$ANTHROPIC_API_KEY" ANTHROPIC_API_KEY
assert_secret_absent "$case_log" "$ANTHROPIC_AUTH_TOKEN" ANTHROPIC_AUTH_TOKEN
pass "API-key opt-in forwards only the active profile JSON apiKeyEnv"

tests_run=$((tests_run + 1))
new_case missing_profile_credential
AGENT_CONTAINER_FORWARD_API_KEY=true
if run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "credential opt-in without an exported Claude credential should fail"
fi
assert_contains "$case_dir/err" "no credential recognized for profile 'claude' is set and exported"
assert_no_line "$case_log" "ARG=create"
pass "credential opt-in fails clearly when no recognized credential is available"

tests_run=$((tests_run + 1))
new_case explicit_environment_escape_hatch
export TEST_EXPLICIT_ENV='explicit value with spaces MUST_NOT_BE_LOGGED'
export TEST_EMPTY_ENV=
export CLAUDE_CODE_EFFORT_LEVEL=max
AGENT_CONTAINER_FORWARD_ENV='TEST_EXPLICIT_ENV,TEST_EMPTY_ENV,CLAUDE_CODE_EFFORT_LEVEL,TEST_EXPLICIT_ENV'
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"
[ "$(grep -Fxc -- 'ARG=TEST_EXPLICIT_ENV' "$case_log")" -eq 1 ] \
  || fail "explicit environment variable was not forwarded exactly once"
[ "$(grep -Fxc -- 'ARG=TEST_EMPTY_ENV' "$case_log")" -eq 1 ] \
  || fail "explicit empty environment variable was not forwarded exactly once"
[ "$(grep -Fxc -- 'ARG=CLAUDE_CODE_EFFORT_LEVEL' "$case_log")" -eq 1 ] \
  || fail "explicit environment duplicate was not deduplicated"
assert_secret_absent "$case_log" "$TEST_EXPLICIT_ENV" TEST_EXPLICIT_ENV
pass "explicit forwarding supports future and empty settings and deduplicates exact names"

tests_run=$((tests_run + 1))
new_case invalid_explicit_environment
for managed_env_name in \
  HOME \
  AGENT_CONTAINER \
  AGENT_CONTAINER_CPUS \
  AGENT_CONTAINER_HOST_EXEC \
  AGENT_WORKSPACE_TOKEN \
  AGENT_PROFILE \
  AGENT_VERSION \
  AGENT_COMMAND \
  AGENT_PROBE_ARG \
  AGENT_CA_FINGERPRINT \
  AGENT_INSTALLER_URL \
  AGENT_INSTALLER_SHELL \
  AGENT_INSTALLER_VERSION_ENV \
  AGENT_INSTALLER_BIN_DIR_ENV \
  AGENT_INSTALLER_HOME_ENV \
  AGENT_INSTALLER_NONINTERACTIVE_ENV \
  HOST_UID \
  HOST_GID \
  HOST_HOME \
  XDG_RUNTIME_DIR \
  IS_SANDBOX \
  BASE_IMAGE \
  DEFAULT_BASE_IMAGE \
  COREPACK_HOME \
  COREPACK_ENABLE_NETWORK \
  COREPACK_DEFAULT_TO_LATEST \
  PNPM_CONFIG_STORE_DIR \
  PNPM_CONFIG_CACHE_DIR \
  PNPM_CONFIG_STATE_DIR \
  HTTP_PROXY \
  FTP_PROXY \
  BASH_COMPAT \
  CURL_HOME \
  GIT_CONFIG_COUNT \
  OPENSSL_CONF \
  SSL_CERT_FILE \
  SSLKEYLOGFILE \
  XDG_CONFIG_HOME \
  SSH_ASKPASS_REQUIRE \
  SSH_AUTH_SOCK \
  POSIXLY_CORRECT \
  CDPATH \
  GLOBIGNORE \
  IFS \
  PS4 \
  PROMPT_COMMAND \
  DISABLE_AUTOUPDATER \
  LD_PRELOAD \
  DYLD_INSERT_LIBRARIES \
  BASH_ENV; do
  AGENT_CONTAINER_FORWARD_ENV="$managed_env_name"
  if run_program "$repo_root/bin/agent-container" claude --version \
    >"$case_dir/reserved-$managed_env_name.out" \
    2>"$case_dir/reserved-$managed_env_name.err"; then
    fail "launcher-managed explicit environment name $managed_env_name should fail"
  fi
  assert_contains \
    "$case_dir/reserved-$managed_env_name.err" \
    "launcher-managed name: $managed_env_name"
  [ ! -s "$case_log" ] \
    || fail "reserved environment rejection contacted the Apple runtime"
done

AGENT_CONTAINER_FORWARD_ENV=NOT_EXPORTED
if run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/unset.out" 2>"$case_dir/unset.err"; then
  fail "an unset explicit environment name should fail"
fi
assert_contains "$case_dir/unset.err" "'NOT_EXPORTED', but it is unset or not exported"
[ ! -s "$case_log" ] || fail "unset environment rejection contacted the Apple runtime"

AGENT_CONTAINER_FORWARD_ENV='bad-name'
if run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/invalid.out" 2>"$case_dir/invalid.err"; then
  fail "an invalid explicit environment name should fail"
fi
assert_contains "$case_dir/invalid.err" "contains an invalid environment-variable name"
[ ! -s "$case_log" ] || fail "invalid environment rejection contacted the Apple runtime"

AGENT_CONTAINER_FORWARD_ENV='GOOD,,BAD'
if run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/empty.out" 2>"$case_dir/empty.err"; then
  fail "an explicit environment list with an empty item should fail"
fi
assert_contains "$case_dir/empty.err" "without empty entries"
[ ! -s "$case_log" ] || fail "malformed environment list contacted the Apple runtime"
pass "explicit forwarding rejects reserved, unset, invalid, and malformed names before runtime access"

tests_run=$((tests_run + 1))
new_case preview_grok
run_program "$repo_root/bin/grok-container" "argument with spaces" \
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
pass "preview Grok uses its official native channel and installer metadata without a profile-specific gate"

tests_run=$((tests_run + 1))
new_case floating_native_latest
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true
FAKE_GROK_LATEST_VERSION=0.2.114
run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
assert_contains "$case_dir/first.err" "Resolved Grok CLI latest channel to 0.2.114"
assert_line "$case_curl_log" "URL=https://x.ai/cli/stable"
assert_line "$case_log" "ARG=AGENT_VERSION=0.2.114"

: > "$case_log"
: > "$case_curl_log"
run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/warm.out" 2>"$case_dir/warm.err"
assert_line "$case_curl_log" "URL=https://x.ai/cli/stable"
assert_no_line "$case_log" "ARG=build"

: > "$case_log"
: > "$case_curl_log"
FAKE_GROK_LATEST_VERSION=0.2.115
run_program "$repo_root/bin/grok-container" --version \
  >"$case_dir/updated.out" 2>"$case_dir/updated.err"
assert_contains "$case_dir/updated.err" "Resolved Grok CLI latest channel to 0.2.115"
assert_line "$case_curl_log" "URL=https://x.ai/cli/stable"
assert_line "$case_log" "ARG=build"
assert_line "$case_log" "ARG=AGENT_VERSION=0.2.115"
pass "an unchanged native latest channel is warm and a moved channel rebuilds"

tests_run=$((tests_run + 1))
new_case image_assets_invalidate_image_recipe
copy_case_assets
AGENT_CONTAINER_VERSION=0.146.0
run_program "$repo_root/bin/codex-container" --version \
  >"$case_dir/first.out" 2>"$case_dir/first.err"

printf '%s\n' '# fingerprint mutation: image setup' \
  >> "$case_asset_dir/image-setup.sh"
run_program "$repo_root/bin/codex-container" --version \
  >"$case_dir/image-setup.out" 2>"$case_dir/image-setup.err"

printf '%s\n' '# fingerprint mutation: connect' \
  >> "$case_asset_dir/agent-workspace-connect"
run_program "$repo_root/bin/codex-container" --version \
  >"$case_dir/connect.out" 2>"$case_dir/connect.err"

printf '%s\n' '# fingerprint mutation: session' \
  >> "$case_asset_dir/agent-workspace-session"
run_program "$repo_root/bin/codex-container" --version \
  >"$case_dir/session.out" 2>"$case_dir/session.err"

[ "$(grep -Fxc -- 'ARG=build' "$case_log")" -eq 4 ] \
  || fail "image setup and workspace helper changes did not invalidate the recipe independently"
pass "image setup and both workspace helpers participate in image reuse"

tests_run=$((tests_run + 1))
new_case malicious_plain_version_response
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true
malicious_version_sentinel="$case_dir/version-response-was-executed"
FAKE_VERSION_RESPONSE_OVERRIDE='0.2.114;touch '"$malicious_version_sentinel"
if run_program "$repo_root/bin/grok-container" --version \
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
if run_program "$repo_root/bin/codex-container" --version \
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
if run_program "$repo_root/bin/claude-container" --version \
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
run_program "$repo_root/bin/grok-container" --version \
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
if run_program "$repo_root/bin/grok-container" --version \
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
FAKE_RUN_SLEEP=300
launch_exec "$repo_root/bin/claude-container" --version \
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
  [ "$attempt" -lt 1200 ] \
    || fail "Claude session did not reach the fake runtime"
  sleep 0.05
done
[ "$(sed -n '1p' "$case_home/.agent-container/session.lock/profile")" = claude ] \
  || fail "global lock did not record the owning profile"

case_log="$case_dir/codex-container.log"
: > "$case_log"
FAKE_RUN_SLEEP=""
if run_program "$repo_root/bin/codex-container" --version \
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
run_program "$repo_root/bin/agent-container" claude --version \
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
if run_program "$repo_root/bin/agent-container" claude --version \
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
if run_program "$repo_root/bin/agent-container" claude --version \
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
if run_program "$repo_root/bin/agent-container" claude --version \
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
FAKE_RUN_SLEEP=300
first_log="$case_log"
launch_exec "$repo_root/bin/claude-container" --version \
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
  [ "$attempt" -lt 1200 ] || fail "first concurrent session did not start"
  sleep 0.05
done

case_log="$case_dir/same-profile.log"
: > "$case_log"
FAKE_RUN_SLEEP=""
if run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/same.out" 2>"$case_dir/same.err"; then
  fail "a second same-profile session bypassed image serialization"
fi
assert_contains "$case_dir/same.err" "Same-profile sessions are serialized"
assert_no_line "$case_log" "ARG=start"
kill -0 "$launcher_pid" 2>/dev/null \
  || fail "first same-profile session exited before the distinct-profile check"

case_log="$case_dir/other-profile.log"
: > "$case_log"
run_program "$repo_root/bin/codex-container" --version \
  >"$case_dir/other.out" 2>"$case_dir/other.err"
assert_line "$case_log" "ARG=start"
kill -0 "$launcher_pid" 2>/dev/null \
  || fail "first same-profile session exited during the distinct-profile check"

kill -TERM "$launcher_pid" \
  || fail "unable to terminate the first same-profile session"
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
  | run_program "$repo_root/bin/claude-container" --version \
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
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/warm.out" 2>"$case_dir/warm.err"
: > "$case_log"
pty_launcher=(/bin/bash "$repo_root/bin/agent-container")
pty_asset_dir="$repo_root/runtime"
if [ -n "$test_launcher_override" ]; then
  pty_launcher=("$test_root/agent-container")
  pty_asset_dir=$test_override_asset_dir
fi
if ! (
  cd "$case_workspace"
  exec /usr/bin/env -i \
    HOME="$case_home" \
    PATH="$curl_wrapper_dir:$fixture_dir:/usr/bin:/bin" \
    LANG=C \
    TERM=xterm-256color \
    FAKE_CONTAINER_LOG="$case_log" \
    FAKE_CREATED_CONTAINER_STATE="$case_home/fake-created-container.json" \
    FAKE_IMAGE_STATE_DIR="$case_home/fake-images" \
    FAKE_READ_STDIN=true \
    /usr/bin/python3 "$repo_root/tests/pty-run.py" --pipe-stdin \
      "${pty_launcher[@]}" \
        --container-bin "$fixture_dir/container" \
        --container-assets "$pty_asset_dir" \
        --container-host-gateway 127.0.0.1 \
        --container-openssl "$fixture_dir/openssl" \
        --container-security "$fixture_dir/security" \
        --container-disable-fd-watchdog \
        --container-version 2.1.220 \
        claude --version
) >"$case_dir/pty.out" 2>"$case_dir/pty.err"; then
  sed -n '1,120p' "$case_dir/pty.out" >&2
  sed -n '1,120p' "$case_dir/pty.err" >&2
  sed -n '1,160p' "$case_log" >&2
  fail "piped-stdin PTY run failed"
fi
assert_line "$case_log" "ARG=--interactive"
assert_no_line "$case_log" "ARG=--tty"
assert_line "$case_log" "STDIN_TTY=false"
assert_line "$case_log" "READ=pipe-to-terminal-output"
pass "piped stdin with terminal stdout avoids Apple ProcessIO ENOTTY"

tests_run=$((tests_run + 1))
new_case exit_status
FAKE_RUN_STATUS=37
set +e
run_program "$repo_root/bin/codex-container" --version \
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
if run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "VirtioFS file-count threshold should fail closed"
fi
assert_contains "$case_dir/err" "A budget-exceeding tree is the legacy workspace"
assert_contains "$case_dir/err" "container/issues/1097"
assert_no_line "$case_log" "ARG=start"
pass "VirtioFS issue #1097 names a capped legacy workspace without claiming an exact largest tree"

tests_run=$((tests_run + 1))
new_case virtiofs_planned_stage_gate
AGENT_CONTAINER_MAX_FILES=7
if run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a budget below planned cold staging should fail closed"
fi
assert_contains "$case_dir/err" \
  "ephemeral legacy session staging"
assert_contains "$case_dir/err" "(9 entries)"
assert_command_count "$case_log" system 0
pass "cold staging is projected before Apple service startup"

tests_run=$((tests_run + 1))
new_case stopped_service_planned_stage_gate
FAKE_SYSTEM_RUNNING=false
AGENT_CONTAINER_MAX_FILES=17
if run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "planned staging should exceed the cold budget before service startup"
fi
assert_contains "$case_dir/err" \
  "ephemeral legacy session staging"
assert_command_count "$case_log" system 0
assert_no_line "$case_log" 'ARG=start'
assert_no_line "$case_log" 'ARG=build'
pass "full cold staging projection rejects before stopped services are mutated"

tests_run=$((tests_run + 1))
new_case singleton_shadow_home_virtiofs_gate
TEST_SINGLETON_LAUNCH=true
FAKE_SYSTEM_RUNNING=false
AGENT_CONTAINER_MAX_FILES=10
shadow_state="$case_home/.agent-container"
shadow_profile_home="$shadow_state/profiles/claude/home"
mkdir -p "$shadow_profile_home"
printf '%s\n' 'managed by agent-container' \
  > "$shadow_state/.agent-container-owned"
touch \
  "$shadow_profile_home/generated-one" \
  "$shadow_profile_home/generated-two" \
  "$shadow_profile_home/generated-three"
if run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "an oversized singleton shadow HOME should fail closed"
fi
assert_contains "$case_dir/err" "persistent 'claude' shadow HOME"
assert_contains "$case_dir/err" "$shadow_profile_home"
assert_contains "$case_dir/err" "The largest counted tree"
assert_contains "$case_dir/err" "--container-workspace-root"
assert_command_count "$case_log" system 0
assert_command_count "$case_log" list 0
assert_no_line "$case_log" 'ARG=build'
assert_no_line "$case_log" 'ARG=create'
pass "shadow-HOME offenders are named before stopped Apple services are mutated"

tests_run=$((tests_run + 1))
new_case singleton_capped_shadow_home_virtiofs_gate
TEST_SINGLETON_LAUNCH=true
FAKE_SYSTEM_RUNNING=false
AGENT_CONTAINER_MAX_FILES=10
shadow_state="$case_home/.agent-container"
shadow_profile_home="$shadow_state/profiles/claude/home"
mkdir -p "$shadow_profile_home"
printf '%s\n' 'managed by agent-container' \
  > "$shadow_state/.agent-container-owned"
for generated_index in $(seq 1 12); do
  touch "$shadow_profile_home/generated-$generated_index"
done
if run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a bounded shadow-HOME scan above the budget should fail closed"
fi
assert_contains "$case_dir/err" "A budget-exceeding tree is the persistent 'claude' shadow HOME"
assert_contains "$case_dir/err" "bounded scan did not compute its exact size"
assert_not_contains "$case_dir/err" "The largest tree"
assert_command_count "$case_log" system 0
pass "capped scans identify one budget-exceeding tree without a false largest-tree claim"

tests_run=$((tests_run + 1))
new_case singleton_shadow_home_risk_acceptance
TEST_SINGLETON_LAUNCH=true
FAKE_SYSTEM_RUNNING=false
AGENT_CONTAINER_MAX_FILES=10
AGENT_CONTAINER_ACCEPT_VIRTIOFS_RISK=true
shadow_state="$case_home/.agent-container"
shadow_profile_home="$shadow_state/profiles/claude/home"
mkdir -p "$shadow_profile_home"
printf '%s\n' 'managed by agent-container' \
  > "$shadow_state/.agent-container-owned"
touch \
  "$shadow_profile_home/generated-one" \
  "$shadow_profile_home/generated-two" \
  "$shadow_profile_home/generated-three"
run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_command_count "$case_log" system 3
assert_line "$case_log" 'ARG=create'
pass "explicit risk acceptance still crosses the reordered local preflight"

tests_run=$((tests_run + 1))
new_case precreate_virtiofs_recount
AGENT_CONTAINER_MAX_FILES=20
build_gate="$case_dir/build.gate"
build_marker="$case_dir/build.marker"
gated_container="$case_dir/gated-container"
: > "$build_gate"
: > "$build_marker"
write_build_gated_container "$gated_container"
TEST_CONTAINER_BIN="$gated_container"
TEST_FAKE_CONTAINER_REAL="$fixture_dir/container"
TEST_FAKE_BUILD_GATE="$build_gate"
TEST_FAKE_BUILD_MARKER="$build_marker"
run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err" &
background_pid=$!
for build_wait_attempt in $(seq 1 3000); do
  [ -s "$build_marker" ] && break
  kill -0 "$background_pid" 2>/dev/null \
    || fail "gated launch exited before reaching image build"
  sleep 0.01
done
[ -s "$build_marker" ] \
  || fail "gated launch did not reach image build"
for generated_index in $(seq 1 21); do
  touch "$case_workspace/generated-during-build-$generated_index"
done
rm -f "$build_gate"
set +e
wait "$background_pid"
recount_status=$?
set -e
background_pid=""
[ "$recount_status" -ne 0 ] \
  || fail "workspace growth during image build bypassed the final entry budget"
assert_contains "$case_dir/err" \
  "A budget-exceeding tree is the legacy workspace"
assert_line "$case_log" 'ARG=build'
assert_no_line "$case_log" 'ARG=create'
pass "cold creation re-counts VirtioFS trees after a slow image build"

tests_run=$((tests_run + 1))
new_case precreate_virtiofs_source_identity
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
swap_share="$case_dir/swap-share"
swap_backup="$case_dir/swap-backup"
swap_target="$case_dir/swap-target"
mkdir "$swap_share" "$swap_target"
build_gate="$case_dir/build.gate"
build_marker="$case_dir/build.marker"
gated_container="$case_dir/gated-container"
: > "$build_gate"
: > "$build_marker"
write_build_gated_container "$gated_container"
TEST_CONTAINER_BIN="$gated_container"
TEST_FAKE_CONTAINER_REAL="$fixture_dir/container"
TEST_FAKE_BUILD_GATE="$build_gate"
TEST_FAKE_BUILD_MARKER="$build_marker"
run_program "$repo_root/bin/agent-container" run claude \
  --share-ro "$swap_share" -- --version \
  >"$case_dir/out" 2>"$case_dir/err" &
background_pid=$!
for build_wait_attempt in $(seq 1 3000); do
  [ -s "$build_marker" ] && break
  kill -0 "$background_pid" 2>/dev/null \
    || fail "source-identity launch exited before reaching image build"
  sleep 0.01
done
[ -s "$build_marker" ] \
  || fail "source-identity launch did not reach image build"
mv "$swap_share" "$swap_backup"
mv "$swap_target" "$swap_share"
rm -f "$build_gate"
set +e
wait "$background_pid"
source_identity_status=$?
set -e
background_pid=""
[ "$source_identity_status" -ne 0 ] \
  || fail "a replaced VirtioFS source bypassed final identity validation"
assert_contains "$case_dir/err" \
  "VirtioFS source for the additional legacy share changed filesystem identity"
assert_no_line "$case_log" 'ARG=create'
pass "cold creation revalidates every frozen VirtioFS source after image work"

tests_run=$((tests_run + 1))
new_case precreate_virtiofs_source_identity_after_final_scan
AGENT_CONTAINER_HOST_BROKER_BIN="$fixture_dir/host-exec-broker"
late_swap_share="$case_dir/late-swap-share"
mkdir "$late_swap_share"
FAKE_REPLACE_DIRECTORY_ON_SYSCTL="$late_swap_share"
FAKE_REPLACE_DIRECTORY_ON_SYSCTL_SNAPSHOT=2
if run_program "$repo_root/bin/agent-container" run claude \
  --share-ro "$late_swap_share" -- --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a VirtioFS source replaced after the final scan reached create"
fi
assert_contains "$case_dir/err" \
  "VirtioFS source for the additional legacy share changed filesystem identity"
assert_no_line "$case_log" 'ARG=create'
[ -f "$late_swap_share/replacement-sentinel" ] \
  && [ -d "$late_swap_share.original" ] \
  || fail "the final-capacity fault did not replace the frozen test source"
pass "all frozen VirtioFS identities are revalidated together after the final scan"

tests_run=$((tests_run + 1))
new_case precreate_legacy_stage_recount
AGENT_CONTAINER_MAX_FILES=20
build_gate="$case_dir/build.gate"
build_marker="$case_dir/build.marker"
gated_container="$case_dir/gated-container"
: > "$build_gate"
: > "$build_marker"
write_build_gated_container "$gated_container"
TEST_CONTAINER_BIN="$gated_container"
TEST_FAKE_CONTAINER_REAL="$fixture_dir/container"
TEST_FAKE_BUILD_GATE="$build_gate"
TEST_FAKE_BUILD_MARKER="$build_marker"
run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err" &
background_pid=$!
for build_wait_attempt in $(seq 1 3000); do
  [ -s "$build_marker" ] && break
  kill -0 "$background_pid" 2>/dev/null \
    || fail "stage-recount launch exited before reaching image build"
  sleep 0.01
done
[ -s "$build_marker" ] \
  || fail "stage-recount launch did not reach image build"
legacy_stage=""
for stage_candidate in \
  "$case_home/.agent-container/sessions"/session-*; do
  [ -d "$stage_candidate" ] && [ ! -L "$stage_candidate" ] || continue
  [ -z "$legacy_stage" ] \
    || fail "legacy launch published more than one managed staging directory"
  legacy_stage="$stage_candidate"
done
[ -n "$legacy_stage" ] \
  || fail "legacy launch did not publish its managed staging directory"
for generated_index in $(seq 1 21); do
  touch "$legacy_stage/generated-during-build-$generated_index"
done
rm -f "$build_gate"
set +e
wait "$background_pid"
stage_recount_status=$?
set -e
background_pid=""
[ "$stage_recount_status" -ne 0 ] \
  || fail "legacy staging growth bypassed the final entry budget"
assert_contains "$case_dir/err" \
  "ephemeral legacy session staging"
assert_no_line "$case_log" 'ARG=create'
pass "cold creation counts the actual legacy staging tree before create"

tests_run=$((tests_run + 1))
new_case precreate_singleton_shadow_home_recount
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_MAX_FILES=20
build_gate="$case_dir/build.gate"
build_marker="$case_dir/build.marker"
gated_container="$case_dir/gated-container"
: > "$build_gate"
: > "$build_marker"
write_build_gated_container "$gated_container"
TEST_CONTAINER_BIN="$gated_container"
TEST_FAKE_CONTAINER_REAL="$fixture_dir/container"
TEST_FAKE_BUILD_GATE="$build_gate"
TEST_FAKE_BUILD_MARKER="$build_marker"
run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err" &
background_pid=$!
for build_wait_attempt in $(seq 1 3000); do
  [ -s "$build_marker" ] && break
  kill -0 "$background_pid" 2>/dev/null \
    || fail "singleton recount launch exited before reaching image build"
  sleep 0.01
done
[ -s "$build_marker" ] \
  || fail "singleton recount launch did not reach image build"
singleton_shadow_home="$case_home/.agent-container/profiles/claude/home"
[ -d "$singleton_shadow_home" ] && [ ! -L "$singleton_shadow_home" ] \
  || fail "cold singleton did not create its managed shadow HOME"
for generated_index in $(seq 1 21); do
  touch "$singleton_shadow_home/generated-during-build-$generated_index"
done
rm -f "$build_gate"
set +e
wait "$background_pid"
singleton_recount_status=$?
set -e
background_pid=""
[ "$singleton_recount_status" -ne 0 ] \
  || fail "singleton shadow-HOME growth bypassed the final entry budget"
assert_contains "$case_dir/err" \
  "persistent 'claude' shadow HOME"
assert_no_line "$case_log" 'ARG=create'
for singleton_state_name in \
  phase creator-pid agent-version image-digest config.sha256; do
  [ ! -e "$case_home/.agent-container/profiles/claude/singleton/$singleton_state_name" ] \
    || fail "a pre-create safety rejection retained stale singleton state: $singleton_state_name"
done
pass "cold singleton recounts HOME growth without publishing stale create state"

tests_run=$((tests_run + 1))
new_case low_file_baseline_preserves_soft_policy
TEST_SINGLETON_LAUNCH=true
FAKE_NUM_FILES=0
FAKE_MAX_FILES=100
FAKE_MAX_FILES_PER_PROC=1000
run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_log" 'ARG=create'
assert_not_contains "$case_dir/err" 'current host headroom'
pass "a projection below the original 70% soft line is admitted without the recovery headroom rule"

tests_run=$((tests_run + 1))
new_case high_vnode_baseline_small_growth
TEST_SINGLETON_LAUNCH=true
FAKE_MAX_VNODES=1000
FAKE_FREE_VNODES=290
run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_log" 'ARG=create'
assert_not_contains "$case_dir/err" 'current host headroom'
pass "a pre-existing vnode cache above 70% permits only a genuinely small singleton mount"

tests_run=$((tests_run + 1))
new_case vnode_projection_is_monotonic_below_boundary
FAKE_MAX_VNODES=1000
FAKE_FREE_VNODES=301
AGENT_CONTAINER_MAX_FILES=100
# 12 workspace entries + 9 actual legacy-stage entries + the shadow-HOME
# root + the conservative fixed overhead produce a 30-entry final projection.
for generated_index in $(seq 1 12); do
  touch "$case_workspace/generated-$generated_index"
done
run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_log" 'ARG=create'
assert_not_contains "$case_dir/err" 'current host headroom'
pass "a 30-entry projection is admitted with 301 vnodes of headroom"

tests_run=$((tests_run + 1))
new_case vnode_projection_is_monotonic_above_boundary
FAKE_MAX_VNODES=1000
FAKE_FREE_VNODES=300
AGENT_CONTAINER_MAX_FILES=100
# Keep this tree identical to the admitted case so only host headroom changes.
for generated_index in $(seq 1 12); do
  touch "$case_workspace/generated-$generated_index"
done
if run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "the same projection should not become safer as host vnode use rises"
fi
assert_contains "$case_dir/err" 'current host headroom'
assert_contains "$case_dir/err" 'vnodes 700/1000'
assert_no_line "$case_log" 'ARG=create'
pass "the same 30-entry projection is rejected with only 300 vnodes of headroom"

tests_run=$((tests_run + 1))
new_case high_vnode_baseline_rejects_growth
FAKE_SYSTEM_RUNNING=false
FAKE_MAX_VNODES=1000
FAKE_FREE_VNODES=290
AGENT_CONTAINER_MAX_FILES=100
for generated_index in $(seq 1 25); do
  touch "$case_workspace/generated-$generated_index"
done
if run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a high vnode baseline should reject a material new VirtioFS tree"
fi
assert_contains "$case_dir/err" 'current host headroom'
assert_contains "$case_dir/err" 'vnodes 710/1000'
assert_command_count "$case_log" system 1
assert_no_line "$case_log" 'ARG=start'
assert_no_line "$case_log" 'ARG=create'
pass "high-baseline recovery rejects growth before starting stopped Apple services"

tests_run=$((tests_run + 1))
new_case service_preflight
FAKE_SYSTEM_RUNNING=false
FAKE_SYSTEM_START_OUTPUT='Launching container-apiserver; internal progress'
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_contains "$case_dir/err" "starting them now"
assert_not_contains "$case_dir/err" 'internal progress'
assert_command_count "$case_log" system 3
assert_line "$case_log" "ARG=start"
assert_line "$case_log" "ARG=build"
pass "stopped Apple services start after local checks without leaking internal progress"

tests_run=$((tests_run + 1))
new_case service_delayed_readiness
FAKE_SYSTEM_RUNNING=false
FAKE_SYSTEM_STATUS_FAILURES_AFTER_START=2
FAKE_SYSTEM_START_OUTPUT='machine API warming up internally'
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_command_count "$case_log" system 5
assert_not_contains "$case_dir/err" 'machine API warming up internally'
assert_line "$case_log" "ARG=build"
pass "service startup tolerates bounded machine-API readiness lag without leaking progress"

tests_run=$((tests_run + 1))
new_case service_start_failure
FAKE_SYSTEM_RUNNING=false
FAKE_SYSTEM_START_FAIL=true
FAKE_SYSTEM_START_OUTPUT='machine API startup failed internally'
if run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a failed Apple service start should stop the launch"
fi
assert_contains "$case_dir/err" "Unable to start Apple container services"
assert_contains "$case_dir/err" 'machine API startup failed internally'
assert_no_line "$case_log" "ARG=build"
pass "Apple service auto-start failures remain actionable and fail closed"

tests_run=$((tests_run + 1))
new_case service_readiness_failure
FAKE_SYSTEM_RUNNING=false
FAKE_SYSTEM_READY_AFTER_START=false
FAKE_SYSTEM_START_OUTPUT='machine API remained unavailable after start'
if run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a successful start command without readiness should stop the launch"
fi
assert_contains "$case_dir/err" \
  "Apple container services did not become ready"
assert_contains "$case_dir/err" \
  'machine API remained unavailable after start'
assert_no_line "$case_log" "ARG=list"
assert_no_line "$case_log" "ARG=build"
pass "post-start readiness failures replay the suppressed startup diagnostics"

tests_run=$((tests_run + 1))
new_case singleton_control_service_preflight
FAKE_SYSTEM_RUNNING=false
run_program "$repo_root/bin/agent-container" singleton status claude \
  >"$case_dir/out" 2>"$case_dir/err"
assert_command_count "$case_log" system 3
assert_command_count "$case_log" list 1
assert_contains "$case_dir/out" 'claude singleton: stopped'
pass "singleton control keeps service auto-start before its first native query"

tests_run=$((tests_run + 1))
new_case version_preflight
FAKE_CONTAINER_VERSION=1.1.9
if run_program "$repo_root/bin/agent-container" codex --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "an old Apple container CLI should be rejected"
fi
assert_contains "$case_dir/err" "1.2.0 or newer"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=start"
pass "minimum Apple container version is enforced"

tests_run=$((tests_run + 1))
new_case explicit_network_settings
AGENT_CONTAINER_DEBIAN_MIRROR='http://mirror.example.test/debian'
AGENT_CONTAINER_HTTP_PROXY='http://proxy.example.test:8080'
AGENT_CONTAINER_NO_PROXY='localhost,127.0.0.1,example.test'
AGENT_CONTAINER_DNS1='1.1.1.1'
AGENT_CONTAINER_TZ='Asia/Singapore'
run_program "$repo_root/bin/agent-container" codex --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_log" "ARG=HTTP_PROXY=http://proxy.example.test:8080"
assert_line "$case_log" "ARG=http_proxy=http://proxy.example.test:8080"
assert_line "$case_log" "ARG=NO_PROXY=localhost,127.0.0.1,example.test"
assert_line "$case_log" "ARG=--dns"
assert_line "$case_log" "ARG=1.1.1.1"
assert_line "$case_log" "ARG=TZ=Asia/Singapore"
assert_line "$case_log" 'ARG=DEBIAN_MIRROR=http://mirror.example.test/debian'
assert_contains "$repo_root/runtime/Containerfile" \
  's|^URIs: ${DEBIAN_MIRROR}$|URIs: http://deb.debian.org/debian|'
assert_contains "$repo_root/runtime/Containerfile" \
  "grep -Fqx 'URIs: http://deb.debian.org/debian'"
assert_contains "$repo_root/runtime/Containerfile" \
  "grep -Fqx 'URIs: http://deb.debian.org/debian-security'"
assert_line "$case_curl_log" "FIRST_ARG=--disable"
assert_line "$case_curl_log" "PROXY_SET=true"
assert_line "$case_curl_log" "PROXY="
assert_line "$case_curl_log" "NOPROXY=localhost,127.0.0.1,example.test"
pass "build-only Debian mirror, HTTP proxy, DNS, and timezone stay explicitly scoped"

tests_run=$((tests_run + 1))
new_case https_debian_mirror_rejected
AGENT_CONTAINER_VERSION=0.146.0
AGENT_CONTAINER_DEBIAN_MIRROR='https://mirror.example.test/debian'
if run_program "$repo_root/bin/agent-container" codex --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "an HTTPS Debian mirror should fail before the bootstrap build"
fi
assert_contains "$case_dir/err" \
  "must use http:// because the pinned Debian slim base has no bootstrap TLS trust store"
assert_no_line "$case_log" "ARG=system"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=create"
unset AGENT_CONTAINER_DEBIAN_MIRROR
pass "HTTPS Debian mirrors fail before services or an untrusted bootstrap build"

tests_run=$((tests_run + 1))
new_case latest_lookup_https_proxy_policy
AGENT_CONTAINER_HTTPS_PROXY='https://https-proxy.example.test:8443'
AGENT_CONTAINER_ALL_PROXY='socks5://fallback-proxy.example.test:1080'
AGENT_CONTAINER_NO_PROXY='localhost,127.0.0.1,internal.example.test'
run_program "$repo_root/bin/agent-container" codex --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_curl_log" "FIRST_ARG=--disable"
assert_line "$case_curl_log" "PROXY_SET=true"
assert_line "$case_curl_log" "PROXY=https://https-proxy.example.test:8443"
assert_line "$case_curl_log" "NOPROXY_SET=true"
assert_line "$case_curl_log" "NOPROXY=localhost,127.0.0.1,internal.example.test"
assert_not_contains "$case_curl_log" "fallback-proxy.example.test"
pass "latest lookup uses only the explicit HTTPS proxy and no-proxy policy"

tests_run=$((tests_run + 1))
new_case latest_lookup_all_proxy_fallback
AGENT_CONTAINER_ALL_PROXY='socks5://all-proxy.example.test:1080'
AGENT_CONTAINER_NO_PROXY='localhost,metadata.example.test'
run_program "$repo_root/bin/agent-container" grok --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_curl_log" "FIRST_ARG=--disable"
assert_line "$case_curl_log" "PROXY_SET=true"
assert_line "$case_curl_log" "PROXY=socks5://all-proxy.example.test:1080"
assert_line "$case_curl_log" "NOPROXY_SET=true"
assert_line "$case_curl_log" "NOPROXY=localhost,metadata.example.test"
pass "latest lookup falls back to the explicit all-protocol proxy"

tests_run=$((tests_run + 1))
new_case latest_lookup_apple_host_proxy_bridge
AGENT_CONTAINER_HTTPS_PROXY='http://host.container.internal:1087'
AGENT_CONTAINER_ALL_PROXY='socks5h://host.container.internal:1080'
run_program "$repo_root/bin/agent-container" grok --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_curl_log" \
  'PROXY=http://host.container.internal:1087'
assert_line "$case_curl_log" 'RESOLVE_COUNT=1'
assert_line "$case_curl_log" \
  'RESOLVE=host.container.internal:1087:127.0.0.1'
assert_not_contains "$case_curl_log" \
  'RESOLVE=host.container.internal:1080:127.0.0.1'
assert_line "$case_log" \
  'ARG=HTTPS_PROXY=http://host.container.internal:1087'
assert_line "$case_log" \
  'ARG=ALL_PROXY=socks5h://host.container.internal:1080'
assert_not_contains "$case_log" 'ARG=HTTPS_PROXY=http://127.0.0.1:1087'
assert_not_contains "$case_log" 'ARG=ALL_PROXY=socks5h://127.0.0.1:1080'
pass "Apple host proxy bridge is loopback-resolved only for host curl"

tests_run=$((tests_run + 1))
new_case network_control_characters_rejected
AGENT_CONTAINER_VERSION=0.146.0
for control_setting_name in \
  AGENT_CONTAINER_HTTP_PROXY \
  AGENT_CONTAINER_DEBIAN_MIRROR \
  AGENT_CONTAINER_NO_PROXY \
  AGENT_CONTAINER_TZ \
  AGENT_CONTAINER_CPUS \
  AGENT_CONTAINER_MEMORY; do
  control_setting_value=$(printf 'safe\nforged-field=value')
  export "$control_setting_name=$control_setting_value"
  if run_program "$repo_root/bin/codex-container" --version \
    >"$case_dir/$control_setting_name.out" \
    2>"$case_dir/$control_setting_name.err"; then
    fail "$control_setting_name with a control character should fail closed"
  fi
  assert_contains "$case_dir/$control_setting_name.err" \
    "contains unsupported control characters"
  assert_no_line "$case_log" "ARG=build"
  assert_no_line "$case_log" "ARG=create"
  unset "$control_setting_name"
  : > "$case_log"
done

AGENT_CONTAINER_DEBIAN_MIRROR='http://mirror.example.test/debian?channel=stable'
if run_program "$repo_root/bin/codex-container" --version \
  >"$case_dir/invalid-mirror.out" \
  2>"$case_dir/invalid-mirror.err"; then
  fail "a Debian mirror URL with a query should fail closed"
fi
assert_contains "$case_dir/invalid-mirror.err" \
  "without credentials, query parameters, fragments, or a trailing slash"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=create"
unset AGENT_CONTAINER_DEBIAN_MIRROR
: > "$case_log"

control_setting_name=AGENT_CONTAINER_HTTP_PROXY
control_setting_value=$(printf 'safe\033forged-field=value')
export "$control_setting_name=$control_setting_value"
if run_program "$repo_root/bin/codex-container" --version \
  >"$case_dir/non-line-control.out" \
  2>"$case_dir/non-line-control.err"; then
  fail "$control_setting_name with a non-line control character should fail closed"
fi
assert_contains "$case_dir/non-line-control.err" \
  "contains unsupported control characters"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=create"
unset "$control_setting_name"
pass "runtime network and sizing values cannot inject singleton hash fields"

tests_run=$((tests_run + 1))
new_case docker_proxy_rejected
AGENT_CONTAINER_HTTP_PROXY='http://host.docker.internal:7890'
if run_program "$repo_root/bin/agent-container" claude --version \
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
run_program "$repo_root/bin/agent-container" codex --version \
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
new_case host_broker_ssh_agent_policy
capture_broker="$case_dir/capture-host-broker"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'if [ "${SSH_AUTH_SOCK+x}" = x ]; then'
  printf '%s\n' '  printf "SSH_AUTH_SOCK=%s\n" "$SSH_AUTH_SOCK" > "$0.env"'
  printf '%s\n' 'else'
  printf '%s\n' '  printf "SSH_AUTH_SOCK_UNSET\n" > "$0.env"'
  printf '%s\n' 'fi'
  printf 'exec %q "$@"\n' "$fixture_dir/host-exec-broker"
} > "$capture_broker"
chmod 0755 "$capture_broker"
SSH_AUTH_SOCK="$case_dir/live-ssh-agent.sock"
/usr/bin/python3 - "$SSH_AUTH_SOCK" <<'PY' &
import socket
import sys
import time

listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(sys.argv[1])
listener.listen()
while True:
    connection, _ = listener.accept()
    # Model a live socket whose listener accepts but never answers. The
    # launcher's identity probe must time out, terminate, and reap ssh-add.
    while True:
        time.sleep(1)
PY
background_pid=$!
socket_attempt=0
while [ ! -S "$SSH_AUTH_SOCK" ] && [ "$socket_attempt" -lt 100 ]; do
  sleep 0.02
  socket_attempt=$((socket_attempt + 1))
done
[ -S "$SSH_AUTH_SOCK" ] || fail "SSH-agent fixture did not publish its socket"

AGENT_CONTAINER_HOST_BROKER_BIN="$capture_broker"
run_program "$repo_root/bin/agent-container" run codex -- --version \
  >"$case_dir/default.out" 2>"$case_dir/default.err"
assert_line "$capture_broker.env" "SSH_AUTH_SOCK=$SSH_AUTH_SOCK"
assert_contains "$case_dir/default.err" \
  "The host SSH agent socket did not answer"
assert_no_line "$case_log" "ARG=--ssh"

: > "$case_log"
AGENT_CONTAINER_HOST_SSH_AGENT=false
run_program "$repo_root/bin/agent-container" run codex -- --version \
  >"$case_dir/disabled.out" 2>"$case_dir/disabled.err"
assert_line "$capture_broker.env" "SSH_AUTH_SOCK_UNSET"
assert_not_contains "$case_dir/disabled.err" \
  "The host SSH agent socket did not answer"
assert_no_line "$case_log" "ARG=--ssh"

AGENT_CONTAINER_HOST_SSH_AGENT=true
run_program "$repo_root/bin/agent-container" run codex -- --version \
  >"$case_dir/explicit.out" 2>"$case_dir/explicit.err"
assert_line "$capture_broker.env" "SSH_AUTH_SOCK=$SSH_AUTH_SOCK"

kill -TERM "$background_pid"
set +e
wait "$background_pid"
set -e
background_pid=""
rm -f "$SSH_AUTH_SOCK"
if run_program "$repo_root/bin/agent-container" run codex -- --version \
  >"$case_dir/missing.out" 2>"$case_dir/missing.err"; then
  fail "explicit host SSH-agent mode should reject a missing socket"
fi
assert_contains "$case_dir/missing.err" \
  "--container-host-ssh-agent requires SSH_AUTH_SOCK to name a live agent socket"
pass "host broker SSH-agent policy covers default, disabled, and explicit modes"

tests_run=$((tests_run + 1))
new_case lifecycle_gate
mkdir -p "$case_home/.local/share/.agent-container.install.lock"
printf '%s\n' "$$" \
  > "$case_home/.local/share/.agent-container.install.lock/pid"
if run_program "$repo_root/bin/agent-container" claude --version \
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
if run_program "$repo_root/bin/agent-container" claude --version \
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
new_case stale_owned_lifecycle_lock
stale_lifecycle_pid=900000
while kill -0 "$stale_lifecycle_pid" 2>/dev/null; do
  stale_lifecycle_pid=$((stale_lifecycle_pid + 1))
done
stale_reaper_pid=$((stale_lifecycle_pid + 1000))
while kill -0 "$stale_reaper_pid" 2>/dev/null; do
  stale_reaper_pid=$((stale_reaper_pid + 1))
done
stale_lifecycle_lock="$case_home/.local/share/.agent-container.install.lock"
mkdir -p "$stale_lifecycle_lock/.reap"
printf '%s\n' "$stale_lifecycle_pid" > "$stale_lifecycle_lock/pid"
printf '%s\n' "stale.$stale_lifecycle_pid.owner" \
  > "$stale_lifecycle_lock/owner"
# Model a reclaimer killed between publishing its PID and its owner token.
printf '%s\n' "$stale_reaper_pid" > "$stale_lifecycle_lock/.reap/pid"
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_log" "ARG=start"
if find "$case_home/.local/share" -maxdepth 1 \
  \( -name '.agent-container.install.lock' \
     -o -name '.agent-container.install.lock.reaped.*' \) \
  -print -quit | grep -q .; then
  fail "stale lifecycle recovery left a lock or quarantine directory"
fi
pass "dead owned lifecycle locks recover abandoned incomplete reaper claims"

tests_run=$((tests_run + 1))
new_case stale_legacy_lifecycle_lock
legacy_lifecycle_pid=910000
while kill -0 "$legacy_lifecycle_pid" 2>/dev/null; do
  legacy_lifecycle_pid=$((legacy_lifecycle_pid + 1))
done
legacy_lifecycle_lock="$case_home/.local/share/.agent-container.install.lock"
mkdir -p "$legacy_lifecycle_lock"
printf '%s\n' "$legacy_lifecycle_pid" > "$legacy_lifecycle_lock/pid"
if run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "a dead PID-only legacy lifecycle lock should fail closed"
fi
assert_contains "$case_dir/err" \
  "A stale legacy lifecycle lock cannot be reclaimed safely"
for mutating_command in build create start stop delete rm; do
  assert_no_line "$case_log" "ARG=$mutating_command"
done
[ "$(cat "$legacy_lifecycle_lock/pid")" = "$legacy_lifecycle_pid" ] \
  && [ ! -e "$legacy_lifecycle_lock/owner" ] \
  && [ ! -e "$legacy_lifecycle_lock/.reap" ] \
  || fail "legacy lifecycle rejection mutated the stale lock"
[ ! -e "$case_home/.agent-container" ] \
  || fail "legacy lifecycle rejection published managed runtime state"
pass "dead PID-only legacy lifecycle locks remain fail-closed and untouched"

tests_run=$((tests_run + 1))
new_case exact_state_marker
mkdir "$case_home/.agent-container"
printf '%s\n' 'managed by agent-container' 'unexpected trailing record' \
  > "$case_home/.agent-container/.agent-container-owned"
if run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "an ownership marker with trailing content should be rejected"
fi
assert_contains "$case_dir/err" "invalid agent-container ownership marker"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=start"
pass "state ownership markers require exact complete contents"

tests_run=$((tests_run + 1))
new_case exact_image_metadata
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
profile_meta="$case_home/.agent-container/profiles/claude/meta"
printf '%s\n' 'unexpected trailing record' \
  >> "$profile_meta/image-build-id"
: > "$case_log"
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/second.out" 2>"$case_dir/second.err"
assert_line "$case_log" "ARG=build"
assert_line "$case_log" "ARG=start"

printf '%s\n' 'do not replace through symlink' > "$case_dir/metadata-target"
rm -f "$profile_meta/image-ref"
ln -s "$case_dir/metadata-target" "$profile_meta/image-ref"
: > "$case_log"
if run_program "$repo_root/bin/agent-container" claude --version \
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
if run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/symlink.out" 2>"$case_dir/symlink.err"; then
  fail "state-root symlink should be rejected"
fi
assert_contains "$case_dir/symlink.err" "Refusing a symlink as the Agent container state root"
assert_no_line "$case_log" "ARG=start"

new_case home_workspace_rejected
case_workspace="$case_home"
if run_program "$repo_root/bin/agent-container" codex --version \
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
if run_program "$repo_root/bin/agent-container" claude --version \
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
  if run_program "$repo_root/bin/agent-container" claude --version \
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
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
: > "$case_log"
retagged_image_state=$(find "$case_home/fake-images" \
  -mindepth 1 -maxdepth 1 -type f -print -quit)
[ -n "$retagged_image_state" ] \
  || fail "fake image state was unavailable for retag simulation"
printf '%s\n' \
  '[{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","configuration":{"creationDate":"2026-07-29T00:00:00Z","name":"agent-container-claude:latest","descriptor":{"digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","mediaType":"application/vnd.oci.image.index.v1+json","size":123}},"variants":[]}]' \
  > "$retagged_image_state"
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/second.out" 2>"$case_dir/second.err"
assert_line "$case_log" "ARG=build"
assert_line "$case_log" "ARG=start"
pass "an externally retargeted image tag invalidates the warm cache"

tests_run=$((tests_run + 1))
new_case create_digest_verification
FAKE_RETAG_AFTER_INSPECT=true
if run_program "$repo_root/bin/agent-container" claude --version \
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
if run_program "$repo_root/bin/agent-container" claude --version \
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
if run_program "$repo_root/bin/agent-container" claude --version \
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
if run_program "$repo_root/bin/agent-container" claude --version \
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
run_program "$repo_root/bin/agent-container" claude --version \
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
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/warm.out" 2>"$case_dir/warm.err"
: > "$case_log"
FAKE_RUN_OUTPUT='agent-output-only'
run_program "$repo_root/bin/agent-container" claude --version \
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
run_program "$repo_root/bin/agent-container" claude --version \
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
run_program "$repo_root/bin/agent-container" claude --version \
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
run_program "$repo_root/bin/agent-container" claude --version \
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
new_case singleton_default_all_profiles
TEST_SINGLETON_LAUNCH=true
for singleton_profile_version in \
  'claude 2.1.220' \
  'codex 0.146.0' \
  'grok 0.2.114'; do
  singleton_profile=${singleton_profile_version%% *}
  AGENT_CONTAINER_VERSION=${singleton_profile_version#* }
  run_program "$repo_root/bin/$singleton_profile-container" "from-$singleton_profile" \
    >"$case_dir/$singleton_profile.out" \
    2>"$case_dir/$singleton_profile.err"
  assert_line "$case_log" \
    "ARG=agent-$singleton_profile-$(id -u)-singleton"
  assert_line "$case_log" \
    'ARG=com.loadchange.agent-container.mode=singleton'
  assert_line "$case_log" 'ARG=/bin/sleep'
  assert_line "$case_log" 'ARG=infinity'
  assert_line "$case_log" "ARG=from-$singleton_profile"
  assert_not_contains "$case_log" 'workspace-roots-sha256'

  run_program "$repo_root/bin/agent-container" singleton status "$singleton_profile" \
    >"$case_dir/$singleton_profile.status.out" \
    2>"$case_dir/$singleton_profile.status.err"
  grep -Eq \
    "^$singleton_profile singleton: running \\(container=agent-$singleton_profile-$(id -u)-singleton phase=ready config-sha256=[0-9a-f]{64}\\)$" \
    "$case_dir/$singleton_profile.status.out" \
    || fail "$singleton_profile singleton status did not report its ready container and configuration fingerprint"
  run_program "$repo_root/bin/agent-container" singleton stop "$singleton_profile" \
    >"$case_dir/$singleton_profile.stop.out" \
    2>"$case_dir/$singleton_profile.stop.err"
done
[ "$(grep -Fxc -- 'ARG=create' "$case_log")" -eq 3 ] \
  || fail "default singleton launches did not create exactly one VM per profile"
[ "$(grep -Fxc -- 'ARG=start' "$case_log")" -eq 3 ] \
  || fail "default singleton launches did not start exactly one VM per profile"
pass "Claude, Codex, and Grok all default to one profile singleton"

tests_run=$((tests_run + 1))
new_case singleton_two_workspaces
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_VERSION=0.2.114
singleton_project_a="$case_dir/project-a"
singleton_project_b="$case_dir/project-b"
mkdir -p "$singleton_project_a" "$singleton_project_b"

run_program_from "$singleton_project_a" \
  "$repo_root/bin/grok-container" from-a "two words" \
  >"$case_dir/a.out" 2>"$case_dir/a.err"
FAKE_MAX_VNODES=1000
FAKE_FREE_VNODES=50
run_program_from "$singleton_project_b" \
  "$repo_root/bin/grok-container" from-b "" \
  >"$case_dir/b.out" 2>"$case_dir/b.err"
FAKE_NUM_FILES=not-a-number
run_program_from "$singleton_project_a" \
  "$repo_root/bin/grok-container" from-a-again \
  >"$case_dir/a-again.out" 2>"$case_dir/a-again.err"

[ "$(grep -Fxc -- 'ARG=create' "$case_log")" -eq 1 ] \
  || fail "two Grok workspaces created more than one singleton"
[ "$(grep -Fxc -- 'ARG=start' "$case_log")" -eq 1 ] \
  || fail "the warm Grok attach restarted its singleton"
[ "$(grep -Fxc -- 'ARG=/usr/local/bin/agent-workspace-session' "$case_log")" -eq 3 ] \
  || fail "three Grok clients did not receive isolated exec sessions"
[ "$(grep -Fxc -- "ARG=$singleton_project_a" "$case_log")" -eq 4 ] \
  || fail "workspace A root and cwd were not isolated in its exec"
[ "$(grep -Fxc -- "ARG=$singleton_project_b" "$case_log")" -eq 2 ] \
  || fail "workspace B root and cwd were not isolated in its exec"
assert_line "$case_log" 'ARG=from-a'
assert_line "$case_log" 'ARG=two words'
assert_line "$case_log" 'ARG=from-b'
assert_line "$case_log" 'ARG=from-a-again'
assert_no_line "$case_log" "ARG=$singleton_project_a:$singleton_project_a"
assert_no_line "$case_log" "ARG=$singleton_project_b:$singleton_project_b"
run_program "$repo_root/bin/agent-container" singleton stop grok \
  >"$case_dir/stop.out" 2>"$case_dir/stop.err"
pass "warm A/B clients reuse one VM without recharging its mount or requiring host capacity counters"

tests_run=$((tests_run + 1))
new_case singleton_warm_latest_is_pinned
TEST_SINGLETON_LAUNCH=true
FAKE_GROK_LATEST_VERSION=0.2.114
run_program "$repo_root/bin/grok-container" first-client \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
: > "$case_curl_log"
FAKE_GROK_LATEST_VERSION=0.2.115
run_program "$repo_root/bin/grok-container" second-client \
  >"$case_dir/second.out" 2>"$case_dir/second.err"
[ ! -s "$case_curl_log" ] \
  || fail "warm singleton attach queried the latest version channel"
[ "$(grep -Fxc -- 'ARG=create' "$case_log")" -eq 1 ] \
  || fail "warm latest attach created a second singleton"
[ "$(grep -Fxc -- 'ARG=/usr/local/bin/agent-workspace-session' "$case_log")" -eq 2 ] \
  || fail "warm latest attach did not create a second isolated exec session"
run_program "$repo_root/bin/agent-container" singleton stop grok \
  >"$case_dir/stop.out" 2>"$case_dir/stop.err"
pass "warm singleton reuses its pinned Agent version without a latest lookup"

tests_run=$((tests_run + 1))
new_case singleton_slow_workspace_broker
copy_case_assets
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_VERSION=0.2.114
slow_release="$case_dir/slow-release"
slow_test_bin="$slow_release/test-bin"
slow_broker_gate="$case_dir/slow-broker.gate"
slow_broker_active="$case_dir/slow-broker.active"
slow_broker_marker="$case_dir/slow-broker.started"
slow_poll_count="$case_dir/slow-broker.poll-count"
slow_watchdog_marker="$case_dir/slow-broker.watchdog-stopped"
slow_broker_lock_fd_marker="$case_dir/slow-broker.lock-fd-closed"
slow_watchdog_lock_fd_marker="$case_dir/slow-broker-watchdog.lock-fd-closed"
mkdir -p "$slow_release" "$slow_test_bin"
if [ -n "$test_launcher_override" ]; then
  ln -s "$test_launcher_override" "$slow_release/agent-container-bin"
else
  cp "$test_launcher_binary" "$slow_release/agent-container-bin"
fi
cp "$repo_root/runtime/agent-container-runtime" \
  "$slow_release/agent-container-runtime"
: > "$slow_broker_gate"
printf '%s\n' 0 > "$slow_poll_count"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'set -euo pipefail'
  printf 'exec -a agent-container %q "$@"\n' \
    "$slow_release/agent-container-bin"
} > "$slow_release/agent-container"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'if { : <&9; } 2>/dev/null; then exit 71; fi'
  printf 'printf "%%s\\n" closed > %q\n' \
    "$slow_broker_lock_fd_marker"
  printf ': > %q\n' "$slow_broker_active"
  printf 'while [ -e %q ]; do /bin/sleep 0.01; done\n' \
    "$slow_broker_gate"
  printf 'rm -f -- %q\n' "$slow_broker_active"
  printf 'printf "%%s\\n" started > %q\n' "$slow_broker_marker"
  printf 'exec %q "$@"\n' \
    "$test_launcher_binary"
} > "$slow_release/agent-container-darwin-arm64"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'if [ "$#" -eq 1 ] && [ "$1" = 30 ]; then'
  printf '%s\n' '  if { : <&9; } 2>/dev/null; then exit 72; fi'
  printf '  printf "%%s\\n" closed > %q\n' \
    "$slow_watchdog_lock_fd_marker"
  printf '%s\n' '  /bin/sleep "$1" &'
  printf '%s\n' '  watchdog_child=$!'
  printf '  trap '\''kill -TERM "$watchdog_child" 2>/dev/null || true; wait "$watchdog_child" 2>/dev/null || true; printf "%%s\\n" stopped > %q; exit 0'\'' TERM\n' \
    "$slow_watchdog_marker"
  printf '%s\n' '  wait "$watchdog_child"'
  printf '%s\n' '  exit 0'
  printf '%s\n' 'fi'
  printf 'if [ "$#" -eq 1 ] && [ "$1" = 0.05 ] && [ -e %q ]; then\n' \
    "$slow_broker_active"
  printf '  IFS= read -r poll_count < %q\n' "$slow_poll_count"
  printf '%s\n' \
    '  case "$poll_count" in ""|*[!0-9]*) exit 65 ;; esac'
  printf '%s\n' '  poll_count=$((poll_count + 1))'
  printf '  printf "%%s\\n" "$poll_count" > %q\n' "$slow_poll_count"
  printf '%s\n' '  if [ "$poll_count" -eq 101 ]; then'
  printf '    rm -f -- %q %q\n' \
    "$slow_broker_active" "$slow_broker_gate"
  printf '%s\n' '  fi'
  printf '%s\n' 'fi'
  printf '%s\n' 'exec /bin/sleep "$@"'
} > "$slow_test_bin/sleep"
chmod 0755 \
  "$slow_release/agent-container" \
  "$slow_release/agent-container-runtime" \
  "$slow_release/agent-container-darwin-arm64" \
  "$slow_test_bin/sleep"
[ -L "$slow_release/agent-container-bin" ] \
  || chmod 0755 "$slow_release/agent-container-bin"
# Installed releases resolve the physical workspace launcher from the asset
# directory, which the installer always stages alongside the runtime. Model
# that layout so the delayed fake is the launcher this case dispatches.
cp "$slow_release/agent-container-darwin-arm64" \
  "$case_asset_dir/agent-container-darwin-arm64"
chmod 0755 "$case_asset_dir/agent-container-darwin-arm64"
TEST_RUNNER_PATH="$slow_test_bin:$fixture_dir:/usr/bin:/bin"

run_program "$slow_release/agent-container" grok delayed-broker-client \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$slow_broker_marker" started
assert_line "$slow_watchdog_marker" stopped
assert_line "$slow_broker_lock_fd_marker" closed
assert_line "$slow_watchdog_lock_fd_marker" closed
IFS= read -r slow_poll_total < "$slow_poll_count"
case "$slow_poll_total" in
  ''|*[!0-9]*) fail "slow workspace-broker poll count was not numeric" ;;
esac
[ "$slow_poll_total" -ge 101 ] \
  || fail "workspace broker started before crossing the legacy 100-poll cutoff"
assert_line "$case_log" 'ARG=delayed-broker-client'
assert_line "$case_log" 'WORKSPACE_CONNECT_STATUS=0'
run_program "$slow_release/agent-container" singleton stop grok \
  >"$case_dir/stop.out" 2>"$case_dir/stop.err"
pass "singleton attach outlives the old polling cutoff without leaking its lifecycle lock"

tests_run=$((tests_run + 1))
new_case singleton_concurrent_clients
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_VERSION=0.2.114
singleton_project_a="$case_dir/project-a"
singleton_project_b="$case_dir/project-b"
mkdir -p "$singleton_project_a" "$singleton_project_b"
FAKE_RUN_SLEEP=300
TEST_LAUNCH_CWD="$singleton_project_a" launch_exec \
  "$repo_root/bin/grok-container" slow-client \
  >"$case_dir/slow.out" 2>"$case_dir/slow.err" &
singleton_first_pid=$!
background_pid="$singleton_first_pid"
for singleton_wait_attempt in $(seq 1 3000); do
  grep -Fq 'ARG=slow-client' "$case_log" && break
  kill -0 "$singleton_first_pid" 2>/dev/null \
    || fail "the first singleton client exited before its exec began"
  sleep 0.02
done
grep -Fq 'ARG=slow-client' "$case_log" \
  || fail "the first singleton client did not begin within sixty seconds"
singleton_exec_child_pid=""
for singleton_child_wait_attempt in $(seq 1 500); do
  singleton_exec_child_pid=$(pgrep -P "$singleton_first_pid" -f 'sleep 300' \
    | head -n 1 || true)
  [ -z "$singleton_exec_child_pid" ] || break
  kill -0 "$singleton_first_pid" 2>/dev/null \
    || fail "the first singleton launcher exited before its Apple CLI child was observed"
  sleep 0.02
done
[ -n "$singleton_exec_child_pid" ] \
  || fail "the first singleton launcher did not retain a test Apple CLI child"
secondary_background_pid="$singleton_exec_child_pid"
unset FAKE_RUN_SLEEP
run_program_from "$singleton_project_b" \
  "$repo_root/bin/grok-container" fast-client \
  >"$case_dir/fast.out" 2>"$case_dir/fast.err"
kill -0 "$singleton_first_pid" 2>/dev/null \
  || fail "the second attach waited for the first Agent process to exit"
kill -TERM "$singleton_first_pid" \
  || fail "unable to terminate the first concurrent singleton client"
set +e
wait "$singleton_first_pid"
singleton_first_status=$?
set -e
background_pid=""
[ "$singleton_first_status" -ne 0 ] \
  || fail "TERM unexpectedly produced a successful singleton client status"
for singleton_child_wait_attempt in $(seq 1 500); do
  kill -0 "$singleton_exec_child_pid" 2>/dev/null || break
  sleep 0.02
done
if kill -0 "$singleton_exec_child_pid" 2>/dev/null; then
  kill -TERM "$singleton_exec_child_pid" 2>/dev/null || true
  secondary_background_pid=""
  fail "TERM left the singleton Apple CLI child running after its launcher exited"
fi
secondary_background_pid=""
[ "$(grep -Fxc -- 'ARG=create' "$case_log")" -eq 1 ] \
  || fail "concurrent clients created more than one Grok singleton"
[ "$(grep -Fxc -- 'ARG=/usr/local/bin/agent-workspace-session' "$case_log")" -eq 2 ] \
  || fail "concurrent clients did not receive separate exec sessions"
assert_line "$case_log" 'ARG=slow-client'
assert_line "$case_log" 'ARG=fast-client'
run_program "$repo_root/bin/agent-container" singleton stop grok \
  >"$case_dir/stop.out" 2>"$case_dir/stop.err"
pass "two Grok clients attach concurrently after the singleton lifecycle lock is released"

tests_run=$((tests_run + 1))
new_case singleton_stopped_recreation
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_VERSION=0.2.114
run_program "$repo_root/bin/grok-container" first-client \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
cp "$case_home/fake-created-container.json.stopped" \
  "$case_home/fake-created-container.json"
run_program "$repo_root/bin/grok-container" second-client \
  >"$case_dir/second.out" 2>"$case_dir/second.err"
[ "$(grep -Fxc -- 'ARG=create' "$case_log")" -eq 2 ] \
  || fail "a verified stopped singleton was not recreated exactly once"
assert_line "$case_log" 'ARG=delete'
assert_line "$case_log" 'ARG=--force'
assert_contains "$case_dir/second.err" \
  "Removing a verified stopped 'grok' singleton before recreation"
run_program "$repo_root/bin/agent-container" singleton stop grok \
  >"$case_dir/stop.out" 2>"$case_dir/stop.err"
pass "a verified stopped singleton is safely deleted and recreated"

tests_run=$((tests_run + 1))
new_case singleton_stopped_growth_retained_before_delete
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_VERSION=0.2.114
AGENT_CONTAINER_MAX_FILES=20
run_program "$repo_root/bin/grok-container" first-client \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
cp "$case_home/fake-created-container.json.stopped" \
  "$case_home/fake-created-container.json"
singleton_shadow_home="$case_home/.agent-container/profiles/grok/home"
FAKE_GROW_DIRECTORY_AFTER_STOPPED_INSPECT="$singleton_shadow_home"
FAKE_GROW_DIRECTORY_ENTRY_COUNT=21
if run_program "$repo_root/bin/grok-container" second-client \
  >"$case_dir/second.out" 2>"$case_dir/second.err"; then
  fail "stopped recreation deleted its recoverable container after HOME outgrew the budget"
fi
assert_contains "$case_dir/second.err" \
  "persistent 'grok' shadow HOME"
assert_command_count "$case_log" delete 0
[ -f "$case_home/fake-created-container.json" ] \
  || fail "pre-delete rejection did not retain the stopped native singleton"
for retained_singleton_record in \
  phase creator-pid agent-version image-digest config.sha256; do
  [ -f "$case_home/.agent-container/profiles/grok/singleton/$retained_singleton_record" ] \
    || fail "pre-delete rejection removed existing singleton state: $retained_singleton_record"
done
pass "stopped recreation re-counts HOME and retains the native singleton before deletion"

tests_run=$((tests_run + 1))
new_case singleton_stopped_recreation_with_ssh
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_VERSION=0.2.114
AGENT_CONTAINER_MOUNT_SSH_CONFIG=true
mkdir -p "$case_home/.ssh"
chmod 0700 "$case_home/.ssh"
printf '%s\n' 'Host example.test' '  User git' > "$case_home/.ssh/config"
chmod 0600 "$case_home/.ssh/config"
run_program "$repo_root/bin/grok-container" first-client \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
cp "$case_home/fake-created-container.json.stopped" \
  "$case_home/fake-created-container.json"
run_program "$repo_root/bin/grok-container" second-client \
  >"$case_dir/second.out" 2>"$case_dir/second.err"
[ "$(grep -Fxc -- 'ARG=create' "$case_log")" -eq 2 ] \
  || fail "a stopped singleton with SSH staging was not recreated exactly once"
run_program "$repo_root/bin/agent-container" singleton stop grok \
  >"$case_dir/stop.out" 2>"$case_dir/stop.err"
pass "stopped recreation preserves the frozen nested SSH staging identity"

tests_run=$((tests_run + 1))
new_case singleton_stopped_missing_ssh_is_retained
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_VERSION=0.2.114
AGENT_CONTAINER_MOUNT_SSH_CONFIG=true
mkdir -p "$case_home/.ssh"
chmod 0700 "$case_home/.ssh"
printf '%s\n' 'Host example.test' '  User git' > "$case_home/.ssh/config"
chmod 0600 "$case_home/.ssh/config"
run_program "$repo_root/bin/grok-container" first-client \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
cp "$case_home/fake-created-container.json.stopped" \
  "$case_home/fake-created-container.json"
rm -f "$case_home/.agent-container/profiles/grok/singleton/guest-stage/ssh/config"
rmdir "$case_home/.agent-container/profiles/grok/singleton/guest-stage/ssh"
if run_program "$repo_root/bin/grok-container" second-client \
  >"$case_dir/second.out" 2>"$case_dir/second.err"; then
  fail "recreation accepted a missing frozen SSH staging source"
fi
assert_contains "$case_dir/second.err" \
  "SSH metadata staging is no longer a real directory"
assert_command_count "$case_log" delete 0
run_program "$repo_root/bin/agent-container" singleton stop grok \
  >"$case_dir/stop.out" 2>"$case_dir/stop.err"
pass "missing frozen nested staging is rejected before native deletion"

tests_run=$((tests_run + 1))
new_case singleton_stopped_recreation_stage_replaced_after_delete
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_VERSION=0.2.114
run_program "$repo_root/bin/grok-container" first-client \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
cp "$case_home/fake-created-container.json.stopped" \
  "$case_home/fake-created-container.json"
singleton_stage="$case_home/.agent-container/profiles/grok/singleton/guest-stage"
FAKE_REPLACE_DIRECTORY_AFTER_DELETE="$singleton_stage"
if run_program "$repo_root/bin/grok-container" second-client \
  >"$case_dir/second.out" 2>"$case_dir/second.err"; then
  fail "recreation accepted a replaced staging source after native deletion"
fi
assert_contains "$case_dir/second.err" "changed filesystem identity"
assert_contains "$case_dir/second.err" \
  "verified stopped 'grok' singleton was already deleted; no replacement container was created"
assert_contains "$case_dir/second.err" \
  "retained untrusted managed paths under '$case_home/.agent-container/profiles/grok/singleton'"
assert_command_count "$case_log" delete 1
[ "$(grep -Fxc -- 'ARG=create' "$case_log")" -eq 1 ] \
  || fail "a replacement container was created after staging identity changed"
[ -f "$singleton_stage/replacement-sentinel" ] \
  && [ -d "$singleton_stage.original" ] \
  || fail "cleanup deleted a replaced or original singleton staging tree"
for inactive_singleton_record in \
  phase creator-pid agent-version image-digest config.sha256; do
  [ ! -e "$case_home/.agent-container/profiles/grok/singleton/$inactive_singleton_record" ] \
    || fail "cleanup retained stale singleton state record: $inactive_singleton_record"
done
[ ! -d "$case_home/.agent-container/session.lock" ] \
  && [ ! -d "$case_home/.agent-container/profiles/grok/session.lock" ] \
  && [ ! -d "$case_home/.local/share/.agent-container.install.lock" ] \
  || fail "failed recreation left a global, profile, or lifecycle lock"
if find "$case_home/.agent-container/sessions" -mindepth 1 -print -quit \
  | grep -q .; then
  fail "failed recreation left per-session staging"
fi
pass "post-delete source replacement retains untrusted data but clears safe state and locks"

tests_run=$((tests_run + 1))
new_case singleton_stopped_recreation_root_replaced_after_delete
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_VERSION=0.2.114
run_program "$repo_root/bin/grok-container" first-client \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
cp "$case_home/fake-created-container.json.stopped" \
  "$case_home/fake-created-container.json"
singleton_root="$case_home/.agent-container/profiles/grok/singleton"
FAKE_REPLACE_DIRECTORY_AFTER_DELETE="$singleton_root"
FAKE_REPLACEMENT_SINGLETON_RECORDS=true
if run_program "$repo_root/bin/grok-container" second-client \
  >"$case_dir/second.out" 2>"$case_dir/second.err"; then
  fail "recreation accepted a replaced singleton state root after native deletion"
fi
assert_contains "$case_dir/second.err" \
  "Singleton state root changed filesystem identity"
assert_contains "$case_dir/second.err" \
  "Could not safely clear inactive singleton state records"
assert_command_count "$case_log" delete 1
[ "$(grep -Fxc -- 'ARG=create' "$case_log")" -eq 1 ] \
  || fail "a replacement container was created after the state root changed"
[ -f "$singleton_root/replacement-sentinel" ] \
  && [ -d "$singleton_root.original" ] \
  || fail "cleanup deleted a replaced or original singleton state root"
for replacement_singleton_record in \
  phase creator-pid agent-version image-digest config.sha256; do
  assert_line "$singleton_root/$replacement_singleton_record" \
    foreign-replacement-record
done
[ ! -d "$case_home/.agent-container/session.lock" ] \
  && [ ! -d "$case_home/.agent-container/profiles/grok/session.lock" ] \
  && [ ! -d "$case_home/.local/share/.agent-container.install.lock" ] \
  || fail "state-root replacement left a global, profile, or lifecycle lock"
pass "post-delete state-root replacement is retained without deleting foreign records"

tests_run=$((tests_run + 1))
new_case singleton_stopped_recreation_with_hosts
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_VERSION=0.2.114
AGENT_CONTAINER_HOST_ALIAS=host-service.example.test
run_program "$repo_root/bin/grok-container" first-client \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
cp "$case_home/fake-created-container.json.stopped" \
  "$case_home/fake-created-container.json"
run_program "$repo_root/bin/grok-container" second-client \
  >"$case_dir/second.out" 2>"$case_dir/second.err"
[ "$(grep -Fxc -- 'ARG=create' "$case_log")" -eq 2 ] \
  || fail "a stopped singleton with hosts staging was not recreated exactly once"
run_program "$repo_root/bin/agent-container" singleton stop grok \
  >"$case_dir/stop.out" 2>"$case_dir/stop.err"
pass "stopped recreation preserves the frozen hosts-file identity"

tests_run=$((tests_run + 1))
new_case singleton_stopped_recreation_with_blocked_hosts
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_VERSION=0.2.114
AGENT_CONTAINER_BLOCK_HOST=blocked-service.example.test
run_program "$repo_root/bin/grok-container" first-client \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
cp "$case_home/fake-created-container.json.stopped" \
  "$case_home/fake-created-container.json"
run_program "$repo_root/bin/grok-container" second-client \
  >"$case_dir/second.out" 2>"$case_dir/second.err"
[ "$(grep -Fxc -- 'ARG=create' "$case_log")" -eq 2 ] \
  || fail "a stopped singleton with blocked-host staging was not recreated exactly once"
run_program "$repo_root/bin/agent-container" singleton stop grok \
  >"$case_dir/stop.out" 2>"$case_dir/stop.err"
pass "blocked-host-only staging is Bash-3-safe across stopped recreation"

tests_run=$((tests_run + 1))
new_case singleton_config_change_fails_closed
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_VERSION=0.2.114
run_program "$repo_root/bin/grok-container" first-client \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
AGENT_CONTAINER_VERSION=0.2.115
if run_program "$repo_root/bin/grok-container" changed-version \
  >"$case_dir/changed.out" 2>"$case_dir/changed.err"; then
  fail "an active singleton accepted a different Agent version"
fi
assert_contains "$case_dir/changed.err" \
  "singleton image is stale or a rebuild was requested"
assert_contains "$case_dir/changed.err" \
  "agent-container singleton stop grok"
[ "$(grep -Fxc -- 'ARG=create' "$case_log")" -eq 1 ] \
  || fail "a configuration change created a second singleton"
run_program "$repo_root/bin/agent-container" singleton stop grok \
  >"$case_dir/stop.out" 2>"$case_dir/stop.err"
pass "singleton configuration changes fail closed instead of creating another VM"

tests_run=$((tests_run + 1))
new_case singleton_linked_worktree_fails_closed
TEST_SINGLETON_LAUNCH=true
AGENT_CONTAINER_VERSION=0.2.114
singleton_main="$case_dir/main"
singleton_worktree="$case_dir/worktree"
mkdir "$singleton_main"
/usr/bin/git -C "$singleton_main" init -q
/usr/bin/git -C "$singleton_main" config user.email test@example.test
/usr/bin/git -C "$singleton_main" config user.name Test
printf '%s\n' base > "$singleton_main/file.txt"
/usr/bin/git -C "$singleton_main" add file.txt
/usr/bin/git -C "$singleton_main" commit -qm base
/usr/bin/git -C "$singleton_main" worktree add \
  -q "$singleton_worktree" -b singleton-worktree
if run_program_from "$singleton_worktree" \
  "$repo_root/bin/grok-container" linked-client \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "default singleton accepted an external Git common directory"
fi
assert_contains "$case_dir/err" \
  'Dynamic singleton sharing currently supports one workspace root'
assert_contains "$case_dir/err" \
  'agent-container run grok --'
[ "$(grep -Fxc -- 'ARG=create' "$case_log")" -eq 0 ] \
  || fail "linked-worktree rejection occurred after singleton creation"
pass "external Git common directories fail closed before singleton startup"
tests_run=$((tests_run + 1))
new_case auto_extra_ca_consumer_split
AGENT_CONTAINER_EXTRA_CA_CERTS=auto
FAKE_SECURITY_CHAIN_FORMAT=three-ca-nul-cr
FAKE_CAPTURE_BUILD_CA="$case_dir/build-ca.pem"
run_program "$repo_root/bin/codex-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"

assert_line "$case_security_log" "ARG=https://chatgpt.com/codex/install.sh"
assert_line "$case_security_log" "ARG=https://releases.openai.com/codex/channels/latest"
assert_line "$case_curl_log" "CA_NATIVE=true"
assert_line "$case_curl_log" "PROXY_CA_NATIVE=true"
assert_line "$case_curl_log" "CACERT_BODY=VkVSU0lPTi1BTkNIT1I="
assert_line "$case_curl_log" "PROXY_CACERT_BODY=VkVSU0lPTi1BTkNIT1I="
assert_not_contains "$case_curl_log" "SU5TVEFMTEVSLUFOQ0hPUg=="
assert_line "$case_dir/build-ca.pem" "SU5TVEFMTEVSLUFOQ0hPUg=="
assert_not_contains "$case_dir/build-ca.pem" "VkVSU0lPTi1BTkNIT1I="
assert_not_contains "$case_dir/build-ca.pem" "Uk9PVC1DQQ=="
auto_build_ca_fingerprint=$(test_sha256_file "$case_dir/build-ca.pem")
assert_line "$case_log" "ARG=AGENT_CA_FINGERPRINT=$auto_build_ca_fingerprint"
assert_contains "$case_log" "ARG=id=agent_ca_bundle,src="
assert_secret_absent \
  "$case_log" \
  'SU5TVEFMTEVSLUFOQ0hPUg==' \
  auto_installer_anchor
assert_secret_absent \
  "$case_log" \
  'VkVSU0lPTi1BTkNIT1I=' \
  auto_version_anchor
pass "auto CA routes the narrowest verified issuers to host curl and BuildKit"

tests_run=$((tests_run + 1))
new_case auto_extra_ca_exact_version_skips_version_chain
AGENT_CONTAINER_EXTRA_CA_CERTS=auto
AGENT_CONTAINER_VERSION=0.146.0
FAKE_CAPTURE_BUILD_CA="$case_dir/build-ca.pem"
run_program "$repo_root/bin/codex-container" --version \
  >"$case_dir/cold.out" 2>"$case_dir/cold.err"

assert_line "$case_security_log" "ARG=https://chatgpt.com/codex/install.sh"
assert_no_line "$case_security_log" \
  "ARG=https://releases.openai.com/codex/channels/latest"
[ ! -s "$case_curl_log" ] \
  || fail "an exact Agent version unexpectedly queried the version channel"
assert_line "$case_dir/build-ca.pem" "SU5TVEFMTEVSLUFOQ0hPUg=="
assert_not_contains "$case_dir/build-ca.pem" "VkVSU0lPTi1BTkNIT1I="

: > "$case_log"
: > "$case_curl_log"
: > "$case_security_log"
run_program "$repo_root/bin/codex-container" --version \
  >"$case_dir/warm.out" 2>"$case_dir/warm.err"
assert_line "$case_security_log" "ARG=https://chatgpt.com/codex/install.sh"
assert_no_line "$case_security_log" \
  "ARG=https://releases.openai.com/codex/channels/latest"
[ ! -s "$case_curl_log" ] \
  || fail "an exact warm-image run unexpectedly queried the version channel"
assert_no_line "$case_log" "ARG=build"
pass "exact auto CA extracts only the installer anchor and skips cold and warm version lookups"

tests_run=$((tests_run + 1))
new_case explicit_extra_ca_secret_and_fingerprint
explicit_ca="$case_dir/explicit-ca.pem"
write_test_certificate "$explicit_ca" 'VkFMSUQtQ0E='
AGENT_CONTAINER_EXTRA_CA_CERTS="$explicit_ca"
FAKE_CAPTURE_BUILD_CA="$case_dir/build-ca.pem"

run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/first.out" 2>"$case_dir/first.err"
explicit_ca_first_fingerprint=$(test_sha256_file "$explicit_ca")
cmp -s "$explicit_ca" "$case_dir/build-ca.pem" \
  || fail "explicit CA content did not reach the BuildKit secret"
assert_line "$case_curl_log" "CACERT_BODY=VkFMSUQtQ0E="
assert_line "$case_log" "ARG=AGENT_CA_FINGERPRINT=$explicit_ca_first_fingerprint"
assert_contains "$case_log" "ARG=id=agent_ca_bundle,src="
assert_secret_absent "$case_log" 'VkFMSUQtQ0E=' explicit_ca

write_test_certificate "$explicit_ca" 'VkFMSUQtQ0EtMg=='
run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/second.out" 2>"$case_dir/second.err"
explicit_ca_second_fingerprint=$(test_sha256_file "$explicit_ca")
[ "$explicit_ca_first_fingerprint" != "$explicit_ca_second_fingerprint" ] \
  || fail "test CA mutation did not change its digest"
assert_line "$case_log" "ARG=AGENT_CA_FINGERPRINT=$explicit_ca_second_fingerprint"
[ "$(grep -Fxc -- 'ARG=build' "$case_log")" -eq 2 ] \
  || fail "changing explicit CA content did not invalidate the warm image"
cmp -s "$explicit_ca" "$case_dir/build-ca.pem" \
  || fail "rebuilt image did not receive the changed explicit CA"
pass "explicit CA uses a BuildKit secret and its public fingerprint invalidates image reuse"

tests_run=$((tests_run + 1))
new_case invalid_expired_future_and_nonca_bundles
AGENT_CONTAINER_VERSION=2.1.220
invalid_ca="$case_dir/invalid-ca.pem"

printf '%s\n' 'not a PEM certificate' > "$invalid_ca"
AGENT_CONTAINER_EXTRA_CA_CERTS="$invalid_ca"
if run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/invalid.out" 2>"$case_dir/invalid.err"; then
  fail "non-PEM extra CA input should fail"
fi
assert_contains "$case_dir/invalid.err" "currently-valid CA certificates"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=create"

: > "$case_log"
: > "$case_openssl_log"
write_test_certificate "$invalid_ca" 'RVhQSVJFRC1DQQ=='
if run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/expired.out" 2>"$case_dir/expired.err"; then
  fail "an expired extra CA should fail"
fi
assert_contains "$case_dir/expired.err" "currently-valid CA certificates"
assert_line "$case_openssl_log" "ARG=-checkend"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=create"

: > "$case_log"
: > "$case_openssl_log"
write_test_certificate "$invalid_ca" 'RlVUVVJFLUNB'
if run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/future.out" 2>"$case_dir/future.err"; then
  fail "a not-yet-valid extra CA should fail"
fi
assert_contains "$case_dir/future.err" "currently-valid CA certificates"
assert_line "$case_openssl_log" "ARG=-startdate"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=create"

: > "$case_log"
: > "$case_openssl_log"
write_test_certificate "$invalid_ca" 'Tk9OQ0E='
if run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/nonca.out" 2>"$case_dir/nonca.err"; then
  fail "a certificate without CA:TRUE should fail"
fi
assert_contains "$case_dir/nonca.err" "currently-valid CA certificates"
assert_line "$case_openssl_log" "ARG=-ext"
assert_no_line "$case_log" "ARG=build"
assert_no_line "$case_log" "ARG=create"
pass "extra CA validation rejects invalid PEM, expired, future, and non-CA certificates before build"

tests_run=$((tests_run + 1))
new_case auto_future_installer_anchor_rejected
AGENT_CONTAINER_EXTRA_CA_CERTS=auto
AGENT_CONTAINER_VERSION=2.1.220
FAKE_SECURITY_INSTALLER_ANCHOR_BODY=RlVUVVJFLUNB
if run_program "$repo_root/bin/claude-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"; then
  fail "auto should reject a not-yet-valid installer-chain CA"
fi
assert_contains "$case_dir/err" \
  "could not verify and export the TLS trust anchor for https://downloads.claude.ai/claude-code-releases/bootstrap.sh"
assert_line "$case_openssl_log" "ARG=-startdate"
assert_no_line "$case_security_log" \
  "ARG=https://downloads.claude.ai/claude-code-releases/latest"
[ ! -s "$case_curl_log" ] \
  || fail "a rejected exact-version auto anchor unexpectedly queried the version channel"
assert_no_line "$case_log" "ARG=build"
pass "auto rejects a not-yet-valid installer anchor before build"

tests_run=$((tests_run + 1))
new_case default_extra_ca_uses_auto_trust_bridge
AGENT_CONTAINER_VERSION=0.146.0
FAKE_CAPTURE_BUILD_CA="$case_dir/build-ca.pem"
run_program "$repo_root/bin/codex-container" --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_security_log" "ARG=https://chatgpt.com/codex/install.sh"
assert_no_line "$case_security_log" \
  "ARG=https://releases.openai.com/codex/channels/latest"
assert_line "$case_dir/build-ca.pem" "SU5TVEFMTEVSLUFOQ0hPUg=="
default_ca_fingerprint=$(test_sha256_file "$case_dir/build-ca.pem")
assert_line "$case_log" "ARG=AGENT_CA_FINGERPRINT=$default_ca_fingerprint"
assert_contains "$case_log" "ARG=id=agent_ca_bundle,src="
pass "default extra CA mode uses the verified macOS trust bridge"

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
run_program "$repo_root/bin/agent-container" codex --version \
  >"$case_dir/out" 2>"$case_dir/err"
assert_line "$case_log" "ARG=$case_dir/linked worktree:$case_dir/linked worktree"
assert_line "$case_log" "ARG=$main_repo/.git:$main_repo/.git"
assert_line "$case_log" "ARG=$case_workspace"
pass "linked worktrees preserve workdir and external Git common-directory mounts"

tests_run=$((tests_run + 1))
new_case real_pty
run_program "$repo_root/bin/agent-container" claude --version \
  >"$case_dir/warm.out" 2>"$case_dir/warm.err"
: > "$case_log"
pty_launcher=(/bin/bash "$repo_root/bin/agent-container")
pty_asset_dir="$repo_root/runtime"
if [ -n "$test_launcher_override" ]; then
  pty_launcher=("$test_root/agent-container")
  pty_asset_dir=$test_override_asset_dir
fi
if ! (
  cd "$case_workspace"
  exec /usr/bin/env -i \
    HOME="$case_home" \
    PATH="$curl_wrapper_dir:$fixture_dir:/usr/bin:/bin" \
    LANG=C \
    TERM=xterm-256color \
    FAKE_CONTAINER_LOG="$case_log" \
    FAKE_CREATED_CONTAINER_STATE="$case_home/fake-created-container.json" \
    FAKE_IMAGE_STATE_DIR="$case_home/fake-images" \
    FAKE_READ_STDIN=true \
    /usr/bin/python3 "$repo_root/tests/pty-run.py" \
      "${pty_launcher[@]}" \
        --container-bin "$fixture_dir/container" \
        --container-assets "$pty_asset_dir" \
        --container-host-gateway 127.0.0.1 \
        --container-openssl "$fixture_dir/openssl" \
        --container-security "$fixture_dir/security" \
        --container-disable-fd-watchdog \
        --container-version 2.1.220 \
        claude --version
) >"$case_dir/pty.out" 2>"$case_dir/pty.err"; then
  sed -n '1,120p' "$case_dir/pty.out" >&2
  sed -n '1,120p' "$case_dir/pty.err" >&2
  sed -n '1,160p' "$case_log" >&2
  fail "real PTY run failed"
fi
assert_line "$case_log" "ARG=--interactive"
assert_line "$case_log" "ARG=--tty"
assert_line "$case_log" "STDIN_TTY=true"
assert_line "$case_log" "READ=terminal-input"
pass "a real PTY reaches the Apple CLI with input and terminal mode intact"

echo "1..$tests_run"
