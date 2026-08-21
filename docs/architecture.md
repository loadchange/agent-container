# Architecture: persistent profile VMs with dynamic workspaces

Validated platform: Apple `container` 1.2.0 on Apple silicon and macOS 26 or
newer.

## Scope and invariants

`agent-container` runs native Linux arm64 Agent CLIs through Apple's public
`container` CLI. Claude Code, Codex CLI, and Grok CLI are declarative profiles
of one runtime. The core launcher owns image construction, persistent container
identity, workspace transport, UID/GID handling, TTY forwarding, security
policy, and cleanup.

The normal path has these invariants:

- at most one managed container for each `(profile, host UID)` pair, created on
  first use;
- the container remains running until an explicit `singleton stop`;
- each invocation starts a new Agent process through `container exec`;
- every invocation keeps its own cwd, TTY or pipes, signals, and exit status;
- only that invocation's current Git root is dynamically mounted;
- the guest PATH mirrors the host command catalog through a per-client
  host-tool broker: `git` and `gh` default to host-first sandboxed host
  executables, and commands the guest image does not provide fall back to
  sandboxed host executables (`--no-container-host-tools` opts out);
- no real host HOME or predeclared multi-project root set is mounted;
- clients of one profile share the VM and isolated profile HOME.

The stable native name is `agent-<profile>-<uid>-singleton`. The container's
primary process is an inert lifetime anchor. Agent behavior is never delegated
to an Agent-specific resident process, so Claude, Codex, and Grok all follow the
same execution model.

## Why use Apple's `container` CLI

The public CLI is the production API boundary:

```text
Rust launcher
  -> internal shell runtime
    -> Apple container CLI
      -> container-apiserver and Apple helper services
        -> Virtualization.framework Micro-VM
          -> Linux arm64 image and native Agent executable
```

This project does not embed the low-level Containerization Swift package and
does not use `container machine`. Apple's services continue to own OCI content,
snapshots, vmnet, Virtualization.framework setup, vminitd, PTYs, signals, and
runtime helper processes. The project adds a stricter identity and lifecycle
protocol around that supported CLI.

`container machine` is a persistent general-purpose VM and can expose a broad
home share. A managed profile singleton remains a narrowly configured Apple
container with an inspected image, isolated shadow HOME, and no statically
mounted workspace.

## Host launcher split

One Rust binary is installed under the generic and compatibility names:

```text
agent-container
claude-container
codex-container
grok-container
```

The binary dispatches from the basename of `argv[0]`, parses only leading
`--container-*` launcher options, and preserves every other argument as an
`OsString`. It then uses `exec(2)` to replace itself with the adjacent internal
`agent-container-runtime`; it does not introduce a signal-forwarding parent.
The environment used between those two components is private implementation
detail rather than a public configuration interface.

The Rust binary also owns the internal workspace-broker entry point. Keeping
the broker in the signed host launcher removes a Node.js bootstrap from the
default path and gives the wire protocol a compact, typed implementation.

## Persistent container and independent clients

A typical two-project profile looks like this:

```text
terminal A                         terminal B
    |                                  |
    +-- Rust launcher                  +-- Rust launcher
    |      |                           |      |
    |      +-- broker A                |      +-- broker B
    |          sandboxed SFTP(A)       |          sandboxed SFTP(B)
    |                                  |
    +-- container exec A               +-- container exec B
           |                                  |
           +-- private mount ns A              +-- private mount ns B
           +-- SSHFS project A                 +-- SSHFS project B
           +-- Agent process A                 +-- Agent process B
                        \                      /
                         agent-<profile>-<uid>-singleton
                         one VM + one profile HOME
```

The first invocation builds or verifies the image, creates a stopped named
container, verifies its exact digest and provenance, starts it detached, and
publishes managed state as ready. A later invocation verifies the same native
record and immediately takes the client path.

`container exec` receives `--interactive` and receives `--tty` only when both
host stdin and stdout are terminals. Piped invocations therefore do not ask
Apple 1.2 to initialize a terminal on a non-terminal descriptor. Every exec is
started as root only long enough for mount-namespace setup; the Agent itself is
started as the host numeric UID/GID with supplementary groups cleared and
`no_new_privs` enabled.

