# Security model

## Objective and trust assumptions

`agent-container` reduces the ambient macOS authority available to an Agent CLI
by running it in an Apple Containerization Linux Micro-VM. It preserves a
selected project, a profile-specific persistent HOME, terminal behavior, and
normal network access. It does not promise that data intentionally exposed to
the Agent remains safe.

The following are trusted:

- the macOS account and another process already running as that account;
- installed launcher/runtime assets;
- Apple's `container` services and supported macOS system executables;
- the selected profile, image recipe, base image, publisher endpoints, and
  publisher installer;
- explicit launcher options and files the user chooses to expose.

The Agent, repository contents, prompts, generated commands, plugins, and
downloaded runtime content may be hostile or mistaken. The design aims to keep
their default filesystem authority narrower than the macOS account.

Another same-user host process can already edit the project, inspect the user's
processes, replace user-owned state, or invoke Apple's CLI. This project is not
an isolation boundary between mutually hostile macOS processes.

## Default trust boundary

The default path keeps one VM per profile and host UID. Multiple clients of
that profile share:

- one guest kernel and container root filesystem;
- one Linux numeric UID/GID and process table;
- one mutable profile HOME;
- one VM network namespace and resource allocation.

Each client separately receives:

- its own Agent process and arguments;
- its own stdin/stdout and TTY decision;
- its own host workspace broker and random token;
- its own host-tool broker and random token, unless
  `--no-container-host-tools` is selected;
- its own private guest mount namespace and SSHFS mount;
- its own current working directory and exit status.

A private mount namespace means project B is not present in project A's normal
path view merely because both clients use one VM. It is not a strong security
boundary against a malicious same-profile peer: same-UID processes share a
kernel and `/proc`, may signal or inspect one another subject to Linux policy,
and can influence the shared profile HOME. Treat all concurrent repositories
inside one profile as mutually trusted. Use separate macOS accounts or another
strong isolation layer for hostile projects.

The persistent container's primary process is only a lifetime anchor. Every
Agent invocation is new. No Agent-specific background process receives broader
workspace access, and no Agent sandbox mode is changed by the container
lifecycle.

## Filesystem exposure by default

The Agent can read and write:

- the current Git top-level directory, or cwd outside Git, through that
  invocation's SSHFS mount;
- its profile's isolated shadow HOME;
- normal writable paths in the persistent Linux container root.

The Agent does not receive by default:

- the real macOS HOME as a whole;
- another profile's HOME;
- project roots used by other clients as ordinary mounts;
- host SSH private-key files or the SSH-agent socket;
- arbitrary host environment variables;
- native host-command execution beyond the sandboxed host-tool channel
  described below.

Through that default channel, host `git` runs with the real Git configuration
(including credential helpers, includes, and HTTP headers) and host `gh` runs
with readable GitHub CLI configuration. This is a deliberate authority grant:
an Agent-driven `git push` or `gh` call carries the operator's identity and
credentials, confined to the workspace-scoped host sandbox. Every other
cataloged host command runs with an isolated execution HOME instead of the
real one. `--no-container-host-tools` removes the channel entirely.

The workspace is intentionally read-write. The Agent and code it executes can
modify or delete tracked and untracked files, replace hooks, and write secrets
into the repository. Micro-VM isolation does not protect data that crosses its
boundary deliberately.

The shadow HOME uses the same guest path string as the real HOME but has a
different host source below `~/.agent-container/profiles/<profile>/home`.
Credentials, settings, plugins, histories, and caches stored there survive
client exit and singleton stop. Persistence is useful and also means a
compromised session can affect later sessions of that profile.

## Dynamic workspace broker

### Authentication and lifetime

One Rust broker is created for one client. Before publishing an endpoint it:

- canonicalizes an existing directory and rejects `/`;
- verifies fixed macOS system executables;
- reads 256 random bits from `/dev/urandom`;
- binds the inspected Apple gateway on an ephemeral IPv4 port.

The broker accepts one TCP connection, waits at most 30 seconds for it, and
requires the exact versioned authentication frame within one absolute
five-second deadline and 100-byte limit. Comparison covers the complete frame.
An invalid or late connection consumes the one attempt and terminates the
broker, limiting brute-force and protocol-confusion behavior.

The token is transferred to the root setup helper only for connection setup,
is not embedded in a process argument, and is unset before the unprivileged
Agent starts. It is still a short-lived secret available to trusted launcher
and setup processes. Another same-user macOS process is already within the host
trust assumption and could interfere with local networking or process state.

