#!/bin/bash
set -euo pipefail

export LC_ALL=C

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
container_name=${AGENT_WORKSPACE_LIVE_CONTAINER:-}
gateway=${AGENT_WORKSPACE_LIVE_GATEWAY:-}
runtime_uid=${AGENT_WORKSPACE_LIVE_UID:-$(id -u)}
runtime_gid=${AGENT_WORKSPACE_LIVE_GID:-$(id -g)}

case "$container_name" in
  agent-workspace-session-test-*) ;;
  *)
    printf '%s\n' \
      'Set AGENT_WORKSPACE_LIVE_CONTAINER to a dedicated agent-workspace-session-test-* container.' \
      >&2
    exit 64
    ;;
esac
case "$runtime_uid:$runtime_gid" in
  *[!0-9:]*|:*|*::*|*:) exit 64 ;;
esac

for required in \
  "$repo_root/agent-container-darwin-arm64" \
  "$repo_root/target/release/agent-container-launcher" \
  "$repo_root/agent-workspace-connect" \
  "$repo_root/agent-workspace-session" \
  "$repo_root/tests/fixtures/workspace-session-test-agent"; do
  [ -f "$required" ] && [ ! -L "$required" ] \
    || { printf 'Unsafe live-test input: %s\n' "$required" >&2; exit 64; }
done
command -v container >/dev/null 2>&1 \
  || { printf 'Apple container CLI is unavailable.\n' >&2; exit 64; }

if [ -z "$gateway" ]; then
  network_record=$(mktemp /tmp/agent-workspace-network.XXXXXXXX)
  container network inspect default > "$network_record"
  gateway=$(/usr/bin/osascript -l JavaScript - "$network_record" <<'JXA'
ObjC.import('Foundation');
function run(argv) {
  const source = $.NSString.stringWithContentsOfFileEncodingError(
    argv[0], $.NSUTF8StringEncoding, null
  );
  const value = JSON.parse(ObjC.unwrap(source));
  if (!Array.isArray(value) || value.length !== 1) throw new Error('network');
  return value[0].status.ipv4Gateway;
}
JXA
  )
  /bin/rm -f -- "$network_record"
fi
printf '%s\n' "$gateway" \
  | /usr/bin/awk -F. 'NF == 4 { for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1; ok=1 } END { exit !ok }' \
  || { printf 'Invalid live-test gateway.\n' >&2; exit 64; }

# Use a canonical host path whose guest ancestors are not the Linux `/private`
# compatibility tree.  On macOS, `/tmp` canonicalizes to `/private/tmp`; a
# minimal test image may not have that tree, and a deliberately private caller
# umask can leave its synthetic ancestors inaccessible to the runtime UID.
test_root=$(mktemp -d "$repo_root/.agent-workspace-session-live-test.XXXXXXXX")
test_root=$(CDPATH= cd -- "$test_root" && pwd -P)
background_pids=()
guest_pid_files=()
owned_broker_pids=()
owned_broker_roots=()
wait_status=0
active_wait_watchdog_pid=
active_wait_writer_open=0
broker_pid=
broker_endpoint=
broker_token=
session_pid=
session_guest_pid_file=

