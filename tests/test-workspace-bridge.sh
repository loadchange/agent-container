#!/bin/bash
set -euo pipefail

export LC_ALL=C

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
connect_script="$repo_root/runtime/agent-workspace-connect"
session_script="$repo_root/runtime/agent-workspace-session"
peer_source="$repo_root/tests/fixtures/workspace-bridge-peer.rs"
test_root=$(mktemp -d /tmp/agent-workspace-bridge.XXXXXX)
test_root=$(CDPATH= cd -- "$test_root" && pwd -P)
tests_run=0
failures=0
active_pid=""
client_pid=""
held_input_fd_open=false
watchdog_pid=""
watchdog_sequence=0

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  set +e
  if [ -n "$client_pid" ] && kill -0 "$client_pid" 2>/dev/null; then
    kill -TERM "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
  fi
  client_pid=""
  if [ "$held_input_fd_open" = true ]; then
    exec 8>&-
  fi
  held_input_fd_open=false
  if [ -n "$watchdog_pid" ] && kill -0 "$watchdog_pid" 2>/dev/null; then
    kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
  watchdog_pid=""
  if [ -n "$active_pid" ] && kill -0 "$active_pid" 2>/dev/null; then
    kill -TERM "$active_pid" 2>/dev/null || true
    wait "$active_pid" 2>/dev/null || true
  fi
  active_pid=""
  case "$test_root" in
    /tmp/agent-workspace-bridge.*|/private/tmp/agent-workspace-bridge.*)
      rm -rf -- "$test_root"
      ;;
    *)
      printf '# refusing to clean unexpected test root: %s\n' "$test_root" >&2
      status=1
      ;;
  esac
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fail() {
  printf 'not ok %d - %s\n' "$tests_run" "$*" >&2
  exit 1
}

record_failure() {
  failures=$((failures + 1))
  printf 'not ok %d - %s\n' "$tests_run" "$*" >&2
}

pass() {
  printf 'ok %d - %s\n' "$tests_run" "$*"
}

skip() {
  local description=$1
  local reason=$2
  printf 'ok %d - %s # SKIP %s\n' "$tests_run" "$description" "$reason"
}

next_test() {
  tests_run=$((tests_run + 1))
}

show_diagnostic_file() {
  local file=$1
  if [ -s "$file" ]; then
    sed 's/^/# /' "$file" >&2
  fi
}

stop_active_process() {
  if [ -n "$active_pid" ] && kill -0 "$active_pid" 2>/dev/null; then
    kill -TERM "$active_pid" 2>/dev/null || true
  fi
  if [ -n "$active_pid" ]; then
    wait "$active_pid" 2>/dev/null || true
  fi
  active_pid=""
}

wait_with_timeout() {
  local process_pid=$1
  local stop_file attempt process_status
  watchdog_sequence=$((watchdog_sequence + 1))
  stop_file="$test_root/watchdog-stop-$watchdog_sequence"
  [ ! -e "$stop_file" ] || fail "watchdog stop marker already exists"
  (
    attempt=0
    while [ ! -e "$stop_file" ] \
      && kill -0 "$process_pid" 2>/dev/null \
      && [ "$attempt" -lt 80 ]; do
      sleep 0.25
      attempt=$((attempt + 1))
    done
    [ -e "$stop_file" ] && exit 0
    if kill -0 "$process_pid" 2>/dev/null; then
      kill -TERM "$process_pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$process_pid" 2>/dev/null || true
      exit 124
    fi
    exit 0
  ) &
  watchdog_pid=$!

  set +e
  wait "$process_pid"
  process_status=$?
  : > "$stop_file"
  wait "$watchdog_pid" 2>/dev/null || true
  watchdog_pid=""
  return "$process_status"
}

