#!/bin/bash
set -euo pipefail

# Real macOS host-exec integration test. It deliberately does not invoke the
# Apple container runtime. The production client has a fixed guest path under
# /run; for this host-only test its source is evaluated in memory with that one
# constant replaced by a test environment variable. The checked-in client is
# never copied or modified.

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
broker_script="$repo_root/runtime/host-exec-broker.mjs"
client_script="$repo_root/runtime/host-exec-client"
sandbox_bin=/usr/bin/sandbox-exec

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  tests_passed=$((tests_passed + 1))
  printf 'ok %s - %s\n' "$tests_passed" "$*"
}

for required in node jq base64 dd tr sed find mkfifo xcode-select xcrun; do
  command -v "$required" >/dev/null 2>&1 \
    || fail "required host command is unavailable: $required"
done
[ -x "$sandbox_bin" ] || fail "sandbox-exec is unavailable: $sandbox_bin"
[ -f "$broker_script" ] && [ ! -L "$broker_script" ] \
  || fail 'host-exec-broker.mjs is unavailable'
[ -f "$client_script" ] && [ ! -L "$client_script" ] \
  || fail 'host-exec-client is unavailable'

real_home=$(CDPATH= cd -- "${HOME:?HOME is not set}" && pwd -P)
test_root=''
broker_pid=''
signal_client_pid=''
signal_producer_pid=''
tests_passed=0
cleanup() {
  cleanup_status=$?
  trap - EXIT INT TERM HUP
  for transient_pid in "$signal_client_pid" "$signal_producer_pid"; do
    if [ -n "$transient_pid" ] && kill -0 "$transient_pid" 2>/dev/null; then
      kill -TERM "$transient_pid" 2>/dev/null || true
    fi
  done
  for transient_pid in "$signal_client_pid" "$signal_producer_pid"; do
    [ -z "$transient_pid" ] || wait "$transient_pid" >/dev/null 2>&1 || true
  done
  if [ -n "$broker_pid" ] && kill -0 "$broker_pid" 2>/dev/null; then
    kill -TERM "$broker_pid" 2>/dev/null || true
    cleanup_wait=0
    while kill -0 "$broker_pid" 2>/dev/null && [ "$cleanup_wait" -lt 60 ]; do
      sleep 0.05
      cleanup_wait=$((cleanup_wait + 1))
    done
    if kill -0 "$broker_pid" 2>/dev/null; then
      kill -KILL "$broker_pid" 2>/dev/null || true
    fi
  fi
  if [ -n "$broker_pid" ]; then
    wait "$broker_pid" >/dev/null 2>&1 || true
  fi
  # Delete only the exact, validated directory created above. find -depth keeps
  # cleanup portable without a broad recursive rm target.
  case "$test_root" in
    "$real_home"/.agent-container-host-exec-test.*)
      if [ -d "$test_root" ]; then
        chmod -R u+rwX "$test_root" 2>/dev/null || true
        find "$test_root" -depth -delete 2>/dev/null || true
      fi
      ;;
  esac
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

test_root=$(mktemp -d "$real_home/.agent-container-host-exec-test.XXXXXX") \
  || fail 'could not create the host-exec test directory'
case "$test_root" in
  "$real_home"/.agent-container-host-exec-test.*) ;;
  *) fail "mktemp returned an unsafe test path: $test_root" ;;
esac

session_dir="$test_root/session"
broker_real_home="$test_root/real-home"
exec_home="$broker_real_home/exec-home"
workspace="$broker_real_home/workspace"
read_only_root="$broker_real_home/read-only-root"
unshared_root="$test_root/not-shared"
mkdir -m 0700 \
  "$session_dir" \
  "$broker_real_home" \
  "$exec_home" \
  "$workspace" \
  "$read_only_root" \
  "$unshared_root"
printf '%s\n' 'must-not-be-readable' > "$unshared_root/secret"