cleanup() {
  local status=$?
  local broker_index diagnostic_file job_spec pid pid_file

  trap '' INT TERM HUP ALRM
  trap - EXIT
  set +e
  cancel_wait_watchdog
  if [ "$status" -ne 0 ]; then
    printf 'workspace session live test failed (status %s); diagnostics follow.\n' \
      "$status" >&2
    for diagnostic_file in \
      "$test_root"/*.session.err \
      "$test_root"/*.session.out \
      "$test_root"/*.broker.err; do
      [ -f "$diagnostic_file" ] || continue
      printf '%s\n' "--- ${diagnostic_file##*/}" >&2
      /bin/cat -- "$diagnostic_file" >&2
    done
    printf '%s\n' '--- workspace files' >&2
    /usr/bin/find "$test_root" -mindepth 2 -maxdepth 2 -type f \
      ! -name '*.broker.record' -print 2>/dev/null >&2 || true
    printf '%s\n' '--- guest lifecycle state' >&2
    container exec "$container_name" /bin/bash -c '
      uid=$1
      /usr/bin/find /sys/fs/cgroup -maxdepth 1 -type d \
        -name "agent-container-$uid-*" -print
      /usr/bin/find /run/agent-container -maxdepth 1 \
        \( -name "session-$uid-*" -o -name "control-$uid-*" \
           -o -name "live-test-$uid-*.pid" \) -print
      /usr/bin/ps -eo pid=,ppid=,sid=,pgid=,stat=,comm=,args= \
        | /bin/grep -E \
          "agent-workspace-(session|connect)|workspace-session-test-agent|sshfs" \
        | /bin/grep -v grep || true
    ' live-diagnostics "$runtime_uid" >&2 2>&1 || true
  fi
  for pid_file in "${guest_pid_files[@]}"; do
    container exec "$container_name" /bin/bash -c '
      pid_file=$1
      if [ -s "$pid_file" ]; then
        pid=$(/bin/cat "$pid_file")
        case "$pid" in ""|0|*[!0-9]*) ;; *) /bin/kill -TERM "$pid" 2>/dev/null ;; esac
      fi
      /bin/rm -f -- "$pid_file"
    ' live-cleanup "$pid_file" >/dev/null 2>&1 || true
  done
  for pid in "${background_pids[@]}"; do
    if job_spec=$(host_job_spec_for_pid "$pid"); then
      builtin kill -TERM "$job_spec" 2>/dev/null || true
      /bin/sleep 0.05
      builtin kill -KILL "$job_spec" 2>/dev/null || true
    else
      wait "$pid" 2>/dev/null || true
    fi
  done
  for broker_index in "${!owned_broker_pids[@]}"; do
    wait_for_owned_broker_exit \
      "${owned_broker_pids[$broker_index]}" \
      "${owned_broker_roots[$broker_index]}" || true
  done
  case "$test_root" in
    "$repo_root"/.agent-workspace-session-live-test.*)
      /bin/rm -rf -- "$test_root"
      ;;
    *) status=1 ;;
  esac
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

wait_for_file() {
  local file=$1
  local attempt

  for attempt in $(/usr/bin/seq 1 600); do
    [ -s "$file" ] && return 0
    /bin/sleep 0.025
  done
  return 1
}

host_job_is_active() {
  local wanted_pid=$1

  host_job_spec_for_pid "$wanted_pid" >/dev/null
}

host_job_spec_for_pid() {
  local wanted_pid=$1
  local active_pid job_number job_record job_state

  [ -n "$wanted_pid" ] || return 1
  for job_state in -lr -ls; do
    while IFS=' ' read -r job_record active_pid _; do
      [ "$active_pid" = "$wanted_pid" ] || continue
      job_number=${job_record#\[}
      job_number=${job_number%%\]*}
      case "$job_number" in
        ''|*[!0-9]*) return 1 ;;
      esac
      printf '%%%s\n' "$job_number"
      return 0
    done < <(jobs "$job_state" 2>/dev/null)
  done
  return 1
}

cancel_wait_watchdog() {
  if [ "$active_wait_writer_open" -eq 1 ]; then
    printf '\n' >&9 2>/dev/null || true
    exec 9>&-
    active_wait_writer_open=0
  fi
  if [ -n "$active_wait_watchdog_pid" ]; then
    wait "$active_wait_watchdog_pid" 2>/dev/null || true
    active_wait_watchdog_pid=
  fi
}

start_wait_watchdog() {
  local timeout_seconds=$1
  local fifo

  case "$timeout_seconds" in
    ''|0|*[!0-9]*) return 64 ;;
  esac
  [ -z "$active_wait_watchdog_pid" ] \
    && [ "$active_wait_writer_open" -eq 0 ] || return 70
  fifo="$test_root/.wait-watchdog.$RANDOM.$RANDOM"
  /usr/bin/mkfifo -m 0600 -- "$fifo"
  exec 9<> "$fifo"
  exec 8< "$fifo"
  /bin/rm -f -- "$fifo"
  active_wait_writer_open=1
  /bin/bash -c '
    exec 9>&-
    parent_pid=$1
    timeout_seconds=$2
    if IFS= read -r -t "$timeout_seconds" -u 8 unused; then
      exit 0
    fi
    [ "$PPID" = "$parent_pid" ] || exit 0
    builtin kill -ALRM "$parent_pid"
  ' wait-watchdog "$$" "$timeout_seconds" &
  active_wait_watchdog_pid=$!
  exec 8<&-
}

