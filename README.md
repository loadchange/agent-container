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

## Install Apple container

- Apple silicon Mac
- macOS 26 or newer
- Apple [`container` 1.2.0+](https://github.com/apple/container/releases)
- system Bash, `plutil`, and macOS JavaScriptCore (`osascript`)

Download the latest signed `.pkg` from Apple's
[`container` releases](https://github.com/apple/container/releases), open it,
and complete the macOS installer. Then verify the version and start its
per-user services:

```bash
container --version  # must be 1.2.0 or newer
container system start
container system status
```

If an older `container` installation is already running, stop it before using
Apple's installed updater:

```bash
container system stop
/usr/local/bin/update-container.sh
container system start
```

This project never installs, starts, stops, upgrades, or reconfigures Apple's
service for you.

## Install agent-container

### One-command full install

Once the release assets and `release-manifest.sha256` are published on `main`,
install or atomically upgrade all three profiles with:

```bash
curl -fsSL https://raw.githubusercontent.com/loadchange/agent-container/main/install.sh | bash
```

If macOS cannot reach GitHub directly, run `proxy_on` in that same shell before
the command. The separate proxy settings needed by the image builder are shown
in [Host proxy plus container proxy demo](#host-proxy-plus-container-proxy-demo).

The installer validates every asset, publishes a content-addressed release
under `~/.local/share/agent-container/releases/`, atomically switches `current`,
and installs commands in `~/.local/bin`. A failed upgrade rolls the complete
installation back.

Ensure that directory is on `PATH` in the current shell and add the same line
to `~/.zshrc` for later terminals:

```bash
export PATH="$HOME/.local/bin:$PATH"
agent-container profiles
```

### Install from a source checkout

From this source checkout, after generating/verifying the committed release
manifest:

```bash
AGENT_CONTAINER_INSTALL_BASE_URL="file://$PWD" ./install.sh
```

The same selector arguments described below work from a checkout, for example:

```bash
AGENT_CONTAINER_INSTALL_BASE_URL="file://$PWD" \
  ./install.sh --profile grok
```

### Select which profiles to install

Use `--profile` once for a single Agent or repeat it for a chosen set. No
selector means all profiles; `--all` expresses that default explicitly.
`--profile=grok` is equivalent to `--profile grok`, and `--all` cannot be
combined with `--profile`:

```bash
installer_url='https://raw.githubusercontent.com/loadchange/agent-container/main/install.sh'

# Grok only
curl -fsSL "$installer_url" | bash -s -- --profile grok

# Claude Code only
curl -fsSL "$installer_url" | bash -s -- --profile claude

# Codex only
curl -fsSL "$installer_url" | bash -s -- --profile codex

# Claude Code plus Codex
curl -fsSL "$installer_url" | \
  bash -s -- --profile claude --profile codex

# All three, explicitly
curl -fsSL "$installer_url" | bash -s -- --all
```

Every selection includes the shared `agent-container`, `Containerfile`, and
entrypoint. Only the selected compatibility commands and profile definitions
are published into the current release. The selection is the desired managed
set: rerunning the installer with another selection removes unselected command
links only when the installer can prove that this project owns them. It never
removes an unknown or user-owned command.

Confirm the profiles present in the current managed release with:

```bash
agent-container profiles
```

The project installer does **not** install Claude, Codex, or Grok directly on
macOS, and selecting a profile does not pull or build its image. Each official
native Linux CLI is downloaded into its own image only when that profile is
first invoked.

### Optionally prebuild the selected images

A version probe is the shortest way to build an installed profile without
entering its interactive UI. Run the command matching your selection:

```bash
# Claude Code only
claude-container --version

# Codex only
codex-container --version

# Grok only (experimental opt-in is currently required)
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true grok-container --version
```

To prebuild all three current native CLIs:

```bash
claude-container --version
codex-container --version
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true grok-container --version
```

Profiles that are never invoked do not get an Agent image or persistent Agent
HOME. Changing the installed profile selection does not itself delete an
existing profile image, credentials, or persistent HOME.

## Built-in profiles

| Profile | Compatibility command | Official native installer | Channel | Status |
|---|---|---|---|---|
| `claude` | `claude-container` | `https://claude.ai/install.sh` (`bash`) | Claude `latest` | preview |
| `codex` | `codex-container` | `https://chatgpt.com/codex/install.sh` (`sh`) | Codex `latest` | preview |
| `grok` | `grok-container` | `https://x.ai/cli/install.sh` (`bash`) | Grok `stable` | experimental |

All three profiles follow their publisher's current native release channel.
On every launch, the host resolves that channel to one exact version and puts
the exact value into the image recipe fingerprint. An unchanged channel reuses
the warm image; a channel update rebuilds only that profile. No profile installs
an npm package, and the Debian guest does not contain Node.js or npm.

The Grok profile remains experimental while Agent-specific login and
interactive flows are qualified, and it must be enabled explicitly:

```bash
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true grok-container --version
```

`preview` profiles are enabled by default but have not yet completed the full
real-Agent qualification matrix. `stable` is reserved for profiles verified on
Apple container through build, login, TTY/pipes, workspace writes, signals,
state persistence, and a warm second run.

See [docs/profiles.md](docs/profiles.md) for the strict JSON profile contract
and how to add another native Linux arm64 Agent CLI.

## First run and authentication

The first run builds a local OCI image from a digest-pinned Debian Bookworm slim
arm64 base. Before the build, the host resolves the profile's official channel
to an exact version; only that exact version reaches the installer and image
recipe. Later runs inspect the image identity and reuse it when the resolved
version is unchanged. On a clone-capable backing filesystem such as APFS,
Apple's unpacked-root copy path can use copy-on-write cloning.

The build downloads and runs the profile's official installer with a private
build-only `HOME=/opt/agent-native`. It then requires the installed command to
be a Linux arm64 ELF and requires its version probe to report the resolved exact
version. Claude and Grok are reduced to their single native ELF in
`/usr/local/bin`; Codex keeps its complete standalone release tree because its
binary depends on adjacent helpers and resources. None of this build state can
read the runtime profile HOME or workspace because those mounts do not exist
during image construction.

Each launch creates a stopped auto-remove container first, verifies its frozen
OCI digest and project provenance, and only then attaches `container start`.
The session Agent command therefore cannot execute with the workspace,
profile HOME, or opted-in host capabilities mounted until this verification
succeeds. Image construction is a separate trusted supply-chain phase: the
publisher's install script and downloaded release artifacts execute in Apple's
isolated builder, without those session mounts.

Authenticate each profile inside its isolated guest HOME:

```bash
# Claude currently has no --device-auth flag. Follow the URL/login prompt.
claude-container auth login

# Device flows are suitable for a headless Micro-VM.
codex-container login --device-auth
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true \
  grok-container login --device-auth
```

Then start an interactive session from the repository you want mounted:

```bash
cd /path/to/your/repository
claude-container
codex-container
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true grok-container
```

Arguments after a compatibility command are passed to the native Agent
unchanged. Use `claude-container --help`, `codex-container --help`, or
`AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true grok-container --help` for
Agent-specific options.

The Codex/Grok device flows avoid relying on an automatic browser callback from
the Micro-VM. Claude currently exposes no device-auth flag; follow its prompts
and open any displayed URL in the host browser. Agent-specific login flows
remain part of the preview or experimental qualification matrix rather than a
current compatibility guarantee. Each isolated shadow HOME is persistent, so
credentials and session state written there survive VM and image replacement.
Host `~/.claude`, `~/.codex`, `~/.grok`, and other real Agent directories are
never imported or mounted automatically.

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

All launcher settings use the shared `AGENT_CONTAINER_` namespace. An override
can prefix one command or be exported for later commands:

```bash
AGENT_CONTAINER_CPUS=6 AGENT_CONTAINER_MEMORY=8g codex-container

export AGENT_CONTAINER_VERSION=0.146.0
codex-container --version
unset AGENT_CONTAINER_VERSION
```

### Runtime, image, and network overrides

| Variable | Default | Purpose |
|---|---|---|
| `AGENT_CONTAINER_CPUS` | `4` | CPUs for each Agent session VM |
| `AGENT_CONTAINER_MEMORY` | `4g` | Memory for each Agent session VM |
| `AGENT_CONTAINER_BUILD_CPUS` | `4` | CPUs used when Apple creates the shared image builder |
| `AGENT_CONTAINER_BUILD_MEMORY` | `4g` | Memory used when Apple creates the shared image builder |
| `AGENT_CONTAINER_VERSION` | profile `latest` policy | Use `latest` or one exact native release such as `0.146.0` |
| `AGENT_CONTAINER_BASE_IMAGE` | pinned Debian Bookworm slim arm64 digest | Use another safe OCI base/mirror reference; included in the image fingerprint |
| `AGENT_CONTAINER_REBUILD` | `false` | Force a `--no-cache --pull` rebuild of the selected profile |
| `AGENT_CONTAINER_SKIP_BUILD` | `false` | Never build; fail if the selected profile image is absent or stale |
| `AGENT_CONTAINER_ENABLE_EXPERIMENTAL` | `false` | Permit experimental profiles such as Grok |
| `AGENT_CONTAINER_HTTP_PROXY` | unset | Forward `HTTP_PROXY`/`http_proxy` to the builder and Agent VM |
| `AGENT_CONTAINER_HTTPS_PROXY` | unset | Forward `HTTPS_PROXY`/`https_proxy` to the builder and Agent VM |
| `AGENT_CONTAINER_ALL_PROXY` | unset | Forward `ALL_PROXY`/`all_proxy` to the builder and Agent VM |
| `AGENT_CONTAINER_NO_PROXY` | `localhost,127.0.0.1` | Proxy bypass list, forwarded when any Agent proxy is set |
| `AGENT_CONTAINER_DNS1` | unset | Primary DNS passed to builds and session VMs |
| `AGENT_CONTAINER_DNS2` | unset | Secondary DNS passed to builds and session VMs |
| `AGENT_CONTAINER_TZ` | unset | Set the session VM `TZ`, for example `Asia/Singapore` |

The default base image reference is already complete and safe. If an older
shell has a malformed override such as a wrapped value or a missing `/`, clear
it instead of copying the default by hand:

```bash
unset AGENT_CONTAINER_BASE_IMAGE
```

Apple reuses its already-running shared `buildkit` helper. Build CPU, memory,
and DNS flags apply when that helper is created; they do not reconfigure an
existing helper. Session VM resource and DNS flags apply to each new session.

### Host proxy plus container proxy demo

There are two separate network hops on a cold `latest` launch:

1. The macOS launcher queries the publisher's current version with host
   `curl`. It follows ordinary host `http_proxy`, `https_proxy`, and
   `ALL_PROXY` variables; `proxy_on` must be active in the same shell.
2. Apple's builder downloads Debian packages, the official installer, and the
   native CLI. The running Agent also needs network access. These two guests
   use the `AGENT_CONTAINER_*_PROXY` values.

For a local HTTP proxy listening on macOS loopback port `1087`, a complete
example is:

```bash
# 1. Host-side install and latest-channel requests.
proxy_on

# 2. Make the host loopback proxy reachable from Apple container VMs.
#    This Apple system change needs sudo and may need to be recreated after a
#    restart. Choose a non-conflicting address if this one conflicts locally.
container system dns list
# If host.container.internal is not already listed, create it once:
sudo container system dns create \
  host.container.internal --localhost 203.0.113.113

# 3. Builder and running-Agent proxy settings.
export AGENT_CONTAINER_HTTP_PROXY='http://host.container.internal:1087'
export AGENT_CONTAINER_HTTPS_PROXY='http://host.container.internal:1087'
export AGENT_CONTAINER_NO_PROXY='localhost,127.0.0.1'

# Build/reuse Grok and run its native version probe.
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true grok-container --version
```

If the proxy already listens on an address directly reachable by the VM, use
that address and skip the DNS/PF bridge. Apple's documented
[`--localhost` bridge](https://github.com/apple/container/blob/main/docs/how-to.md#access-a-host-service-from-a-container)
disables Private Relay while present, and its packet-filter redirect is lost
after a restart. The launcher never creates this administrator-controlled
system change automatically. `host.docker.internal` is Docker-specific, has
no Apple container meaning, and is rejected.

Setting only `AGENT_CONTAINER_HTTP_PROXY` or
`AGENT_CONTAINER_HTTPS_PROXY` cannot bootstrap the host-side latest-channel
query. Conversely, `proxy_on` alone does not automatically forward its
`127.0.0.1` endpoint into a VM.

### Capability and safety overrides

| Variable | Default | Purpose |
|---|---|---|
| `AGENT_CONTAINER_FORWARD_API_KEY` | `false` | Forward only the selected profile's declared key (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or `XAI_API_KEY`) |
| `AGENT_CONTAINER_FULL_GIT_CONFIG` | `false` | Expose the full host Git config instead of only `user.name`/`user.email` |
| `AGENT_CONTAINER_MOUNT_GH` | `false` | Mount host GitHub CLI configuration read-only |
| `AGENT_CONTAINER_FORWARD_SSH_AGENT` | `false` | Forward the live SSH-agent socket; never mounts private-key files |
| `AGENT_CONTAINER_MOUNT_SSH_CONFIG` | `false` | Copy selected SSH metadata into an ephemeral read-only mount |
| `AGENT_CONTAINER_MAX_FILES` | `40000` | Maximum projected entries across all VirtioFS shares |
| `AGENT_CONTAINER_FD_STOP_PERCENT` | `80` | Live file/vnode watchdog stop threshold; valid range is 50–95 |
| `AGENT_CONTAINER_ACCEPT_VIRTIOFS_RISK` | `false` | Continue past selected VirtioFS risk checks after explicit acceptance |
| `AGENT_CONTAINER_ALLOW_CONCURRENT` | `false` | Allow distinct profiles to overlap; also requires risk acceptance |
| `AGENT_CONTAINER_DISABLE_FD_WATCHDOG` | `false` | Disable the live file/vnode watchdog; intended only for controlled tests |

Capability flags can expose credentials or weaken host-risk controls. Review
[docs/security.md](docs/security.md) before enabling them. For example:

```bash
export XAI_API_KEY='...'
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true \
AGENT_CONTAINER_FORWARD_API_KEY=true \
  grok-container
```

### Installation and development overrides

| Variable | Default | Purpose |
|---|---|---|
| `AGENT_CONTAINER_INSTALL_BASE_URL` | published raw `main` URL | Change where `install.sh` downloads its manifest and immutable asset set |
| `AGENT_CONTAINER_ASSET_DIR` | installed/current release | Use another complete launcher asset directory, mainly for source development |
| `AGENT_CONTAINER_BIN` | `container` | Use another Apple `container` executable, mainly for source builds/tests |

Arbitrary `AGENT_CONTAINER_IMAGE` values and a custom
`AGENT_CONTAINER_STATE_DIR` are intentionally unsupported: image references
must remain profile-scoped for provenance, and state must remain globally
discoverable under `~/.agent-container` for safe cleanup.

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

The built-in profiles select `latest`, meaning the publisher-controlled Claude
latest, Codex latest, or Grok stable channel. The host queries that profile's
official version endpoint on every launch, strictly parses one exact version,
and includes it in the image fingerprint. Test or temporarily pin another
published exact native release with:

```bash
AGENT_CONTAINER_VERSION=0.146.0 codex-container --version
```

The recipe fingerprint includes the profile, version, base image,
Containerfile, its context allowlist, and the entrypoint. A changed input
rebuilds only that profile.

An exact `AGENT_CONTAINER_VERSION` bypasses the channel lookup, which permits an
offline rollback or warm run when its matching image is already cached. A cold
build still needs network access to the Debian repositories and publisher's
installer/artifacts. Claude and Grok auto-updaters are disabled in runtime
sessions, so publisher releases enter through this fingerprinted rebuild path
instead of mutating a running image.

Following a publisher channel intentionally trades reproducibility for
automatic publisher-selected upgrades. Even an exact version is not a
bit-for-bit reproducible supply chain: the official install script URL and
Debian package repositories can change. The default Debian base itself is
digest-pinned. See [docs/security.md](docs/security.md) for the different
integrity checks performed by the Claude, Codex, and Grok installers.

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

No Docker compatibility command or Docker runtime asset is shipped. For
safety, the uninstaller does not claim or delete legacy Docker images or
volumes, whose names alone cannot prove ownership.

## Architecture

See [docs/architecture.md](docs/architecture.md) for the decision to use Apple's
versioned `container` CLI instead of embedding the unstable low-level Swift API,
and for the exact Micro-VM, OCI snapshot, mount, and lifecycle model.
