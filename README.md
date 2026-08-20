# agent-container

Run Claude Code, Codex CLI, and Grok CLI in lightweight Linux Micro-VMs on an
Apple silicon Mac. The normal path keeps one persistent Apple container for
each `(profile, macOS UID)` pair and starts a fresh Agent process for every
terminal with `container exec`.

```text
agent-container [launcher options] <profile> [agent arguments...]
claude-container [launcher options] [claude arguments...]
codex-container  [launcher options] [codex arguments...]
grok-container   [launcher options] [grok arguments...]

agent-container singleton status <profile>
agent-container singleton stop <profile>
```

The default invocation needs no launcher options:

```bash
cd /path/to/project-a
grok-container
```

Opening another project does **not** start a second Grok VM:

```bash
# Terminal 1
cd /path/to/project-a && grok-container

# Terminal 2
cd /path/to/project-b && grok-container
```

Both commands use `agent-grok-<uid>-singleton`, but each receives an independent
Grok process, stdin/stdout, TTY, current directory, workspace transport, and
exit status. Claude and Codex use the same execution model. This is VM reuse,
not an Agent-specific background service: there is no shared Grok process and
no Agent-specific lifecycle or sandbox change.

## Runtime model

The selected Agent is a native `linux/arm64` executable inside an Apple
Containerization Micro-VM. It is not a macOS Mach-O process. The persistent VM
provides:

- one inspected image and writable guest root per profile and host UID;
- one isolated, persistent profile HOME for login, settings, history, and
  caches;
- normal outbound guest networking;
- multiple concurrent `container exec` clients, each with its own TTY and cwd.

The real macOS HOME is never mounted wholesale. If the host HOME is
`/Users/alice`, the guest uses the same path string, but its contents come from
`~/.agent-container/profiles/<profile>/home`, not `/Users/alice` itself.

Apple `container` 1.2 cannot add a bind mount to a running container. The
default path therefore does not pre-mount project A, project B, a common parent,
or a configured root list. For each invocation, the launcher:

1. resolves the current Git top-level directory, or the current directory when
   outside Git;
2. starts a one-connection Rust workspace broker on macOS;
3. starts `container exec` in a private guest mount namespace;
4. mounts that one host project at the same absolute path through SSHFS and raw
   SFTP;
5. changes to the caller's original cwd and starts a fresh Agent process as the
   host numeric UID/GID;
6. unmounts the workspace and exits the broker when that Agent process ends.

This makes project switching dynamic. No root registration, root environment
variable, or singleton restart is needed when moving between ordinary Git
repositories.

The private mount namespace prevents one client's SSHFS mount from appearing in
another client's normal filesystem view. Clients of the same profile still
share a VM, Linux UID, process table, and mutable profile HOME, so they must be
treated as one trust boundary. Use a separate macOS account or a separately
isolated workflow for mutually hostile projects.

## Requirements

- Apple silicon Mac
- macOS 26 or newer
- Apple [`container` 1.2.0+](https://github.com/apple/container/releases)
- Apple's `container` CLI installed (the launcher starts its per-user services
  automatically when needed)

## Installing and updating Apple `container`

