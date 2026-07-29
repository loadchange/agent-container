# Security model

## Security objective

`agent-container` places an Agent CLI and the commands it launches inside a
dedicated Apple Containerization Linux Micro-VM. The objective is to reduce the
macOS host surface available to an untrusted or mistaken Agent while preserving
an interactive, physical-machine-like development workflow.

The Micro-VM is an isolation boundary, not a guarantee that mounted data is
safe. Anything explicitly shared with the guest must be treated as available
to the Agent, its subprocesses, and any code executed from the workspace.

The macOS user account, installed launcher assets, and Apple's per-user
container services are trusted. Another process already running as the same
macOS user can mutate project state or call the Apple CLI directly; this design
does not claim to isolate mutually hostile host processes from one another.

## What is isolated

By default the guest does not receive:

- the real macOS home directory as a wholesale share;
- another Agent profile's persistent home;
- host API keys from the environment;
- host `~/.ssh` private-key files or the SSH agent socket;
- the host GitHub CLI configuration;
- the full host Git or XDG Git configuration;
- arbitrary host environment variables or sockets.

The workspace and explicitly enabled capability paths can still be selected
subdirectories of the macOS home. They are mounted separately and do not turn
the parent home into a share.

The Linux root filesystem is ephemeral per session. The selected profile has a
persistent shadow HOME under
`~/.agent-container/profiles/<profile>/home/`. It is mounted at the same guest
absolute path as the host home, but it contains only that profile's isolated
state.

The process runs as the host numeric UID/GID, with supplementary groups
cleared and `no_new_privs` enabled. This prevents routine Agent execution from
remaining root inside the guest. It does not change the permissions of data
that was deliberately mounted read-write.

## What is exposed by default

The repository root is read-write because a coding Agent must edit it. An
external Git common directory is also read-write when required by a linked
worktree or submodule. The Agent can therefore read, change, delete, or commit
anything in those shares, including repository-local secrets and Git metadata.

A generated global Git configuration containing only `user.name` and
`user.email` is staged read-only at `/run/agent-host/gitconfig`. The guest uses
it through `GIT_CONFIG_GLOBAL`. Credential helpers, HTTP headers, URL rewrites,
and includes are excluded by default.

The guest always has ordinary outbound networking. There is currently no
hostname allowlist, egress firewall, or policy proxy in this project. A
malicious process can exfiltrate any workspace or profile-home data it can
read.

## Capabilities are denied by default

Higher-risk host integrations require explicit environment switches:

| Capability | Switch | Exposure |
|---|---|---|
| Profile API key | `AGENT_CONTAINER_FORWARD_API_KEY=true` | the profile's declared key environment variable |
| SSH agent | `AGENT_CONTAINER_FORWARD_SSH_AGENT=true` | signing/authentication through the live agent socket |
| SSH metadata | `AGENT_CONTAINER_MOUNT_SSH_CONFIG=true` | non-symlink `config`, `known_hosts*`, `allowed_signers` files |
| GitHub CLI config | `AGENT_CONTAINER_MOUNT_GH=true` | host `~/.config/gh` read-only |
| Full Git config | `AGENT_CONTAINER_FULL_GIT_CONFIG=true` | host `~/.gitconfig` copy and `~/.config/git` read-only |
| Concurrent VMs | `AGENT_CONTAINER_ALLOW_CONCURRENT=true` plus risk acceptance | additional VirtioFS-affected sessions across distinct profiles; one session per profile remains enforced |

Enabling a capability authorizes use, not only reading. SSH agent forwarding
does not reveal private-key bytes, but guest code can request signatures or
authenticate to reachable systems. Git and GitHub configuration may contain
tokens, credential helpers, custom commands, extra HTTP headers, or URL
rewrites. Audit them before mounting.

SSH private keys are never copied by the launcher. SSH metadata mounting and
SSH agent forwarding are separate decisions. A key file committed or copied
inside the selected workspace is still visible because the workspace itself is
the intended read-write capability.

## Authentication

The safest persistent authentication flow is to run the Agent's normal login
command inside its profile:

```bash
agent-container claude
agent-container codex login --device-auth
```

The resulting credentials remain in that profile's isolated shadow HOME and
survive image replacement. The launcher does not automatically copy the native
macOS Agent home or share credentials between profiles.

