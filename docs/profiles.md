# Agent profiles

## Purpose

A profile describes how the shared runtime obtains and verifies one native
Linux arm64 Agent CLI. It does not define container lifecycle, workspace
mounts, host commands, CA policy, or persistent services. Those are core
runtime responsibilities and behave the same for Claude, Codex, and Grok.

List the installed profiles with:

```bash
agent-container profiles
```

| ID | Agent | Status | Official installer | Version channel | Final image payload |
|---|---|---|---|---|---|
| `claude` | Claude Code | preview | `https://claude.ai/install.sh` | `https://downloads.claude.ai/claude-code-releases/latest` | one ELF |
| `codex` | Codex CLI | preview | `https://chatgpt.com/codex/install.sh` | `https://releases.openai.com/codex/channels/latest` | standalone tree |
| `grok` | Grok CLI | preview | `https://x.ai/cli/install.sh` | `https://x.ai/cli/stable` | one ELF |

All three are ordinary built-in profiles. Every normal invocation reuses one
container per profile and host UID; no profile supplies its own resident Agent
protocol. Each terminal starts a fresh profile command with independent
arguments, TTY, cwd, and dynamic workspace.

## Schema version 2

Profiles live at `runtime/profiles/<id>.json` in the source tree and at
`profiles/<id>.json` beside the installed runtime. The launcher parses them as inert JSON
with macOS JavaScriptCore and requires one exact typed key set. The Codex file
shows every field:

```json
{
  "schema": 2,
  "id": "codex",
  "displayName": "Codex CLI",
  "status": "preview",
  "installerKind": "native-script",
  "installerUrl": "https://chatgpt.com/codex/install.sh",
  "installerShell": "sh",
  "installerVersionUrl": "https://releases.openai.com/codex/channels/latest",
  "installerVersionFormat": "rust-tag-json",
  "installerVersionEnv": "CODEX_RELEASE",
  "installerBinDirEnv": "CODEX_INSTALL_DIR",
  "installerHomeEnv": "CODEX_HOME",
  "installerNonInteractiveEnv": "CODEX_NON_INTERACTIVE",
  "version": "latest",
  "command": "codex",
  "probeArg": "--version",
  "apiKeyEnv": "OPENAI_API_KEY",
  "disableAutoUpdateEnv": ""
}
```

| Field | Type | Contract |
|---|---|---|
| `schema` | integer | Exactly `2` |
| `id` | string | Matches the filename; 1–32 lowercase letters, digits, or hyphens; does not start with a digit or hyphen |
| `displayName` | string | Non-empty safe ASCII display text |
| `status` | string | `stable`, `preview`, or `experimental` |
| `installerKind` | string | Currently exactly `native-script` |
| `installerUrl` | string | Safe HTTPS URL for the publisher install script |
| `installerShell` | string | Exactly `bash` or `sh` |
| `installerVersionUrl` | string | Safe HTTPS endpoint identifying the current publisher release |
| `installerVersionFormat` | string | `plain-semver` or the constrained Codex `rust-tag-json` form |
| `installerVersionEnv` | string | Optional validated variable receiving the exact version; empty means a positional argument |
| `installerBinDirEnv` | string | Optional validated installer output-directory variable |
| `installerHomeEnv` | string | Optional validated installer state-root variable |
| `installerNonInteractiveEnv` | string | Optional validated unattended-install variable |
| `version` | string | `latest` or one exact safe semantic version |
| `command` | string | One safe executable basename, never a path or shell fragment |
| `probeArg` | string | `--version`, `-V`, or `version` |
| `apiKeyEnv` | string | Optional uppercase credential variable name |
| `disableAutoUpdateEnv` | string | Optional uppercase variable set to `1` in Agent processes |

Every key is required, including fields whose value is an empty string. C0
control characters and DEL are rejected. Environment names, URL characters,
profile IDs, command names, and versions receive field-specific validation.
The file is never sourced or evaluated as shell.