wait_for_process() {
  local pid=$1
  local initial_signal=${2:-}
  local job_spec kill_wait_timed_out=0 process_status timed_out=0

  case "$initial_signal" in
    ''|TERM|KILL) ;;
    *) return 64 ;;
  esac

  job_spec=$(host_job_spec_for_pid "$pid") || {
    set +e
    wait "$pid" 2>/dev/null
    wait_status=$?
    set -e
    return 0
  }
  trap 'timed_out=1' ALRM
  start_wait_watchdog 20
  if [ -n "$initial_signal" ]; then
    builtin kill -s "$initial_signal" "$job_spec"
  fi
  set +e
  wait "$pid" 2>/dev/null
  process_status=$?
  set -e
  cancel_wait_watchdog
  trap - ALRM
  if [ "$timed_out" -eq 1 ]; then
    builtin kill -KILL "$job_spec" 2>/dev/null || true
    trap 'kill_wait_timed_out=1' ALRM
    start_wait_watchdog 1
    set +e
    wait "$pid" 2>/dev/null || true
    set -e
    cancel_wait_watchdog
    trap - ALRM
    : "$kill_wait_timed_out"
    wait_status=124
  else
    wait_status=$process_status
  fi
}

start_broker() {
  local workspace=$1
  local stem=$2
  local record="$test_root/$stem.broker.record"
  local error="$test_root/$stem.broker.err"
  local line extra attempt

  : > "$record"
  : > "$error"
  "$repo_root/agent-container-darwin-arm64" \
    __workspace-broker "$workspace" "$gateway" \
    > "$record" 2> "$error" &
  broker_pid=$!
  background_pids+=("$broker_pid")
  for attempt in $(/usr/bin/seq 1 600); do
    [ -s "$record" ] && break
    host_job_is_active "$broker_pid" || break
    /bin/sleep 0.025
  done
  [ -s "$record" ] || { /bin/cat "$error" >&2; return 1; }
  IFS=$'\t' read -r broker_endpoint broker_token extra < "$record"
  [ -z "${extra:-}" ] && [ "${#broker_token}" -eq 64 ]
  line=$(sed -n '1p' "$record")
  [ "$line" = "$broker_endpoint"$'\t'"$broker_token" ]
}

start_owned_broker() {
  local workspace=$1
  local stem=$2
  local record="$test_root/$stem.broker.record"
  local error="$test_root/$stem.broker.err"
  local fifo="$test_root/$stem.owner.fifo"
  local pid_record="$test_root/$stem.broker.pid"
  local line extra attempt

  : > "$record"
  : > "$error"
  (
    trap - EXIT INT TERM HUP
    /usr/bin/mkfifo -m 0600 -- "$fifo"
    exec 7<> "$fifo"
    exec 8< "$fifo"
    /bin/rm -f -- "$fifo"
    (
      exec 7>&-
      exec "$repo_root/target/release/agent-container-launcher" \
        __workspace-broker "$workspace" "$gateway" --liveness-fd 8
    ) > "$record" 2> "$error" &
    owned_pid=$!
    exec 8<&-
    printf '%s\n' "$owned_pid" > "$pid_record"
    wait "$owned_pid"
  ) &
  broker_owner_pid=$!
  background_pids+=("$broker_owner_pid")
  for attempt in $(/usr/bin/seq 1 600); do
    [ -s "$record" ] && [ -s "$pid_record" ] && break
    host_job_is_active "$broker_owner_pid" || break
    /bin/sleep 0.025
  done
  [ -s "$record" ] && [ -s "$pid_record" ] \
    || { /bin/cat "$error" >&2; return 1; }
  owned_broker_pid=$(/bin/cat -- "$pid_record")
  case "$owned_broker_pid" in ""|0|*[!0-9]*) return 1 ;; esac
  owned_broker_pids+=("$owned_broker_pid")
  owned_broker_roots+=("$workspace")
  IFS=$'\t' read -r broker_endpoint broker_token extra < "$record"
  [ -z "${extra:-}" ] && [ "${#broker_token}" -eq 64 ]
  line=$(sed -n '1p' "$record")
  [ "$line" = "$broker_endpoint"$'\t'"$broker_token" ]
}

wait_for_owned_broker_exit() {
  local pid=$1
  local workspace=$2
  local attempt broker_command

  for attempt in $(/usr/bin/seq 1 400); do
    broker_command=$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)
    case "$broker_command" in
      *"__workspace-broker $workspace "*) /bin/sleep 0.025 ;;
      *) return 0 ;;
    esac
  done
  printf 'owned broker %s did not exit after owner death.\n' "$pid" >&2
  return 1
}

