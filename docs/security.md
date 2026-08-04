# Security model

## Security objective

`agent-container` places an Agent CLI and the commands it launches inside a
dedicated Apple Containerization Linux Micro-VM. The objective is to reduce the
macOS host surface available to an untrusted or mistaken Agent while preserving
an interactive, physical-machine-like development workflow.

The Micro-VM is an isolation boundary, not a guarantee that mounted data is
safe. Anything explicitly shared with the guest must be treated as available
to the Agent, its subprocesses, and any code executed from the workspace. In
explicit `run` mode, the workspace and additional share policy also defines
what sandboxed brokered host processes can read or modify.

The macOS user account, installed launcher assets, and Apple's per-user
container services are trusted. Another process already running as the same
macOS user can mutate project state or call the Apple CLI directly; this design
does not claim to isolate mutually hostile host processes from one another.

## What is isolated

In the legacy launch mode, the guest does not receive:

- the real macOS home directory as a wholesale share;
- another Agent profile's persistent home;
- host API keys from the environment;
- host `~/.ssh` private-key files or the SSH agent socket;
- the host GitHub CLI configuration;
- the full host Git or XDG Git configuration;
- arbitrary or prefix-matched host environment variables or sockets.

The workspace and explicitly enabled capability paths can still be selected
subdirectories of the macOS home. They are mounted separately and do not turn
the parent home into a share.

Explicit `run` mode is a separate opt-in boundary. It adds a per-session native
host-command broker, selected host Git configuration, and access to a live host
SSH agent when one exists. These capabilities are described below; selecting
`run` must not be interpreted as preserving the legacy Micro-VM-only boundary.

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

The Claude profile is one narrow environment exception: it inherits an exact,
reviewed list of non-credential provider, model, telemetry, UI, timeout, and
team settings documented in the README. It does not scan the `ANTHROPIC_*` or
`CLAUDE_CODE_*` prefixes. This distinction matters because those prefixes also
contain OAuth/session tokens, private-key paths, file descriptors, and internal
host process state. Values are inherited with Apple container's `--env NAME`
form rather than copied into command arguments.

## Capabilities are denied by default

Higher-risk host integrations require explicit environment switches:

| Capability | Switch | Exposure |
|---|---|---|
| Profile credential | `AGENT_CONTAINER_FORWARD_API_KEY=true` | the selected profile's declared authentication variables; Claude accepts `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` |
| Additional exact environment names | `AGENT_CONTAINER_FORWARD_ENV=NAME1,NAME2` | each named, exported host value; launcher identity, shell-loader, proxy, and updater variables are rejected |
| SSH agent | `AGENT_CONTAINER_FORWARD_SSH_AGENT=true` | signing/authentication through the live agent socket |
| SSH metadata | `AGENT_CONTAINER_MOUNT_SSH_CONFIG=true` | selected `config`, `known_hosts`, `known_hosts.old`, `allowed_signers` files |
| GitHub CLI config | `AGENT_CONTAINER_MOUNT_GH=true` | host `~/.config/gh` read-only |
| Full Git config | `AGENT_CONTAINER_FULL_GIT_CONFIG=true` | host `~/.gitconfig` copy and `~/.config/git` read-only |
| Concurrent VMs | `AGENT_CONTAINER_ALLOW_CONCURRENT=true` plus risk acceptance | additional VirtioFS-affected sessions across distinct profiles; one session per profile remains enforced |
| Sandboxed host commands | `agent-container run <profile> ...` or `<profile>-container run ...` | eligible native commands from the host `PATH`; live SSH agent when present |
| Additional directory, read-only | `--share-ro PATH` in `run` mode | directory contents to the guest and brokered host processes without write authorization |
| Additional directory, read-write | `--share-rw PATH` in `run` mode | read, change, and delete authority for both the guest and brokered host processes |

Enabling a capability authorizes use, not only reading. An explicitly named
environment value may itself be a credential and is fully readable in the
guest. SSH agent forwarding
does not reveal private-key bytes, but guest code can request signatures or
authenticate to reachable systems. Git and GitHub configuration may contain
tokens, credential helpers, custom commands, extra HTTP headers, or URL
rewrites. Audit them before mounting.

SSH private keys are never copied by the launcher. SSH metadata mounting and
SSH agent forwarding are separate decisions. A key file committed or copied
inside the selected workspace is still visible because the workspace itself is
the intended read-write capability.

## Explicit run mode and native host execution

The compatibility commands reserve an explicit `run` form, equivalent to the
generic launcher form:

```bash
codex-container run --share-ro /path/to/reference --
agent-container run codex --share-ro /path/to/reference --
```

The legacy `codex-container ...` and `agent-container codex ...` forms do not
start a host broker. `run` is intentionally broader: every guest process that
can read the per-session token can request any command in that session's frozen
host-command manifest. Token authentication rejects clients that do not possess
the session token; it is not a way to distinguish the Agent from untrusted code
the Agent launches inside the same guest.