node_executable=$(node -p 'require("node:fs").realpathSync(process.execPath)')
case "$node_executable" in
  /*) ;;
  *) fail 'node did not resolve to an absolute executable' ;;
esac
node_bin_dir=$(dirname -- "$node_executable")
if [ "$(basename -- "$node_bin_dir")" = bin ]; then
  node_tool_root=$(dirname -- "$node_bin_dir")
else
  node_tool_root="$node_bin_dir"
fi
node_tool_root=$(CDPATH= cd -- "$node_tool_root" && pwd -P)
developer_tool_path=$(xcode-select -p 2>/dev/null) \
  || fail 'xcode-select did not return an active developer directory'
developer_tool_path=$(CDPATH= cd -- "$developer_tool_path" && pwd -P) \
  || fail 'the active developer directory is unavailable'
case "$developer_tool_path" in
  */Contents/Developer)
    developer_tool_root=${developer_tool_path%/Contents/Developer}
    ;;
  *) developer_tool_root="$developer_tool_path" ;;
esac
git_executable=$(xcrun --find git 2>/dev/null) \
  || fail 'xcrun did not resolve the selected host Git executable'
case "$git_executable" in
  "$developer_tool_root"/*) ;;
  *) fail 'selected host Git is outside the admitted developer runtime' ;;
esac
python_executable=$(xcrun --find python3 2>/dev/null) \
  || fail 'xcrun did not resolve the selected host Python executable'
case "$python_executable" in
  "$developer_tool_root"/*) ;;
  *) fail 'selected host Python is outside the admitted developer runtime' ;;
esac

token=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
wrong_token=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
printf 'first\tnode\t%s\nfirst\tgit\t%s\nfallback\tpython3\t%s\n' \
  "$node_executable" \
  "$git_executable" \
  "$python_executable" \
  > "$session_dir/host-commands.tsv"
printf 'rw\t%s\nro\t%s\n' "$workspace" "$read_only_root" \
  > "$session_dir/host-roots.tsv"
printf '%s\n%s\n' "$node_tool_root" "$developer_tool_root" \
  > "$session_dir/host-tool-roots.txt"
printf '%s\n' "$token" > "$session_dir/host-exec-token"
printf '%s\n' \
  '[agentContainer]' \
  '  testMarker = isolated-real-home' \
  > "$broker_real_home/.gitconfig"
mkdir -m 0700 "$broker_real_home/.ssh"
printf '%s\n' 'test-private-key-must-remain-denied' \
  > "$broker_real_home/.ssh/id_ed25519"
chmod 0600 "$broker_real_home/.ssh/id_ed25519"
chmod 0600 \
  "$session_dir/host-commands.tsv" \
  "$session_dir/host-roots.tsv" \
  "$session_dir/host-tool-roots.txt" \
  "$session_dir/host-exec-token"

broker_stdout="$test_root/broker.stdout"
broker_stderr="$test_root/broker.stderr"
controlled_path="$node_bin_dir:/usr/bin:/bin:/usr/sbin:/sbin"
PATH="$controlled_path" \
  node "$broker_script" \
    --session-dir "$session_dir" \
    --bind-address 127.0.0.1 \
    --launcher-pid "$$" \
    --real-home "$broker_real_home" \
    --exec-home "$exec_home" \
    --sandbox-bin "$sandbox_bin" \
    > "$broker_stdout" 2> "$broker_stderr" &
broker_pid=$!

endpoint_file="$session_dir/host-exec-endpoint"
ready_wait=0
while [ ! -s "$endpoint_file" ] && [ "$ready_wait" -lt 200 ]; do
  kill -0 "$broker_pid" 2>/dev/null \
    || fail "broker exited before readiness: $(sed -n '1,4p' "$broker_stderr")"
  sleep 0.05
  ready_wait=$((ready_wait + 1))
done
[ -s "$endpoint_file" ] \
  || fail "broker did not become ready: $(sed -n '1,4p' "$broker_stderr")"
endpoint=$(sed -n '1p' "$endpoint_file")
case "$endpoint" in
  127.0.0.1:[1-9][0-9]*) ;;
  *) fail "broker published an unexpected endpoint: $endpoint" ;;
esac
pass 'broker starts and atomically publishes an IPv4 endpoint'

# Evaluate the real client with only its fixed guest staging directory changed
# in memory. HOST_EXEC_TEST_DIR is rejected by the client environment filter and
# therefore cannot leak into the spawned host command.
client_source=$(
  sed \
    's|^readonly host_exec_dir=/run/agent-host$|readonly host_exec_dir=${HOST_EXEC_TEST_DIR:?}|' \
    "$client_script"
)
case "$client_source" in
  *'readonly host_exec_dir=${HOST_EXEC_TEST_DIR:?}'*) ;;
  *) fail 'could not prepare the in-memory host-only client source' ;;
esac

client_stdout="$test_root/client.stdout"
client_stderr="$test_root/client.stderr"
set +e
printf 'pipe-data' \
  | (
      CDPATH= cd -- "$workspace" \
        && OPENAI_API_KEY=must-not-forward \
          HOST_EXEC_TEST_DIR="$session_dir" \
          /bin/bash -c "$client_source" host-exec node -e '
            let input = "";
            process.stdin.on("data", (chunk) => { input += chunk; });
            process.stdin.on("end", () => {
              process.stdout.write(`stdout:${input}:${String(process.env.OPENAI_API_KEY)}`);
              process.stderr.write("stderr:ok");
              process.exit(23);
            });
          '
    ) > "$client_stdout" 2> "$client_stderr"
client_status=$?
set -e
[ "$client_status" -eq 23 ] \
  || fail "client returned $client_status instead of host exit status 23: $(sed -n '1,4p' "$client_stderr")"
[ "$(sed -n '1p' "$client_stdout")" = 'stdout:pipe-data:undefined' ] \
  || fail "unexpected streamed stdout: $(sed -n '1,3p' "$client_stdout")"
[ "$(sed -n '1p' "$client_stderr")" = 'stderr:ok' ] \
  || fail "unexpected streamed stderr: $(sed -n '1,3p' "$client_stderr")"
pass 'explicit host-exec streams piped stdin/stdout/stderr and preserves exit status'

# Exercise the two client-side protocol producers at the same time: a
# throttled stdin sender owns a large frame while the foreground shell receives
# SIGTERM and queues a signal frame. The host command handles SIGTERM so every
# input byte must still arrive and the broker must parse both frames cleanly.
signal_fifo="$test_root/signal-input.fifo"
signal_ready="$workspace/signal-ready"
signal_go="$test_root/signal-go"
signal_total_bytes=262144
mkfifo "$signal_fifo" || fail 'could not create the signal concurrency FIFO'
(
  CDPATH= cd -- "$workspace" || exit 1
  export HOST_EXEC_TEST_DIR="$session_dir"
  exec /bin/bash -c "$client_source" host-exec node -e '
    const fs = require("node:fs");
    const readyPath = process.argv[1];
    let bytes = 0;
    let signals = 0;
    process.on("SIGTERM", () => { signals += 1; });
    fs.writeFileSync(readyPath, "ready");
    process.stdin.on("data", (chunk) => { bytes += chunk.length; });
    process.stdin.on("end", () => {
      process.stdout.write(`${bytes}:${signals}`);
      process.exit(signals === 1 ? 0 : 41);
    });
  ' "$signal_ready"
) < "$signal_fifo" > "$client_stdout" 2> "$client_stderr" &
signal_client_pid=$!
node -e '
  const fs = require("node:fs");
  const goPath = process.argv[1];
  const total = Number(process.argv[2]);
  const chunk = Buffer.alloc(4096, 120);
  let sent = 0;
  function pump() {
    if (!fs.existsSync(goPath)) {
      setTimeout(pump, 5);
      return;
    }
    if (sent >= total) return;
    process.stdout.write(chunk);
    sent += chunk.length;
    setTimeout(pump, 5);
  }
  pump();
' "$signal_go" "$signal_total_bytes" > "$signal_fifo" &
signal_producer_pid=$!

signal_ready_wait=0
while [ ! -s "$signal_ready" ] && [ "$signal_ready_wait" -lt 300 ]; do
  kill -0 "$signal_client_pid" 2>/dev/null || break
  sleep 0.01
  signal_ready_wait=$((signal_ready_wait + 1))
done
if [ ! -s "$signal_ready" ]; then
  kill -TERM "$signal_client_pid" "$signal_producer_pid" 2>/dev/null || true
  wait "$signal_client_pid" >/dev/null 2>&1 || true
  wait "$signal_producer_pid" >/dev/null 2>&1 || true
  signal_client_pid=''
  signal_producer_pid=''
  fail "host signal probe did not become ready: $(sed -n '1,3p' "$client_stderr")"
fi
: > "$signal_go"
sleep 0.02
kill -TERM "$signal_client_pid" 2>/dev/null \
  || fail 'could not signal the running host-exec client'

set +e
wait "$signal_producer_pid"
signal_producer_status=$?
signal_producer_pid=''
wait "$signal_client_pid"
signal_client_status=$?
signal_client_pid=''
set -e
[ "$signal_producer_status" -eq 0 ] \
  || fail "signal stdin producer returned $signal_producer_status"
[ "$signal_client_status" -eq 0 ] \
  || fail "signal-aware client returned $signal_client_status: $(sed -n '1,4p' "$client_stderr")"
[ "$(sed -n '1p' "$client_stdout")" = "$signal_total_bytes:1" ] \
  || fail "signal/input frames were not serialized intact: $(sed -n '1,3p' "$client_stdout")"
pass 'client serializes a signal with throttled stdin without corrupting frames'

set +e
printf 'restrictive-umask-data' \
  | (
      CDPATH= cd -- "$workspace" \
        && umask 0777 \
        && HOST_EXEC_TEST_DIR="$session_dir" \
          /bin/bash -c "$client_source" host-exec node -e '
            let input = "";
            process.stdin.on("data", (chunk) => { input += chunk; });
            process.stdin.on("end", () => process.stdout.write(input));
          '
    ) > "$client_stdout" 2> "$client_stderr"
umask_client_status=$?
set -e
[ "$umask_client_status" -eq 0 ] \
  || fail "restrictive-umask client returned $umask_client_status: $(sed -n '1,3p' "$client_stderr")"
[ "$(sed -n '1p' "$client_stdout")" = 'restrictive-umask-data' ] \
  || fail 'a restrictive caller umask prevented the protocol lock from working'
pass 'client fixes private lock permissions independently of caller umask'

# If the host exits without consuming stdin, the sender can be blocked inside
# dd while the FIFO writer remains open. Cleanup must terminate the sender's
# complete process group within its deadline instead of waiting for caller EOF.
blocked_fifo="$test_root/blocked-input.fifo"
mkfifo "$blocked_fifo" || fail 'could not create the blocked-cleanup FIFO'
(
  CDPATH= cd -- "$workspace" || exit 1
  export HOST_EXEC_TEST_DIR="$session_dir"
  exec /bin/bash -c "$client_source" host-exec node -e 'process.exit(0)'
) < "$blocked_fifo" > "$client_stdout" 2> "$client_stderr" &
signal_client_pid=$!
(exec sleep 5) > "$blocked_fifo" &
signal_producer_pid=$!

blocked_wait=0
while [ "$blocked_wait" -lt 200 ]; do
  blocked_state=$(
    ps -o stat= -p "$signal_client_pid" 2>/dev/null \
      | tr -d '[:space:]' \
      || true
  )
  case "$blocked_state" in
    ''|Z*) break ;;
  esac
  sleep 0.01
  blocked_wait=$((blocked_wait + 1))
done
if [ "$blocked_wait" -ge 200 ]; then
  kill -TERM "$signal_producer_pid" 2>/dev/null || true
  wait "$signal_producer_pid" >/dev/null 2>&1 || true
  signal_producer_pid=''
  kill -KILL "$signal_client_pid" 2>/dev/null || true
  wait "$signal_client_pid" >/dev/null 2>&1 || true
  signal_client_pid=''
  fail 'client cleanup waited indefinitely for blocked caller stdin'
fi
set +e
wait "$signal_client_pid"
blocked_client_status=$?
signal_client_pid=''
kill -TERM "$signal_producer_pid" 2>/dev/null || true
wait "$signal_producer_pid" >/dev/null 2>&1 || true
signal_producer_pid=''
set -e
[ "$blocked_client_status" -eq 0 ] \
  || fail "blocked-stdin cleanup returned $blocked_client_status: $(sed -n '1,3p' "$client_stderr")"
pass 'client bounds cleanup when the host exits before caller stdin closes'

# Basename invocation with no argv exercises Bash 3.2 + nounset empty-array
# behavior. Empty non-TTY stdin makes `node` exit without entering a REPL.
set +e
( CDPATH= cd -- "$workspace" \
    && HOST_EXEC_TEST_DIR="$session_dir" \
      /bin/bash -c "$client_source" node ) \
  < /dev/null > "$client_stdout" 2> "$client_stderr"
zero_argv_status=$?
set -e
[ "$zero_argv_status" -eq 0 ] \
  || fail "basename/zero-argv invocation returned $zero_argv_status: $(sed -n '1,3p' "$client_stderr")"
[ ! -s "$client_stdout" ] && [ ! -s "$client_stderr" ] \
  || fail 'basename/zero-argv invocation produced unexpected output'
pass 'command basename invocation supports zero argv under macOS Bash'

set +e
( CDPATH= cd -- "$workspace" \
    && HOST_EXEC_TEST_DIR="$session_dir" \
      /bin/bash -c "$client_source" host-exec \
        git config --global --get agentContainer.testMarker ) \
  < /dev/null > "$client_stdout" 2> "$client_stderr"
git_config_status=$?
set -e
[ "$git_config_status" -eq 0 ] \
  || fail "host Git config lookup returned $git_config_status: $(sed -n '1,3p' "$client_stderr")"
[ "$(sed -n '1p' "$client_stdout")" = 'isolated-real-home' ] \
  || fail "host Git did not read the isolated real-home config: $(sed -n '1,3p' "$client_stderr")"
pass 'host Git reads the broker-selected real HOME configuration'

set +e
( CDPATH= cd -- "$workspace" \
    && HOST_EXEC_TEST_DIR="$session_dir" \
      /bin/bash -c "$client_source" host-exec \
        git hash-object "$broker_real_home/.ssh/id_ed25519" ) \
  < /dev/null > "$client_stdout" 2> "$client_stderr"
private_key_status=$?
set -e
[ "$private_key_status" -ne 0 ] && [ ! -s "$client_stdout" ] \
  || fail 'host Git unexpectedly read SSH private-key material'
pass 'host Git cannot read an SSH private key outside admitted metadata paths'

( CDPATH= cd -- "$workspace" \
    && HOST_EXEC_TEST_DIR="$session_dir" \
      /bin/bash -c "$client_source" host-exec \
        python3 -c 'import os; print(os.environ["HOME"])' ) \
  < /dev/null > "$client_stdout" 2> "$client_stderr"
[ "$(sed -n '1p' "$client_stdout")" = "$exec_home" ] \
  || fail "host Python did not receive the isolated execution HOME: $(sed -n '1,3p' "$client_stderr")"
pass 'stock host Python runs from the selected developer runtime with isolated HOME'

printf '%s\n' "$wrong_token" > "$session_dir/host-exec-token"
set +e
( CDPATH= cd -- "$workspace" \
    && HOST_EXEC_TEST_DIR="$session_dir" \
      /bin/bash -c "$client_source" host-exec node --version ) \
  < /dev/null > "$client_stdout" 2> "$client_stderr"
bad_token_status=$?
set -e
printf '%s\n' "$token" > "$session_dir/host-exec-token"
[ "$bad_token_status" -eq 125 ] \
  || fail "bad token returned $bad_token_status instead of protocol status 125"
grep -Fq 'AUTH_FAILED' "$client_stderr" \
  || fail "bad token did not produce AUTH_FAILED: $(sed -n '1,3p' "$client_stderr")"
pass 'incorrect session token is rejected'

# A fatal authentication result must make the connection terminal. A malicious
# half-open client must not be able to submit a valid request afterward, and the
# broker must actively destroy the connection instead of leaving a slot pinned.
protocol_bypass_marker="$workspace/protocol-bypass-marker"
protocol_probe_stderr="$test_root/protocol-probe.stderr"
set +e
node - "$endpoint" "$wrong_token" "$token" "$workspace" "$protocol_bypass_marker" \
  > /dev/null 2> "$protocol_probe_stderr" <<'NODE'
const fs = require('node:fs');
const net = require('node:net');

const [endpoint, wrongToken, token, cwd, marker] = process.argv.slice(2);
const separator = endpoint.lastIndexOf(':');
const host = endpoint.slice(0, separator);
const port = Number(endpoint.slice(separator + 1));
const baseRequest = {
  v: 1,
  type: 'run',
  command: 'node',
  cwd,
  argv: [
    '-e',
    'require("node:fs").writeFileSync(process.argv[1], "unexpected")',
    marker,
  ],
  env: {},
  stdin: false,
};
const invalidRequest = { ...baseRequest, token: wrongToken };
const validRequest = { ...baseRequest, token };
const heldSockets = [];

function openRejectedConnection(sendSameConnectionFollowup) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host, port, allowHalfOpen: true });
    heldSockets.push(socket);
    let response = '';
    let settled = false;

    socket.once('connect', () => {
      socket.write(`${JSON.stringify(invalidRequest)}\n`);
    });
    socket.on('data', (chunk) => {
      response += chunk.toString('utf8');
      if (settled || !response.includes('"code":"AUTH_FAILED"')) return;
      settled = true;
      if (sendSameConnectionFollowup) {
        socket.write(`${JSON.stringify(validRequest)}\n`);
      }
      resolve();
    });
    socket.on('error', (error) => {
      if (!settled) reject(error);
    });
    socket.on('close', () => {
      if (!settled) reject(new Error(`rejected connection closed without AUTH_FAILED: ${response}`));
    });
  });
}

function runFreshConnection() {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host, port });
    const request = {
      ...baseRequest,
      token,
      argv: ['-e', 'process.exit(0)'],
    };
    let buffer = '';
    let settled = false;

    function finish(error) {
      if (settled) return;
      settled = true;
      socket.destroy();
      if (error) reject(error);
      else resolve();
    }

    socket.once('connect', () => {
      socket.write(`${JSON.stringify(request)}\n`);
    });
    socket.on('data', (chunk) => {
      buffer += chunk.toString('utf8');
      while (buffer.includes('\n')) {
        const newline = buffer.indexOf('\n');
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        let frame;
        try {
          frame = JSON.parse(line);
        } catch {
          finish(new Error(`fresh connection received invalid JSON: ${line}`));
          return;
        }
        if (frame.type === 'error') {
          finish(new Error(`fresh connection was rejected: ${frame.code}`));
          return;
        }
        if (frame.type === 'exit') {
          finish(frame.status === 0 ? undefined : new Error(`fresh command exited ${frame.status}`));
          return;
        }
      }
    });
    socket.on('error', finish);
    socket.on('close', () => {
      if (!settled) finish(new Error('fresh connection closed before command exit'));
    });
  });
}

async function probe() {
  // Fill the advertised connection limit with peers that never close their
  // writable half. A correctly terminal broker releases each server-side slot.
  for (let index = 0; index < 32; index += 1) {
    await openRejectedConnection(index === 0);
  }
  await new Promise((resolve) => setTimeout(resolve, 400));
  if (fs.existsSync(marker)) {
    throw new Error('the same connection executed a request after AUTH_FAILED');
  }
  await runFreshConnection();
}

let timeoutHandle;
const timeout = new Promise((_, reject) => {
  timeoutHandle = setTimeout(() => reject(new Error('terminal protocol probe timed out')), 8000);
});

Promise.race([probe(), timeout])
  .catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  })
  .finally(() => {
    clearTimeout(timeoutHandle);
    for (const socket of heldSockets) socket.destroy();
  });
NODE
protocol_probe_status=$?
set -e
[ "$protocol_probe_status" -eq 0 ] \
  || fail "terminal protocol probe failed: $(sed -n '1,3p' "$protocol_probe_stderr")"
[ ! -e "$protocol_bypass_marker" ] \
  || fail 'a valid request executed after the connection had failed authentication'
pass 'fatal authentication rejects connection reuse and releases half-open slots'

set +e
( CDPATH= cd -- "$workspace" \
    && HOST_EXEC_TEST_DIR="$session_dir" \
      /bin/bash -c "$client_source" host-exec not-authorized --version ) \
  < /dev/null > "$client_stdout" 2> "$client_stderr"
unauthorized_status=$?
set -e
[ "$unauthorized_status" -eq 125 ] \
  || fail "unauthorized command returned $unauthorized_status instead of 125"
grep -Fq 'COMMAND_DENIED' "$client_stderr" \
  || fail "unauthorized command did not produce COMMAND_DENIED: $(sed -n '1,3p' "$client_stderr")"
pass 'command absent from the session manifest is rejected'

[ -w "$read_only_root" ] \
  || fail 'read-only test root is not writable outside sandbox-exec'
set +e
(
  CDPATH= cd -- "$read_only_root" \
    && HOST_EXEC_TEST_DIR="$session_dir" \
      /bin/bash -c "$client_source" host-exec node -e '
        const fs = require("node:fs");
        try {
          fs.writeFileSync("sandbox-must-deny", "unexpected");
          process.stdout.write("WRITE_SUCCEEDED");
          process.exit(99);
        } catch (error) {
          process.stdout.write(`DENIED:${error.code}`);
        }
      ' < /dev/null
) > "$client_stdout" 2> "$client_stderr"
read_only_status=$?
set -e
[ "$read_only_status" -eq 0 ] \
  || fail "read-only sandbox probe returned $read_only_status: $(sed -n '1,3p' "$client_stderr")"
[ "$(sed -n '1p' "$client_stdout")" = 'DENIED:EPERM' ] \
  || fail "read-only sandbox probe was not denied: $(sed -n '1,3p' "$client_stdout")"
[ ! -e "$read_only_root/sandbox-must-deny" ] \
  || fail 'sandbox created a file inside a declared read-only root'
pass 'sandbox-exec denies writes beneath a declared read-only root'

( CDPATH= cd -- "$workspace" \
    && HOST_EXEC_TEST_DIR="$session_dir" \
      /bin/bash -c "$client_source" host-exec node -e '
        const fs = require("node:fs");
        try {
          fs.readFileSync(process.argv[1], "utf8");
          process.stdout.write("READ_SUCCEEDED");
          process.exit(99);
        } catch (error) {
          process.stdout.write(`DENIED:${error.code}`);
        }
      ' "$unshared_root/secret" < /dev/null ) \
  > "$client_stdout" 2> "$client_stderr"
[ "$(sed -n '1p' "$client_stdout")" = 'DENIED:EPERM' ] \
  || fail "sandbox read outside declared roots was not denied: $(sed -n '1,3p' "$client_stdout")"
pass 'sandbox-exec denies reads outside every declared root'

printf '1..%s\n' "$tests_passed"
