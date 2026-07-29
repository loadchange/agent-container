# agent-container

Run Agent CLIs in Apple's official container runtime on Apple silicon Macs.
Claude Code, Codex CLI, and future agents are profiles of one standardized,
macOS-only runtime instead of separate container scripts.

```text
agent-container <profile> [agent arguments...]
claude-container [claude arguments...]
codex-container  [codex arguments...]
grok-container   [grok arguments...]
```

The host integration is native Swift, Virtualization.framework, and Apple's
Containerization stack. The Agent itself still runs as an `arm64` **Linux**
process in a lightweight Micro-VM; a macOS Mach-O Agent binary cannot run in
the guest.

This does not reproduce macOS GUI, Keychain, Xcode, Mach-O binaries, or the
complete host toolchain. Agent-specific browser login must support a device
flow or another guest-compatible mechanism.

## What “physical-machine-like” means

Each session preserves the parts of local CLI use that matter most:

- the repository and current directory appear at the same absolute path;
- the Agent process uses the host's numeric UID/GID, so created files keep the
  expected ownership;
- stdin, a real TTY, terminal resize, exit status, and signals are forwarded;
- authentication, settings, sessions, and caches persist in a separate home
  for each Agent;
- the VM and writable OCI root are disposable after every `--rm` session.

It deliberately does **not** mount the real host home directory. The guest
`HOME` has the same path string as the host home, but its mount source is an
isolated profile home under `~/.agent-container/profiles/<id>/home`. A nested
workspace mount supplies only the selected repository. This preserves familiar
paths without exposing unrelated documents, browser data, credentials, or
another Agent's state.

## Status and important safety warning