Client exit terminates only that Agent and its SSHFS session. It does not stop
the VM or another client. `singleton stop <profile>` is the explicit persistent
container lifecycle boundary.

## Dynamic workspace transport

### Motivation

Apple `container` 1.2 can specify volumes only while creating a container. It
cannot add a mount to an already-running container through `container exec`.
Pre-mounting project A and project B would require knowing every future path,
would expand the VM's authority, and would reproduce the large-tree VirtioFS
risk that the persistent design is intended to avoid.

The normal path instead transports one canonical project root for one exec.
Inside Git, that root is the repository top level; outside Git, it is the
physical current directory. The original cwd must resolve beneath that root.

### Host broker

For every client, the Rust launcher:

1. canonicalizes an existing directory and rejects `/`;
2. verifies `/usr/bin/sandbox-exec` and `/usr/libexec/sftp-server` as fixed
   non-symlink system executables;
3. generates 32 bytes from `/dev/urandom` and encodes a 64-character lowercase
   hexadecimal token;
4. binds the selected Apple host-gateway IPv4 address on TCP port zero;
5. prints exactly one tab-separated endpoint/token record to its parent;
6. takes the read end of a private owner-liveness pipe and marks it
   close-on-exec;
7. waits at most 30 seconds for one connection while also watching owner
   liveness;
8. accepts at most 100 authentication bytes under one absolute five-second
   deadline;
9. starts the SFTP server under a parameterized macOS sandbox and relays raw
   bytes in both directions;
10. exits when the one connection and SFTP child end.

The authentication frame is versioned and exact. Reading it one byte at a time
prevents the broker from consuming the beginning of the first SFTP packet. The
token is not accepted as a command-line argument to the guest transport.

Only the host runtime retains the liveness writer. The broker child explicitly
closes it, and the Apple CLI child closes it before `container exec`, so neither
can keep the owner alive accidentally. EOF, a pipe error, or unexpected pipe
data is fail-closed. It stops pre-connection acceptance or calls
`shutdown(SHUT_RDWR)` on the attached TCP stream. Consequently, even
`SIGKILL` of the runtime tears down that client's workspace without stopping
the singleton or another client's broker.

The SFTP child receives a default-deny sandbox profile. It can execute the fixed
system SFTP binary, read and write below the canonical workspace, traverse only
the ancestors needed to reach it, and use standard system runtime files. An
explicit network deny prevents the child from creating another network
channel. The unsandboxed Rust parent owns only endpoint acceptance and byte
relay; it does not interpret SFTP paths or execute workspace commands.

This uses Apple's deprecated `sandbox-exec` interface. The default workspace
path fails closed if that fixed executable or the profile cannot be used, and
the policy must be retested on every supported macOS release.

### Guest mount namespace

The container exec enters a new mount namespace with private propagation before
creating a mountpoint. It validates that:

- the requested root and cwd are canonical absolute paths;
- neither overlaps protected guest system trees;
- the cwd is below the root and does not traverse a workspace symlink;
- the mountpoint is empty and not already mounted;
- `/dev/fuse`, SSHFS, `fusermount3`, and the fixed transport helper are present;
- the resulting filesystem type is FUSE/SSHFS.

The guest transport prefixes the one authentication frame and then runs
`socat -t 1 STDIO TCP4-CONNECT:...` as the raw bidirectional SFTP relay. Local
stdin EOF produces a TCP write-half-close while the relay can still read the
peer. Remote EOF ends the relay, after which the parent terminates and reaps a
producer that may still be blocked on SSHFS stdin. The one-second `socat`
inactivity bound applies after one side reaches EOF; this is a lifecycle relay,
not a general tunnel that waits indefinitely for delayed trailing data. Broker
loss therefore terminates SSHFS. SSHFS mounts the remote current directory at
the same absolute path with short attribute, entry, and negative caches.