run_sftp_batch() {
  local batch_file=$1
  local output_file=$2
  local error_file=$3
  local client_status

  AGENT_WORKSPACE_ENDPOINT="$workspace_endpoint" \
    AGENT_WORKSPACE_TOKEN="$workspace_token" \
    /usr/bin/sftp -q \
      -b "$batch_file" \
      -D "$test_root/agent-workspace-connect-host" \
      agent-container:. \
      > "$output_file" 2> "$error_file" &
  client_pid=$!
  set +e
  wait_with_timeout "$client_pid"
  client_status=$?
  set -e
  client_pid=""
  return "$client_status"
}

wait_for_record() {
  local record_file=$1
  local process_log=$2
  local attempt=0
  while [ ! -s "$record_file" ] \
    && kill -0 "$active_pid" 2>/dev/null \
    && [ "$attempt" -lt 400 ]; do
    sleep 0.05
    attempt=$((attempt + 1))
  done
  if [ ! -s "$record_file" ]; then
    show_diagnostic_file "$process_log"
    stop_active_process
    fail "background process did not publish its endpoint"
  fi
}

wait_for_active_success() {
  local process_log=$1
  local process_status
  set +e
  wait_with_timeout "$active_pid"
  process_status=$?
  set -e
  active_pid=""
  if [ "$process_status" -ne 0 ]; then
    show_diagnostic_file "$process_log"
    fail "background process exited with status $process_status"
  fi
}

start_broker() {
  local workspace_root=$1
  local record_file=$2
  local process_log=$3
  local record_line extra_field port

  : > "$record_file"
  : > "$process_log"
  "$broker_binary" __workspace-broker "$workspace_root" 127.0.0.1 \
    > "$record_file" 2> "$process_log" &
  active_pid=$!
  wait_for_record "$record_file" "$process_log"

  record_line=$(sed -n '1p' "$record_file")
  [ "$(wc -l < "$record_file" | tr -d '[:space:]')" = 1 ] \
    || fail "broker endpoint record was not exactly one line"
  if ! IFS=$'\t' read -r workspace_endpoint workspace_token extra_field \
      < "$record_file"; then
    fail "broker endpoint record was incomplete"
  fi
  [ -z "$extra_field" ] \
    || fail "broker endpoint record contained extra fields"
  [ "$record_line" = "$workspace_endpoint"$'\t'"$workspace_token" ] \
    || fail "broker endpoint record was not canonical"
  case "$workspace_endpoint" in
    127.0.0.1:*) port=${workspace_endpoint#127.0.0.1:} ;;
    *) fail "broker did not bind the requested localhost address" ;;
  esac
  case "$port" in
    ''|0|0*|*[!0-9]*) fail "broker published an invalid port" ;;
  esac
  [ "$port" -le 65535 ] 2>/dev/null \
    || fail "broker published an out-of-range port"
  [[ "$workspace_token" =~ ^[0-9a-f]{64}$ ]] \
    || fail "broker published an invalid token"
}

printf 'TAP version 13\n'
printf '1..8\n'

[ -x "$connect_script" ] || fail "agent-workspace-connect is not executable"
[ -x "$session_script" ] || fail "agent-workspace-session is not executable"
[ -f "$peer_source" ] || fail "workspace bridge peer fixture is absent"

valid_token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

next_test
invalid_endpoints=(
  ''
  'localhost:1234'
  '127.0.0.01:1234'
  '127.0.0.1:0'
  '127.0.0.1:01234'
  '127.0.0.1:65536'
  '256.0.0.1:1234'
  '127.0.0.1:1234:5678'
  '[::1]:1234'
  $'127.0.0.1:1234\nextra'
)
for invalid_endpoint in "${invalid_endpoints[@]}"; do
  set +e
  AGENT_WORKSPACE_ENDPOINT="$invalid_endpoint" \
    AGENT_WORKSPACE_TOKEN="$valid_token" \
    "$connect_script" > /dev/null 2> "$test_root/connect-rejection.err"
  rejection_status=$?
  set -e
  [ "$rejection_status" -eq 64 ] \
    || fail "connect accepted or misclassified endpoint '$invalid_endpoint' (status $rejection_status)"
  grep -Fq 'agent-workspace-connect:' "$test_root/connect-rejection.err" \
    || fail "connect endpoint rejection did not identify the helper"
