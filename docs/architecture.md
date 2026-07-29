# Architecture: a macOS-native runtime for Agent CLIs

Date: 2026-07-29
Validated upstream versions: `apple/container` 1.2.0 and
`apple/containerization` 0.40.1.

## Scope

`agent-container` is a macOS-only host launcher for command-line coding agents.
The host must be Apple silicon running macOS 26 or newer. The selected Agent
CLI does **not** run as a Darwin process: it runs as `linux/arm64` inside a
short-lived Micro-VM managed by Apple's Containerization stack.

Claude Code, Codex CLI, and Grok CLI are profiles of the same runtime. The core
owns isolation, lifecycle, identity, mounts, and safety checks; a profile owns
only the Agent package metadata and command. This separation is the foundation
for adding more Agent CLIs without copying the launcher.

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
          -> pinned linux/arm64 Agent CLI
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

## Image model and APFS copy-on-write

The shared `Containerfile` installs one pinned npm Agent package selected by a
profile. It also includes common development tools and the generic entrypoint.
Within the project's lifecycle locks and same-user trust boundary, the image
descriptor selected for a session is treated as immutable. An external
same-user `container image delete` or prune can still make startup fail, but it
cannot make the launcher execute an unverified replacement image.

Apple's image service caches OCI content and unpacked roots. On a clone-capable
backing filesystem such as APFS, its filesystem copy path uses `clonefile`
copy-on-write semantics rather than sharing one writable installation volume.
Consequently:

- the exact top-level Agent package version and local image identity are
  auditable;
- warm sessions reuse cached image content;
- concurrent image roots do not share a writable npm installation;
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

## State and session lifecycle

The default state root is `~/.agent-container`:

```text
~/.local/share/.agent-container.install.lock/ # lifecycle registration/transaction mutex
~/.agent-container/
  .agent-container-owned
  profiles/<id>/
    home/                 # persistent isolated Agent HOME
    meta/
      image-ref
      image-build-id
      image-identity
    session.lock/         # one image/session transaction per profile
  sessions/session-<pid>/ # ephemeral staged host metadata
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
| Apple service, VM, PTY, signals, cleanup | npm package and pinned version |
| UID/GID and shadow HOME | installed command and version probe |
| workspace, Git, and capability mounts | declared API-key environment variable |
| image cache and provenance | optional auto-update disable variable |
| VirtioFS file/FD/vnode guards | no shell fragments or arbitrary host mounts |

Profiles are validated JSON data and are never sourced as shell. See
[profiles.md](profiles.md) for the schema and extension process.

## Network boundary

Apple's standard CLI currently gives the Micro-VM unrestricted outbound
networking. The launcher can set proxy, DNS, and timezone values, but it does
not implement a hostname allowlist or an egress firewall. A proxy setting is
connectivity configuration, not a security boundary.

This is why credentials and host capabilities are denied by default and why
the project does not automatically add any Agent-specific permission-bypass
flag. See [security.md](security.md) for the complete threat model.

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
