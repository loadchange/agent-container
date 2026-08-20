#!/bin/bash
set -euo pipefail

# Reproducible local release builder.
#
#   scripts/build-release.sh [--tarball]
#
# 1. builds the launcher twice in isolated target directories, strips and
#    ad-hoc codesigns each build, and proves both are byte-identical;
# 2. refreshes the plain target/release build used by source-tree shims;
# 3. stages the complete flat release layout under dist/ together with the
#    full manifest produced by scripts/generate-manifest.sh;
# 4. with --tarball, also packs agent-container-darwin-arm64.tar.gz, the
#    single payload asset shared by the installer and the Homebrew formula
#    in Formula/ (GitHub Release asset names cannot contain "/", so the
#    per-file layout is shipped inside the tarball instead).
#
# The native launcher is never committed to git. CI, the installer's local
# source-checkout mode, and the Homebrew workflow all consume dist/.

readonly PROGRAM_NAME="build-release"

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

die() {
  echo "$PROGRAM_NAME: Error: $*" >&2
  exit 1
}

usage_die() {
  echo "$PROGRAM_NAME: Error: $*" >&2
  echo "Usage: scripts/build-release.sh [--tarball]" >&2
  exit 64
}

pack_tarball=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tarball)
      pack_tarball=true
      shift
      ;;
    -h|--help)
      sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) usage_die "unknown argument '$1'." ;;
  esac
done

[ "$(uname -s 2>/dev/null || true)" = "Darwin" ] \
  || die "agent-container releases are built on macOS only."
[ "$(uname -m 2>/dev/null || true)" = "arm64" ] \
  || die "agent-container releases require Apple silicon."
command -v cargo >/dev/null 2>&1 \
  || die "Cargo is required to build the launcher."
for required_tool in /usr/bin/strip /usr/bin/codesign /usr/bin/file; do
  [ -x "$required_tool" ] \
    || die "Required macOS tool is unavailable: $required_tool"
done

build_root=$(mktemp -d "${TMPDIR:-/tmp}/agent-container-release.XXXXXX")
trap 'rm -rf -- "$build_root"' EXIT
build_one="$build_root/release-one"
build_two="$build_root/release-two"

for target_dir in "$build_one" "$build_two"; do
  CARGO_INCREMENTAL=0 CARGO_TARGET_DIR="$target_dir" \
    cargo build \
      --locked \
      --offline \
      --release \
      --manifest-path "$repo_root/Cargo.toml" \
      --bin agent-container-launcher

  artifact="$target_dir/release/agent-container-launcher"
  /usr/bin/strip "$artifact"
  /usr/bin/codesign --force --sign - "$artifact"
  [ "$(/usr/bin/file -b "$artifact")" = "Mach-O 64-bit executable arm64" ] \
    || die "The built launcher is not a thin arm64 Mach-O executable."
  /usr/bin/codesign --verify --strict "$artifact"
  /usr/bin/codesign -dvv "$artifact" 2>&1 \
    | grep -F 'Signature=adhoc' >/dev/null \
    || die "The built launcher does not carry an ad-hoc signature."
done

cmp "$build_one/release/agent-container-launcher" \
  "$build_two/release/agent-container-launcher" \
  || die "The two launcher builds are not byte-identical; the release is not reproducible."

# Source-tree shims and the live test suite use the plain unsigned build.
cargo build --locked --offline --release \
  --manifest-path "$repo_root/Cargo.toml" \
  --bin agent-container-launcher >/dev/null

dist_dir="$repo_root/dist"
rm -rf -- "$dist_dir"
mkdir -- "$dist_dir" "$dist_dir/profiles"

install -m 0755 \
  "$build_one/release/agent-container-launcher" \
  "$dist_dir/agent-container-darwin-arm64"
install -m 0755 \
  "$repo_root/runtime/agent-container-runtime" \
  "$dist_dir/agent-container-runtime"
install -m 0755 "$repo_root/runtime/entrypoint.sh" \
  "$dist_dir/entrypoint.sh"
install -m 0755 "$repo_root/runtime/host-exec-client" \
  "$dist_dir/host-exec-client"
install -m 0755 \
  "$repo_root/runtime/agent-workspace-connect" \
  "$dist_dir/agent-workspace-connect"
install -m 0755 \
  "$repo_root/runtime/agent-workspace-session" \
  "$dist_dir/agent-workspace-session"
install -m 0644 "$repo_root/runtime/Containerfile" \
  "$dist_dir/Containerfile"
install -m 0644 "$repo_root/runtime/Containerfile.dockerignore" \
  "$dist_dir/Containerfile.dockerignore"
install -m 0644 "$repo_root/runtime/host-exec-broker.mjs" \
  "$dist_dir/host-exec-broker.mjs"
for profile_id in claude codex grok; do
  install -m 0644 "$repo_root/profiles/$profile_id.json" \
    "$dist_dir/profiles/$profile_id.json"
done

"$repo_root/scripts/generate-manifest.sh" \
  --binary "$dist_dir/agent-container-darwin-arm64" \
  > "$dist_dir/release-manifest.sha256"

# Fail early on the same shell-asset validation the installer performs on
# download, so a broken release never reaches dist/.
bash -n \
  "$dist_dir/agent-container-runtime" \
  "$dist_dir/entrypoint.sh" \
  "$dist_dir/host-exec-client" \
  "$dist_dir/agent-workspace-connect" \
  "$dist_dir/agent-workspace-session" \
  || die "A staged shell asset failed syntax validation."

if [ "$pack_tarball" = true ]; then
  tarball="$dist_dir/agent-container-darwin-arm64.tar.gz"
  COPYFILE_DISABLE=1 tar -czf "$tarball" -C "$dist_dir" \
    agent-container-darwin-arm64 \
    agent-container-runtime \
    Containerfile \
    Containerfile.dockerignore \
    entrypoint.sh \
    host-exec-client \
    host-exec-broker.mjs \
    agent-workspace-connect \
    agent-workspace-session \
    profiles/claude.json \
    profiles/codex.json \
    profiles/grok.json \
    release-manifest.sha256
  echo "Built tarball:           $tarball"
fi

echo "Built launcher:          $dist_dir/agent-container-darwin-arm64"
echo "Staged release assets:   $dist_dir"