done
invalid_tokens=(
  ''
  '0123456789abcdef'
  '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde'
  '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0'
  '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeF'
  'g123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
)
for invalid_token in "${invalid_tokens[@]}"; do
  set +e
  AGENT_WORKSPACE_ENDPOINT='127.0.0.1:1234' \
    AGENT_WORKSPACE_TOKEN="$invalid_token" \
    "$connect_script" > /dev/null 2> "$test_root/connect-rejection.err"
  rejection_status=$?
  set -e
  [ "$rejection_status" -eq 64 ] \
    || fail "connect accepted or misclassified an invalid token (status $rejection_status)"
  grep -Fq 'exactly 64 lowercase hexadecimal' "$test_root/connect-rejection.err" \
    || fail "connect token rejection was not specific"
done
pass "connect rejects non-canonical endpoints and tokens before transport"

next_test
bridge_fixture_available=false
if ! command -v rustc >/dev/null 2>&1; then
  skip "connect emits one exact auth frame and preserves binary traffic" "rustc is unavailable"
else
  if ! rustc --edition=2021 "$peer_source" \
      -o "$test_root/workspace-bridge-peer" \
      > "$test_root/peer-build.out" 2> "$test_root/peer-build.err"; then
    show_diagnostic_file "$test_root/peer-build.err"
    fail "could not compile workspace bridge peer fixture"
  fi
  grep -Fq '/usr/bin/socat -t 1 STDIO' "$connect_script" \
    || fail "connect no longer invokes the bounded guest transport"
  sed "s|/usr/bin/socat|$test_root/workspace-bridge-peer|" "$connect_script" \
    > "$test_root/agent-workspace-connect-host"
  chmod 0700 "$test_root/agent-workspace-connect-host"

  : > "$test_root/peer.endpoint"
  : > "$test_root/peer.err"
  "$test_root/workspace-bridge-peer" --peer "$valid_token" \
    > "$test_root/peer.endpoint" 2> "$test_root/peer.err" &
  active_pid=$!
  wait_for_record "$test_root/peer.endpoint" "$test_root/peer.err"
  peer_endpoint=$(sed -n '1p' "$test_root/peer.endpoint")
  case "$peer_endpoint" in
    127.0.0.1:[1-9]* ) ;;
    *) fail "peer published an invalid localhost endpoint" ;;
  esac
  printf '\000SFTP-REQUEST\377\020\n' \
    | AGENT_WORKSPACE_ENDPOINT="$peer_endpoint" \
        AGENT_WORKSPACE_TOKEN="$valid_token" \
        "$test_root/agent-workspace-connect-host" \
    > "$test_root/connect-response.bin"
  wait_for_active_success "$test_root/peer.err"
  printf '\377SFTP-RESPONSE\000\021\n' \
    > "$test_root/expected-connect-response.bin"
  cmp "$test_root/expected-connect-response.bin" \
      "$test_root/connect-response.bin" \
    || fail "connect changed the binary server response"
  [ "$(printf 'AGENT-CONTAINER-WORKSPACE/1 %s\n' "$valid_token" | wc -c | tr -d '[:space:]')" = 93 ] \
    || fail "authentication frame is not 93 bytes"

  # Keep the local stdin writer open after sending no payload. The peer closes
  # immediately after authenticating; agent-workspace-connect must reap its
  # blocked producer instead of leaking the old `{ printf; cat; } | nc` pipe.
  : > "$test_root/peer-close.endpoint"
  : > "$test_root/peer-close.err"
  "$test_root/workspace-bridge-peer" --peer-close-after-auth "$valid_token" \
    > "$test_root/peer-close.endpoint" 2> "$test_root/peer-close.err" &
  active_pid=$!
  wait_for_record "$test_root/peer-close.endpoint" "$test_root/peer-close.err"
  peer_close_endpoint=$(sed -n '1p' "$test_root/peer-close.endpoint")
  mkfifo "$test_root/connect-held-open.fifo"
  exec 8<> "$test_root/connect-held-open.fifo"
  held_input_fd_open=true
  AGENT_WORKSPACE_ENDPOINT="$peer_close_endpoint" \
    AGENT_WORKSPACE_TOKEN="$valid_token" \
    "$test_root/agent-workspace-connect-host" \
      < "$test_root/connect-held-open.fifo" \
      > "$test_root/connect-close-response.bin" \
      2> "$test_root/connect-close.err" &
  client_pid=$!
  set +e
  wait_with_timeout "$client_pid"
  close_client_status=$?
  set -e
  client_pid=""
  exec 8>&-
  held_input_fd_open=false
  [ "$close_client_status" -eq 0 ] \
    || fail "connect did not exit cleanly when a quiet peer closed (status $close_client_status)"
  wait_for_active_success "$test_root/peer-close.err"
  cmp "$test_root/expected-connect-response.bin" \
      "$test_root/connect-close-response.bin" \
    || fail "connect changed the close-after-auth peer response"
  bridge_fixture_available=true
  pass "connect preserves framed binary traffic and reaps a blocked producer on peer close"
