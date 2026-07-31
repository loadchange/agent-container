# Architecture: a macOS-native runtime for Agent CLIs

Date: 2026-07-30
Validated upstream versions: `apple/container` 1.2.0 and
`apple/containerization` 0.40.1.

## Scope

`agent-container` is a macOS-only host launcher for command-line coding agents.
The host must be Apple silicon running macOS 26 or newer. The selected Agent
CLI does **not** run as a Darwin process: it runs as `linux/arm64` inside a
short-lived Micro-VM managed by Apple's Containerization stack.

Claude Code, Codex CLI, and Grok CLI are profiles of the same runtime. The core
owns isolation, lifecycle, identity, mounts, and safety checks; a profile owns
only the official native-installer contract, release-channel metadata, and
command. This separation is the foundation for adding more Agent CLIs without
copying the launcher.

## Decision: use Apple's `container` CLI

The public `container` CLI is the production boundary. This project does not
link the low-level Containerization Swift package directly and does not use
`container machine`.

```text
agent-container (Bash host launcher)
  -> container CLI (native Swift client)
    -> container-apiserver (launchd/XPC)
      -> core-images helper (OCI content and snapshots)
      -> vmnet network helper
      -> one container-runtime-linux helper per session
        -> Virtualization.framework Micro-VM
          -> optimized Linux kernel + vminitd
          -> exact publisher-channel-resolved linux/arm64 native Agent CLI
```

Directly embedding Containerization would make this project responsible for
kernel and vminit acquisition, OCI content storage, root filesystem creation,
APFS snapshots, vmnet allocation, vsock/gRPC, PTY resize, signals, crash
recovery, cleanup, signing, and entitlements. Apple's services already own
those responsibilities. Keeping the API behind a versioned CLI also limits the
impact of Swift API churn; Containerization promises source stability only
within a minor release.