Broker authority is also bound to the host runtime's lifetime. Only that
runtime retains the writer of an unlinked private pipe. The runtime closes fd 7
in both the Rust broker process and Apple CLI child; the broker owns fd 8 as a
close-on-exec reader. EOF, read error, or unexpected data revokes the broker
fail-closed.
Before attach this stops acceptance, and after attach it shuts down both halves
of the active TCP stream. A normally exiting, signalled, or `SIGKILL`ed host
runtime therefore cannot leave its workspace endpoint or authenticated stream
alive.

### macOS sandbox

After authentication, the broker starts exactly
`/usr/libexec/sftp-server -e -d ROOT` through `/usr/bin/sandbox-exec`. The
profile begins with `deny default`, imports the minimum system baseline, denies
network access, permits the fixed SFTP executable, and grants file read/write
only below the canonical workspace plus ancestor traversal metadata.

Workspace text is not interpolated into the sandbox language. It is supplied
as a profile parameter and as an `OsString` argument. This prevents quote
injection and avoids lossy argument conversion. Symlink traversal is still
subject to the sandbox's resolved filesystem policy, so a symlink in the
workspace does not authorize an outside target.

The Rust parent remains outside that sandbox to own the TCP endpoint and relay
bytes. It does not parse requested paths, execute a shell, or expose a general
command protocol. Compromise of the SFTP child should therefore encounter the
macOS root restriction; compromise of the Rust parent would be host-native and
is inside the installed-launcher trust assumption.

Apple has deprecated `sandbox-exec`. The profile is tested against each
supported macOS release and the broker fails closed if required fixed system
components are absent. Deprecation means Apple can change or remove this
boundary in the future.

### Guest mount setup

The root helper creates a private mount namespace before mounting. It rejects
non-canonical roots/cwds, protected guest trees, an occupied or nonempty
mountpoint, unexpected filesystem types, and a cwd that resolves through a
workspace symlink or outside the root. SSHFS connects through a fixed root-owned
transport helper and FUSE device.

After readiness, the helper places the Agent session leader in a private,
root-owned cgroup v2 leaf. `setpriv` then starts the profile executable with the
host numeric UID/GID, cleared supplementary groups, and `no_new_privs`. The
executable must be root-owned, executable, not group/other-writable, and outside
the writable workspace. The helper never recursively changes host ownership.

Cleanup freezes the Agent leaf, sends TERM to that stable membership snapshot,
unfreezes it for a one-second grace period, then uses `cgroup.kill` and waits
for the leaf to report `populated 0`. Freezing prevents PID reuse between
membership enumeration and signalling, and the leaf also contains descendants
that deliberately create another process group/session or double-fork. Only
after the complete Agent tree is gone does cleanup terminate SSHFS, unmount
FUSE, and remove helper-created state. Loss of the authenticated host broker
terminates the guest transport and enters the same cleanup path.
Host-launcher `SIGKILL` is covered by the owner-liveness EOF path: it revokes
the stream, SSHFS exits, and the still-running root helper performs the cgroup
and mount cleanup. Direct `SIGKILL` of that guest root helper is different: it
can still prevent the helper itself from running cleanup, so the containing
`container exec`, transport lifetime, and next lifecycle reconciliation remain
important. A persistent VM should not be interpreted as a durable workspace
mount.

## Default host-tool broker

Each singleton client may also start one host-tool broker: the same
authenticated Node.js broker legacy `run` uses, loaded with the complete host
command catalog. The launcher freezes the ordered host `PATH` directories and
the deny/first policy into a catalog specification, declares one writable
execution root — the canonical workspace — and stages a fresh 256-bit session
token. The broker expands the specification into the validated manifest
in-process: every executable is canonicalized inside an admitted tool root,
Agent binaries, launcher commands, `container`, and `sudo` are always denied,
and Agent-writable paths are excluded. The guest session helper retrieves the
catalog from the authenticated broker and creates per-session shims and
credential files inside the client's private runtime directory; the token
travels by environment name, never in an argument vector, and the shims are
invisible to other clients. Host-first names (`git`, `gh`, and explicit
`--container-host-exec-first` additions) precede the guest PATH; every other
name sits behind it and is used only when the guest image lacks the command.