After mount readiness, the helper creates a root-owned cgroup v2 leaf and an
independent session/process group, conditionally reacquires the exec PTY as its
controlling terminal, drops to the host identity, and starts the exact
root-owned profile executable. Every descendant inherits the cgroup even if it
later calls `setsid`, `setpgid`, or double-forks.

Signal and EXIT cleanup freeze the cgroup leaf, queue TERM to its stable member
snapshot, unfreeze for the grace period, use the atomic `cgroup.kill` boundary,
and wait for `populated 0` before stopping SSHFS or unmounting. This avoids
signalling a recycled PID while still reaching descendants that left the
original process group. The mount exists only in that private namespace, so
normal path lookup by another client does not see it. Unexpected SSHFS exit also
triggers the same Agent-tree cleanup.

Private namespaces prevent accidental mount sharing, but the clients still
share one kernel, Linux identity, process table, and profile HOME. They are not
a hard boundary for mutually hostile same-profile workloads.

### Git limitation

The default transport currently carries one root. A linked worktree whose Git
common directory is outside the worktree root cannot be represented as one
SFTP mount and is rejected before broker startup. The advanced `run` path can
use separate Apple volume mounts for that case. Ordinary repositories and
switching among unrelated roots require no configuration.

## Host tool broker

Alongside the workspace broker, each client starts one host-tool broker by
default: the authenticated Node.js broker shared with legacy `run`. Both
launch modes use one catalog implementation. The launcher freezes the ordered
host `PATH` directories, the deny/first policy, and the resolved Node.js and
Xcode/CommandLineTools executables into a catalog specification
(`host-catalog.json`), declares the canonical workspace as the only writable
execution root, stages a fresh 256-bit token, and binds the broker to its own
PID so the channel ends with the client. The broker expands the specification
into the validated command manifest in-process — canonicalizing every
executable, freezing `/usr/bin` developer shims to the selected developer
installation, skipping symlinks whose targets leave every declared tool root,
and excluding Agent-writable paths — instead of a per-candidate fork/exec
walk in the shell launcher.

The endpoint and token travel to the guest as `AGENT_WORKSPACE_HOST_EXEC_*`
values on the same private environment path as the workspace transport. The
root session helper writes them into the client's private runtime directory,
retrieves the command catalog from the authenticated broker, and builds two
shim directories of tiny wrapper scripts: host-first names (`git`, `gh`, and
any `--container-host-exec-first` additions) ahead of the Agent `PATH`, and
every other cataloged name behind it, so a host command runs exactly when the
verified guest image does not provide that name. `AGENT_HOST_EXEC_DIR` points
the guest client at the per-session credentials.

Proxied `git` and `gh` run on macOS with the real HOME, so pushes and GitHub
calls use host credential helpers and logins. When the launching terminal
exports a live `SSH_AUTH_SOCK`, the broker forwards that socket to exactly
those identity commands, so host `git` also reaches SSH remotes through the
operator's agent — signatures only, with key files still unreadable under the
sandbox (`--no-container-host-ssh-agent` opts out; an explicit
`--container-host-ssh-agent` fails closed without a live agent). Every other
proxied command
receives the isolated broker execution HOME, keeping host dotfiles and stored
credentials out of generic tools while their caches persist per profile. The
generated sandbox confines writes to the workspace and that execution HOME.
Host tools operate on the real project directory, avoiding SFTP round-trips
for metadata- and I/O-heavy work entirely; the per-invocation broker channel
adds roughly 0.2 s of startup latency, has no PTY, and leaves host-side
processes and listening ports on macOS rather than in the guest.

When the broker runtime is unavailable — most commonly a Mac without Node.js —
the default launch warns once and continues with guest binaries; an explicit
`--container-host-tools` fails closed before any native mutation, and
`--no-container-host-tools` skips the channel. The capability is per-client
and therefore not part of the singleton configuration fingerprint.

## Shadow HOME and static mounts

For host `/Users/alice`, the persistent mapping is:

