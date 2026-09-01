#!/bin/sh
set -eu

setup_ca() {
  : "${AGENT_CA_FINGERPRINT:?AGENT_CA_FINGERPRINT is required}"

  ca_secret=/run/secrets/agent_ca_bundle
  case "$AGENT_CA_FINGERPRINT" in
    none)
      [ ! -s "$ca_secret" ]
      return
      ;;
  esac
  printf '%s\n' "$AGENT_CA_FINGERPRINT" \
    | grep -Eq '^[0-9a-f]{64}$' \
    || exit 64
  [ -s "$ca_secret" ]
  ca_size=$(wc -c < "$ca_secret" | tr -d '[:space:]')
  case "$ca_size" in
    ''|*[!0-9]*) exit 65 ;;
  esac
  [ "$ca_size" -le 1048576 ]
  [ "$(sha256sum "$ca_secret" | awk '{print $1}')" = "$AGENT_CA_FINGERPRINT" ]

  ca_dir=/usr/local/share/ca-certificates/agent-container
  install -d -m 0755 "$ca_dir"
  awk -v output_dir="$ca_dir" '
    BEGIN { inside = 0; count = 0; valid = 1 }
    /^-----BEGIN CERTIFICATE-----$/ {
      if (inside || count >= 64) valid = 0
      count += 1
      output = sprintf("%s/ca-%03d.crt", output_dir, count)
      inside = 1
      print > output
      next
    }
    /^-----END CERTIFICATE-----$/ {
      if (!inside) valid = 0
      if (inside) { print > output; close(output) }
      inside = 0
      next
    }
    inside && /^[A-Za-z0-9+\/=]+$/ { print > output; next }
    !inside && /^[[:space:]]*$/ { next }
    { valid = 0 }
    END { if (!valid || inside || count == 0 || count > 64) exit 1 }
  ' "$ca_secret"
  ca_count=0
  for ca_file in "$ca_dir"/*.crt; do
    [ -f "$ca_file" ]
    ca_count=$((ca_count + 1))
    openssl x509 -in "$ca_file" -noout >/dev/null
    openssl x509 -in "$ca_file" -checkend 0 -noout >/dev/null
    ca_not_before=$(openssl x509 -in "$ca_file" -startdate -noout)
    case "$ca_not_before" in
      notBefore=*) ;;
      *) exit 65 ;;
    esac
    ca_not_before=${ca_not_before#notBefore=}
    ca_not_before_epoch=$(date -u --date="$ca_not_before" '+%s')
    [ "$ca_not_before_epoch" -le "$(date -u '+%s')" ]
    openssl x509 -in "$ca_file" -noout -ext basicConstraints \
      | grep -Eq '^[[:space:]]*CA:TRUE([,[:space:]]|$)'
  done
  [ "$ca_count" -ge 1 ] && [ "$ca_count" -le 64 ]
  update-ca-certificates
}

setup_toolchain() {
  : "${NODE_VERSION:?NODE_VERSION is required}"
  : "${NODE_SHA:?NODE_SHA is required}"
  : "${PNPM_VERSION:?PNPM_VERSION is required}"
  : "${COREPACK_HOME:?COREPACK_HOME is required}"

  printf '%s\n' "$NODE_VERSION" \
    | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || exit 64
  printf '%s\n' "$NODE_SHA" \
    | grep -Eq '^[0-9a-f]{64}$' \
    || exit 64
  printf '%s\n' "$PNPM_VERSION" \
    | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || exit 64
  [ "$COREPACK_HOME" = /usr/local/lib/agent-corepack ] || exit 64

  node_archive="node-v${NODE_VERSION}-linux-arm64.tar.xz"
  node_url="https://nodejs.org/dist/v${NODE_VERSION}/${node_archive}"
  curl --disable --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    --retry 5 --retry-all-errors \
    "$node_url" --output "/tmp/$node_archive"
  printf '%s  %s\n' "$NODE_SHA" "/tmp/$node_archive" \
    | sha256sum --check --strict
  tar -xJf "/tmp/$node_archive" -C /usr/local --strip-components=1
  rm -f "/tmp/$node_archive"

  install -d -m 0755 "$COREPACK_HOME"
  corepack enable
  NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    corepack prepare "pnpm@${PNPM_VERSION}" --activate
  chmod -R a-w "$COREPACK_HOME"
  [ "$(node --version)" = "v${NODE_VERSION}" ]
  [ "$(pnpm --version)" = "$PNPM_VERSION" ]
  /usr/bin/python3 -c 'import sys; assert sys.version_info >= (3, 11)'

  probe_home=/tmp/agent-corepack-probe
  probe_uid=$(id -u nobody)
  probe_gid=$(id -g nobody)
  install -d -o "$probe_uid" -g "$probe_gid" -m 0700 "$probe_home"
  printf '{"packageManager":"pnpm@%s"}\n' "$PNPM_VERSION" \
    > "$probe_home/package.json"
  chown "$probe_uid:$probe_gid" "$probe_home/package.json"
  probe_pnpm_root="$probe_home/pnpm-data"
  set -- \
    /usr/bin/setpriv \
      --reuid="$probe_uid" --regid="$probe_gid" --clear-groups \
    /usr/bin/env \
      HOME="$probe_home" \
      XDG_CACHE_HOME="$probe_home/.cache" \
      COREPACK_HOME="$COREPACK_HOME" \
      COREPACK_ENABLE_NETWORK=0 \
      PNPM_CONFIG_STORE_DIR="$probe_pnpm_root/store" \
      PNPM_CONFIG_CACHE_DIR="$probe_pnpm_root/cache" \
      PNPM_CONFIG_STATE_DIR="$probe_pnpm_root/state" \
      PATH=/usr/local/bin:/usr/bin:/bin
  probe_version=$(cd "$probe_home" && "$@" pnpm --version)
  [ "$probe_version" = "$PNPM_VERSION" ]
  [ "$(cd "$probe_home" && "$@" pnpm config get store-dir)" \
    = "$probe_pnpm_root/store" ]
  [ "$(cd "$probe_home" && "$@" pnpm config get cache-dir)" \
    = "$probe_pnpm_root/cache" ]
  [ "$(cd "$probe_home" && "$@" pnpm config get state-dir)" \
    = "$probe_pnpm_root/state" ]
  probe_store_path=$(cd "$probe_home" && "$@" pnpm store path)
  case "$probe_store_path" in
    "$probe_pnpm_root/store"|"$probe_pnpm_root/store"/*) ;;
    *) exit 65 ;;
  esac
  [ ! -e "$probe_home/.cache/node/corepack" ]
  rm -rf "$probe_home"
}

[ "$#" -eq 1 ] || exit 64
case "$1" in
  ca) setup_ca ;;
  toolchain) setup_toolchain ;;
  *) exit 64 ;;
esac