The shared image recipe additionally binds each built-in ID to its reviewed
installer URL, shell, command, and installer variable contract. A syntactically
valid edit cannot silently redirect a built-in ID to another publisher.

## What profiles cannot request

Schema 2 deliberately has no fields for:

- volume paths or workspace lists;
- real HOME access;
- persistent-container commands;
- Linux capabilities or mount namespaces;
- native host-command execution;
- arbitrary environment inheritance;
- SSH/GitHub/Git configuration mounts;
- CA files, Keychain access, or TLS-verification changes;
- Agent permission-bypass arguments.

The core runtime supplies one persistent container plus per-exec SFTP/SSHFS
workspace transport for every profile. Making that behavior profile data would
allow an installer description to expand host authority.

## Version resolution

For a `latest` profile, every launch:

1. requests the profile's official version endpoint with host `curl`;
2. strictly reduces the response to one exact version;
3. includes that value and the complete build recipe in the image fingerprint;
4. reuses an image only when its recorded fingerprint and inspected OCI
   identity agree.

The floating channel string is never handed to the publisher installer. A
channel move changes the desired recipe. Because the normal container is
persistent, stop the profile before adopting a newly resolved image:

```bash
agent-container singleton stop codex
codex-container --version
```

Use a leading launcher option to select an exact version for one invocation:

```bash
agent-container singleton stop codex
codex-container --container-version 0.146.0 --version
```

An exact version skips the channel request and can reuse a matching warm image
without network access. It does not edit the profile, and a cold build still
needs the Debian and publisher endpoints.

The image tag remains `agent-container-<profile>:latest`; that is a local cache
name, not the publisher channel and not ownership proof.

## Image construction and verification

The default base is a digest-pinned Debian Bookworm slim arm64 image. The build
uses a private `HOME=/opt/agent-native` and has no workspace, runtime profile
HOME, API key, SSH agent, GitHub configuration, or host Git configuration
mounted.

Core passes only constrained profile values to the shared `Containerfile`. The
publisher script receives the already-resolved exact version through its
documented positional or environment interface. After installation, the recipe
requires:

- the command to resolve below the controlled install root;
- `file` to identify an ELF64 ARM aarch64 executable;
- the profile version probe to report the requested exact version.

Claude and Grok need no adjacent install tree, so only the final ELF enters
`/usr/local/bin`. Codex depends on adjacent helpers and resources; its complete
versioned standalone tree remains under `/opt/agent-native/.codex` and the
command links into it.

The default `--container-extra-ca auto` bridge and an explicitly selected CA
bundle are core policy, not profile authority. A profile identifies two known
HTTPS endpoints; it cannot choose a host file or cause the whole macOS Keychain
to enter the guest. A user-selected CA path must arrive through
`--container-extra-ca`. CA contents are delivered as a BuildKit secret, while
the public digest becomes a recipe input.

Useful build controls are leading launcher options:

```bash
codex-container --container-version 0.146.0 --version
codex-container --container-rebuild --version
codex-container --container-skip-build --version
codex-container --container-base-image mirror.example/debian:bookworm-slim --version
```

Changing an image input while the singleton is active fails closed. Stop it
before rebuilding or changing version/base/CA policy.

## Persistent HOME and process policy

Each profile has one isolated directory:

```text
~/.agent-container/profiles/<id>/home/
```

It is mounted at the same absolute guest path as the host HOME, but it does not
contain the real host HOME. Login state, settings, history, plugins, and caches
persist across Agent processes, singleton stops, image replacement, and a
normal uninstall. Different profiles never share this directory.

All clients of one profile do share it. A repository can therefore influence a
later client by changing Agent-managed state or plugins. Private workspace mount
namespaces prevent ordinary path visibility across clients but do not make
same-profile processes mutually hostile sandboxes.

If `disableAutoUpdateEnv` is non-empty, core sets it for each Agent process.
Claude uses `DISABLE_AUTOUPDATER`; Grok uses
`GROK_DISABLE_AUTOUPDATER`. Publisher updates then enter through host channel
resolution and a verified image rebuild instead of mutating the running image.