start_session() {
  local workspace=$1
  local stem=$2
  shift 2

  session_guest_pid_file="/run/agent-container/live-test-$runtime_uid-$RANDOM-$RANDOM.pid"
  guest_pid_files+=("$session_guest_pid_file")
  container exec --interactive --uid 0 --gid 0 --workdir / \
    --env "AGENT_WORKSPACE_ENDPOINT=$broker_endpoint" \
    --env "AGENT_WORKSPACE_TOKEN=$broker_token" \
    "$container_name" \
    /bin/bash -c '
      pid_file=$1
      shift
      umask 077
      printf "%s\n" "$$" > "$pid_file"
      exec "$@"
    ' live-wrapper "$session_guest_pid_file" \
    /usr/local/bin/agent-workspace-session \
    "$workspace" "$workspace" "$runtime_uid" "$runtime_gid" \
    workspace-session-test-agent "$@" \
    > "$test_root/$stem.session.out" \
    2> "$test_root/$stem.session.err" &
  session_pid=$!
  background_pids+=("$session_pid")
}

signal_guest_session() {
  local pid_file=$1
  local signal_name=$2

  container exec "$container_name" /bin/bash -c '
    pid_file=$1
    signal_name=$2
    pid=$(/bin/cat "$pid_file")
    case "$pid" in ""|0|*[!0-9]*) exit 64 ;; esac
    /bin/kill -s "$signal_name" "$pid"
  ' live-signal "$pid_file" "$signal_name"
}

assert_guest_clean() {
  container exec "$container_name" /bin/bash -c '
    uid=$1
    shift
    for identity in "$@"; do
      case "$identity" in
        [1-9]*:[1-9]*) ;;
        *) exit 64 ;;
      esac
      pid=${identity%%:*}
      expected_start=${identity##*:}
      case "$pid:$expected_start" in *[!0-9:]*|:*|*::*|*:) exit 64 ;; esac
      for unused in $(/usr/bin/seq 1 80); do
        [ ! -r "/proc/$pid/stat" ] && break
        current_start=$(/usr/bin/awk "{ print \$22 }" "/proc/$pid/stat" 2>/dev/null || true)
        [ "$current_start" != "$expected_start" ] && break
        /bin/sleep 0.025
      done
      current_start=$(/usr/bin/awk "{ print \$22 }" "/proc/$pid/stat" 2>/dev/null || true)
      if [ "$current_start" = "$expected_start" ]; then
        printf "expected guest process identity %s to be gone:\n" "$identity" >&2
        /usr/bin/ps -o pid=,ppid=,sid=,pgid=,stat=,comm=,args= \
          -p "$pid" >&2 || true
        exit 1
      fi
    done
    test -z "$(/usr/bin/find /sys/fs/cgroup -maxdepth 1 -type d -name "agent-container-$uid-*" -print -quit)"
    test -z "$(/usr/bin/find /run/agent-container -maxdepth 1 \( -name "session-$uid-*" -o -name "control-$uid-*" \) -print -quit)"
    for proc_dir in /proc/[0-9]*; do
      [ -r "$proc_dir/cmdline" ] || continue
      proc_pid=${proc_dir##*/}
      [ "$proc_pid" != "$$" ] || continue
      proc_command=$(/usr/bin/tr "\000" " " < "$proc_dir/cmdline" 2>/dev/null || true)
      case "$proc_command" in
        *"/usr/local/bin/agent-workspace-session"*|\
        *"/usr/local/bin/agent-workspace-connect"*|\
        *"/usr/local/bin/workspace-session-test-agent"*|\
        *"/usr/bin/sshfs "*)
          printf "unexpected live-test guest process %s: %s\n" \
            "$proc_pid" "$proc_command" >&2
          exit 1
          ;;
      esac
    done
  ' live-assert "$runtime_uid" "$@"
}

read_tree_identity() {
  local base=$1
  local pid start_time

  pid=$(/bin/cat -- "$base.pid")
  start_time=$(/bin/cat -- "$base.start")
  case "$pid:$start_time" in *[!0-9:]*|:*|*::*|*:) return 1 ;; esac
  [ "$pid" -gt 0 ] && [ "$start_time" -gt 0 ] || return 1
  printf '%s:%s\n' "$pid" "$start_time"
}

container cp "$repo_root/agent-workspace-session" \
  "$container_name:/usr/local/bin/agent-workspace-session" >/dev/null
