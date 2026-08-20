#!/bin/bash
set -euo pipefail

# Writes Formula/agent-container.rb for one published release.
#
#   scripts/generate-formula.sh VERSION SHA256
#
# The output is deterministic: only the version, url, and sha256 stanzas
# change between releases, so the release workflow produces clean diffs when
# it commits the refreshed formula back to this repository (which is itself
# the Homebrew tap).

readonly PROGRAM_NAME="generate-formula"

[ "$#" -eq 2 ] || {
  echo "$PROGRAM_NAME: Error: exactly one version and one sha256 are required." >&2
  echo "Usage: scripts/generate-formula.sh VERSION SHA256" >&2
  exit 64
}

release_version=$1
release_sha256=$2

case "$release_version" in
  ''|*[!0-9A-Za-z._-]*)
    echo "$PROGRAM_NAME: Error: unsupported version string." >&2
    exit 64
    ;;
esac
case "$release_sha256" in
  ''|*[!0-9a-f]*)
    echo "$PROGRAM_NAME: Error: the sha256 must be a lowercase hex digest." >&2
    exit 64
    ;;
esac
[ "${#release_sha256}" -eq 64 ] || {
  echo "$PROGRAM_NAME: Error: the sha256 must have 64 characters." >&2
  exit 64
}

cat <<'FORMULA' | sed \
  -e "s/__VERSION__/$release_version/g" \
  -e "s/__SHA256__/$release_sha256/g"
# Managed by scripts/generate-formula.sh. The release workflow refreshes the
# version, url, and sha256 stanzas on every published release; edit the
# generator, not this file.
class AgentContainer < Formula
  desc "Run Claude Code, Codex CLI, and Grok CLI in Apple container Micro-VMs"
  homepage "https://github.com/loadchange/agent-container"
  version "__VERSION__"
  sha256 "__SHA256__"
  url "https://github.com/loadchange/agent-container/releases/download/v__VERSION__/agent-container-darwin-arm64.tar.gz"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  def install
    libexec.install Dir["*"]
    %w[
      agent-container
      claude-container
      codex-container
      grok-container
    ].each do |name|
      bin.install_symlink libexec/"agent-container-darwin-arm64" => name
    end
  end

  def caveats
    <<~EOS
      Apple container 1.2.0 or newer is required and is not installed by this
      formula. Install it with:

          brew install container

      agent-container starts Apple's per-user container services automatically
      whenever a profile is launched.
    EOS
  end

  test do
    assert_match "claude", shell_output("#{bin}/agent-container profiles")
  end
end
FORMULA