## Environment and credential contract

`apiKeyEnv` names the profile's one primary API-key variable. Profile JSON does
not import it automatically. `--container-forward-api-key` is off by default
and, when enabled, expands only that active profile field. It does not grant a
profile an alternative-token list or
provider-specific forwarding behavior. Login state in the shadow HOME remains
the default authentication path.

No profile receives provider, endpoint, model, token, or Agent settings from
the host automatically. Each user-supplied name outside `apiKeyEnv` must be
authorized with `--container-forward-env`. For example:

```bash
export ANTHROPIC_BASE_URL='https://open.bigmodel.cn/api/anthropic'
export ANTHROPIC_AUTH_TOKEN='replace-with-provider-token'
export ANTHROPIC_MODEL='glm-5.2'

claude-container \
  --container-forward-env \
  ANTHROPIC_BASE_URL,ANTHROPIC_AUTH_TOKEN,ANTHROPIC_MODEL
```

The option contains names only. Values are read from the exported environment
and do not enter launcher or Apple CLI argument vectors. Secret-bearing syntax
such as `--container-forward-env ANTHROPIC_AUTH_TOKEN=secret` is invalid.

The declared primary API key can be authorized explicitly:

```bash
export OPENAI_API_KEY='...'
codex-container --container-forward-api-key
```

These launcher options are core interfaces. A profile cannot add implicit
environment inheritance or secret sources.

## Compatibility commands

The Rust host launcher dispatches from `argv[0]`:

```text
claude-container ARGS...  -> agent-container claude ARGS...
codex-container ARGS...   -> agent-container codex ARGS...
grok-container ARGS...    -> agent-container grok ARGS...
```

Leading `--container-*` options are consumed before profile insertion. `--`
ends launcher parsing. The first ordinary argument also ends parsing and is
preserved with every following `OsString`. Unknown leading namespaced options
fail instead of leaking a typo to an Agent.

The aliases also support the advanced legacy path:

```text
codex-container [launcher options] run [run options...] [-- Agent args...]
agent-container [launcher options] run codex [run options...] [-- Agent args...]
```

The default form selects the persistent singleton; `run` selects a short-lived
Apple-volume and host-command compatibility path. This distinction is core
runtime behavior, not profile metadata.

## Adding a profile

1. Confirm the publisher supplies a native Linux arm64 executable and an HTTPS
   installer capable of selecting one exact version.
2. Audit version selection, checksums/signatures, unattended operation, install
   layout, adjacent helper requirements, and the version probe.
3. Add a complete schema-2 JSON file with a new ID and start its status as
   `experimental`.
4. Extend the shared `Containerfile` allowlist and layout verification for the
   fixed official installer contract. Do not add profile-provided shell.
5. Validate JSON and core parsing:

   ```bash
   plutil -convert json -o /dev/null runtime/profiles/<id>.json
   agent-container profiles
   ```

6. Build with source assets through the documented launcher development
   options, then test exact version, cold and warm startup, TTY, pipes, signals,
   login persistence, UID/GID writes, and dynamic workspace cleanup:

   ```bash
   ./agent-container \
     --container-assets "$PWD" \
     --container-enable-experimental \
     <id> --version
   ```
7. Test two concurrent projects against the same profile singleton and verify
   that each receives an independent cwd/TTY/mount namespace while sharing only
   the intended profile state.
8. Add channel parsing, malformed-response, CA, image identity, installer
   layout, broker authentication, and stop/status tests.
9. Add the profile and optional compatibility alias to the installer's signed
   release asset set.
10. Promote to `preview` only after the real Apple-container matrix passes; use
    `stable` only for a fully supported integration.

A new profile must not add Agent-specific lifecycle, mount, service, CA, or
permission-bypass behavior to core merely by naming similar Agent flags. Any
new host capability requires an explicit interface and threat-model update.