The main design reference is Apple's experimental
[`examples/sandboxy`](https://github.com/apple/containerization/tree/0.40.1/examples/sandboxy).
It demonstrates the same per-Agent Micro-VM model. `agent-container` uses the
supported CLI path rather than copying that experimental application and its
broad host capabilities.

`container machine` is intentionally not used. It is a persistent,
general-purpose VM whose default read-write home sharing is broader than this
project needs. Each invocation instead creates a named, auto-remove container
with an ephemeral Linux root and a narrowly selected set of host shares.

## Native image model and APFS copy-on-write

The shared `Containerfile` starts from Debian Bookworm slim rather than a
language-runtime image. Its default is the Linux arm64 manifest pinned as:

```text
mirror.gcr.io/library/debian:bookworm-slim@sha256:9b67294679b30e5d6ab257b40594feeb4a4b81f7fcf4131f4decf0d6a212a9b0
```

Node.js and npm are not installed. The image contains common development tools,
one native Agent release, and the generic entrypoint.

Every built-in profile currently selects `latest`. Before inspecting or
building its image, every host launch queries the profile's official version
channel: Claude's plain-text latest endpoint, Codex's JSON latest channel, or
Grok's plain-text stable endpoint. The response must reduce to one safe exact
version. That exact value, rather than the floating channel name, is included in
the recipe fingerprint and passed to the official installer. An exact
`AGENT_CONTAINER_VERSION` skips channel resolution; this allows a matching warm
image to run without channel network access, although a missing image still
requires a networked build.

Image construction runs the selected official script with a build-only
`HOME=/opt/agent-native` and no workspace or persistent profile mounts. Claude
uses `https://claude.ai/install.sh` through `bash`, Codex uses
`https://chatgpt.com/codex/install.sh` through `sh`, and Grok uses
`https://x.ai/cli/install.sh` through `bash`. The resolved exact version is
supplied as the installer's positional argument or documented environment
variable, so a channel movement between resolution and build cannot silently
select a different Agent release.

After installation the recipe resolves the command target, requires `file` to
identify a Linux ELF64 ARM aarch64 executable, and requires the version probe
to report the resolved version. Claude and Grok require no adjacent installer
tree, so their single ELF is copied to `/usr/local/bin` and the temporary tree
is removed. Claude links against Debian's glibc; Grok is statically linked.
Codex retains its full versioned standalone tree under
`/opt/agent-native/.codex/packages/standalone/`, including its adjacent code-mode
host, `rg`, `bwrap`, and resources; `/usr/local/bin/codex` links into that tree.

Within the project's lifecycle locks and same-user trust boundary, the image
descriptor selected for a session is treated as immutable. An external
same-user `container image delete` or prune can still make startup fail, but it
cannot make the launcher execute an unverified replacement image.

Apple's image service caches OCI content and unpacked roots. On a clone-capable
backing filesystem such as APFS, its filesystem copy path uses `clonefile`
copy-on-write semantics rather than sharing one writable installation volume.
Consequently:

- the exact channel-resolved native Agent version and local image identity are
  auditable;
- warm sessions reuse cached image content;
- concurrent image roots do not share a writable Agent installation;
- changing the profile, requested Agent version, base image, Containerfile,
  context allowlist, or entrypoint invalidates the launcher build fingerprint.

The default image reference is `agent-container-<profile>:latest`. Per-profile
image reference, build fingerprint, and inspected identity are recorded under
`~/.agent-container/profiles/<profile>/meta/`. Image tags alone are not treated
as ownership proof. Before the session entrypoint or requested Agent command
can execute with workspace/profile mounts, the launcher uses a two-stage Apple
CLI flow: `container create --rm`, strict `container inspect`, then attached
`container start`. This is a project-level fail-closed
verification protocol, not a server-side atomic compare-and-start API. The
stopped container's OCI descriptor digest, project labels, IDs, state, and
terminal mode must match the preceding image inspection. A tag changed between
image inspection and creation therefore fails closed instead of starting
different content.

## Runtime identity and the shadow HOME

The physical-machine-like behavior comes from identity and path continuity,
not from exposing the real macOS home directory.

For a host home such as `/Users/alice`, the launcher creates this mapping:

```text
macOS host                                      Linux guest
~/.agent-container/profiles/codex/home/   <->  /Users/alice       (rw)
/Users/alice/work/project/                 <->  same absolute path (rw)
external Git common directory             <->  same absolute path (rw, if needed)
per-session staged metadata                <->  /run/agent-host    (ro)
```

The first share is an isolated, persistent **shadow HOME**. It has the same
absolute guest path as the macOS home, but its contents come from the selected
profile's private state directory. The actual macOS home root is never mounted
wholesale; the workspace and any explicitly enabled capability paths are
separate, narrower shares. Agent login state, settings, histories, and caches
written below `$HOME` therefore persist for that profile without being shared
with another profile or with the native macOS installation.

The build-only installer HOME is unrelated to this runtime shadow HOME. At
runtime the launcher also sets the profile-declared updater-disable variable
when one exists: `DISABLE_AUTOUPDATER=1` for Claude and
`GROK_DISABLE_AUTOUPDATER=1` for Grok. Release changes are therefore handled by
the host's channel resolution and fingerprinted image replacement rather than
an updater mutating a session root.

The repository root is mounted at its original absolute path. The original
current directory becomes the guest working directory. This preserves project
paths recorded by Agent CLIs and Git. Linked worktrees and submodules may need
an external Git common directory, which is mounted separately at its original
path.

VirtioFS exposes numeric ownership and Apple does not currently provide a
`keep-id`/uidmap facility. The root entrypoint adds a passwd/group record for
the host numeric UID/GID, or rewrites the single colliding image passwd record
so `getpwuid` still resolves the isolated shadow HOME. It then executes the
Agent with `setpriv`, cleared supplementary groups, and `no_new_privs`. It
never recursively changes ownership of a host share.

The launcher attaches stdin for both TTY and piped use. It records a TTY in the
created container only when both stdin and stdout are terminals; attached start
otherwise tries to put a pipe into raw terminal mode and fails with `ENOTTY` on
Apple 1.2. It preserves argument boundaries, waits for the Apple CLI, and
translates `INT`, `TERM`, and `HUP` into a named container stop. This gives
interactive Agent CLIs normal terminal behavior while keeping cleanup under the
host launcher.

## Explicit run mode and the host-exec broker

The legacy `agent-container <profile> ...` interface starts only the verified
Linux Agent environment described above. A separate, explicit interface opts
into a wider host integration boundary:

```text
agent-container run <profile> [runtime options...] [-- agent arguments...]
<profile>-container run [runtime options...] [-- agent arguments...]
```

`run` snapshots eligible executable basenames from the launcher's host `PATH`
before the Agent starts. It writes a frozen per-session manifest containing the
command basename, canonical executable path, and either `first` or `fallback`
resolution; the broker independently re-resolves and freezes each target while
loading the manifest. A PATH symlink whose canonical target is outside its
admitted tool runtime is skipped individually, so an unrelated pipx/uv-style
link cannot poison the complete session. When an active Xcode or
CommandLineTools installation can resolve
common stock developer shims such as `/usr/bin/git` and `/usr/bin/python3`, the
launcher freezes those commands to the selected executables so they do not need
xcrun's ambient host cache at request time. Otherwise it retains the original
shim. A selected developer runtime is admitted read-only and its actual tool
directories are inserted immediately before `/usr/bin` in the brokered child
`PATH`, preserving any user-selected earlier toolchain. The selected Agent
command, launcher compatibility commands, the
Apple `container` command, and `sudo` are unconditionally excluded. A repeated
`--no-host-exec COMMAND` removes another basename; `--host-first COMMAND` moves
an allowed basename to the host-first set. These lists select direct shim
routes, not subprocess policy: a routed shell, interpreter, Git hook, or
credential helper may create more native children. The generated macOS
filesystem sandbox is applied to the process group and is the enforcement
boundary for their filesystem access.

The current filesystem boundary is implemented with Apple's deprecated
`sandbox-exec` interface. `run` fails closed when `/usr/bin/sandbox-exec` is not
available, but Apple may change or remove this interface in a future macOS
release. This host bridge therefore requires release-by-release compatibility
validation and must not be treated as a permanently supported platform API.

Starting the broker necessarily executes one host Node.js process before that
sandbox exists. The launcher canonicalizes both the selected Node command and
its reported `process.execPath`, and rejects either path when it is inside the
workspace, private Agent state, an external writable Git directory, or a
read-write additional share. This bootstrap remains a trusted native dependency
and is not part of the guest fallback command surface.

The guest entrypoint builds two shim directories around the guest's normal
`PATH`:

```text
host-first shims -> guest command directories -> host-fallback shims
```

The usual policy is therefore guest-first: a Linux binary in the image wins,
and a host command is used only when the guest lacks that basename. `git` is
host-first by default because this mode is intended to approximate the
physical-machine repository workflow. The shim does not mount or execute a
Mach-O file in Linux. It sends the exact argument vector and stdin to a generic
Linux client, which authenticates to a native macOS broker; the broker executes
the already-resolved host path without invoking a shell and streams stdout,
stderr, and the final exit status back.

Additional shares are repeatable `--share-ro PATH` or `--share-rw PATH`
options. The launcher canonicalizes each existing directory, mounts it at the
same absolute guest path, rejects unsafe and overlapping roots, and includes it
in the VirtioFS budget. The same ordered root manifest becomes the macOS
sandbox policy for brokered commands:

- the repository and required external Git directory are read-write;
- each additional directory receives exactly its requested read-only or
  read-write mode;
- host executable and runtime dependency roots are read-only;
- the real host HOME is not admitted as a general filesystem root.

The two enforcement paths are intentionally aligned: `--share-ro` limits both
the guest mount and brokered host processes to read access, while `--share-rw`
permits both sides to mutate that tree. A host command cannot use the broker to
bypass a read-only guest mount.

Ordinary brokered commands run with a persistent, per-profile HOME at
`~/.agent-container/profiles/<id>/host-home`. It is separate from the real host
HOME and from the Linux shadow HOME. Host Git is a deliberate exception. For
that one command, the broker selects the real host HOME so Git can discover the
selected real `.gitconfig` and `.config/git` files, while the sandbox admits
only those Git configuration inputs rather than the complete HOME. The named
`.ssh/config`, `.ssh/known_hosts`, `.ssh/known_hosts.old`, and
`.ssh/allowed_signers` metadata paths are admitted read-only. The broker does
not separately reject a named path because
it is a symlink; the symlink target must independently be inside a
sandbox-authorized root for traversal to succeed. A live host `SSH_AUTH_SOCK`,
when present, is also admitted to `run` sessions. SSH private-key files are
never admitted or copied. Git configuration can still select credential helpers
or external commands, and SSH-agent possession authorizes authentication and
signing operations; whether a macOS credential helper can reach Keychain from
the sandbox is platform-dependent.

The broker is a per-launch child, not a persistent service. The launcher creates
a random 256-bit token, command/root manifests, and authenticated endpoint
metadata under its restrictive session staging directory. The guest sees those
files through the existing read-only `/run/agent-host` mount. Each authenticated
request gets a distinct host process group. Client disconnect, launcher exit,
VM stop, or broker termination kills that complete group, including ordinary
background descendants that remain members, before session staging is removed.
Deliberate `setsid`-style daemonization can escape a PGID and is outside the
protocol contract; the broker is not a durable service manager. The broker also
watches the launcher PID so an uncatchable launcher failure does not
intentionally leave a normal host service behind.

Host-exec requests are pipe based and do not allocate a pseudo-terminal. Stdin,
stdout, and stderr can stream through the connection, but commands that require
a controlling terminal, raw mode, or terminal ioctls must run in the guest or
outside `agent-container`. This is independent of the outer Agent session,
which retains the normal PTY behavior described above.

Selecting `run` is the user's authorization for this broader mode. The command
manifest, token authentication, and macOS sandbox narrow native host execution,
but they do not make it equivalent to the legacy Micro-VM-only boundary. In
particular, a brokered host interpreter executes code as the macOS user within
the admitted roots. Omitting `run` is the way to avoid creating the broker at
all.

## State and session lifecycle

The default state root is `~/.agent-container`:

```text
~/.local/share/.agent-container.install.lock/ # lifecycle registration/transaction mutex
~/.agent-container/
  .agent-container-owned
  profiles/<id>/
    home/                 # persistent isolated Agent HOME
    host-home/            # persistent isolated HOME for ordinary host tools
    meta/
      image-ref
      image-build-id
      image-identity
    session.lock/         # one image/session transaction per profile
  sessions/session-<pid>/ # ephemeral metadata, broker manifests/token/endpoint
  session.lock/           # global native-session safety lock
```

The state root must remain below the real host home, must not overlap the
workspace or Git shares, and must have valid provenance before a non-empty
directory is adopted. Session staging and locks are removed on normal exit and
signals.

The lock is global rather than per profile because the principal concurrency
risk is in Apple VirtioFS, not in any specific Agent. Parallel sessions require
both `AGENT_CONTAINER_ALLOW_CONCURRENT=true` and explicit acceptance of the
VirtioFS risk. That opt-in permits distinct profiles to overlap; the
per-profile lock still serializes sessions sharing one mutable,
provenance-tracked image tag.

Install and uninstall hold the lifecycle mutex for their entire transaction.
A launcher holds it only until its `sessions/session-<pid>` registration (and,
by default, the global session lock) is durable, then releases it before build
or run. Thus an uninstaller either wins the mutex before a launch begins, or
sees the live registration and aborts before mutation; explicitly accepted
concurrent launchers are still possible.

Every native VM also carries project, profile, host-UID, and launcher-PID
labels in an ID derived from the same values. If SIGKILL prevents shell EXIT
cleanup, the next lifecycle-locked launch enumerates Apple containers, deletes
only an exactly matching project-owned orphan, and then removes its complete
stale session staging. Missing or contradictory provenance is never guessed.

## Core and profile responsibilities

| Core runtime | Agent profile |
|---|---|
| macOS/Apple silicon/version preflight | display name and stable/preview/experimental status |
| Apple service, VM, PTY, signals, cleanup | official installer URL, shell, and exact-version interface |
| UID/GID and shadow HOME | installed command and version probe |
| workspace, Git, capability mounts, and explicit run-mode broker | official version endpoint and response format |
| image cache and provenance | API-key and optional auto-update-disable variables |
| VirtioFS file/FD/vnode guards | no shell fragments or arbitrary host mounts |

Profiles are validated JSON data and are never sourced as shell. See
[profiles.md](profiles.md) for the schema and extension process.

## Network boundary

Apple's standard CLI currently gives the Micro-VM unrestricted outbound
networking. The launcher can set proxy, DNS, and timezone values, but it does
not implement a hostname allowlist or an egress firewall. A proxy setting is
connectivity configuration, not a security boundary.

Legacy sessions continue to deny credentials and host capabilities by default,
and the project does not automatically add any Agent-specific
permission-bypass flag. Explicit `run` sessions intentionally add the
authenticated host broker, selected host Git configuration and live SSH agent
described above; network reachability is not what confines that broker. Its
authorization token, frozen command manifest, and macOS filesystem sandbox are
the relevant controls. See [security.md](security.md) for the complete threat
model.

## Known upstream constraints

- [`container#1097`](https://github.com/apple/container/issues/1097): VirtioFS
  lookups can retain host file descriptors and exhaust the system-wide table.
- [`container#165`](https://github.com/apple/container/issues/165): bind mounts
  have no UID/GID translation.
- [`container#141`](https://github.com/apple/container/issues/141): host-to-guest
  filesystem change notifications are unreliable for watch-mode tools.
- Host-loopback access requires Apple's DNS/PF bridge, which disables Private
  Relay and loses its redirect rule after restart.

These are platform limitations shared by every profile. The launcher reduces
risk but cannot repair them. Performance and rollout criteria are documented
in [performance.md](performance.md).
