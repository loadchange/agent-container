# claude-docker

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) inside a Docker container with your host settings and persistent authentication.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/loadchange/claude-docker/main/install.sh | bash
```

This installs the `claude-docker` command to `~/.local/bin/`.

To update, run the same command again.

## Usage

```bash
claude-docker
```

All arguments are passed through to `claude`:

```bash
claude-docker --dangerously-skip-permissions
claude-docker -p "explain this codebase"
```

The current directory is mounted as the workspace inside the container.

## Configuration

You can customize the container environment by exporting the following optional environment variables before running `claude-docker`:

- **Proxy**:
  - `CLAUDE_DOCKER_HTTP_PROXY`: HTTP proxy URL (e.g., `http://127.0.0.1:1087`)
  - `CLAUDE_DOCKER_HTTPS_PROXY`: HTTPS proxy URL
  - `CLAUDE_DOCKER_ALL_PROXY`: SOCKS/ALL proxy URL (e.g., `socks5://127.0.0.1:1080`)
  - `CLAUDE_DOCKER_NO_PROXY`: Comma-separated list of domains to bypass the proxy (defaults to `localhost,127.0.0.1`)
- **DNS**:
  - `CLAUDE_DOCKER_DNS1`: Primary custom DNS server IP (e.g., `1.1.1.1`)
  - `CLAUDE_DOCKER_DNS2`: Secondary custom DNS server IP (e.g., `1.0.0.1`)
- **Timezone**:
  - `CLAUDE_DOCKER_TZ`: Container timezone (e.g., `Asia/Shanghai`)

Example:
```bash
export CLAUDE_DOCKER_HTTP_PROXY="http://127.0.0.1:1087"
export CLAUDE_DOCKER_HTTPS_PROXY="http://127.0.0.1:1087"
export CLAUDE_DOCKER_ALL_PROXY="socks5://127.0.0.1:1080"
export CLAUDE_DOCKER_NO_PROXY="localhost,127.0.0.1"
export CLAUDE_DOCKER_DNS1="1.1.1.1"
export CLAUDE_DOCKER_DNS2="1.0.0.1"
export CLAUDE_DOCKER_TZ="America/Phoenix"
claude-docker
```

## What it does

On first run, `claude-docker`:

1. Builds a lightweight Docker image (Debian slim + git + curl)
2. Installs Claude Code into a persistent Docker volume
3. Prompts you to log in via OAuth (browser-based)

On subsequent runs, it starts instantly with your existing authentication and settings.

## Host settings

The following files from `~/.claude/` are synced into the container on each launch:

- `settings.json` - Claude Code configuration
- `CLAUDE.md` - global instructions
- `hooks/` - custom hook scripts
- `plugins/` - installed plugins and skills
- `commands/` - custom slash commands
- `agents/` - custom agent definitions

These are copied to `~/.claude-docker/` to avoid conflicts with the host-side Claude Code (which uses macOS Keychain for credentials).

## Data storage

| Path | Purpose |
|------|---------|
| `~/.claude-docker/` | Container-side Claude config (credentials, settings copy) |
| `~/.claude-docker.json` | Onboarding state |
| Docker volume `claude-code-local` | Claude Code installation (persists auto-updates) |

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/loadchange/claude-docker/main/uninstall.sh | bash
```

## Requirements

- Docker
- bash