The command list is convenience surface, not the security boundary; the
generated sandbox is. Every proxied process runs under a generated
`deny default` `sandbox-exec` profile whose writable filesystem scope is the
workspace root plus the isolated broker execution HOME. Only `git` and `gh`
run with `HOME` set to the real home — so host credential helpers and the
GitHub CLI login behave exactly as in a host terminal, with additional reads
limited to `~/.gitconfig`, XDG Git configuration, SSH metadata (never
private-key files), and `~/.config/gh`. Every other cataloged command runs
with the isolated execution HOME and cannot read real-home dotfiles or stored
credentials through the sandbox. The broker authenticates every request,
polls its launcher PID, and exits when the client ends, so the channel cannot
outlive the terminal that created it.

When the launching terminal exports a live `SSH_AUTH_SOCK`, the broker
environment carries that one socket path and supplies it to exactly the
identity commands above, so sandboxed host `git` authenticates to SSH remotes
through the operator's agent: signatures only, never key bytes, and key files
stay unreadable. Generic cataloged commands keep an agent-free environment.
While a client runs, guest-driven `git` therefore holds the same remote
authentication authority as the operator's own terminal — an agent is a
signing oracle, and a hostile workload could push or fetch anywhere that
authority reaches. `--no-container-host-ssh-agent` withholds the socket from
the broker; an explicit `--container-host-ssh-agent` fails closed when no
live agent socket exists. The socket path crosses into neither the guest nor
the singleton configuration fingerprint through this per-client path;
mounting the socket into the VM itself remains the separate static
`--container-forward-ssh-agent` capability below.

This remains an explicit host-code-execution capability with the same caveats
as legacy `run`: cataloged interpreters and shells (and interpreters reachable
through Git hooks or credential helpers) execute as the macOS user inside the
declared scope, and `sandbox-exec` is a deprecated Apple interface. Broadening
the catalog beyond git/gh did not change the boundary type — a two-command
git channel already reached arbitrary host execution through aliases and
hooks — but it does widen read access to the admitted tool roots and make the
capability the everyday path; `--container-host-exec-deny` narrows it, and
`--no-container-host-tools` never creates the broker. When the broker runtime
is unavailable the default launch degrades to guest binaries with one
warning; an explicit `--container-host-tools` fails closed instead.

## Identity and Linux privilege

Apple volume mounts have no UID/GID translation. The runtime creates or adjusts
one guest passwd/group entry for the host numeric identity and starts Agents
under it. This preserves ownership of workspace writes without `chown -R` on
host data.

`CAP_SYS_ADMIN` is present on the persistent container so the trusted root
session helper can create FUSE mounts and namespaces. The Agent process is not
started as root and receives `no_new_privs`, but it shares a container with that
root setup path. This is a broader in-guest boundary than a VM whose complete
process tree is permanently unprivileged. The root-owned helper and executable
path validation are part of the trusted computing base.

Linux UID matching does not grant access to the real HOME because it is not
mounted. It does grant the expected read/write permissions on the selected
workspace and shadow HOME.

## Network boundary

Apple's standard container network gives the VM ordinary outbound access. The
project does not currently enforce a hostname allowlist, DNS allowlist, or
egress firewall. Proxy, DNS, and CA policy is accepted only through leading
`--container-*` launcher options; exported proxy or CA configuration is not
implicitly adopted. A proxy or DNS option changes connectivity, and an added
CA changes trust. None confines destinations.

The Agent can therefore exfiltrate any readable workspace, profile credential,
forwarded environment value, or opted-in configuration over the network. Agent
approval and sandbox features remain valuable defense in depth, but the
launcher does not inject a permission bypass and does not override a profile's
own sandbox setting.

`host.docker.internal` is not an Apple-container address and is rejected.
Apple's optional `host.container.internal` DNS/PF bridge requires administrator
action, disables Private Relay while configured, and loses its redirect after a
restart. The launcher never creates that host-wide change.

## Environment and credentials

There is no prefix-wide or reviewed-list host environment inheritance. No
Claude, Anthropic, provider, endpoint, model, token, or Agent setting crosses
the boundary automatically. Loader variables, path control, launcher
internals, HOME, shell state, and other dangerous names are rejected even when
requested.

Profile login state in the shadow HOME is the default authentication path.
Credential and setting forwarding is explicit:

- `--container-forward-api-key` is off by default and forwards only the
  exported variable named by the active profile's single `apiKeyEnv` field;
- `--no-container-forward-api-key` explicitly disables that capability;
- `--container-forward-env NAME1,NAME2` authorizes each additional exported
  provider endpoint, model, alternative token, or Agent setting by exact name.

