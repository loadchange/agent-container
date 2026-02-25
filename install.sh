#!/bin/bash
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/loadchange/claude-docker/main/claude-docker"
INSTALL_DIR="$HOME/.local/bin"
COMMAND_NAME="claude-docker"

echo "Installing $COMMAND_NAME..."

# --- Create installation directory ---
mkdir -p "$INSTALL_DIR"

# --- Download and place the script ---
curl -fsSL "$REPO_URL" -o "$INSTALL_DIR/$COMMAND_NAME"
chmod +x "$INSTALL_DIR/$COMMAND_NAME"

# --- Check PATH ---
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  echo ""
  echo "Warning: $INSTALL_DIR is not in your PATH."
  echo "Add the following to your shell profile (~/.zshrc, ~/.bashrc, etc.):"
  echo ""
  echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
  echo ""
fi

echo "Installed $COMMAND_NAME to $INSTALL_DIR/$COMMAND_NAME"
echo ""
echo "Run 'claude-docker' to start Claude Code in Docker."