fi

next_test
broker_available=false
broker_skip_reason=""
if [ "$(uname -s)" != Darwin ]; then
  broker_skip_reason="requires macOS sandbox-exec and sftp-server"
elif [ "$bridge_fixture_available" != true ]; then
  broker_skip_reason="host transport fixture is unavailable"
elif ! command -v cargo >/dev/null 2>&1; then
  broker_skip_reason="cargo is unavailable"
elif [ ! -x /usr/bin/sandbox-exec ] \
  || [ ! -x /usr/libexec/sftp-server ] \
  || [ ! -x /usr/bin/sftp ]; then
  broker_skip_reason="required macOS sandbox or SFTP executable is unavailable"
fi
if [ -n "$broker_skip_reason" ]; then
  skip "Rust broker supports real SFTP workspace list, read, and write" "$broker_skip_reason"
else
  if ! CARGO_TARGET_DIR="$test_root/cargo-target" \
      cargo build --quiet --locked --offline \
        --manifest-path "$repo_root/Cargo.toml" \
        --bin agent-container-launcher \
      > "$test_root/cargo-build.out" 2> "$test_root/cargo-build.err"; then
    show_diagnostic_file "$test_root/cargo-build.err"
    fail "could not build the Rust workspace broker"
  fi
  broker_binary="$test_root/cargo-target/debug/agent-container-launcher"
  [ -x "$broker_binary" ] || fail "Rust workspace broker binary was not produced"
  workspace_root=$(mktemp -d "$test_root/workspace.XXXXXX")
  printf '\000WORKSPACE-SEED\377\n' > "$workspace_root/seed.bin"
  printf '\377WORKSPACE-UPLOAD\000\n' > "$test_root/upload-source.bin"
  printf '%s\n' \
    'ls .' \
    "get seed.bin $test_root/downloaded-seed.bin" \
    "put $test_root/upload-source.bin uploaded.bin" \
    'ls .' \
    'quit' \
    > "$test_root/sftp-success.batch"

  start_broker "$workspace_root" \
    "$test_root/broker-success.record" "$test_root/broker-success.err"
  if ! run_sftp_batch \
      "$test_root/sftp-success.batch" \
      "$test_root/sftp-success.out" \
      "$test_root/sftp-success.err"; then
    show_diagnostic_file "$test_root/sftp-success.err"
    show_diagnostic_file "$test_root/broker-success.err"
    stop_active_process
    fail "macOS sftp client could not use the Rust workspace broker"
  fi
  wait_for_active_success "$test_root/broker-success.err"
  cmp "$workspace_root/seed.bin" "$test_root/downloaded-seed.bin" \
    || fail "workspace read changed file contents"
  cmp "$test_root/upload-source.bin" "$workspace_root/uploaded.bin" \
    || fail "workspace write changed file contents"
  grep -Fq 'seed.bin' "$test_root/sftp-success.out" \
    || fail "workspace listing omitted the seed file"
  grep -Fq 'uploaded.bin' "$test_root/sftp-success.out" \
    || fail "workspace listing omitted the uploaded file"
  broker_available=true
  pass "Rust broker supports real SFTP workspace list, read, and write"