This project targets Apple `container` 1.2.0+ on macOS 26+. Apple's open
[`container` issue #1097](https://github.com/apple/container/issues/1097)
reports VirtioFS file-descriptor retention and exhaustion behavior; reports
include application failures and a macOS kernel panic. The launcher therefore:

- allows one Agent VM at a time by default, across all profiles;
- rejects projected shares above 40,000 filesystem entries;
- checks the host file/vnode tables before launch;
- stops a running VM when file/vnode use reaches an 80% threshold.

There is no universally proven safe threshold while the upstream issue remains
open. Do not run million-file stress reproducers on a daily-use Mac. The escape
hatches are explicit and intentionally verbose:

```bash
export AGENT_CONTAINER_ACCEPT_VIRTIOFS_RISK=true
export AGENT_CONTAINER_ALLOW_CONCURRENT=true
```

This permits different profiles to overlap. Sessions of the same profile stay
serialized so two builds cannot race on that profile's provenance-tracked
image tag.

## Requirements

- Apple silicon Mac
- macOS 26 or newer
- Apple [`container` 1.2.0+](https://github.com/apple/container/releases)
- system Bash, `plutil`, and macOS JavaScriptCore (`osascript`)

Install Apple's signed package and start its per-user services yourself:

```bash
container system start
container system status
```

The launcher never starts, stops, upgrades, or reconfigures that service.

## Install

From this source checkout, after generating/verifying the committed release
manifest:

```bash
AGENT_CONTAINER_INSTALL_BASE_URL="file://$PWD" ./install.sh
```

After this exact asset set and `release-manifest.sha256` are published on
`main`, the remote installer is:

```bash
curl -fsSL https://raw.githubusercontent.com/loadchange/claude-docker/main/install.sh | bash
```

The installer validates every asset, publishes a content-addressed release
under `~/.local/share/agent-container/releases/`, atomically switches `current`,
and installs commands in `~/.local/bin`. A failed upgrade rolls the complete
installation back.

Ensure `~/.local/bin` is on `PATH`, then list the installed profiles:

```bash
agent-container profiles
```

## Built-in profiles

| Profile | Compatibility command | Pinned Linux package | Status |
|---|---|---|---|
| `claude` | `claude-container` | `@anthropic-ai/claude-code@2.1.220` | preview |
| `codex` | `codex-container` | `@openai/codex@0.146.0` | preview |
| `grok` | `grok-container` | `@xai-official/grok@0.2.110` | experimental |

The pinned Grok package includes a Linux arm64 payload. Its profile remains
experimental while Agent-specific login and interactive flows are qualified,
and it must be enabled explicitly:

```bash
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true grok-container --version
```

`preview` profiles are enabled by default but have not yet completed the full
real-Agent qualification matrix. `stable` is reserved for profiles verified on
Apple container through build, login, TTY/pipes, workspace writes, signals,
state persistence, and a warm second run.

See [docs/profiles.md](docs/profiles.md) for the strict JSON profile contract
and how to add another npm-distributed Agent CLI.

## First run and authentication

The first run builds a local OCI image containing the profile's exact
top-level Agent package version. Later runs inspect its identity and reuse it.
On a clone-capable backing filesystem such as APFS, Apple's unpacked-root copy
path can use copy-on-write cloning.

Each launch creates a stopped auto-remove container first, verifies its frozen
OCI digest and project provenance, and only then attaches `container start`.
The session Agent command therefore cannot execute with the workspace,
profile HOME, or opted-in host capabilities mounted until this verification
succeeds. Image construction is a separate trusted supply-chain phase: npm
lifecycle scripts and the declared version probe do execute in Apple's
isolated builder, without those session mounts.

```bash
claude-container
codex-container login --device-auth
```

The intended paths are Claude's interactive guest login and Codex's device
flow, which avoids depending on a localhost browser callback from the
Micro-VM. Both flows remain part of the preview qualification matrix rather
than a current compatibility guarantee. Each isolated shadow HOME is
persistent, so credentials and session state written there survive VM and
image replacement. Host
`~/.claude`, `~/.codex`, and other real Agent directories are never imported or
mounted automatically.

API keys are also denied by default. A profile may forward only its declared
key name after explicit authorization:

```bash
export OPENAI_API_KEY='...'
AGENT_CONTAINER_FORWARD_API_KEY=true codex-container
```

Running Codex this way does not forward `ANTHROPIC_API_KEY`, `XAI_API_KEY`, or
arbitrary host environment variables. Prefer interactive/device login when
possible so a long-lived host secret need not enter the VM.

## Workspace, Git, SSH, and GitHub CLI

When invoked within Git, the repository top-level directory is mounted at the
same absolute path and the original current directory is retained. Linked
worktrees, submodules, and external Git common directories are handled as
separate mounts. Apple has no bind-mount UID mapping yet
([issue #165](https://github.com/apple/container/issues/165)), so the entrypoint
drops from root to the host numeric UID/GID without recursively changing any
host mount.

The default Git configuration is a temporary file containing only
`user.name` and `user.email`. Credential helpers, HTTP headers, URL rewrites,
and includes do not enter the VM. These capabilities require separate opt-ins:

```bash
# May expose Git credentials, extra headers, URL rewrites, and includes.
AGENT_CONTAINER_FULL_GIT_CONFIG=true codex-container

# Exposes the host gh configuration, including readable tokens, read-only.
AGENT_CONTAINER_MOUNT_GH=true codex-container

# Forwards only the live SSH-agent socket; host ~/.ssh key files are not mounted.
AGENT_CONTAINER_FORWARD_SSH_AGENT=true codex-container

# Copies config/known_hosts metadata to an ephemeral read-only mount.
AGENT_CONTAINER_MOUNT_SSH_CONFIG=true codex-container
```

Read-only credentials can still be read and exfiltrated. Review
[docs/security.md](docs/security.md) before enabling them.

## Permissions and network boundary

The runtime does not inject `--dangerously-skip-permissions`, Codex full-auto,
or any equivalent bypass. Agent-level approval and sandbox controls stay on by
default.

Apple's public CLI currently gives the VM normal outbound networking and has no
hostname allowlist comparable to the experimental `sandboxy` example. This
project therefore cannot promise protection from exfiltration once a secret or
sensitive workspace is mounted. Isolation reduces ambient host access and
contains guest processes; it does not make untrusted instructions harmless.

## Configuration

All runtime settings use the shared `AGENT_CONTAINER_` namespace:

| Variable | Default | Purpose |
|---|---:|---|
| `AGENT_CONTAINER_CPUS` | `4` | Session VM CPUs |
| `AGENT_CONTAINER_MEMORY` | `4g` | Session VM memory |
| `AGENT_CONTAINER_BUILD_CPUS` | `4` | CPUs when Apple creates the shared image builder |
| `AGENT_CONTAINER_BUILD_MEMORY` | `4g` | Memory when Apple creates the shared image builder |
| `AGENT_CONTAINER_VERSION` | profile pin | Override the selected Agent version |
| `AGENT_CONTAINER_BASE_IMAGE` | pinned Node 22 Bookworm OCI digest | Override the base image or mirror |
| `AGENT_CONTAINER_REBUILD` | `false` | Force a no-cache rebuild and pull |
| `AGENT_CONTAINER_MAX_FILES` | `40000` | Maximum projected VirtioFS entries |
| `AGENT_CONTAINER_FD_STOP_PERCENT` | `80` | Live file/vnode stop threshold |
| `AGENT_CONTAINER_BIN` | `container` | Alternate Apple CLI, useful for source builds/tests |

Proxy, DNS, and timezone values are forwarded only when explicitly set:

```bash
export AGENT_CONTAINER_HTTPS_PROXY='http://host.container.internal:7890'
export AGENT_CONTAINER_NO_PROXY='localhost,127.0.0.1'
export AGENT_CONTAINER_DNS1='1.1.1.1'
export AGENT_CONTAINER_TZ='Asia/Singapore'
codex-container
```

`host.docker.internal` is rejected because it is Docker-specific. Apple's
documented host-loopback DNS/PF bridge is an administrator-controlled system
change; the launcher never creates it automatically.

Apple reuses its already-running shared `buildkit` helper. Build CPU, memory,
and DNS flags apply when that helper is created; they do not reconfigure an
existing helper. Session VM resource and DNS flags apply to each new session.

## Persistent layout

```text
~/.local/share/.agent-container.install.lock/  # short launch/transaction gate
~/.agent-container/
  .agent-container-owned
  session.lock/                # global #1097 safety lock while active
  sessions/session-<pid>/      # ephemeral, secret-capable staging
  profiles/<id>/
    home/                      # isolated persistent shadow HOME
    meta/                      # image ref, recipe hash, inspected identity
    session.lock/              # same-profile image/session serialization
```

Only `profiles/<id>/home` is mounted at the guest's HOME path. Core state,
other profiles, and image provenance never enter the guest. Launchers hold the
shared lifecycle gate until their PID registration is durable; install and
uninstall hold it for the whole transaction, closing start/remove races.
After an uncatchable launcher death, the next launch reconciles registrations
with Apple container IDs and ownership labels. It removes only a proven orphan
VM and its secret-capable staging; ambiguous resources fail closed.

## Updating an Agent

Profiles fix the top-level Agent package to an exact version for controlled
upgrades. Test another published exact version for one profile with:

```bash
AGENT_CONTAINER_VERSION=0.145.0 codex-container --version
```

The recipe fingerprint includes the profile, version, base image,
Containerfile, its context allowlist, and the entrypoint. A changed input
rebuilds only that profile.

This is controlled versioning, not a bit-for-bit reproducible supply chain.
The default base is digest-pinned, but Debian packages and the npm transitive
graph can still move. Full reproducibility additionally requires
snapshot/versioned OS packages and a locked dependency graph.

## Performance expectations

Apple's Micro-VM path removes the Docker Desktop daemon/LinuxKit layer and uses
cached OCI roots, with copy-on-write cloning when the backing filesystem
supports it. That does not prove a universal speedup: VM boot and VirtioFS
metadata operations can be slower than a native host process, and Agent
response time is often network-bound. Measure cold build, warm launch,
repository scans, and representative Agent tasks separately before claiming a
gain. See [docs/performance.md](docs/performance.md).

## Uninstall

```bash
./uninstall.sh
```

The default removes installed commands, managed release assets, and only those
profile images whose stored recipe and inspected identity still match. It
preserves every profile HOME.

To also remove logins, sessions, caches, and all project-owned state:

```bash
./uninstall.sh --purge
```

After publication, `uninstall.sh` can equivalently be fetched from the same
raw `main` URL used by the installer.

Uninstall fails closed before mutation if an Agent session is active or path,
marker, image, or symlink provenance cannot be proved.

`claude-docker` remains only as a deprecated command alias for
`agent-container claude`; it no longer starts or manages Docker. For safety,
the installer and uninstaller do not claim or delete legacy Docker images or
volumes, whose names alone cannot prove ownership.

## Architecture

See [docs/architecture.md](docs/architecture.md) for the decision to use Apple's
versioned `container` CLI instead of embedding the unstable low-level Swift API,
and for the exact Micro-VM, OCI snapshot, mount, and lifecycle model.
