#!/bin/bash
set -euo pipefail

# Generates the release manifest in one canonical asset order. Two shapes share
# that order:
#
#   scripts/generate-manifest.sh                tree manifest (no native
#                                               launcher; tracked in git)
#   scripts/generate-manifest.sh --binary PATH  full release manifest with the
#                                               native launcher first (uploaded
#                                               with each GitHub Release)
#   scripts/generate-manifest.sh --check        verify the tracked tree
#                                               manifest matches the sources
#
# The flat release names and their order mirror the ASSETS array in install.sh
# and the staging list in scripts/build-release.sh; keep the three in sync.

readonly PROGRAM_NAME="generate-manifest"

# Flat release name -> repository source path.
readonly RELEASE_ASSET_SOURCES=(
  "agent-container-runtime:runtime/agent-container-runtime"
  "Containerfile:runtime/Containerfile"
  "Containerfile.dockerignore:runtime/Containerfile.dockerignore"
  "entrypoint.sh:runtime/entrypoint.sh"
  "host-exec-client:runtime/host-exec-client"
  "host-exec-broker.mjs:runtime/host-exec-broker.mjs"
  "agent-workspace-connect:runtime/agent-workspace-connect"
  "agent-workspace-session:runtime/agent-workspace-session"
  "profiles/claude.json:runtime/profiles/claude.json"
  "profiles/codex.json:runtime/profiles/codex.json"
  "profiles/grok.json:runtime/profiles/grok.json"
)

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

die() {
  echo "$PROGRAM_NAME: Error: $*" >&2
  exit 1
}

usage_die() {
  echo "$PROGRAM_NAME: Error: $*" >&2
  echo "Usage: scripts/generate-manifest.sh [--binary PATH | --check]" >&2
  exit 64
}

binary_path=""
check_mode=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --binary)
      [ "$#" -ge 2 ] || usage_die "--binary requires a path."
      binary_path=$2
      shift 2
      ;;
    --binary=*)
      binary_path=${1#--binary=}
      [ -n "$binary_path" ] || usage_die "--binary requires a path."
      shift
      ;;
    --check)
      check_mode=true
      shift
      ;;
    -h|--help)
      sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) usage_die "unknown argument '$1'." ;;
  esac
done

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "shasum or sha256sum is required."
  fi
}

emit_manifest() {
  local release_asset source_path

  if [ -n "$binary_path" ]; then
    [ -f "$binary_path" ] && [ ! -L "$binary_path" ] \
      || die "The native launcher is not a regular file: $binary_path"
    printf '%s  agent-container-darwin-arm64\n' \
      "$(sha256_file "$binary_path")"
  fi
  for release_asset in "${RELEASE_ASSET_SOURCES[@]}"; do
    source_path=${release_asset#*:}
    [ -f "$repo_root/$source_path" ] && [ ! -L "$repo_root/$source_path" ] \
      || die "Release asset is missing from the repository: $source_path"
    printf '%s  %s\n' \
      "$(sha256_file "$repo_root/$source_path")" "${release_asset%%:*}"
  done
}

if [ "$check_mode" = true ]; then
  tracked_manifest="$repo_root/release-manifest.sha256"
  [ -f "$tracked_manifest" ] && [ ! -L "$tracked_manifest" ] \
    || die "The tracked release manifest is missing: $tracked_manifest"
  generated_manifest=$(mktemp)
  trap 'rm -f -- "$generated_manifest"' EXIT
  binary_path=""
  emit_manifest > "$generated_manifest"
  if ! cmp -s "$generated_manifest" "$tracked_manifest"; then
    diff -u "$tracked_manifest" "$generated_manifest" >&2 || true
    die "release-manifest.sha256 does not match the repository sources; regenerate it with scripts/generate-manifest.sh."
  fi
  echo "release-manifest.sha256 matches ${#RELEASE_ASSET_SOURCES[@]} tracked release assets."
  exit 0
fi

emit_manifest