fi

next_test
if [ "$broker_available" != true ]; then
  skip "Rust broker sandbox denies SFTP reads outside workspace" "${broker_skip_reason:-broker setup did not run}"
else
  printf '%s\n' \
    "get /etc/passwd $test_root/escaped-passwd" \
    'quit' \
    > "$test_root/sftp-escape.batch"
  start_broker "$workspace_root" \
    "$test_root/broker-escape.record" "$test_root/broker-escape.err"
  if run_sftp_batch \
      "$test_root/sftp-escape.batch" \
      "$test_root/sftp-escape.out" \
      "$test_root/sftp-escape.err"; then
    escape_status=0
  else
    escape_status=$?
  fi
  wait_for_active_success "$test_root/broker-escape.err"
  if [ "$escape_status" -eq 0 ]; then
    record_failure "Rust broker sandbox allowed SFTP to read /etc/passwd"
  elif [ -s "$test_root/escaped-passwd" ]; then
    record_failure "Rust broker sandbox exposed bytes from /etc/passwd"
  elif ! grep -Eiq 'denied|failure|couldn.t|not found' \
      "$test_root/sftp-escape.err"; then
    show_diagnostic_file "$test_root/sftp-escape.err"
    record_failure "SFTP did not report the sandbox denial"
  else
    pass "Rust broker sandbox denies SFTP reads outside workspace"
  fi
fi

next_test
physical_launcher="$repo_root/dist/agent-container-darwin-arm64"
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  skip "physical release launcher dispatches the private workspace broker" \
    "requires the built macOS arm64 release in dist/"
elif [ ! -x "$physical_launcher" ]; then
  fail "built physical release launcher is not executable; run scripts/build-release.sh"
else
  physical_workspace=$(mktemp -d "$test_root/physical-workspace.XXXXXX")
  previous_broker_binary=${broker_binary:-}
  broker_binary="$physical_launcher"
  start_broker "$physical_workspace" \
    "$test_root/physical-broker.record" "$test_root/physical-broker.err"
  stop_active_process
  broker_binary=$previous_broker_binary
  pass "physical release launcher dispatches the private workspace broker"
fi

next_test
if [ "$broker_available" != true ]; then
  skip "broker owner EOF revokes an unaccepted workspace endpoint" \
    "${broker_skip_reason:-broker setup did not run}"
else
  liveness_fifo="$test_root/broker-liveness.fifo"
  liveness_record="$test_root/broker-liveness.record"
  liveness_error="$test_root/broker-liveness.err"
  mkfifo -m 0600 "$liveness_fifo"
  exec 7<> "$liveness_fifo"
  exec 8< "$liveness_fifo"
  rm -f -- "$liveness_fifo"
  (
    exec 7>&-
    exec "$broker_binary" __workspace-broker \
      "$workspace_root" 127.0.0.1 --liveness-fd 8
  ) > "$liveness_record" 2> "$liveness_error" &
  active_pid=$!
  exec 8<&-
  wait_for_record "$liveness_record" "$liveness_error"
  exec 7>&-
  set +e
  wait_with_timeout "$active_pid"
  liveness_status=$?
  set -e
  active_pid=""
  [ "$liveness_status" -eq 1 ] \
    || fail "owner EOF returned unexpected broker status $liveness_status"
  grep -Fq 'workspace broker owner exited' "$liveness_error" \
    || fail "owner EOF did not report liveness revocation"
  pass "broker owner EOF revokes an unaccepted workspace endpoint"
fi

next_test
bash -n "$session_script" \
  || fail "workspace session helper has invalid shell syntax"