`--container-forward-env` accepts names, not assignments. A secret must first
be exported, then authorized as a name; `NAME=VALUE` syntax is invalid. Only
the names are serialized into launcher and Apple CLI argument vectors. Values
are transferred separately, but are fully readable and exfiltratable by the
Agent and anything it can execute.

## Static Git, GitHub, and SSH capabilities

The host-tool broker above is the default credential path and is per-client.
The static capabilities below instead change what the guest environment itself
receives; they matter for guest tools that embed Git and whenever
`--no-container-host-tools` is selected.

The default staged guest Git file contains only host `user.name` and
`user.email`. The following leading launcher flags expand authority:

| Capability | Exposure |
|---|---|
| `--container-full-git-config` | Full selected `.gitconfig` and XDG Git configuration, including possible credentials, helpers, headers, includes, and URL rewrites |
| `--container-mount-gh` | Read-only GitHub CLI configuration, commonly including a usable token |
| `--container-forward-ssh-agent` | Live signing/authentication authority through the agent socket; no key files |
| `--container-mount-ssh-config` | Copied `config`, `known_hosts`, `known_hosts.old`, and `allowed_signers`; no private keys |

Read-only means the Agent cannot modify the mounted source through that path;
it can still read, use, copy, or exfiltrate it. SSH-agent forwarding can
authorize remote authentication or signatures without revealing private-key
bytes.

These mounts/socket choices are established when the persistent container is
created and enter its configuration fingerprint. A later invocation cannot
silently add or change them. Stop and recreate the profile to change the
policy. Because every client shares the VM, a static capability enabled for
that singleton belongs to the profile trust boundary, not only to the terminal
that requested it.

## Advanced legacy `run` boundary

`run` is a separate explicit authorization for a broader, short-lived path. It
uses Apple volumes for the project and additional shares and can route selected
commands to a native macOS host-command broker. It requires stopping the same
profile's singleton first.

The broker freezes eligible host executable paths and tool roots in manifests,
authenticates requests, executes without a shell, and applies a generated macOS
filesystem sandbox to the native process group. The selected Agent,
compatibility commands, Apple `container`, and `sudo` are never exposed as host
commands. Users can remove more names or prefer a selected host command through
`run` options.

The command catalog and execution properties match the default host-tool
channel; what `run` adds beyond the default's single writable workspace root
is scope:

- read-write shares authorize modification or deletion of additional trees;
- a worktree's external Git common directory can be admitted read-write;
- the workspace itself is a VirtioFS mount rather than per-client SFTP.

As in the default channel, a native interpreter or shell runs as the macOS
user, an allowed process can start children within the sandbox, host Git and
gh can use selected real configuration and a live SSH agent, the transport is
pipe-only with no controlling PTY, and deliberately detached descendants can
escape a process-group lifetime contract.

The host-command sandbox, token, and manifest narrow the capability but do not
make native execution harmless. Omitting `run` avoids creating this broker.

## State and cleanup safety

Managed paths are canonicalized, kept below the real HOME, checked for unsafe
symlinks, and required to carry ownership markers before nonempty adoption.
Private state may not overlap workspaces or explicit shares. Staging uses a
restrictive umask and is removed when its client ends.

Container names are not ownership evidence. Image and container operations use
recorded references plus exact project labels, host UID, profile, creator PID,
mode, image digest, configuration hash, and runtime state. On ambiguous native
errors, the launcher retains the resource rather than deleting something it
cannot prove it owns.

Installer, uninstaller, launch, and singleton stop share a two-layer lifecycle
gate:

- a BSD kernel lock on an open descriptor for the canonical HOME inode;
- a directory record containing the exact PID and a random owner token.

Synchronous child operations inherit the descriptor, so killing a parent does
not admit another mutation while its child still runs. Owner-aware stale state
can be quarantined only while holding the kernel lock. Malformed, substituted,
or older ambiguous lock records fail closed.

Cold singleton creation holds the gate until the detached container has passed
running-state inspection and ready state is durable. A racing client waits and
then revalidates. `singleton stop` takes the same lock and verifies full
provenance before deletion. Profile HOME survives stop and non-purge uninstall.

These controls protect cleanup and accidental path expansion. They do not
protect data already exposed to a compromised guest or another trusted
same-user host process.

## VirtioFS host risk

