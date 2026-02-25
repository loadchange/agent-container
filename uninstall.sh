#!/bin/bash
set -euo pipefail

INSTALL_DIR="$HOME/.local/bin"
COMMAND_NAME="claude-docker"
IMAGE_NAME="claude-code-docker"
VOLUME_NAME="claude-code-local"

echo "Uninstalling $COMMAND_NAME..."

# 1. Remove Executable
if [ -f "$INSTALL_DIR/$COMMAND_NAME" ]; then
  rm "$INSTALL_DIR/$COMMAND_NAME"
  echo "Removed executable: $INSTALL_DIR/$COMMAND_NAME"
fi

# 2. Remove Config Files
if [ -d "$HOME/.claude-docker" ]; then
  read -r -p "Do you want to remove the configuration directory (~/.claude-docker)? [y/N] " response
  if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    rm -rf "$HOME/.claude-docker"
    echo "Removed directory: $HOME/.claude-docker"
  else
    echo "Skipped: $HOME/.claude-docker"
  fi
fi

if [ -f "$HOME/.claude-docker.json" ]; then
  read -r -p "Do you want to remove the onboarding state file (~/.claude-docker.json)? [y/N] " response
  if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    rm "$HOME/.claude-docker.json"
    echo "Removed file: $HOME/.claude-docker.json"
  else
    echo "Skipped: $HOME/.claude-docker.json"
  fi
fi

# 3. Remove Docker Image
if docker image inspect "$IMAGE_NAME" > /dev/null 2>&1; then
  docker rmi -f "$IMAGE_NAME" > /dev/null 2>&1 || echo "Warning: Could not remove Docker image $IMAGE_NAME."
  echo "Removed Docker image: $IMAGE_NAME"
fi

# 4. Remove Docker Volume
if docker volume inspect "$VOLUME_NAME" > /dev/null 2>&1; then
  docker volume rm "$VOLUME_NAME" > /dev/null 2>&1 || echo "Warning: Could not remove Docker volume $VOLUME_NAME."
  echo "Removed Docker volume: $VOLUME_NAME"
fi

echo ""
echo "$COMMAND_NAME has been successfully uninstalled."