container cp "$repo_root/agent-workspace-connect" \
  "$container_name:/usr/local/bin/agent-workspace-connect" >/dev/null
container cp "$repo_root/tests/fixtures/workspace-session-test-agent" \
  "$container_name:/usr/local/bin/workspace-session-test-agent" >/dev/null
container exec "$container_name" /bin/chmod 0755 \
  /usr/local/bin/agent-workspace-session \
  /usr/local/bin/agent-workspace-connect \
  /usr/local/bin/workspace-session-test-agent

printf 'TAP version 13\n'
printf '1..5\n'

normal_workspace="$test_root/normal"
/bin/mkdir "$normal_workspace"
start_broker "$normal_workspace" normal
normal_broker_pid=$broker_pid
start_session "$normal_workspace" normal exit-tree normal 37
normal_session_pid=$session_pid
wait_for_process "$normal_session_pid"
[ "$wait_status" -eq 37 ]
normal_ordinary_identity=$(read_tree_identity "$normal_workspace/normal.ordinary")
normal_detached_identity=$(read_tree_identity "$normal_workspace/normal.detached")
normal_stubborn_identity=$(read_tree_identity "$normal_workspace/normal.stubborn")
wait_for_process "$normal_broker_pid"
[ "$wait_status" -eq 0 ]
[ "$(/bin/cat "$normal_workspace/normal.ordinary.term")" = TERM ]
[ "$(/bin/cat "$normal_workspace/normal.detached.term")" = TERM ]
assert_guest_clean \
  "$normal_ordinary_identity" \
  "$normal_detached_identity" \
  "$normal_stubborn_identity"
printf 'ok 1 - normal Agent exit preserves status and cgroup-cleans ordinary, detached, and TERM-ignoring descendants\n'

term_workspace="$test_root/term"
/bin/mkdir "$term_workspace"
start_broker "$term_workspace" term
term_broker_pid=$broker_pid
start_session "$term_workspace" term wait-tree term
term_session_pid=$session_pid
term_pid_file=$session_guest_pid_file
wait_for_file "$term_workspace/term.ready"
term_main_identity=$(read_tree_identity "$term_workspace/term.main")
term_ordinary_identity=$(read_tree_identity "$term_workspace/term.ordinary")
term_detached_identity=$(read_tree_identity "$term_workspace/term.detached")
term_stubborn_identity=$(read_tree_identity "$term_workspace/term.stubborn")
signal_guest_session "$term_pid_file" TERM
wait_for_process "$term_session_pid"
[ "$wait_status" -eq 143 ]
wait_for_process "$term_broker_pid"
[ "$wait_status" -eq 0 ]
[ "$(/bin/cat "$term_workspace/term.main.term")" = TERM ]
[ "$(/bin/cat "$term_workspace/term.ordinary.term")" = TERM ]
[ "$(/bin/cat "$term_workspace/term.detached.term")" = TERM ]
assert_guest_clean \
  "$term_main_identity" \
  "$term_ordinary_identity" \
  "$term_detached_identity" \
  "$term_stubborn_identity"
printf 'ok 2 - helper TERM returns 143 and leaves no Agent tree, cgroup, mount, or session state\n'

loss_workspace="$test_root/loss"
/bin/mkdir "$loss_workspace"
start_broker "$loss_workspace" loss
loss_broker_pid=$broker_pid
start_session "$loss_workspace" loss idle-tree loss
loss_session_pid=$session_pid
wait_for_file "$loss_workspace/loss.ready"
loss_main_identity=$(read_tree_identity "$loss_workspace/loss.main")
loss_ordinary_identity=$(read_tree_identity "$loss_workspace/loss.ordinary")
loss_detached_identity=$(read_tree_identity "$loss_workspace/loss.detached")
loss_stubborn_identity=$(read_tree_identity "$loss_workspace/loss.stubborn")
wait_for_process "$loss_broker_pid" TERM
[ "$wait_status" -eq 143 ]
wait_for_process "$loss_session_pid"
[ "$wait_status" -eq 74 ]
# Once the SFTP peer is gone, signal handlers cannot reliably write markers
# through the failed FUSE mount.  Kernel process absence is the authoritative
# cleanup assertion for this path.
assert_guest_clean \
  "$loss_main_identity" \
  "$loss_ordinary_identity" \
  "$loss_detached_identity" \
  "$loss_stubborn_identity"
printf 'ok 3 - broker loss returns 74 and reclaims the complete Agent tree\n'