```text
host managed state                                      guest
~/.agent-container/profiles/codex/home/        <->      /Users/alice  (rw)
profile singleton static staging               <->      /run/agent-host (ro)
per-exec host Git root                          <->      same path through SSHFS
```

The real `/Users/alice` directory is not mounted. The path-compatible shadow
HOME lets Agent state persist without exposing unrelated documents or another
profile's state. All clients of one profile intentionally share it.

Static opt-ins such as full Git configuration, GitHub CLI configuration, SSH
metadata, and the live SSH agent are container-creation capabilities. Their
content or identity contributes to the singleton configuration fingerprint.
Changing one while the container is running requires an explicit stop and
recreation; it is never silently added to an existing VM.

The default staged Git configuration contains only `user.name` and
`user.email`. It does not carry credential helpers, includes, HTTP headers, or
URL rewrites.

## Image model

The shared image starts from a digest-pinned Debian Bookworm slim arm64 base.
It contains common Linux tools, SSHFS/FUSE helpers, the generic entrypoint, and
one exact native Agent release. It does not install Node.js or npm for normal
operation.

Every built-in profile selects a publisher channel. On launch, the host reduces
that channel response to one safe exact version. The image recipe fingerprint
includes at least:

- the complete validated profile;
- resolved exact Agent version;
- base-image reference;
- `Containerfile`, build-context allowlist, entrypoint, and workspace helpers;
- selected guest CA fingerprint;
- relevant build recipe inputs.

The build uses a private installer HOME and has no runtime profile HOME,
workspace, API key, SSH agent, or GitHub configuration mounted. After the
official script runs, the recipe requires a Linux ELF64 ARM aarch64 command and
an exact version-probe match. Claude and Grok are reduced to one ELF; Codex
keeps its adjacent standalone resources.

Image references are profile-scoped cache names, not ownership proof. Before a
new singleton executes any client, the launcher inspects the image descriptor,
creates a stopped container with project labels, and inspects that stopped
container again. Its name, profile, host UID, creator PID, mode, image digest,
terminal state, and configuration hash must all match. Ambiguity is retained
for manual inspection rather than deleted speculatively.

On APFS, Apple's image and root filesystem implementation can use clonefile
copy-on-write. That improves warm root creation but does not make project I/O
native-speed; the default project path is SFTP/SSHFS.

## CA transport

`--container-extra-ca auto` is the normal default. macOS Security independently
verifies the known installer endpoint and, when resolving a floating channel,
the version endpoint. The highest currently-valid issuer explicitly marked
`CA:TRUE` from each verified chain is scoped to its consumer:

- the version-chain CA is used only for the host channel request;
- the installer-chain CA is supplied to the builder and installed into the
  guest system trust store.

The two CAs may differ. The complete Keychain is never copied. An explicit PEM
bundle must be selected with `--container-extra-ca` and supplies one reviewed
trust set after strict count, size, validity, Basic Constraints, symlink, and
stable-digest checks. PEM contents enter BuildKit as a secret; only their
public digest enters cache/provenance metadata.

The base-image pull and early Debian bootstrap precede guest CA installation.
They need their own trusted route. TLS errors and HTTP authorization errors are
different layers: certificate error 60 indicates chain verification failure;
HTTP 403 indicates that TLS succeeded and an origin or enterprise allowlist
denied access.

## Configuration boundary

The Rust launcher exposes a finite public `--container-*` vocabulary. Value
options cover resources, image selection, proxies, DNS, timezone, credential
policy, CA choice, safety thresholds, and development executable paths.
Boolean options cover rebuild behavior, static Git/GitHub/SSH capabilities, and
legacy VirtioFS safety controls.

Only leading launcher options are consumed. `--` ends launcher parsing, and an
unknown leading namespaced option is rejected as a typo. This prevents a
generic CLI parser from consuming future Agent flags while removing the need
for users to manipulate the internal Rust-to-runtime environment contract. The
full public option table is in the README and is mechanically aligned with
`src/launcher.rs`.