Apple [`container#1097`](https://github.com/apple/container/issues/1097)
reports retained host file descriptors during large VirtioFS scans, including
application failures and a kernel panic. The default project is transported by
SFTP/SSHFS rather than a persistent Apple volume, substantially narrowing the
large-workspace trigger.

VirtioFS remains for the isolated profile HOME and selected static
configuration mounts. Legacy `run` also uses it for the project and extra
shares. The runtime retains:

- a configurable entry budget, default 40,000, for relevant mounted trees;
- projected host file/per-process-file/vnode preflight;
- a live file/vnode watchdog for the attached legacy `run` lifecycle, with a
  default stop threshold of 80%;
- verified named containers and signal cleanup.

A default singleton outlives its client launcher, so it cannot retain that
client-owned live watchdog after disconnect. File-count and projected-capacity
checks still run before client attachment. This residual risk is one reason to
keep shadow HOME and static mounts small and to stop unused profile VMs.

The following flags weaken those controls and are intended for controlled
testing:

```bash
codex-container \
  --container-accept-virtiofs-risk \
  --container-disable-fd-watchdog
```

`--container-allow-concurrent` concerns overlapping legacy `run` VMs and also
requires explicit VirtioFS risk acceptance. Normal per-profile singletons can
coexist because their dynamic projects are not persistent Apple volumes, but
each still contributes its profile HOME and static mounts. There is no proven
universally safe threshold.

## Extra certificate authorities

`--container-extra-ca auto` is the default. It is not TLS bypass. macOS Security
must first verify each known endpoint and hostname. For the installer endpoint
and, only for floating-version resolution, the version endpoint, the launcher
selects a currently-valid issuer whose Basic Constraints explicitly contain
`CA:TRUE`. Any explicit bundle must be selected through
`--container-extra-ca /absolute/path.pem`; an exported path is not treated as
container policy.

The resulting trust is scoped during transport:

- the version-chain issuer is used only for the host channel request;
- the installer-chain issuer becomes a BuildKit secret and is installed into
  the guest trust store;
- the complete Keychain is not copied or synchronized;
- the two selected issuers may differ.

An explicit bundle is a broader user trust decision. It must be a non-symlink
regular file no larger than 1 MiB containing 1–64 currently-valid CA
certificates. The launcher checks `notBefore`, `notAfter`, Basic Constraints,
and stable source/staged digests. It never uses `-k` or `--insecure`.

Once installed, a CA can authenticate certificates for every guest application
using Debian's system store, not only the installer. An enterprise interception
issuer may therefore observe or alter Agent API, Git HTTPS, plugin, and other
guest TLS traffic. Treat an explicit CA as broad network trust.

The facility cannot cover every bootstrap hop. OCI `FROM` resolution happens
before the BuildKit secret is available, and the current apt bootstrap happens
before guest CA installation. Redirects, CDNs, and installer-internal downloads
may also use endpoints not represented by automatic mode.

Error classes must remain distinct:

- `curl: (60)` is certificate-chain verification failure;
- HTTP `403` means TLS succeeded and an origin or enterprise authorization
  policy denied the URL.

A 403 requires the documented publisher domain to be admitted through the
organization's allowlist process. Adding another CA or disabling verification
cannot legitimately solve it.

## Image and publisher supply chain

The builder executes a publisher-provided script with outbound network access.
It has no workspace, runtime profile HOME, API key, SSH, GitHub, or host Git
mount. It can still change the image and contact the network.

The default base image is pinned by digest, but Debian packages and mutable
publisher script URLs are not bit-for-bit pinned. Resolving a channel to an
exact Agent version prevents the floating channel from moving between host
resolution and installer selection; it does not attest mutable installer logic
or a compromised publisher.

Publisher integrity behavior differs:

- Claude's installer verifies its selected executable against publisher
  release metadata;
- Codex verifies the standalone release and retains required adjacent helpers;
- Grok currently depends more heavily on HTTPS and exact-version/ELF
  consistency checks.

The shared recipe rejects commands outside the controlled install root,
non-Linux/non-arm64 executables, and version mismatches. Those checks catch
layout and consistency errors, not every supply-chain compromise.

At runtime, declared Agent auto-updaters are disabled so executable updates
arrive through channel resolution and image replacement. Mutable profile HOME
contents remain intentionally outside the immutable image identity.

## Other upstream limitations

- [`container#165`](https://github.com/apple/container/issues/165): no Apple
  bind-mount UID/GID translation.
- [`container#141`](https://github.com/apple/container/issues/141): unreliable
  VirtioFS host edit notifications; SSHFS/FUSE has separate watcher semantics.
- `sandbox-exec` is a deprecated macOS interface.

These limitations require release-by-release validation; the launcher can
reduce their impact but cannot repair the platform.
