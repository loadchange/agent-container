# Agent profiles

## Purpose

An Agent profile turns the common Apple-container runtime into a launcher for
one native Linux arm64 Agent CLI. Profiles contain declarative metadata for an
official installer, its version channel, and the installed command. They do not
define mounts, shell fragments, or host capabilities.

List the installed profiles with:

```bash
agent-container profiles
```

The built-in profiles are:

| ID | Agent | Status | Official installer | Shell | Version channel | Image payload |
|---|---|---|---|---|---|---|
| `claude` | Claude Code | preview | `https://claude.ai/install.sh` | `bash` | `https://downloads.claude.ai/claude-code-releases/latest` | single ELF |
| `codex` | Codex CLI | preview | `https://chatgpt.com/codex/install.sh` | `sh` | `https://releases.openai.com/codex/channels/latest` | complete standalone tree |
| `grok` | Grok CLI | experimental | `https://x.ai/cli/install.sh` | `bash` | `https://x.ai/cli/stable` | single ELF |

All three built-in profiles set `version` to `latest`; “latest” means the
publisher channel shown in the table, including Grok's stable channel. The
floating name is never installed directly.

Experimental profiles require an explicit opt-in:

```bash
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true agent-container grok
```

`preview` profiles are available without an opt-in, but do not claim the full
real-Agent qualification required for `stable`.

## Schema version 2

Profiles live in `profiles/<id>.json`. The launcher uses the system
JavaScriptCore through `osascript` to parse each file once, validate an exact
typed key set, and extract inert values. The Codex profile illustrates every
schema-2 field:

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

| Field | Type | Meaning and constraints |
|---|---|---|
| `schema` | integer | must currently be `2` |
| `id` | string | must equal the filename; 1–32 lowercase letters, digits, and hyphens, not starting with a digit or hyphen |
| `displayName` | string | non-empty ASCII name limited to letters, digits, spaces, and `._+()/-` |
| `status` | string | `stable`, `preview`, or `experimental`; only experimental profiles require an opt-in |
| `installerKind` | string | currently only `native-script` |
| `installerUrl` | string | HTTPS URL of the publisher's native install script, limited to safe URL characters |
| `installerShell` | string | exactly `bash` or `sh`, according to the publisher's documented invocation |
| `installerVersionUrl` | string | HTTPS endpoint that identifies the publisher's current release |
| `installerVersionFormat` | string | `plain-semver` for a one-line version or `rust-tag-json` for Codex metadata whose `tag_name` starts with `rust-v` |
| `installerVersionEnv` | string | optional environment variable through which the installer receives the resolved exact version; empty means pass it as a positional argument |
| `installerBinDirEnv` | string | optional installer variable used to direct its visible command into `/opt/agent-native/.local/bin` |
| `installerHomeEnv` | string | optional installer-specific state root; Codex uses `CODEX_HOME` so the complete standalone tree remains under `/opt/agent-native/.codex` |
| `installerNonInteractiveEnv` | string | optional variable set to `1` for unattended installation; Codex uses `CODEX_NON_INTERACTIVE` |
| `version` | string | `latest` or one exact numeric `major.minor.patch` version with an optional safe prerelease/build suffix; no range or shell syntax |
| `command` | string | one ASCII executable basename using letters, digits, `.`, `_`, or `-`; not a path or shell command |
| `probeArg` | string | `--version`, `-V`, or `version` |
| `apiKeyEnv` | string | optional uppercase `[A-Z_][A-Z0-9_]*` environment-variable name |
| `disableAutoUpdateEnv` | string | optional uppercase `[A-Z_][A-Z0-9_]*` variable set to `1` in every session |

Every field shown above is required, including optional-value fields, which use
an empty string when not applicable. String values may not contain C0 control
characters or DEL. Profiles are parsed as data and are never passed to `eval`
or `source`. Environment-variable names and URLs are validated again before
they enter the build.

The shared image recipe currently binds each built-in profile ID to its exact
official installer URL, shell, command, and installer-variable contract. This
prevents a valid-looking edit from silently redirecting a built-in profile.
Schema validation limits command injection; it does not attest the publisher's
script or downloaded executable. See [security.md](security.md).

## Version resolution and image fingerprint

For a `latest` profile, every launch performs these steps before image reuse is
decided:

1. Fetch the profile's official `installerVersionUrl` over HTTPS using the
   ordinary host `curl` network and proxy environment. A proxy-restricted host
   must enable its host proxy, such as `proxy_on`, before launch.
2. Strictly parse one exact version. Plain responses must contain only a safe
   semantic version; Codex JSON must contain a safe `rust-v...` `tag_name`.
3. Include that exact version, the complete profile JSON, Debian base image,
   shared `Containerfile`, context allowlist, and entrypoint in the recipe
   fingerprint.
4. Reuse the inspected image only when both its fingerprint and recorded OCI
   identity match. A moved publisher channel makes the profile rebuild.

`AGENT_CONTAINER_VERSION` overrides the profile for one invocation. The value
may be `latest` or an exact release:

```bash
AGENT_CONTAINER_VERSION=0.146.0 agent-container codex --version
```

An exact override skips the channel request. It can therefore run offline when
the matching image is already warm, and is also the rollback mechanism. If the
matching image is absent or stale, a cold build still needs the Debian and
publisher download endpoints. The override does not edit the profile file.

