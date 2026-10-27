#!/bin/bash
set -euo pipefail

# Portable (macOS and Linux) integration test for full host access: the
# broker's `--access full` mode, the real guest client, and the authenticated
# loopback tunnel. It needs only node, jq, and the tools the guest client
# itself requires, and it never invokes sandbox-exec or the Apple container
# runtime. A stand-in sandbox program is used only to prove that the default
# sandboxed mode still behaves exactly as before.
#
# Everything is bash 3.2 compatible because macOS still ships /bin/bash 3.2.

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
broker_script="$repo_root/runtime/host-exec-broker.mjs"
client_script="$repo_root/runtime/host-exec-client"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

tests_passed=0
pass() {
  tests_passed=$((tests_passed + 1))
  printf 'ok %s - %s\n' "$tests_passed" "$*"
}

for required in node jq base64 dd tr sed od head sleep mktemp find ps perl; do
  command -v "$required" >/dev/null 2>&1 \
    || fail "required command is unavailable: $required"
done
[ -f "$broker_script" ] && [ -f "$client_script" ] \
  || fail 'broker or client script is missing'

tmp_base=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
test_root=''
broker_pid=''
sandbox_broker_pid=''
launcher_pid=''
helper_pid=''
extra_pids=''

cleanup() {
  local cleanup_status=$?
  local pid
  trap - EXIT INT TERM HUP
  for pid in $broker_pid $sandbox_broker_pid $helper_pid $extra_pids $launcher_pid; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in $broker_pid $sandbox_broker_pid $helper_pid $launcher_pid; do
    wait "$pid" 2>/dev/null || true
  done
  # Delete only the exact directory created below.
  case "$test_root" in
    "$tmp_base"/agent-container-host-full-test.*)
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

test_root=$(mktemp -d "$tmp_base/agent-container-host-full-test.XXXXXX") \
  || fail 'could not create the test directory'
case "$test_root" in
  "$tmp_base"/agent-container-host-full-test.*) ;;
  *) fail "mktemp returned an unsafe path: $test_root" ;;
esac

session_dir="$test_root/session"
guest_dir="$test_root/guest"
real_home="$test_root/real-home"
bin_dir="$test_root/host-bin"
outside_dir="$test_root/outside"
mkdir -m 0700 "$session_dir" "$guest_dir" "$real_home" "$bin_dir" "$outside_dir"
real_home=$(CDPATH= cd -- "$real_home" && pwd -P)
outside_dir=$(CDPATH= cd -- "$outside_dir" && pwd -P)

wait_until() {
  # wait_until SECONDS COMMAND...: poll every 50 ms.
  local limit=$(( $1 * 20 )) attempt=0
  shift
  while [ "$attempt" -lt "$limit" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
    attempt=$((attempt + 1))
  done
  return 1
}

file_is_nonempty() { [ -s "$1" ]; }
# kill -0 succeeds for a zombie, and a process reparented to a PID 1 that does
# not reap leaves one behind, so read the process state instead.
pid_is_alive() {
  local state
  state=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  case "$state" in
    ''|Z*) return 1 ;;
  esac
  return 0
}
pid_is_gone() { ! pid_is_alive "$1"; }

# --- Fake host commands ----------------------------------------------------