At launch, the host `PATH` is reduced to safe executable basenames and canonical
paths. Most host commands are fallbacks behind guest command directories, so a
guest-native Linux command wins. `git` is host-first by default. The selected
Agent command, launcher compatibility commands, the Apple `container` command,
and `sudo` are excluded. `--no-host-exec COMMAND` removes another direct host
entry and can be repeated; `--host-first COMMAND` changes an eligible command's
resolution order. These controls govern broker entry points, not a security
boundary: an allowed shell, Node.js/Python interpreter, Git hook, or credential
helper can start another executable. The generated macOS filesystem sandbox
applies to that derived process tree and is the boundary that enforces admitted
read/write roots. `--no-host-exec git`, for example, removes the direct `git`
shim but cannot prevent another allowed host process from starting Git inside
the same sandbox.

The per-session broker itself needs a native Node.js bootstrap before its
generated sandbox exists. The launcher canonicalizes the selected command and
the `process.execPath` it reports, and refuses to execute either from the
workspace, private Agent state, an external writable Git directory, or a
read-write additional share. PATH symlinks that resolve outside their admitted
read-only tool runtime are omitted one basename at a time. A host Node installed
elsewhere remains a trusted launcher dependency; `run` should not be used with a
host toolchain whose ownership or integrity is not trusted.

The broker never evaluates a shell command assembled by the guest. It validates
the token and frozen basename-to-path mapping, preserves the argument vector,
and starts the canonical executable in a new process group under a generated
macOS sandbox profile. Host executable/runtime roots are read-only. The
repository and required external Git directory are read-write. Each additional
canonical directory is admitted with the same `ro` or `rw` mode used for its
guest mount. Unsafe roots, the complete real HOME, overlaps, and paths colliding
with runtime state or assets are rejected. Thus `--share-ro` is enforced on
both sides of the bridge, although it still authorizes reading and possible
network exfiltration. Host runtime roots can be broader than one executable—for
example a Homebrew, nvm, pyenv, or selected Xcode/CommandLineTools installation
tree—and their complete admitted contents are readable even though they are not
writable.

This boundary currently depends on Apple's deprecated `/usr/bin/sandbox-exec`
interface. The launcher refuses to start host-exec without it, but deprecation
means its behavior and availability require validation on each supported macOS
release. The generated profile is a defense-in-depth boundary with a platform
lifecycle risk, not a promise that Apple will preserve this API indefinitely.

Ordinary host commands receive
`~/.agent-container/profiles/<profile>/host-home` as HOME. This avoids ambient
access through the real HOME and keeps their mutable state separate from both
the native macOS tool configuration and the guest's shadow HOME. That directory
persists across sessions for the profile and must itself be treated as mutable
tool state.

Host Git deliberately uses the real host HOME for configuration discovery, but
the sandbox admits only the selected real `.gitconfig` and `.config/git`
configuration inputs rather than the entire directory. It also admits the named
`.ssh/config`, `.ssh/known_hosts`, `.ssh/known_hosts.old`, and
`.ssh/allowed_signers` metadata paths read-only. The broker does not
independently reject a named path merely because
it is a symlink; its target must independently fall within a sandbox-authorized
root, or traversal fails. SSH private-key files are not admitted. Values in the
admitted Git configuration are readable by host Git and can be printed back to
the guest, so secrets must not be stored there casually. Git configuration is
also active behavior, not passive text: aliases, includes, hooks,
credential helpers, filters, signing commands, URL rewrites, and SSH
configuration can cause more native processes, authentication, or network
access. Includes that point outside admitted roots may fail, but should not be
treated as a security policy by themselves.

When a live `SSH_AUTH_SOCK` exists, `run` admits that socket to the broker by
default so host Git and other allowed native tools can authenticate or request
signatures. Private-key bytes are not mounted or copied, but possession of the
socket is authority to use the agent. A configured credential helper may also
be executed. Whether Keychain-backed helpers can access macOS Keychain from the
generated sandbox is platform- and release-dependent and remains a validation
item; do not rely on either success or denial as a stable security guarantee.
Use `--no-host-exec git` to keep the direct `git` command guest-native, and use a
legacy session when no native host process or live host SSH-agent exposure is
acceptable.

The command allowlist and filesystem sandbox do not create a network allowlist.
A permitted native tool may use the host network, and an interpreter such as
Node.js or Python can execute arbitrary program logic with the macOS user's
identity inside the admitted sandbox policy. Review workspace code and every
shared directory before granting this mode.

The broker uses a random 256-bit token and per-session endpoint and manifests.
They are staged with restrictive permissions and exposed read-only to the guest.
Each request is one non-PTY connection with piped stdin and streamed stdout and
stderr. Interactive native programs that require a controlling terminal, raw
mode, or terminal ioctls are unsupported even when the outer Agent has a TTY.

Every request has its own process group. Connection loss terminates that group;
normal launcher cleanup stops the broker and all groups before deleting the
token and manifests. The broker watches the launcher PID as an additional
parent-death control, so an uncatchable launcher exit does not intentionally
leave normal host children or services running. A child that deliberately calls
`setsid` can leave its original process group and evade PGID cleanup; such
daemonization is unsupported, and the broker must not be treated as a durable
service manager or a hostile-process containment boundary. Lifecycle cleanup
also does not undo filesystem writes, network actions, authentication, or
signatures already performed during the session.

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