for session_contract in \
  'exec /usr/bin/unshare' \
  '--mount' \
  '--propagation private' \
  'trap cleanup EXIT' \
  '/usr/bin/sshfs' \
  'agent-container:.' \
  '-o cache_timeout=1' \
  '/usr/bin/setpriv' \
  '/usr/bin/setsid' \
  'setsid_arguments+=(--ctty)' \
  '--default-signal=INT' \
  '--default-signal=QUIT' \
  '--clear-groups' \
  '--no-new-privs' \
  'printf '\''1\n'\'' > "$agent_cgroup/cgroup.freeze"' \
  'printf '\''1\n'\'' > "$agent_cgroup/cgroup.kill"' \
  'exec 7<> "$agent_start_fifo"' \
  'exec 8< "$agent_start_fifo"' \
  'printf '\''%s\n'\'' "$agent_pid" > "$agent_cgroup/cgroup.procs"' \
  'while :; do' \
  'session_runtime_dir=$(/usr/bin/mktemp -d' \
  'XDG_RUNTIME_DIR="$session_runtime_dir"'; do
  grep -Fq -- "$session_contract" "$session_script" \
    || fail "workspace session helper is missing contract: $session_contract"
done
grep -Fq -- '/usr/bin/setsid --fork' "$session_script" \
  && fail "workspace session must keep the direct Agent PID instead of a setsid supervisor"
grep -Eq '^[[:space:]]*wait[[:space:]]+-n([[:space:]]|$)' "$session_script" \
  && fail "workspace session must not lose a fast Agent status through wait -n"
agent_stop_line=$(grep -nF 'stop_agent_processes' "$session_script" \
  | tail -n 1 | cut -d: -f1)
cgroup_remove_line=$(grep -nF '/usr/bin/rmdir -- "$agent_cgroup"' "$session_script" \
  | head -n 1 | cut -d: -f1)
cleanup_cd_line=$(grep -nF 'cd / 2>/dev/null || true' "$session_script" \
  | head -n 1 | cut -d: -f1)
sshfs_term_line=$(grep -nF 'kill -TERM "$sshfs_pid"' "$session_script" \
  | head -n 1 | cut -d: -f1)
sshfs_wait_line=$(grep -nF '[ -z "$sshfs_pid" ] || wait "$sshfs_pid"' "$session_script" \
  | head -n 1 | cut -d: -f1)
fallback_unmount_line=$(grep -nF '/usr/bin/fusermount3 -u -- "$workspace_root"' "$session_script" \
  | head -n 1 | cut -d: -f1)
case "$agent_stop_line:$cgroup_remove_line:$cleanup_cd_line:$sshfs_term_line:$sshfs_wait_line:$fallback_unmount_line" in
  *[!0-9:]*|:*|*::*|*:)
    fail "workspace session cleanup ordering could not be inspected"
    ;;
esac
[ "$agent_stop_line" -lt "$cgroup_remove_line" ] \
  && [ "$cgroup_remove_line" -lt "$cleanup_cd_line" ] \
  && [ "$cleanup_cd_line" -lt "$sshfs_term_line" ] \
  && [ "$sshfs_term_line" -lt "$sshfs_wait_line" ] \
  && [ "$sshfs_wait_line" -lt "$fallback_unmount_line" ] \
  || fail "workspace session must empty the Agent cgroup, reap SSHFS, then use fallback unmount"
if [ "$(id -u)" -ne 0 ]; then
  set +e
  "$session_script" /tmp /tmp 1 1 claude \
    > "$test_root/session-nonroot.out" 2> "$test_root/session-nonroot.err"
  session_status=$?
  set -e
  [ "$session_status" -eq 64 ] \
    || fail "workspace session did not reject non-root execution with status 64"
  grep -Fq 'must run as root' "$test_root/session-nonroot.err" \
    || fail "workspace session non-root rejection was not explicit"
fi
pass "workspace session statically enforces private mount and privilege-drop contracts"

next_test
skip "workspace session performs a live FUSE mount" \
  "requires the Linux guest, root/CAP_SYS_ADMIN, /dev/fuse, sshfs, and a live host broker"

[ "$tests_run" -eq 8 ] || fail "internal TAP plan mismatch"
[ "$failures" -eq 0 ] || exit 1