workspace_a="$test_root/project-a"
workspace_b="$test_root/project-b"
/bin/mkdir "$workspace_a" "$workspace_b"
start_broker "$workspace_a" project-a
broker_a_pid=$broker_pid
endpoint_a=$broker_endpoint
token_a=$broker_token
start_session "$workspace_a" project-a wait-tree project-a
session_a_pid=$session_pid
pid_file_a=$session_guest_pid_file
start_broker "$workspace_b" project-b
broker_b_pid=$broker_pid
endpoint_b=$broker_endpoint
token_b=$broker_token
broker_endpoint=$endpoint_b
broker_token=$token_b
start_session "$workspace_b" project-b wait-tree project-b
session_b_pid=$session_pid
pid_file_b=$session_guest_pid_file
wait_for_file "$workspace_a/project-a.ready"
wait_for_file "$workspace_b/project-b.ready"
project_a_main_identity=$(read_tree_identity "$workspace_a/project-a.main")
project_a_ordinary_identity=$(read_tree_identity "$workspace_a/project-a.ordinary")
project_a_detached_identity=$(read_tree_identity "$workspace_a/project-a.detached")
project_a_stubborn_identity=$(read_tree_identity "$workspace_a/project-a.stubborn")
project_b_main_identity=$(read_tree_identity "$workspace_b/project-b.main")
project_b_ordinary_identity=$(read_tree_identity "$workspace_b/project-b.ordinary")
project_b_detached_identity=$(read_tree_identity "$workspace_b/project-b.detached")
project_b_stubborn_identity=$(read_tree_identity "$workspace_b/project-b.stubborn")
heartbeat_before=$(/bin/cat "$workspace_b/project-b.heartbeat")
signal_guest_session "$pid_file_a" TERM
wait_for_process "$session_a_pid"
[ "$wait_status" -eq 143 ]
/bin/sleep 0.2
heartbeat_after=$(/bin/cat "$workspace_b/project-b.heartbeat")
[ "$heartbeat_after" != "$heartbeat_before" ]
container exec "$container_name" /bin/bash -c '
  pid=$(/bin/cat "$1")
  /bin/kill -0 "$pid"
' live-isolation "$pid_file_b"
signal_guest_session "$pid_file_b" TERM
wait_for_process "$session_b_pid"
[ "$wait_status" -eq 143 ]
wait_for_process "$broker_a_pid"
[ "$wait_status" -eq 0 ]
wait_for_process "$broker_b_pid"
[ "$wait_status" -eq 0 ]
assert_guest_clean \
  "$project_a_main_identity" \
  "$project_a_ordinary_identity" \
  "$project_a_detached_identity" \
  "$project_a_stubborn_identity" \
  "$project_b_main_identity" \
  "$project_b_ordinary_identity" \
  "$project_b_detached_identity" \
  "$project_b_stubborn_identity"
printf 'ok 4 - concurrent A/B sessions share one container and terminating A does not affect B\n'

owner_loss_workspace="$test_root/owner-loss"
/bin/mkdir "$owner_loss_workspace"
start_owned_broker "$owner_loss_workspace" owner-loss
owner_loss_parent_pid=$broker_owner_pid
owner_loss_broker_pid=$owned_broker_pid
start_session "$owner_loss_workspace" owner-loss idle-tree owner-loss
owner_loss_session_pid=$session_pid
wait_for_file "$owner_loss_workspace/owner-loss.ready"
owner_loss_main_identity=$(read_tree_identity "$owner_loss_workspace/owner-loss.main")
owner_loss_ordinary_identity=$(read_tree_identity "$owner_loss_workspace/owner-loss.ordinary")
owner_loss_detached_identity=$(read_tree_identity "$owner_loss_workspace/owner-loss.detached")
owner_loss_stubborn_identity=$(read_tree_identity "$owner_loss_workspace/owner-loss.stubborn")
wait_for_process "$owner_loss_parent_pid" KILL
[ "$wait_status" -eq 137 ]
wait_for_process "$owner_loss_session_pid"
[ "$wait_status" -eq 74 ]
wait_for_owned_broker_exit "$owner_loss_broker_pid" "$owner_loss_workspace"
assert_guest_clean \
  "$owner_loss_main_identity" \
  "$owner_loss_ordinary_identity" \
  "$owner_loss_detached_identity" \
  "$owner_loss_stubborn_identity"
printf 'ok 5 - SIGKILL of the broker owner closes the active workspace and reclaims the guest session\n'