For a deliberate one-session API-key handoff, export the environment variable
declared by the profile and enable forwarding:

```bash
export OPENAI_API_KEY='...'
AGENT_CONTAINER_FORWARD_API_KEY=true agent-container codex
```

The core forwards only the selected profile's declared variable. For the
built-in profiles these are `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and
`XAI_API_KEY`. Do not put keys in command-line arguments, image build arguments,
profile JSON, or a repository file.

The key is still readable by processes in that guest session and can be sent
over the network. Environment forwarding is convenience, not secret
brokerage.

## Agent permission modes

The launcher does not automatically add Claude, Codex, Grok, or future
Agent-specific permission-bypass flags. Agent arguments are passed through
unchanged, so a user can still explicitly request a dangerous Agent mode.

Micro-VM isolation does not make such a mode harmless: the Agent retains full
access to the read-write workspace, its persistent profile home, and every
enabled capability. Keep the Agent's own approvals and sandbox enabled unless
the mounted-data impact is understood.

## Network and proxy limitations

`AGENT_CONTAINER_HTTP_PROXY`, `AGENT_CONTAINER_HTTPS_PROXY`,
`AGENT_CONTAINER_ALL_PROXY`, and `AGENT_CONTAINER_NO_PROXY` configure normal
proxy environment variables. `AGENT_CONTAINER_DNS1` and
`AGENT_CONTAINER_DNS2` configure DNS. None creates an allowlist.

`host.docker.internal` has no Apple-container meaning and is rejected. Apple's
optional `host.container.internal` DNS/PF bridge requires administrator
configuration, disables Private Relay, and loses its redirect after restart.
The launcher never creates that bridge automatically.

## Host filesystem and state safety

The launcher canonicalizes writable state paths, rejects broken or unsafe
symlinks, refuses state outside the host home, and rejects overlap between
private state and workspace/Git shares. A non-empty state root must carry the
exact ownership marker before adoption.

Per-session Git and SSH staging is created with a restrictive umask, mounted
read-only, and removed on exit. Image deletion should rely on the recorded
reference, build fingerprint, inspected identity, and ownership provenance;
an image name by itself is not sufficient authorization.

Launch registration and install/uninstall use the same atomic lifecycle mutex.
The uninstaller holds it through preflight and mutation, while a launcher holds
it until its live PID registration is visible. This prevents a new Agent VM
from starting in the gap between an activity check and destructive cleanup.

These checks protect against accidental path expansion and unsafe cleanup.
They do not protect data already mounted into a compromised guest.

## VirtioFS host-risk controls

Apple [`container#1097`](https://github.com/apple/container/issues/1097)
reports retained host file descriptors during large VirtioFS scans. Reports
include host application failures and a kernel panic. Current mitigations are:

- a default 40,000-entry budget across workspace, external Git data, profile
  HOME, and opted-in configuration shares;
- a projected 70% host file/per-process-file/vnode preflight;
- one native session globally by default;
- a live watchdog that stops the named VM at 80% by default;
- named sessions, verified create-before-start, signal cleanup, and auto-remove.

There is no proven universally safe threshold. The following variables weaken
these controls and are intended only for controlled experiments:

```bash
AGENT_CONTAINER_ACCEPT_VIRTIOFS_RISK=true
AGENT_CONTAINER_ALLOW_CONCURRENT=true
AGENT_CONTAINER_DISABLE_FD_WATCHDOG=true
```

Changing `AGENT_CONTAINER_MAX_FILES` or
`AGENT_CONTAINER_FD_STOP_PERCENT` also changes the safety policy. Do not run
large-file-count stress tests on a machine containing important unsaved work.

## Other upstream limitations

- [`container#165`](https://github.com/apple/container/issues/165): there is no
  bind-mount UID/GID mapping. Matching the host numeric identity is required.
- [`container#141`](https://github.com/apple/container/issues/141): host edits
  do not reliably generate guest filesystem events. Watchers may miss changes
  even when ordinary reads see them.

## Profile and image supply chain

Profiles select packages installed into a network-enabled OCI build. Treat the
profile JSON, npm package/version, base image, Containerfile, and entrypoint as
trusted code inputs. Pin versions, review package ownership, prefer a base
image digest for controlled deployments, and inspect changes before rebuilding.

Profiles are data rather than shell, but a valid profile can still select a
malicious npm package. Schema validation is not package attestation.
