# Managed by scripts/generate-formula.sh. The release workflow refreshes the
# version, url, and sha256 stanzas on every published release; edit the
# generator, not this file.
class AgentContainer < Formula
  desc "Run Claude Code, Codex CLI, and Grok CLI in Apple container Micro-VMs"
  homepage "https://github.com/loadchange/agent-container"
  version "0.1.4"
  sha256 "a93ccc68bc7a6a72e56348408577aeabd75d907121f2d6d1923c25c64f4c8653"
  url "https://github.com/loadchange/agent-container/releases/download/v0.1.4/agent-container-darwin-arm64.tar.gz"

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