The image reference remains `agent-container-<profile>:latest`; that OCI tag is
only a local cache name and is unrelated to the publisher's release channel.
Arbitrary cross-profile image tags would make concurrent builds and uninstall
provenance ambiguous.

## Native build and runtime behavior

The default base is the Debian Bookworm slim Linux arm64 manifest pinned by
digest:

```text
mirror.gcr.io/library/debian:bookworm-slim@sha256:9b67294679b30e5d6ab257b40594feeb4a4b81f7fcf4131f4decf0d6a212a9b0
```

The image does not install Node.js or npm. On a cold build, the profile supplies
these controlled arguments to the shared `Containerfile`:

- `AGENT_PROFILE`;
- `AGENT_INSTALLER_URL`;
- `AGENT_INSTALLER_SHELL`;
- `AGENT_INSTALLER_VERSION_ENV`;
- `AGENT_INSTALLER_BIN_DIR_ENV`;
- `AGENT_INSTALLER_HOME_ENV`;
- `AGENT_INSTALLER_NONINTERACTIVE_ENV`;
- `AGENT_VERSION`;
- `AGENT_COMMAND`;
- `AGENT_PROBE_ARG`.

The script is downloaded over HTTPS and run with a build-only
`HOME=/opt/agent-native`. Claude and Grok receive the exact version as a
positional argument. Codex receives it through `CODEX_RELEASE`, together with
`CODEX_NON_INTERACTIVE=1`, `CODEX_INSTALL_DIR`, and `CODEX_HOME`. The build then
requires the command to resolve inside the controlled install root, verifies it
is an ELF64 ARM aarch64 executable, and requires `--version` to report the exact
requested release.

Claude and Grok require no adjacent installer tree, so the image copies only
their ELF to `/usr/local/bin` and removes the temporary tree. Claude uses the
base image's glibc, while Grok is statically linked. Codex
depends on adjacent standalone helpers and resources, so its complete versioned
release tree remains under `/opt/agent-native/.codex/packages/standalone/` and
`/usr/local/bin/codex` links into it.

Useful build controls are:

```bash
AGENT_CONTAINER_VERSION="$wanted_version" agent-container codex --version
AGENT_CONTAINER_BASE_IMAGE=mirror.example/debian:bookworm-slim agent-container codex
AGENT_CONTAINER_REBUILD=true agent-container codex --version
AGENT_CONTAINER_SKIP_BUILD=true agent-container codex --version
```

## Persistent profile HOME and updater policy

Every profile receives its own directory:

```text
~/.agent-container/profiles/<id>/home/
```

That directory is mounted as the entire guest `$HOME` at the same absolute path
as the macOS home. For example, the Codex profile for `/Users/alice` sees
`HOME=/Users/alice`, but `/Users/alice` contains Codex's isolated persistent
state rather than Alice's real macOS home. This runtime shadow HOME is separate
from the `/opt/agent-native` HOME used while building the image.

The Agent's normal login, settings, history, plugins, and cache persist, but
profiles never share a HOME. API-key forwarding is explicit and uses only the
profile's `apiKeyEnv`. When declared, the launcher sets the updater-disable
variable on every session: `DISABLE_AUTOUPDATER=1` for Claude and
`GROK_DISABLE_AUTOUPDATER=1` for Grok. Image replacement, not an in-session
updater, owns those release changes.

## Adding a profile

1. Confirm that the publisher provides a native Linux arm64 executable and an
   HTTPS installer that supports unattended installation of one exact version.
   A macOS Mach-O executable cannot run in the guest.
2. Audit the installer's version-selection interface, install layout, helper
   dependencies, checksum/signature behavior, and version probe. Do not discard
   adjacent resources merely because the main executable is an ELF.
3. Add `profiles/<id>.json` using every schema-2 field and start the integration
   as `experimental`.
4. Extend the shared `Containerfile` allowlist and native-layout validation for
   the new official installer. Profiles cannot inject shell fragments to add
   this behavior themselves.
5. Validate that the file is JSON and that the launcher accepts it:

   ```bash
   plutil -convert json -o /dev/null profiles/<id>.json
   agent-container profiles
   ```

6. Build and probe it from a small disposable repository:

   ```bash
   AGENT_CONTAINER_ASSET_DIR="$PWD" \
   AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true \
     ./agent-container <id> --version
   ```

7. Verify native ELF architecture, the exact release, interactive TTY input,
   piped stdin, exit status, signal cleanup, login persistence, workspace writes
   with the host UID/GID, and a second warm invocation that skips the build.
8. Add tests for channel resolution, an exact offline override, malformed
   channel responses, layout/resource preservation, API-key policy, isolated
   HOME, image identity, and the experimental gate.
9. Add the JSON file to the installer's immutable release asset list. If a
   convenience command is wanted, add a thin wrapper that performs only:

   ```bash
   exec /path/to/agent-container <id> "$@"
   ```

10. Document Agent-specific login and any known Linux incompatibilities. Move a
    contract-tested integration to `preview`; promote it to `stable` only after
    the complete real Apple-container end-to-end matrix passes.

Adding a profile must not add Agent-specific directories, authentication
migration, mounts, or dangerous flags to the core launcher. If a new Agent
needs a broader host capability, design it as a generic, default-deny runtime
capability and update the threat model first.

## Compatibility wrappers

The project may install `claude-container`, `codex-container`, and
`grok-container` as thin aliases. They must preserve arguments exactly and must
not implement separate runtime behavior. The canonical interface remains:

```bash
agent-container <profile> [agent arguments...]
```