No provider or Agent environment setting is part of that private inherited
contract. `--container-forward-api-key` is off by default and expands only the
active profile's `apiKeyEnv` when enabled.
All other endpoint, model, token, and Agent settings require exact exported
names in `--container-forward-env`. The option accepts names rather than
`NAME=VALUE` assignments: values travel through the environment handoff and do
not enter launcher or Apple CLI argument vectors.

Settings that affect a persistent VM are hashed. A client may not attach with a
different CPU, memory, network, CA, image, or static capability policy. The
operator stops that profile and lets the next invocation create the new
configuration.

## State and lifecycle

The managed state root is:

```text
~/.agent-container/
  .agent-container-owned
  profiles/<id>/
    home/
    host-home/
    meta/
      image-ref
      image-build-id
      image-identity
    singleton/
      phase
      creator-pid
      agent-version
      image-digest
      config.sha256
      guest-stage/
  sessions/session-<launcher-pid>/
```

The state root must remain below the real HOME, may not overlap shared data,
and requires exact ownership markers. Persistent profile HOME is preserved
across singleton stop and ordinary uninstall.

Launch, install, uninstall, and singleton stop use a two-layer lifecycle lock:
a BSD `lockf` on an open descriptor for the canonical HOME inode plus a strict
PID/random-owner directory record. The kernel lock survives while inherited
synchronous children still mutate native state. Owner-aware stale records can
be quarantined only while holding that lock; malformed or older ambiguous state
fails closed.

A cold singleton holds the lock through image verification, container create,
detached start, running-state inspection, and ready publication. Another client
waits, then revalidates and attaches. Warm client staging is removed before the
lock is released. Per-client brokers are not stored as persistent services.

The control commands remain available even if a profile wrapper was removed:

```text
agent-container singleton status <profile>
agent-container singleton stop <profile>
```

Stop verifies the reserved name and full provenance before deletion. Stale
legacy auto-remove containers are reconciled separately and only when their
labels and dead launcher PID prove ownership.

## Advanced legacy `run`

`run` deliberately retains the older per-launch lifecycle:

```text
agent-container [launcher options] run <profile> [run options...] [-- Agent args...]
```

It creates an attached auto-remove VM, mounts the workspace and optional
read-only/read-write shares through Apple volumes, and exposes native host
commands through the same host-exec broker and catalog implementation as the
default path; the guest builds its shims from the broker-generated manifest at
container start instead of a catalog request. Guest binaries are preferred
except for explicitly host-first commands such as Git and gh.

This boundary differs from the default path in transport, not in command
surface: it uses VirtioFS for user trees and per-launch container lifecycle.
It exists for linked worktrees and extra shares, and requires stopping that
profile's singleton first.

## Network boundary

Apple's VM has ordinary outbound networking. Proxy, DNS, timezone, and CA
options configure connectivity and trust; they do not implement an egress
allowlist. Proxy and CA overrides are accepted only through their
`--container-*` options, not implicitly from exported launcher configuration.
The project does not inject Agent permission-bypass options.

The default workspace broker binds an inspected IPv4 gateway, but possession of
its single-use 256-bit token is the authentication boundary. Its SFTP child has
network access denied by the macOS sandbox. The Agent VM itself remains capable
of reaching provider APIs and other network destinations.

## Known upstream constraints

- [`container#1097`](https://github.com/apple/container/issues/1097): VirtioFS
  lookups can retain host file descriptors. Dynamic SFTP avoids a persistent
  VirtioFS project mount, but shadow HOME and static opt-ins still need guards.
- [`container#165`](https://github.com/apple/container/issues/165): Apple bind
  mounts have no UID/GID translation. The runtime matches numeric identity.
- [`container#141`](https://github.com/apple/container/issues/141): VirtioFS
  host-to-guest change notifications can be unreliable. SSHFS has its own FUSE
  cache and watcher limitations and must be benchmarked independently.
- `sandbox-exec` is deprecated and can change or disappear in a future macOS
  release.
- Host-loopback access needs Apple's administrator-controlled DNS/PF bridge,
  which disables Private Relay while active and loses its redirect on restart.

See [security.md](security.md) for the trust model and
[performance.md](performance.md) for measurement requirements.
