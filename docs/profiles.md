# Agent profiles

## Purpose

An Agent profile turns the common Apple-container runtime into a launcher for
one Linux arm64 Agent CLI. Profiles contain declarative package metadata; they
do not define mounts, shell fragments, or host capabilities.

List the installed profiles with:

```bash
agent-container profiles
```

The built-in profiles are:

| ID | Agent | Status | Package | Pinned version |
|---|---|---|---|---:|
| `claude` | Claude Code | preview | `@anthropic-ai/claude-code` | `2.1.220` |
| `codex` | Codex CLI | preview | `@openai/codex` | `0.146.0` |
| `grok` | Grok CLI | experimental | `@xai-official/grok` | `0.2.110` |

Experimental profiles require an explicit opt-in:

```bash
AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true agent-container grok
```

`preview` profiles are available without an opt-in, but do not claim the full
real-Agent qualification required for `stable`.

## Schema version 1

Profiles live in `profiles/<id>.json`. The launcher uses the system JavaScriptCore
through `osascript` to parse each file once, validate an exact typed key set,
and extract inert values. A current profile has this shape:

```json
{
  "schema": 1,
  "id": "codex",
  "displayName": "Codex CLI",
  "status": "preview",
  "installerKind": "npm",
  "package": "@openai/codex",
  "version": "0.146.0",
  "command": "codex",
  "probeArg": "--version",
  "apiKeyEnv": "OPENAI_API_KEY",
  "disableAutoUpdateEnv": ""
}
```

| Field | Type | Meaning and constraints |
|---|---|---|
| `schema` | integer | must currently be `1` |
| `id` | string | must equal the filename; 1–32 lowercase letters, digits, and hyphens, not starting with a digit or hyphen |
| `displayName` | string | non-empty ASCII name limited to letters, digits, spaces, and `._+()/-` |
| `status` | string | `stable`, `preview`, or `experimental`; only experimental profiles require an opt-in |
| `installerKind` | string | currently only `npm` |
| `package` | string | unscoped `name` or scoped `@scope/name`, limited to ASCII letters, digits, `.`, `_`, and `-` |
| `version` | string | exact numeric `major.minor.patch` plus an optional safe suffix; no ranges or shell syntax |
| `command` | string | one ASCII executable basename using letters, digits, `.`, `_`, or `-`; not a path or shell command |
| `probeArg` | string | `--version`, `-V`, or `version` |
| `apiKeyEnv` | string | optional uppercase `[A-Z_][A-Z0-9_]*` environment-variable name |
| `disableAutoUpdateEnv` | string | optional uppercase `[A-Z_][A-Z0-9_]*` variable set to `1` in every session |

Every field shown above is required, including optional-value fields, which use
an empty string when not applicable. String values may not contain C0 control
characters or DEL. Profiles are parsed as data and are never passed to `eval`
or `source`.

Schema validation limits command injection, but it does not establish that an
npm package is trustworthy. Profiles distributed with the project are part of
the trusted supply chain.

## Build and runtime behavior

On first use, the profile supplies these controlled build arguments to the
shared `Containerfile`:

- `AGENT_PACKAGE`;
- `AGENT_VERSION`;
- `AGENT_COMMAND`;
- `AGENT_PROBE_ARG`.

The build installs exactly `<package>@<version>` and runs the declared version
probe. The resulting default image name is
`agent-container-<profile>:latest`.

The recipe fingerprint includes the shared Containerfile, its context
allowlist, generic entrypoint, complete profile JSON, selected version, and
base image. A matching image tag is reused only when its recorded inspected
identity also matches.

Useful build controls are:

```bash
AGENT_CONTAINER_VERSION="$wanted_version" agent-container codex --version
AGENT_CONTAINER_BASE_IMAGE=mirror.example/node:22-bookworm-slim agent-container codex
AGENT_CONTAINER_REBUILD=true agent-container codex --version
AGENT_CONTAINER_SKIP_BUILD=true agent-container codex --version
```

`AGENT_CONTAINER_VERSION` overrides the selected profile version for that run.
It does not edit the profile file. Image references remain fixed at
`agent-container-<profile>:latest`: allowing arbitrary cross-profile tags would
make concurrent builds and uninstall provenance ambiguous.

## Persistent profile HOME

Every profile receives its own directory:

```text
~/.agent-container/profiles/<id>/home/
```

That directory is mounted as the entire guest `$HOME` at the same absolute path
as the macOS home. For example, the Codex profile for `/Users/alice` sees
`HOME=/Users/alice`, but `/Users/alice` contains Codex's isolated persistent
state rather than Alice's real macOS home.

This lets the Agent's normal login, settings, history, plugins, and cache
persist. Profiles never share a HOME. To authenticate, prefer the Agent's own
login flow inside the profile. API-key forwarding is explicit and uses only
the profile's `apiKeyEnv`; see [security.md](security.md).

## Adding a profile

1. Confirm that the Agent has an npm package which installs and runs on
   `linux/arm64` with Node 22. A macOS Mach-O executable cannot run in the
   guest.
2. Pin an exact package version. Do not use `latest`, a range, a Git URL, or an
   install script.
3. Add `profiles/<id>.json` using every schema-1 field. Start new integrations
   as `experimental`.
4. Validate that the file is JSON and that the launcher accepts it:

   ```bash
   plutil -convert json -o /dev/null profiles/<id>.json
   agent-container profiles
   ```

5. Build and probe it from a small disposable repository:

   ```bash
   AGENT_CONTAINER_ASSET_DIR="$PWD" \
   AGENT_CONTAINER_ENABLE_EXPERIMENTAL=true \
     ./agent-container <id> --version
   ```

6. Verify interactive TTY input, piped stdin, exit status, signal cleanup,
   login persistence, workspace writes with the host UID/GID, and a second
   warm invocation that skips the build.
7. Add profile-matrix tests proving the correct package, version, command,
   API-key variable, isolated HOME, image reference, and experimental gate.
8. Add the JSON file to the installer's immutable release asset list. If a
   convenience command is wanted, add a thin wrapper that performs only:

   ```bash
   exec /path/to/agent-container <id> "$@"
   ```

9. Document Agent-specific login and any known Linux incompatibilities. Move a
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