`container` is available in [Homebrew core](https://formulae.brew.sh/formula/container)
and requires the same Apple silicon Mac on macOS 26 or newer:

```bash
brew install container    # install
brew upgrade container    # update to the latest release
```

Alternatively, download Apple's signed package (1.2.0 or newer) from the
[`container` releases page](https://github.com/apple/container/releases) and
install it manually.

After installing or updating, verify the version and service state:

```bash
container --version
container system status
container system start
```

You normally do not need to run `container system start` yourself. Every Claude,
Codex, or Grok launch checks the service, starts it once when it is stopped, and
verifies that it became ready before touching images or singleton containers.

`agent-container` does not install, upgrade, or reconfigure Apple's service.
Updating Apple `container` does not require rebuilding profile images: each
launch revalidates its recorded image recipe and rebuilds only when the recipe
changes.

## Install agent-container

### Homebrew (recommended)

This repository is its own Homebrew tap:

```bash
brew tap loadchange/agent-container
brew install agent-container
```

Updates follow normal Homebrew flow — the release pipeline refreshes the
formula on every published release:

```bash
brew upgrade agent-container
```

The formula installs the prebuilt launcher and runtime assets under the
Homebrew prefix; `agent-container`, `claude-container`, `codex-container`, and
`grok-container` are linked into your PATH automatically. Apple's `container`
CLI is not pulled in as a dependency (install it as shown above if it is not
already present).

### curl | bash

Install or atomically upgrade all three profiles:

```bash
curl -fsSL https://raw.githubusercontent.com/loadchange/agent-container/main/install.sh | bash
```

Add the installed command directory to the current shell and `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
agent-container profiles
```

Select a smaller managed profile set with repeatable `--profile` options:

```bash
installer_url='https://raw.githubusercontent.com/loadchange/agent-container/main/install.sh'

curl -fsSL "$installer_url" | bash -s -- --profile grok
curl -fsSL "$installer_url" | bash -s -- --profile claude --profile codex
curl -fsSL "$installer_url" | bash -s -- --all
```

The installer downloads the latest
[GitHub Release](https://github.com/loadchange/agent-container/releases)
tarball and its SHA-256 manifest, validates every asset, publishes the release
below `~/.local/share/agent-container/releases/`, and atomically switches
`current`. Re-running it with a different selection removes only commands and
profile assets whose ownership it can prove. If a deselected profile still has a
managed singleton, stop that profile before changing the selection:

```bash
agent-container singleton stop grok
```

`--base-url` remains available for an internal mirror; it must serve
`release-manifest.sha256` and the release tarball. It replaces the removed
installer environment variable.

### From source

Build the reproducible release locally, then install from the staged `dist/`
layout (the installer picks it up automatically):

```bash
scripts/build-release.sh
./install.sh --all
```

The native launcher is never committed to git; it is built twice, stripped,
ad-hoc signed, and byte-compared before it is staged.

## Built-in profiles

| Profile | Command | Official native installer | Publisher channel | Status |
|---|---|---|---|---|
| `claude` | `claude-container` | `https://claude.ai/install.sh` | Claude `latest` | preview |
| `codex` | `codex-container` | `https://chatgpt.com/codex/install.sh` | Codex `latest` | preview |
| `grok` | `grok-container` | `https://x.ai/cli/install.sh` | Grok `stable` | preview |

All three profiles are enabled normally; Grok needs no special opt-in. The host
resolves a floating publisher channel to one exact version before deciding
whether an image is reusable. Claude and Grok install one native ELF; Codex
retains its complete standalone tree because its executable depends on adjacent
helpers and resources. Node.js and npm are not installed in the normal Agent
image.

The first invocation may build the image and create the profile singleton. A
version probe is a convenient prebuild:

```bash
claude-container --version
codex-container --version
grok-container --version
```

The container remains available after the command exits. The Agent process does
not.

## Login and normal use

Authentication is stored in the selected profile's isolated HOME:

```bash
claude-container auth login
codex-container login --device-auth
grok-container login --device-auth
```

Then enter any repository:

```bash
cd /path/to/repository
claude-container
```

Arguments are passed to the native Agent without shell reconstruction. Launcher
options are recognized only at the beginning of the command. The first normal
Agent argument ends launcher parsing, and a leading `--` explicitly ends it:

```bash
codex-container --container-cpus 6 --container-memory 8g -- --agent-option
agent-container --container-cpus 6 codex --agent-option
```

Use `--` when an Agent itself ever defines an option beginning with
`--container-`.

## Multi-project singleton lifecycle

The stable native identity is:

```text
agent-<profile>-<host-uid>-singleton
```

One user can therefore have up to one managed Claude VM, one Codex VM, and one
Grok VM at the same time. Multiple terminals may attach to each one. Inspect or
stop them independently:

```bash
agent-container singleton status claude
agent-container singleton status codex
agent-container singleton status grok

agent-container singleton stop claude
agent-container singleton stop codex
agent-container singleton stop grok
```

`stop` deletes the verified container but preserves the profile image and
profile HOME. The next invocation recreates the singleton. A stopped or
malformed native resource is never adopted only because its name matches; full
labels, image digest, state, and managed records must agree.

VM, image, network, CA, and static capability choices are fingerprinted. If a
running singleton differs from newly requested settings or a publisher channel
has moved, stop that profile and launch it again. The launcher fails closed
instead of silently attaching to a differently configured VM.

### Linked worktrees

The dynamic default transports one Git root. A linked worktree whose Git common
directory is outside that root currently needs the advanced `run` path, which
can mount both paths with Apple volumes. Stop the profile singleton first:

```bash
agent-container singleton stop codex
codex-container run --
```

Ordinary repositories, nested directories, and switching between unrelated Git
roots need no special configuration.

## Workspace transport and semantics

The default workspace channel is not SSH login. The Rust broker generates a
random 256-bit token, binds one ephemeral TCP port, accepts one connection, and
requires a bounded authentication line within five seconds. It then runs
`/usr/libexec/sftp-server` inside a default-deny macOS `sandbox-exec` profile
whose writable filesystem scope is the canonical project root. The broker does
not start a shell, accept commands, expose HOME, or provide a reusable daemon.

The guest's SSHFS transport sends the authentication frame and then forwards an
unmodified SFTP byte stream. The token is not placed in an argv vector and is
cleared before the Agent starts. The SFTP mount is created only in that exec's
private mount namespace. Each Agent tree also receives an independent process
group and root-owned cgroup v2 leaf. Exit, signal, or broker loss removes the
whole tree—including detached background descendants—before SSHFS is stopped
and the private mount is removed.

The host runtime is also the broker's explicit owner. It alone retains the
write end of a private liveness pipe; the broker owns a close-on-exec reader,
and the Apple `container exec` child does not inherit the writer. Normal exit,
a handled signal, or `SIGKILL` of that launcher therefore produces EOF. The
broker fails closed, stops accepting, and shuts down an active TCP stream. The
guest observes transport loss and runs the same SSHFS/cgroup cleanup. This
revokes only that client workspace: the profile singleton and concurrent
clients remain running.

Files created by the Agent use the host numeric UID/GID. The mount is
read-write: the Agent can read, modify, rename, or delete anything in the
selected project. SSHFS caching is intentionally short, but remote/FUSE
semantics are not identical to a native APFS directory. File-watch tools should
be tested and may need polling or a restart after host-side edits.

## Configuration: `--container-*`

Normal use requires no configuration. Public launcher settings are command-line
options handled by the Rust launcher; users should not export internal runtime
variables, and legacy public runtime-variable names are rejected. Value options
accept either `--name VALUE` or `--name=VALUE`.
Boolean options use `--container-<name>` and `--no-container-<name>`.

### Runtime, build, and network values

| Option | Default | Purpose |
|---|---|---|
| `--container-cpus VALUE` | `4` | CPUs assigned to the profile singleton |
| `--container-memory VALUE` | `4g` | Memory assigned to the profile singleton |
| `--container-build-cpus VALUE` | `4` | CPUs for Apple's shared image builder when created |
| `--container-build-memory VALUE` | `4g` | Memory for Apple's shared image builder when created |
| `--container-version VALUE` | profile channel | `latest` or one exact native version |
| `--container-base-image VALUE` | pinned Debian Bookworm slim digest | Alternate safe OCI base or mirror reference |
| `--container-http-proxy VALUE` | unset | Builder and guest HTTP proxy |
| `--container-https-proxy VALUE` | unset | Host HTTPS channel, builder, and guest HTTPS proxy |
| `--container-all-proxy VALUE` | unset | Host channel fallback, builder, and guest all-protocol proxy |
| `--container-no-proxy VALUE` | `localhost,127.0.0.1` | Host channel, builder, and guest proxy bypass list |
| `--container-extra-ca VALUE` | `auto` | macOS-verified-chain bridge or an absolute reviewed PEM bundle |
| `--container-dns1 VALUE` | unset | Primary build/guest DNS server |
| `--container-dns2 VALUE` | unset | Secondary build/guest DNS server |
| `--container-timezone VALUE` | unset | Guest `TZ`, such as `Asia/Singapore` |
| `--container-forward-env VALUE` | unset | Comma-separated exact exported names for provider, model, token, or Agent settings |
| `--container-host-alias VALUE` | unset | Comma-separated guest DNS names mapped to the Apple host gateway while preserving URL/SNI |
| `--container-block-host VALUE` | unset | Comma-separated guest DNS names mapped to IPv4 and IPv6 blackholes |
| `--container-max-files VALUE` | `40000` | Safety budget for remaining VirtioFS-backed trees and legacy `run` shares |
| `--container-fd-stop-percent VALUE` | `80` | Legacy `run` file/vnode watchdog threshold, from 50 through 95 |

### Boolean capabilities and controls

| Option | Default | Purpose |
|---|---|---|
| `--container-enable-experimental` | off | Permit an installed custom profile whose schema status is experimental; no current built-in profile needs it |
| `--container-rebuild` | off | Force a no-cache, pull-refresh image rebuild |
| `--container-skip-build` | off | Refuse to build; require a matching warm image |
| `--container-full-git-config` | off | Expose the full selected host Git configuration instead of only identity |
| `--container-mount-gh` | off | Mount host GitHub CLI configuration read-only |
| `--container-forward-api-key` | off | Forward only the active profile's exported `apiKeyEnv` |
| `--container-forward-ssh-agent` | off | Forward the live SSH-agent socket; never mounts private keys |
| `--container-mount-ssh-config` | off | Copy selected SSH metadata into a read-only staged mount |
| `--container-accept-virtiofs-risk` | off | Continue past selected Apple VirtioFS risk checks |
| `--container-allow-concurrent` | off | Permit overlapping legacy `run` VMs; also requires risk acceptance |
| `--container-disable-fd-watchdog` | off | Disable the legacy `run` live file/vnode watchdog for controlled testing |

Every boolean has a negative form, for example
`--no-container-full-git-config`. Repeated settings use the last value.
Unknown leading `--container-*` names fail as likely typos.

### Development and diagnostic values

These options exist for source development, mirrors, and deterministic tests;
ordinary users should not need them:

| Option | Purpose |
|---|---|
| `--container-assets PATH` | Select another complete runtime asset directory |
| `--container-bin PATH` | Select another Apple `container` executable |
| `--container-host-broker PATH` | Select the advanced `run` host-command broker |
| `--container-host-node PATH` | Select the host Node.js executable used by advanced `run` |
| `--container-host-gateway IPv4` | Override the inspected Apple network gateway |
| `--container-openssl PATH` | Select the host OpenSSL executable used for CA validation |
| `--container-security PATH` | Select the macOS Security executable used by `--container-extra-ca auto` |

## Environment and credential forwarding

The launcher does not copy the complete host environment, and it does not
automatically inherit Claude, Anthropic, provider, model, token, or Agent
settings. Login state in the profile HOME remains the default authentication
path.

`--container-forward-api-key` is off by default. Enabling it expands exactly
the active profile's declared
`apiKeyEnv`: `ANTHROPIC_API_KEY` for Claude, `OPENAI_API_KEY` for Codex, or
`XAI_API_KEY` for Grok. It does not discover alternative token names or
provider bundles.

```bash
export XAI_API_KEY='...'
grok-container --container-forward-api-key
```

Every provider endpoint, model selection, alternative token, and Agent setting
must instead be exported and named explicitly with `--container-forward-env`.
For example, an Anthropic-compatible GLM endpoint can be selected with:

```bash
export ANTHROPIC_BASE_URL='https://open.bigmodel.cn/api/anthropic'
export ANTHROPIC_AUTH_TOKEN='replace-with-provider-token'
export ANTHROPIC_MODEL='glm-5.2'
export ANTHROPIC_SMALL_FAST_MODEL='glm-5.2'

claude-container \
  --container-forward-env \
  ANTHROPIC_BASE_URL,ANTHROPIC_AUTH_TOKEN,ANTHROPIC_MODEL,ANTHROPIC_SMALL_FAST_MODEL
```

Only the exact names appear in launcher and Apple CLI argument vectors; their
values are read from the exported environment and passed separately to the
Agent process. In particular, do not pass secrets as `NAME=VALUE`:
`--container-forward-env ANTHROPIC_AUTH_TOKEN=secret` is invalid. Unsafe
loader, launcher-managed, malformed, or unset names are rejected. Forwarding a
name still exposes its complete value to the Agent and anything it can run.

## Git, SSH, and GitHub capabilities

Guest Git receives a staged configuration containing only host `user.name` and
`user.email` by default. Broader capabilities are explicit:

```bash
# May expose credentials, helpers, includes, headers, and URL rewrites.
codex-container --container-full-git-config

# Includes readable GitHub CLI tokens when present.
codex-container --container-mount-gh

# Gives signing/authentication authority to the live agent socket.
codex-container --container-forward-ssh-agent

# Copies config, known_hosts, known_hosts.old, and allowed_signers only.
codex-container --container-mount-ssh-config
```

These are static container capabilities. If their requested state differs from
an already-running singleton, stop that profile before relaunching. Read-only
credentials can still be read and exfiltrated, and an SSH agent can authorize
operations without revealing private-key bytes.

## Proxy and DNS example

There are separate host and guest hops on a cold `latest` launch:

1. macOS resolves the publisher channel with host `curl`;
2. Apple's builder and the running guest perform their own network requests.

All launcher-managed hops use the explicit `--container-http-proxy`,
`--container-https-proxy`, `--container-all-proxy`, and
`--container-no-proxy` values. Exported proxy variables are not a public
container-configuration interface and are not inherited as a substitute for
those options.

For a proxy on macOS loopback port 1087:

```bash
# One-time Apple DNS/PF bridge, if it is not already present.
container system dns list
sudo container system dns create \
  host.container.internal --localhost 203.0.113.113

codex-container \
  --container-http-proxy http://host.container.internal:1087 \
  --container-https-proxy http://host.container.internal:1087 \
  --container-no-proxy localhost,127.0.0.1 \
  --version
```

If the proxy listens on a VM-reachable address, use it directly. Apple's
`--localhost` bridge disables Private Relay while present and loses its packet
filter redirect after restart. The launcher never creates this administrator
change. `host.docker.internal` is Docker-specific and is rejected.

For the exact `host.container.internal` proxy authority, the launcher keeps the
URL unchanged for BuildKit and the guest, while host-side latest-channel curl
uses a scoped DNS override to the macOS loopback listener. A running singleton
also reuses its recorded Agent version without consulting the latest channel;
pass `--container-version latest` explicitly when an update check is intended.

Proxy settings configure connectivity; they are not an egress allowlist.

## TLS and enterprise CAs

`--container-extra-ca` defaults to `auto`. In that mode, macOS Security verifies
the profile's installer endpoint and, for `latest`, the version endpoint. The
launcher carries only an eligible currently-valid `CA:TRUE` issuer from each
verified chain to its intended consumer: the version-chain CA for the host
channel request and the installer-chain CA for the guest trust store. It does
not copy the complete Keychain. If Security.framework cannot reach an endpoint
directly, curl may fetch only its peer chain through the explicitly configured
proxy; Security.framework still performs the hostname and Keychain trust
evaluation locally. This fallback never disables TLS verification or trusts
the curl result by itself.

Any CA override must be selected with `--container-extra-ca`; an exported CA
path or legacy launcher environment variable is not consulted. Proxy and CA
policy are container settings even when the underlying material or endpoint is
read from the host.

Use an audited explicit bundle when the publisher redirects through additional
enterprise-intercepted hosts:

```bash
codex-container \
  --container-extra-ca /absolute/path/to/enterprise-ca-bundle.pem \
  --version
```

An explicit file must be a non-symlink regular PEM no larger than 1 MiB with
1–64 currently-valid CA certificates. TLS hostname and chain verification are
never disabled, and CA material is delivered to the build as a secret rather
than a build argument.

Diagnose failures by layer:

- `curl: (60)` means certificate-chain verification failed. Fix the host trust
  path or provide the reviewed CA needed for that endpoint.
- HTTP `403` means TLS already succeeded and the origin or enterprise web
  policy denied the request. Add the documented publisher domain to the
  organization's allowlist. Another CA and `--insecure` cannot fix an access
  policy denial.

The extra-CA secret arrives after the OCI `FROM` pull, and the current Debian
bootstrap occurs before that CA is installed. Registry and early apt
interception still require Apple/system trust, a public mirror, or a
non-intercepted route. A guest CA expands trust for all software using Debian's
system store, not only the Agent installer.

## Advanced legacy `run` mode

The normal singleton path intentionally exposes only the dynamic workspace and
selected static capabilities. `run` is a separate, broader compatibility path
for tasks that need additional Apple volume mounts or selected native macOS
commands:

```text
agent-container [launcher options] run <profile> [run options...] [-- agent arguments...]
<profile>-container [launcher options] run [run options...] [-- agent arguments...]
```

Stop that profile's singleton before entering legacy mode:

```bash
agent-container singleton stop codex

codex-container run \
  --share-ro /path/to/reference \
  --share-rw /path/to/output \
  -- --agent-option
```

`run` creates a per-launch auto-remove VM and uses Apple VirtioFS for the
workspace and additional shares. It also starts the older Node.js host-command
broker. Eligible host commands are snapshotted from host `PATH`; guest commands
win normally, while host Git is preferred. Tighten the command surface with:

```bash
codex-container run --no-host-exec git --
codex-container run --host-first python3 --
```

The host-command broker authenticates each request and applies a generated
macOS filesystem sandbox to the process group. It can still run native code as
the macOS user inside admitted paths, and allowed interpreters or shells may
start children. Its pipe transport has no PTY. This mode depends on Apple's
deprecated `sandbox-exec` interface and is intentionally not the default.

`--share-ro` and `--share-rw` may be repeated. They cannot overlap each other,
private state, runtime assets, the workspace, or the real HOME as a whole. A
read-only share remains readable and exfiltratable; a read-write share can be
changed or deleted.

## Security boundary

The Micro-VM reduces ambient macOS access; it does not make untrusted prompts or
repositories harmless. By default an Agent can:

- read and write the selected project root;
- read and write its profile HOME;
- communicate with the network without a hostname allowlist;
- affect other concurrent clients of the same profile through shared VM and
  HOME state.

It does not receive the real HOME wholesale, another profile's HOME, host SSH
private-key files, or arbitrary host environment values. Agent permission and
sandbox flags are passed through as the user requested; the launcher does not
inject a permission bypass.

Read [docs/security.md](docs/security.md) before enabling credential or legacy
host-execution capabilities.

## Apple filesystem risk

Apple [`container#1097`](https://github.com/apple/container/issues/1097)
reports VirtioFS file-descriptor retention and includes a kernel-panic report.
The default singleton workspace uses SSHFS/SFTP, so changing from project A to
project B does not add a large persistent VirtioFS workspace mount. The
isolated profile HOME and opted-in static configuration mounts still use Apple
volumes, and legacy `run` uses VirtioFS for its workspace and extra shares.

The launcher retains file-count checks and host file/vnode preflight for those
paths. The live watchdog belongs to the attached legacy `run` lifecycle; a
persistent singleton has no launcher process that can monitor it after clients
disconnect. Risk-acceptance and watchdog-disabling flags are for controlled
tests, not routine use. See [docs/performance.md](docs/performance.md) for a
benchmark and safety protocol.

## Persistent layout

```text
~/.agent-container/
  .agent-container-owned
  profiles/<id>/
    home/                  # persistent isolated guest HOME
    host-home/             # HOME for advanced run-mode host tools
    meta/                  # image recipe and inspected identity
    singleton/             # persistent container lifecycle and static staging
  sessions/session-<pid>/  # ephemeral broker and launch staging
```

The workspace itself is not copied into this tree. Default workspace bytes flow
between the canonical host project and the per-exec SSHFS mount.

## Updating an Agent

Profiles follow publisher channels by default. A moved channel changes the
verified image recipe. Stop the running profile before adopting the new image:

```bash
agent-container singleton stop codex
codex-container --version
```

Temporarily pin or roll back to an exact release:

```bash
agent-container singleton stop codex
codex-container --container-version 0.146.0 --version
```

An exact version skips the host channel request and can reuse a matching warm
image offline. A missing image still needs network access for Debian and the
publisher installer. Exact Agent selection does not make mutable installer
scripts or Debian repositories bit-for-bit reproducible.

## Performance

A warm invocation avoids VM boot but still pays for host validation,
`container exec`, broker authentication, SSHFS mount readiness, and Agent
startup. Metadata-heavy work over SFTP may be slower than APFS or VirtioFS;
online Agent latency is often dominated by the model provider. Measure cold
build, cold singleton creation, warm attach, workspace I/O, and online task time
separately. See [docs/performance.md](docs/performance.md).

## Uninstall

For a curl-installed or source-installed release:

```bash
uninstaller_url='https://raw.githubusercontent.com/loadchange/agent-container/main/uninstall.sh'
curl -fsSL "$uninstaller_url" | bash
```

For a Homebrew install, uninstall the formula first (it removes the same managed
release state), then untap if you no longer want updates:

```bash
brew uninstall agent-container
brew untap loadchange/agent-container
```

The default removes managed commands, release assets, and only images whose
recorded provenance still matches. It preserves profile HOME directories.
For a source checkout, `./uninstall.sh` remains available. If Apple CLI
discovery needs an override, pass `--container-bin /absolute/path/to/container`
to that script (or after `bash -s --` in the curl form).

```bash
curl -fsSL "$uninstaller_url" | bash -s -- --purge
```

`--purge` also removes logins, settings, sessions, caches, and other managed
state. Uninstall fails closed if a singleton or legacy session is active or if
path/image ownership cannot be proved.

## Repository layout

```text
bin/        source-tree command shims (installed releases use direct symlinks)
runtime/    complete release payload: runtime script, Containerfile, broker,
            guest helpers, and per-agent profiles (claude, codex, grok)
src/        Rust launcher and workspace broker
scripts/    reproducible release build, manifest and formula generation
Formula/    Homebrew formula (this repository is its own tap)
tests/      contract tests for the runtime, installer, broker, and workspace
```

The native launcher binary is never committed; `scripts/build-release.sh`
builds it reproducibly into `dist/`, and the release workflow publishes it as a
GitHub Release.

## More documentation

- [Architecture](docs/architecture.md)
- [Profiles](docs/profiles.md)
- [Security model](docs/security.md)
- [Performance protocol](docs/performance.md)