cat > "$bin_dir/hello" <<'EOF'
#!/bin/sh
printf 'hello:'
for argument in "$@"; do printf '[%s]' "$argument"; done
printf '\n'
EOF
cat > "$bin_dir/exitcode" <<'EOF'
#!/bin/sh
exit "${1:-0}"
EOF
cat > "$bin_dir/whereami" <<'EOF'
#!/bin/sh
pwd -P
EOF
# Leaves a service behind that has detached from every pipe.
cat > "$bin_dir/startdaemon" <<'EOF'
#!/bin/sh
sleep 60 </dev/null >/dev/null 2>&1 &
echo "$!" > "$1"
echo started
EOF
# Leaves a background process that still holds this command's stdout open.
cat > "$bin_dir/holdpipe" <<'EOF'
#!/bin/sh
sleep 60 &
echo "$!" > "$1"
echo leader-done
EOF
cat > "$bin_dir/pidsleep" <<'EOF'
#!/bin/sh
echo "$$" > "$1"
exec sleep 60
EOF
cat > "$bin_dir/bigout" <<'EOF'
#!/bin/sh
head -c "${1:-1000000}" /dev/zero | tr '\0' 'x'
EOF
cat > "$bin_dir/loudexit" <<'EOF'
#!/bin/sh
# Large output immediately followed by exit: the drain window must not cut it.
head -c 2000000 /dev/zero | tr '\0' 'y'
exit 3
EOF
# Writes to a NON-BLOCKING stdout until the whole path to a stalled consumer is
# full, records how many bytes it got out, and exits while they are still
# queued. That is exactly the moment the broker's drain window must not treat
# the paused pipe as quiet.
cat > "$bin_dir/fillpipe" <<'EOF'
#!/usr/bin/perl
use strict;
use warnings;
use Fcntl;
use Time::HiRes qw(time sleep);
my ($count_file) = @ARGV;
my $flags = fcntl(STDOUT, F_GETFL, 0) or die "F_GETFL: $!";
fcntl(STDOUT, F_SETFL, $flags | O_NONBLOCK) or die "F_SETFL: $!";
my $chunk = ('p' x 1023) . "\n";
# Fill as fast as the path allows. The path is "stalled" once nothing at all
# has been accepted for 1.5 s; the hard deadline keeps a misbehaving consumer
# from ever hanging the test.
my ($total, $last_progress, $deadline) = (0, time, time + 30);
while ($total < 100_000_000 && time < $deadline) {
  my $written = syswrite(STDOUT, $chunk);
  if (defined $written) {
    $total += $written;
    $last_progress = time;
    next;
  }
  die "write: $!" unless $!{EAGAIN} || $!{EWOULDBLOCK};
  last if time - $last_progress >= 1.5;
  sleep(0.005);
}
open(my $out, '>', $count_file) or die "open: $!";
print $out "$total\n";
close($out);
exit 0;
EOF
chmod 0755 "$bin_dir"/*

node_executable=$(node -p 'process.execPath')
node_bin_dir=$(dirname -- "$node_executable")
node_bin_dir=$(CDPATH= cd -- "$node_bin_dir" && pwd -P)

# --- Loopback echo servers for the tunnel tests ---------------------------

ports_file="$test_root/echo-ports"
# Three loopback services plus four reserved free ports: an echo service on
# the allowlist, an echo service off it, a "burst" service that writes one
# large response and closes immediately (the shape that exposes a relay which
# destroys its peer on a clean close), and free ports for the guest forwarder
# to listen on. On one machine the forwarder cannot share the services' port
# numbers, so the tests use its LISTEN:TARGET form.
burst_bytes=3145728
cat > "$test_root/echo-servers.mjs" <<'EOF'
import net from 'node:net';
import { writeFileSync } from 'node:fs';
const burstBytes = Number(process.argv[3]);
const listen = (server) => new Promise((resolve) => {
  server.listen(0, '127.0.0.1', () => resolve(server.address().port));
});
const echo = () => listen(net.createServer({ allowHalfOpen: true }, (socket) => {
  socket.on('error', () => {});
  socket.pipe(socket);
}));
const burst = () => listen(net.createServer((socket) => {
  socket.on('error', () => {});
  socket.end(Buffer.alloc(burstBytes, 0x62));
}));
const reserve = async () => {
  const server = net.createServer();
  const port = await listen(server);
  await new Promise((resolve) => server.close(resolve));
  return port;
};
const allowed = await echo();
const denied = await echo();
const burstPort = await burst();
const free = [];
for (let index = 0; index < 4; index += 1) free.push(await reserve());
writeFileSync(process.argv[2], `${allowed} ${denied} ${burstPort} ${free.join(' ')}\n`);
setInterval(() => {}, 1000);
EOF
node "$test_root/echo-servers.mjs" "$ports_file" "$burst_bytes" &
helper_pid=$!
wait_until 10 file_is_nonempty "$ports_file" || fail 'loopback services did not start'
read -r echo_allowed_port echo_denied_port burst_port \
  forward_echo_port forward_burst_port forward_unbound_port forward_badtoken_port \
  < "$ports_file"

# --- Start the full-access broker -----------------------------------------

head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$session_dir/host-exec-token"
printf '\n' >> "$session_dir/host-exec-token"
session_token=$(sed -n '1p' "$session_dir/host-exec-token")
printf '{"v":1,"pathDirectories":["%s","%s","/usr/bin","/bin"],"deny":["sudo"],"first":["hello"]}\n' \
  "$bin_dir" "$node_bin_dir" > "$session_dir/host-catalog.json"

sleep 600 &
launcher_pid=$!

broker_out="$test_root/broker.out"
broker_err="$test_root/broker.err"
(
  # The broker's inherited environment is the "terminal environment" that
  # host commands see. AGENT_CONTAINER_* must be stripped; the rest is kept.
  export ANDROID_HOME=/opt/test-android
  export AGENT_CONTAINER_PRIVATE=must-not-leak
  export SSH_AUTH_SOCK=/tmp/test-agent.sock
  exec node "$broker_script" \
    --access full \
    --session-dir "$session_dir" \
    --bind-address 127.0.0.1 \
    --launcher-pid "$launcher_pid" \
    --real-home "$real_home" \
    --tunnel-ports "$echo_allowed_port,$burst_port"
) > "$broker_out" 2> "$broker_err" &
broker_pid=$!
wait_until 15 file_is_nonempty "$session_dir/host-exec-endpoint" \
  || fail "the full-access broker did not publish an endpoint: $(cat "$broker_err")"
endpoint=$(sed -n '1p' "$session_dir/host-exec-endpoint")
broker_host=${endpoint%:*}
broker_port=${endpoint##*:}
tunnel_port=$(jq -r '.tunnelPort' "$broker_out")
[ "$(jq -r '.access' "$broker_out")" = full ] \
  || fail "the readiness line does not report full access: $(cat "$broker_out")"
[ "$tunnel_port" -gt 0 ] || fail 'the broker did not publish a tunnel port'
grep -Fq 'FULL HOST ACCESS' "$broker_err" \
  || fail 'the broker did not announce full access on stderr'
pass 'the broker starts in full-access mode and announces it'

cp "$session_dir/host-exec-endpoint" "$session_dir/host-exec-token" "$guest_dir/"
printf 'full\n' > "$guest_dir/host-exec-mode"

# A realistic guest has a small environment; the client is run under one.
guest_run() {
  env -i PATH="$PATH" HOME=/guest/home TERM=xterm \
    AGENT_HOST_EXEC_DIR="$guest_dir" "$@"
}
client() { guest_run bash "$client_script" "$@"; }

# Raw protocol access for checks the client cannot express. The decoded
# stdout goes to the caller's stdout; the status and decoded stderr are left in
# files because callers usually capture stdout in a command substitution,
# which would hide a shell variable set here.
raw_stderr="$test_root/raw.stderr"
raw_status_file="$test_root/raw.status"
raw_run() {
  local request=$1 line frame_type
  exec 8<>"/dev/tcp/$broker_host/$broker_port" \
    || fail 'could not connect to the broker'
  printf '%s\n' "$request" >&8
  : > "$raw_stderr"
  : > "$raw_status_file"
  while IFS= read -r line <&8; do
    frame_type=$(printf '%s' "$line" | jq -r '.type')
    case "$frame_type" in
      stdout) printf '%s' "$line" | jq -r '.data' | base64 -d ;;
      stderr) printf '%s' "$line" | jq -r '.data' | base64 -d >> "$raw_stderr" ;;
      exit) printf '%s\n' "$(printf '%s' "$line" | jq -r '.status')" > "$raw_status_file"; break ;;
      error) printf 'error:%s\n' "$(printf '%s' "$line" | jq -r '.code')" > "$raw_status_file"; break ;;
    esac
  done
  exec 8>&- 8<&-
}
raw_status() { sed -n '1p' "$raw_status_file"; }
run_request() {
  # run_request COMMAND CWD [ENV_JSON] [ARGV_JSON]
  local env_json=${3-} argv_json=${4-}
  [ -n "$env_json" ] || env_json='{}'
  [ -n "$argv_json" ] || argv_json='[]'
  jq -cn --arg token "$session_token" --arg command "$1" --arg cwd "$2" \
    --argjson env "$env_json" --argjson argv "$argv_json" \
    '{v:1,type:"run",token:$token,command:$command,cwd:$cwd,argv:$argv,env:$env,stdin:false}'
}
zero_token=$(printf '%064d' 0)

# --- Catalog ---------------------------------------------------------------

exec 8<>"/dev/tcp/$broker_host/$broker_port"
printf '{"v":1,"type":"catalog","token":"%s"}\n' "$session_token" >&8
IFS= read -r catalog_line <&8
exec 8>&- 8<&-
[ "$(printf '%s' "$catalog_line" | jq -r '.access')" = full ] \
  || fail 'the catalog does not report full access'
[ "$(printf '%s' "$catalog_line" | jq -r '.tunnel.port')" = "$tunnel_port" ] \
  || fail 'the catalog does not report the tunnel port'
[ "$(printf '%s' "$catalog_line" | jq -c '.tunnel.ports')" = "[$echo_allowed_port,$burst_port]" ] \
  || fail 'the catalog does not report the tunnel port allowlist'
[ "$(printf '%s' "$catalog_line" | jq -r '.commands[] | select(.name == "hello") | .mode')" = first ] \
  || fail 'a host-first command is not marked first'
[ "$(printf '%s' "$catalog_line" | jq -r '.commands[] | select(.name == "whereami") | .mode')" = fallback ] \
  || fail 'an ordinary command is not marked fallback'
[ -z "$(printf '%s' "$catalog_line" | jq -r '.commands[] | select(.name == "sudo") | .name')" ] \
  || fail 'a denied command appears in the catalog'
pass 'the catalog reports access, tunnel, modes, and omits denied commands'

# --- Execution -------------------------------------------------------------

output=$(client hello 'two words' '' "\$dollar" 2>&1) || fail "hello failed: $output"
[ "$output" = 'hello:[two words][][$dollar]' ] || fail "arguments were not preserved: $output"
pass 'arguments reach the host command exactly'

status=0
client exitcode 7 >/dev/null 2>&1 || status=$?
[ "$status" -eq 7 ] || fail "exit status was not propagated: $status"
pass 'the host exit status is propagated'

output=$(guest_run bash "$client_script" printenv HOME 2>&1)
[ "$output" = "$real_home" ] || fail "host command did not receive the real HOME: $output"
pass 'host commands run with the real HOME, not the guest HOME'

output=$(guest_run bash "$client_script" printenv ANDROID_HOME 2>&1)
[ "$output" = /opt/test-android ] || fail "launcher environment was not inherited: $output"
status=0
guest_run bash "$client_script" printenv AGENT_CONTAINER_PRIVATE >/dev/null 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "launcher-internal variable leaked to a host command (status $status)"
output=$(guest_run bash "$client_script" printenv AGENT_HOST_ACCESS 2>&1)
[ "$output" = full ] || fail "host commands are not told about full access: $output"
pass 'host commands inherit the launcher environment minus launcher-internal names'

output=$(env -i PATH="$PATH" HOME=/guest/home TERM=xterm AGENT_HOST_EXEC_DIR="$guest_dir" \
  DEPLOY_PASSWORD=hunter2 ANDROID_SERIAL=emulator-5554 \
  bash "$client_script" printenv DEPLOY_PASSWORD 2>&1)
[ "$output" = hunter2 ] || fail "a secret-looking guest variable was not forwarded: $output"
output=$(env -i PATH="$PATH" HOME=/guest/home TERM=xterm AGENT_HOST_EXEC_DIR="$guest_dir" \
  ANDROID_SERIAL=emulator-5554 bash "$client_script" printenv ANDROID_SERIAL 2>&1)
[ "$output" = emulator-5554 ] || fail "an ordinary guest variable was not forwarded: $output"
host_path=$(guest_run bash "$client_script" printenv PATH 2>&1)
guest_path_probe=$(env -i PATH="$PATH" HOME=/guest/home TERM=xterm AGENT_HOST_EXEC_DIR="$guest_dir" \
  GIT_CONFIG_GLOBAL=/run/agent-host/gitconfig COREPACK_HOME=/usr/local/lib/agent-corepack \
  PNPM_CONFIG_STORE_DIR=/var/lib/agent-container/pnpm/store AGENT_FOO=1 \
  bash "$client_script" sh -c 'printf "%s|%s|%s|%s" "${GIT_CONFIG_GLOBAL-unset}" "${COREPACK_HOME-unset}" "${PNPM_CONFIG_STORE_DIR-unset}" "${AGENT_FOO-unset}"' 2>&1)
[ "$guest_path_probe" = 'unset|unset|unset|unset' ] \
  || fail "guest-image variables crossed the VM boundary: $guest_path_probe"
[ -n "$host_path" ] || fail 'host PATH is empty'
pass 'secret-looking guest variables forward; guest identity and image variables do not'

# The broker applies the same policy even if a client does not.
env_probe='printf "%s\n" "$HOME" "${AGENT_X-unset}" "${LD_PRELOAD-unset}" "${KEEP_ME-unset}" "$SSH_AUTH_SOCK" "$PATH"'
probe_argv=$(jq -cn --arg probe "$env_probe" '["-c", $probe]')
output=$(raw_run "$(run_request sh "$outside_dir" \
  '{"HOME":"/evil","PATH":"/evil","SSH_AUTH_SOCK":"/evil","AGENT_X":"1","LD_PRELOAD":"/evil","KEEP_ME":"yes"}' \
  "$probe_argv")")
expected_probe=$(printf '%s\n' "$real_home" unset unset yes /tmp/test-agent.sock "$PATH")
[ "$(raw_status)" = 0 ] || fail "the reserved-variable probe failed: $(raw_status)"
[ "$output" = "$expected_probe" ] \
  || fail "reserved variables were not dropped by the broker:
$output"
pass 'the broker drops reserved guest variables instead of trusting the client'

output=$(raw_run "$(run_request node "$outside_dir" '{}' '["-p","process.argv0"]')")
[ "$output" = node ] || fail "argv[0] is not the command name: $output"
pass 'argv[0] is the name the guest typed'

# --- Working directory -----------------------------------------------------

output=$(cd "$outside_dir" && client whereami 2>&1)
[ "$output" = "$outside_dir" ] || fail "an arbitrary host directory was not honoured: $output"
pass 'any host directory is a valid working directory (no execution roots)'

output=$(raw_run "$(run_request whereami "/host$outside_dir")")
[ "$output" = "$outside_dir" ] || fail "the /host prefix was not mapped to the host path: $output"
pass 'a cwd below the guest /host mount maps back to the host path'

output=$(raw_run "$(run_request whereami /definitely/guest/only/directory)")
[ "$output" = "$real_home" ] && [ "$(raw_status)" = 0 ] \
  || fail "a guest-only cwd did not fall back to the real HOME: out=$output status=$(raw_status)"
grep -Fq 'does not exist on the macOS host' "$raw_stderr" \
  || fail 'the guest-only cwd fallback was silent'
pass 'a guest-only cwd falls back to HOME and says so on stderr'

# --- Streaming -------------------------------------------------------------

output=$(printf 'streamed-input' | client cat 2>&1)
[ "$output" = streamed-input ] || fail "stdin was not streamed: $output"
size=$(head -c 300000 /dev/zero | client cat 2>/dev/null | wc -c | tr -d ' ')
[ "$size" = 300000 ] || fail "300000 bytes of stdin came back as $size"
pass 'stdin streams to the host command and back'

# `head` exits while the guest is still streaming `yes` into it. Further stdin
# writes then fail with EPIPE, and the late stdin frames race the exit frame.
# Neither may crash the broker or cost the guest its output or exit status.
for attempt in 1 2 3; do
  result=$( { yes | client head -c 300000 2>/dev/null | wc -c | tr -d ' '; } 2>/dev/null
    echo "status=${PIPESTATUS[1]}")
  received=$(printf '%s\n' "$result" | sed -n '1p')
  client_status=$(printf '%s\n' "$result" | sed -n 's/^status=//p')
  [ "$received" = 300000 ] && [ "$client_status" = 0 ] \
    || fail "attempt $attempt: a command that stopped reading stdin early lost output or status: received=$received status=$client_status"
done
pid_is_alive "$broker_pid" || fail 'the broker died when a command stopped reading stdin early'
output=$(client hello still-serving 2>&1)
[ "$output" = 'hello:[still-serving]' ] \
  || fail "the broker stopped serving after an early stdin close: $output"
pass 'a command that stops reading stdin early keeps the broker and its output intact'

size=$(client bigout 3000000 2>/dev/null | wc -c | tr -d ' ')
[ "$size" = 3000000 ] || fail "3000000 bytes of stdout arrived as $size"
status=0
size=$(client loudexit 2>/dev/null | wc -c | tr -d ' ') || status=$?
[ "$size" = 2000000 ] || fail "output written just before exit was truncated to $size"
pass 'large output is delivered completely, including output written just before exit'

# The consumer stalls for four seconds while the host command fills every
# buffer between them and exits (about two seconds in). The drain window is
# 0.4 s, so a broker that treated a backpressured pipe as quiet would destroy
# it long before the consumer wakes and the byte counts would differ.
fill_countfile="$test_root/fillpipe.count"
received=$(client fillpipe "$fill_countfile" 2>/dev/null | { sleep 4; wc -c | tr -d ' '; }) \
  || fail 'the stalled-consumer pipeline failed'
written=$(sed -n '1p' "$fill_countfile")
[ "$written" -gt 100000 ] \
  || fail "the stall did not fill the path (only $written bytes were written)"
[ "$received" = "$written" ] \
  || fail "output queued behind a stalled consumer was truncated: wrote $written, received $received"
pass 'output queued behind a stalled consumer survives the drain window'

# --- Background services ---------------------------------------------------

daemon_pidfile="$test_root/daemon.pid"
started_at=$(date +%s)
output=$(client startdaemon "$daemon_pidfile" 2>&1)
elapsed=$(( $(date +%s) - started_at ))
[ "$output" = started ] || fail "startdaemon output was unexpected: $output"
[ "$elapsed" -le 5 ] || fail "starting a detached service took ${elapsed}s"
daemon_pid=$(sed -n '1p' "$daemon_pidfile")
extra_pids="$extra_pids $daemon_pid"
sleep 1.5
pid_is_alive "$daemon_pid" \
  || fail 'a service started by a finished host command was killed with it'
kill "$daemon_pid" 2>/dev/null || true
pass 'a service started by a finished command keeps running'

hold_pidfile="$test_root/hold.pid"
started_at=$(date +%s)
output=$(client holdpipe "$hold_pidfile" 2>&1)
elapsed=$(( $(date +%s) - started_at ))
[ "$output" = leader-done ] || fail "holdpipe output was unexpected: $output"
[ "$elapsed" -le 6 ] \
  || fail "a background process holding stdout hung the client for ${elapsed}s"
hold_pid=$(sed -n '1p' "$hold_pidfile")
extra_pids="$extra_pids $hold_pid"
kill "$hold_pid" 2>/dev/null || true
pass 'a background process that holds the output pipe does not hang the guest'

stop_pidfile="$test_root/stop.pid"
# exec so $! is the guest client itself, not a wrapper subshell.
( exec env -i PATH="$PATH" HOME=/guest/home TERM=xterm \
    AGENT_HOST_EXEC_DIR="$guest_dir" bash "$client_script" pidsleep "$stop_pidfile" ) \
  >/dev/null 2>&1 &
client_pid=$!
wait_until 10 file_is_nonempty "$stop_pidfile" || fail 'pidsleep did not start'
stop_pid=$(sed -n '1p' "$stop_pidfile")
extra_pids="$extra_pids $stop_pid"
kill -TERM "$client_pid"
wait "$client_pid" 2>/dev/null || true
wait_until 10 pid_is_gone "$stop_pid" \
  || fail 'terminating the guest client did not stop the running host command'
pass 'terminating the guest client stops a host command that is still running'

# --- Authentication and denial --------------------------------------------

raw_run "$(jq -cn --arg cwd "$outside_dir" --arg token "$zero_token" \
  '{v:1,type:"run",token:$token,command:"hello",cwd:$cwd,argv:[],env:{},stdin:false}')" >/dev/null
[ "$(raw_status)" = error:AUTH_FAILED ] || fail "a wrong token was not rejected: $(raw_status)"
raw_run "$(run_request sudo "$outside_dir")" >/dev/null
[ "$(raw_status)" = error:COMMAND_DENIED ] || fail "a denied command ran: $(raw_status)"
raw_run "$(run_request definitely-not-installed "$outside_dir")" >/dev/null
[ "$(raw_status)" = error:COMMAND_DENIED ] || fail "an unknown command ran: $(raw_status)"
raw_run "$(run_request ../../bin/sh "$outside_dir")" >/dev/null
[ "$(raw_status)" = error:INVALID_REQUEST ] || fail "a path-like command was not rejected: $(raw_status)"
pass 'wrong tokens, denied, unknown and path-like commands are rejected'

# --- Loopback tunnel -------------------------------------------------------

cat > "$test_root/tunnel-check.mjs" <<'EOF'
import net from 'node:net';

const host = process.env.T_HOST;
const tunnelPort = Number(process.env.T_PORT);
const token = process.env.T_TOKEN;
const allowed = Number(process.env.T_ALLOWED);
const denied = Number(process.env.T_DENIED);
const burst = Number(process.env.T_BURST);
const burstBytes = Number(process.env.T_BURST_BYTES);
const failures = [];

// A slow reader: authenticate, then do not read for a while. The service has
// long since written its whole response and closed by the time reading
// starts, so every byte must still be sitting in the relay's queues.
function slowRead(line, pauseMs) {
  return new Promise((resolve) => {
    const chunks = [];
    const socket = net.connect({ host, port: tunnelPort, allowHalfOpen: true });
    socket.on('error', () => {});
    socket.on('connect', () => {
      socket.write(Buffer.from(line, 'latin1'));
      socket.pause();
      setTimeout(() => {
        socket.on('data', (data) => chunks.push(data));
        socket.resume();
      }, pauseMs);
    });
    socket.on('close', () => resolve(Buffer.concat(chunks)));
    setTimeout(() => socket.destroy(), pauseMs + 20000);
  });
}

function attempt(line, payload, { halfClose = true, wait = 700 } = {}) {
  return new Promise((resolve) => {
    const chunks = [];
    const socket = net.connect({ host, port: tunnelPort, allowHalfOpen: true });
    socket.on('data', (data) => chunks.push(data));
    socket.on('error', () => {});
    socket.on('connect', () => {
      socket.write(Buffer.concat([Buffer.from(line, 'latin1'), payload]));
      if (halfClose) socket.end();
    });
    socket.on('close', () => resolve(Buffer.concat(chunks)));
    setTimeout(() => socket.destroy(), wait);
  });
}
function check(name, ok) {
  if (!ok) failures.push(name);
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`);
}

const binary = Buffer.from(Array.from({ length: 70000 }, (_, index) => (index * 37 + 11) & 0xff));
binary[100] = 0x0a;
const echoed = await attempt(`AGENT-CONTAINER-TUNNEL/1 ${token} ${allowed}\n`, binary, { wait: 3000 });
check('binary payload with embedded newlines round-trips', Buffer.compare(echoed, binary) === 0);

const noPayload = await attempt(`AGENT-CONTAINER-TUNNEL/1 ${token} ${allowed}\n`, Buffer.alloc(0));
check('an authenticated empty stream ends cleanly', noPayload.length === 0);

const wrongToken = await attempt(`AGENT-CONTAINER-TUNNEL/1 ${'0'.repeat(64)} ${allowed}\n`, Buffer.from('x'));
check('a wrong token receives nothing', wrongToken.length === 0);
const deniedPort = await attempt(`AGENT-CONTAINER-TUNNEL/1 ${token} ${denied}\n`, Buffer.from('x'));
check('a port outside the allowlist receives nothing', deniedPort.length === 0);
const garbage = await attempt('GET / HTTP/1.0\r\n\r\n', Buffer.alloc(0));
check('a non-tunnel protocol receives nothing', garbage.length === 0);
const longLine = await attempt(`${'A'.repeat(400)}\n`, Buffer.alloc(0));
check('an oversized first line receives nothing', longLine.length === 0);
const unterminated = await attempt('AGENT-CONTAINER-TUNNEL/1 ', Buffer.alloc(0), { halfClose: false, wait: 300 });
check('an unterminated line receives nothing', unterminated.length === 0);

const again = await attempt(`AGENT-CONTAINER-TUNNEL/1 ${token} ${allowed}\n`, Buffer.from('still-works'));
check('the listener keeps serving after rejected attempts', again.toString() === 'still-works');

// Several streams at once must stay independent.
const parallel = await Promise.all(Array.from({ length: 8 }, (_, index) =>
  attempt(`AGENT-CONTAINER-TUNNEL/1 ${token} ${allowed}\n`, Buffer.from(`stream-${index}`))));
check('parallel streams stay independent',
  parallel.every((data, index) => data.toString() === `stream-${index}`));

const burstReply = await slowRead(`AGENT-CONTAINER-TUNNEL/1 ${token} ${burst}\n`, 1500);
check(`a service's final burst before closing reaches a slow reader intact (${burstReply.length}/${burstBytes} bytes)`,
  burstReply.length === burstBytes && burstReply.every((byte) => byte === 0x62));

process.exit(failures.length === 0 ? 0 : 1);
EOF
tunnel_output=$(T_HOST="$broker_host" T_PORT="$tunnel_port" T_TOKEN="$session_token" \
  T_ALLOWED="$echo_allowed_port" T_DENIED="$echo_denied_port" \
  T_BURST="$burst_port" T_BURST_BYTES="$burst_bytes" \
  node "$test_root/tunnel-check.mjs" 2>&1) \
  || fail "the loopback tunnel checks failed:
$tunnel_output"
case "$tunnel_output" in *FAIL*) fail "the loopback tunnel checks failed:
$tunnel_output" ;; esac
pass 'the loopback tunnel relays binary streams and rejects everything unauthenticated'

# --- Guest forwarder (agent-host-tunnel) ----------------------------------

forwarder_script="$repo_root/runtime/agent-host-tunnel"
[ -f "$forwarder_script" ] || fail 'agent-host-tunnel is missing'
port_accepts() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
port_refuses() { ! port_accepts "$1"; }

# The forwarder is the guest side of the tunnel: it listens on the guest's
# loopback and speaks the authentication frame for the configured target port.
node "$forwarder_script" \
  --endpoint "$broker_host:$tunnel_port" --token "$session_token" \
  --ports "$forward_echo_port:$echo_allowed_port,$forward_burst_port:$burst_port" \
  > "$test_root/forwarder.out" 2> "$test_root/forwarder.err" &
forwarder_pid=$!
extra_pids="$extra_pids $forwarder_pid"
wait_until 10 port_accepts "$forward_echo_port" \
  || fail "the guest forwarder did not listen: $(cat "$test_root/forwarder.err")"
# A forwarder holding the wrong token must be turned away by the broker.
node "$forwarder_script" \
  --endpoint "$broker_host:$tunnel_port" --token "$zero_token" \
  --ports "$forward_badtoken_port:$echo_allowed_port" \
  > /dev/null 2>&1 &
badtoken_forwarder_pid=$!
extra_pids="$extra_pids $badtoken_forwarder_pid"
wait_until 10 port_accepts "$forward_badtoken_port" \
  || fail 'the wrong-token forwarder did not listen'

cat > "$test_root/forwarder-check.mjs" <<'EOF'
import net from 'node:net';

const echoPort = Number(process.env.F_ECHO);
const burstPort = Number(process.env.F_BURST);
const unboundPort = Number(process.env.F_UNBOUND);
const badTokenPort = Number(process.env.F_BADTOKEN);
const burstBytes = Number(process.env.F_BURST_BYTES);
const failures = [];
function check(name, ok) {
  if (!ok) failures.push(name);
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`);
}
function viaGuest(port, payload, { pauseMs = 0, halfClose = true, wait = 3000 } = {}) {
  return new Promise((resolve) => {
    const chunks = [];
    let refused = false;
    const socket = net.connect({ host: '127.0.0.1', port, allowHalfOpen: true });
    socket.on('error', (error) => { refused = error.code === 'ECONNREFUSED'; });
    socket.on('connect', () => {
      if (pauseMs > 0) socket.pause();
      if (payload.length > 0) socket.write(payload);
      if (halfClose) socket.end();
      if (pauseMs > 0) {
        setTimeout(() => {
          socket.on('data', (data) => chunks.push(data));
          socket.resume();
        }, pauseMs);
      } else {
        socket.on('data', (data) => chunks.push(data));
      }
    });
    socket.on('close', () => resolve({ data: Buffer.concat(chunks), refused }));
    setTimeout(() => socket.destroy(), wait + pauseMs);
  });
}

const binary = Buffer.from(Array.from({ length: 70000 }, (_, index) => (index * 31 + 7) & 0xff));
binary[33] = 0x0a;
const echoed = await viaGuest(echoPort, binary);
check('a guest loopback port reaches the mapped host service with binary payload intact',
  Buffer.compare(echoed.data, binary) === 0);

const parallel = await Promise.all(Array.from({ length: 6 }, (_, index) =>
  viaGuest(echoPort, Buffer.from(`guest-${index}`))));
check('parallel guest connections stay independent',
  parallel.every((result, index) => result.data.toString() === `guest-${index}`));

const burst = await viaGuest(burstPort, Buffer.alloc(0), { pauseMs: 1500, halfClose: false, wait: 20000 });
check(`a service's final burst survives both relay hops to a slow guest reader (${burst.data.length}/${burstBytes} bytes)`,
  burst.data.length === burstBytes && burst.data.every((byte) => byte === 0x62));

const unbound = await viaGuest(unboundPort, Buffer.from('x'));
check('a port the forwarder was not given is refused on the guest side', unbound.refused);

const badToken = await viaGuest(badTokenPort, Buffer.from('x'));
check('a forwarder holding the wrong token receives nothing from the broker',
  !badToken.refused && badToken.data.length === 0);

process.exit(failures.length === 0 ? 0 : 1);
EOF
forwarder_output=$(F_ECHO="$forward_echo_port" F_BURST="$forward_burst_port" \
  F_UNBOUND="$forward_unbound_port" F_BADTOKEN="$forward_badtoken_port" \
  F_BURST_BYTES="$burst_bytes" node "$test_root/forwarder-check.mjs" 2>&1) \
  || fail "the guest forwarder checks failed:
$forwarder_output"
case "$forwarder_output" in *FAIL*) fail "the guest forwarder checks failed:
$forwarder_output" ;; esac
pass 'the guest forwarder maps loopback ports through the tunnel and honours its allowlist and token'

kill -TERM "$forwarder_pid" "$badtoken_forwarder_pid" 2>/dev/null || true
wait "$forwarder_pid" 2>/dev/null || true
wait "$badtoken_forwarder_pid" 2>/dev/null || true
wait_until 10 port_refuses "$forward_echo_port" \
  || fail 'the guest forwarder kept listening after SIGTERM'
pass 'the guest forwarder stops listening when terminated'

expect_forwarder_rejection() {
  local description=$1 expected=$2
  shift 2
  local rejection_output rejection_status=0
  rejection_output=$(node "$forwarder_script" "$@" 2>&1) || rejection_status=$?
  [ "$rejection_status" -ne 0 ] || fail "$description was accepted"
  case "$rejection_output" in
    *"$expected"*) ;;
    *) fail "$description failed with the wrong message: $rejection_output" ;;
  esac
}
forwarder_common=(--endpoint 127.0.0.1:1 --token "$session_token")
expect_forwarder_rejection 'a missing endpoint' '--endpoint must be one IPv4:port' \
  --token "$session_token" --ports 5037
expect_forwarder_rejection 'a short token' '--token must be 64 lowercase hex' \
  --endpoint 127.0.0.1:1 --token abc --ports 5037
for bad_ports in '' 0 65536 abc '5037,' ':5037' '5037:' '1:2:3' '5037,5037' '5037:1,5037:2'; do
  expect_forwarder_rejection "forwarder ports '$bad_ports'" '--ports' \
    "${forwarder_common[@]}" --ports "$bad_ports"
done
expect_forwarder_rejection 'an unknown option' 'usage:' \
  "${forwarder_common[@]}" --ports 5037 --bogus 1
pass 'forwarder argument validation fails closed'

# --- Argument validation ---------------------------------------------------

expect_broker_rejection() {
  local description=$1 expected=$2
  shift 2
  local rejection_output rejection_status=0
  rejection_output=$(node "$broker_script" "$@" 2>&1) || rejection_status=$?
  [ "$rejection_status" -ne 0 ] || fail "$description was accepted"
  case "$rejection_output" in
    *"$expected"*) ;;
    *) fail "$description failed with the wrong message: $rejection_output" ;;
  esac
}
common_arguments=(--session-dir "$session_dir" --bind-address 127.0.0.1
  --launcher-pid "$launcher_pid" --real-home "$real_home")
expect_broker_rejection 'full access with --sandbox-bin' 'is not used with --access full' \
  "${common_arguments[@]}" --access full --sandbox-bin /usr/bin/true
expect_broker_rejection 'full access with --exec-home' 'is not used with --access full' \
  "${common_arguments[@]}" --access full --exec-home "$real_home"
expect_broker_rejection 'tunnel ports without full access' '--tunnel-ports requires --access full' \
  "${common_arguments[@]}" --exec-home "$real_home" --sandbox-bin /usr/bin/true --tunnel-ports 5037
expect_broker_rejection 'an unknown access level' '--access must be sandboxed or full' \
  "${common_arguments[@]}" --access root
for bad_ports in 0 65536 abc 5037, ,5037 5037,,5038 -1 08x; do
  expect_broker_rejection "tunnel ports '$bad_ports'" 'comma-separated list of TCP ports' \
    "${common_arguments[@]}" --access full --tunnel-ports "$bad_ports"
done
missing_session="$test_root/missing-catalog"
mkdir -m 0700 "$missing_session"
cp "$session_dir/host-exec-token" "$missing_session/"
expect_broker_rejection 'a session without a catalog specification' 'host-catalog.json is missing' \
  --session-dir "$missing_session" --bind-address 127.0.0.1 \
  --launcher-pid "$launcher_pid" --real-home "$real_home" --access full
pass 'broker argument and manifest validation fails closed'

# --- Lifetime --------------------------------------------------------------

kill "$launcher_pid" 2>/dev/null || true
wait "$launcher_pid" 2>/dev/null || true
launcher_pid=''
wait_until 10 pid_is_gone "$broker_pid" \
  || fail 'the broker outlived its launcher'
[ ! -e "$session_dir/host-exec-endpoint" ] \
  || fail 'the broker left its endpoint file behind'
broker_pid=''
pass 'the broker exits and removes its endpoint when the launcher dies'

# --- Sandboxed mode is unchanged ------------------------------------------

sandbox_session="$test_root/sandbox-session"
sandbox_guest="$test_root/sandbox-guest"
sandbox_home="$test_root/sandbox-real-home"
sandbox_work="$sandbox_home/work"
mkdir -m 0700 "$sandbox_session" "$sandbox_guest" "$sandbox_home" "$sandbox_home/exec-home" "$sandbox_work"
sandbox_work=$(CDPATH= cd -- "$sandbox_work" && pwd -P)
sandbox_home=$(CDPATH= cd -- "$sandbox_home" && pwd -P)
# Stand-in for sandbox-exec: drop "-p PROFILE" and run the command. It proves
# only the broker's own checks, never the macOS sandbox.
cat > "$test_root/fake-sandbox-exec" <<'EOF'
#!/bin/sh
[ "$1" = "-p" ] && shift 2
exec "$@"
EOF
chmod 0755 "$test_root/fake-sandbox-exec"
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$sandbox_session/host-exec-token"
printf '\n' >> "$sandbox_session/host-exec-token"
printf 'rw\t%s\n' "$sandbox_work" > "$sandbox_session/host-roots.tsv"
printf '{"v":1,"pathDirectories":["/usr/bin","/bin"],"deny":["sudo"],"first":[]}\n' \
  > "$sandbox_session/host-catalog.json"
sleep 600 &
launcher_pid=$!
node "$broker_script" \
  --session-dir "$sandbox_session" --bind-address 127.0.0.1 \
  --launcher-pid "$launcher_pid" --real-home "$sandbox_home" \
  --exec-home "$sandbox_home/exec-home" \
  --sandbox-bin "$test_root/fake-sandbox-exec" \
  > "$test_root/sandbox-broker.out" 2> "$test_root/sandbox-broker.err" &
sandbox_broker_pid=$!
wait_until 15 file_is_nonempty "$sandbox_session/host-exec-endpoint" \
  || fail "the sandboxed broker did not start: $(cat "$test_root/sandbox-broker.err")"
cp "$sandbox_session/host-exec-endpoint" "$sandbox_session/host-exec-token" "$sandbox_guest/"
sandbox_client() {
  env -i PATH="$PATH" HOME=/guest/home TERM=xterm AGENT_HOST_EXEC_DIR="$sandbox_guest" \
    bash "$client_script" "$@"
}
[ "$(jq -r 'has("access")' "$test_root/sandbox-broker.out")" = false ] \
  || fail 'the sandboxed readiness line gained access fields'
output=$(cd "$sandbox_work" && sandbox_client echo inside 2>&1)
[ "$output" = inside ] || fail "a command inside the declared root failed: $output"
status=0
output=$(cd "$outside_dir" && sandbox_client echo outside 2>&1) || status=$?
[ "$status" -ne 0 ] && case "$output" in *CWD_DENIED*) true ;; *) false ;; esac \
  || fail "sandboxed mode no longer denies a cwd outside its roots: $output"
output=$(cd "$sandbox_work" && sandbox_client sh -c 'printf %s "$HOME"' 2>&1)
[ "$output" = "$sandbox_home/exec-home" ] \
  || fail "sandboxed mode no longer uses the isolated HOME: $output"
sandbox_endpoint=$(sed -n '1p' "$sandbox_session/host-exec-endpoint")
sandbox_token=$(sed -n '1p' "$sandbox_session/host-exec-token")
exec 8<>"/dev/tcp/${sandbox_endpoint%:*}/${sandbox_endpoint##*:}"
printf '{"v":1,"type":"catalog","token":"%s"}\n' "$sandbox_token" >&8
IFS= read -r sandbox_catalog <&8
exec 8>&- 8<&-
[ "$(printf '%s' "$sandbox_catalog" | jq -c 'keys')" = '["commands","type"]' ] \
  || fail 'the sandboxed catalog response shape changed'
pass 'the default sandboxed mode is unchanged (roots, isolated HOME, catalog shape)'

# The early-stdin-close crash predates full access; the fix covers both modes.
result=$( { cd "$sandbox_work" && yes | sandbox_client head -c 100000 2>/dev/null | wc -c | tr -d ' '; } 2>/dev/null
  echo "status=${PIPESTATUS[1]}")
[ "$(printf '%s\n' "$result" | sed -n '1p')" = 100000 ] \
  && [ "$(printf '%s\n' "$result" | sed -n 's/^status=//p')" = 0 ] \
  || fail "sandboxed mode lost output when a command stopped reading stdin early: $result"
pid_is_alive "$sandbox_broker_pid" \
  || fail 'the sandboxed broker died when a command stopped reading stdin early'
pass 'sandboxed mode also survives a command that stops reading stdin early'

printf '1..%s\n' "$tests_passed"