For a deliberate one-session credential handoff, export an authentication
variable declared by the profile and enable forwarding:

```bash
export OPENAI_API_KEY='...'
AGENT_CONTAINER_FORWARD_API_KEY=true agent-container codex
```

The core forwards only the selected profile's declared variables. For the
built-in profiles these are `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` for
Claude, `OPENAI_API_KEY` for Codex, and `XAI_API_KEY` for Grok. If more than one
declared Claude credential is exported, both names are inherited so Claude can
apply its own precedence rules. Do not put keys or tokens in command-line
arguments, image build arguments, profile JSON, or a repository file.

The credential is still readable by processes in that guest session and can be
sent over the network. Environment forwarding is convenience, not secret
brokerage. `AGENT_CONTAINER_FORWARD_ENV` is an explicit fallback for newly
introduced exact settings, but using it with a secret name grants the same
guest access and does not provide stronger secret handling.

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

Run-mode extra shares must be existing canonical directories. They may not
contain the real host HOME, overlap the workspace, external Git directory,
runtime assets, private state, or one another. The same canonical roots and
access modes feed both the Apple bind mounts and the broker sandbox manifest.

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
  HOME, run-mode extra directories, and opted-in configuration shares;
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

Profiles select official native install scripts that execute in a
network-enabled OCI builder. Treat the profile JSON, official version endpoint,
installer URL, installer response, base image, Debian repositories,
`Containerfile`, and entrypoint as trusted supply-chain inputs. The builder has
no workspace, runtime shadow HOME, API key, SSH, GitHub, or host Git mounts, so
installer code cannot read those session capabilities. It can still modify the
image being built and use outbound networking.

The default base is Debian Bookworm slim's Linux arm64 manifest pinned as
`mirror.gcr.io/library/debian:bookworm-slim@sha256:9b67294679b30e5d6ab257b40594feeb4a4b81f7fcf4131f4decf0d6a212a9b0`.
This prevents that base reference from moving, but the build's unversioned
`apt-get` packages can change. An `AGENT_CONTAINER_BASE_IMAGE` override changes
the trust root and is part of the recipe fingerprint.

Every built-in profile follows a publisher channel. On each launch, the host
fetches Claude's latest version, Codex's latest release JSON, or Grok's stable
version over HTTPS and strictly reduces the response to one exact version. That
version enters the image fingerprint and is supplied to the installer, which
prevents a floating channel name from selecting a different release during the
build. A malformed or unavailable channel fails closed. An exact
`AGENT_CONTAINER_VERSION` skips this request and can reuse a matching warm image
offline; it does not make a missing image build offline.

The build then downloads the current install script from the profile's official
HTTPS URL and executes it as `bash` or `sh` with a private
`HOME=/opt/agent-native`. The script body itself is not digest-pinned by this
project. TLS authenticates the configured host at download time, but does not
make a mutable script URL reproducible or protect against a compromised
publisher. Exact Agent version selection does not pin the installer logic.

The publishers' artifact-integrity behavior is not uniform:

- Claude's native installer obtains release metadata and verifies its selected
  executable against the SHA-256 value in the publisher's manifest.
- Codex's native installer obtains release metadata and a published checksum,
  verifies the downloaded release, and installs a standalone tree whose helper
  binaries and resources must remain adjacent.
- Grok's native installer currently has no checksum or signature verification.
  It checks that the downloaded executable runs and reports a version. The
  image recipe additionally checks Linux arm64 ELF type and exact version, but
  these are consistency checks, not cryptographic provenance. Grok therefore
  relies more heavily on HTTPS and the security of `x.ai`.

For all three Agents, the image recipe rejects a command that escapes the
controlled install root, rejects a non-ELF or non-arm64 command, and rejects a
version-probe mismatch. Claude and Grok are copied into the final image as one
ELF each because neither requires an adjacent installer tree. Codex retains its
complete versioned standalone directory so stripping adjacent helpers cannot
create a subtly incomplete installation. Claude's ELF still depends on the
glibc supplied by the pinned Debian base; Grok's ELF is statically linked.
These layout checks do not replace publisher signatures or checksums.

Profiles are data rather than shell and their URLs, shells, environment names,
commands, and version formats are constrained. The shared recipe additionally
binds every built-in ID to its expected official installer contract. Schema
validation prevents several injection and redirection classes; it is not
software attestation.

At runtime, Claude receives `DISABLE_AUTOUPDATER=1` and Grok receives
`GROK_DISABLE_AUTOUPDATER=1`. Their installed ELF therefore changes through the
host's channel resolution and provenance-tracked image rebuild, not through an
in-session updater. The persistent shadow HOME still contains mutable login
state, settings, plugins, and caches; preserving it across image replacement is
intentional and those contents remain part of the runtime trust boundary.
