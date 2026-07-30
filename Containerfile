ARG BASE_IMAGE=mirror.gcr.io/library/debian:bookworm-slim@sha256:9b67294679b30e5d6ab257b40594feeb4a4b81f7fcf4131f4decf0d6a212a9b0
FROM ${BASE_IMAGE}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        bubblewrap \
        ca-certificates \
        curl \
        file \
        git \
        gh \
        jq \
        less \
        openssh-client \
        procps \
        ripgrep \
        tar \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

# Keep profile-specific ARGs below the common tool layer so Claude, Codex, and
# Grok share one cached Debian setup instead of reinstalling it per profile.
ARG AGENT_PROFILE
ARG AGENT_INSTALLER_URL
ARG AGENT_INSTALLER_SHELL
ARG AGENT_INSTALLER_VERSION_ENV
ARG AGENT_INSTALLER_BIN_DIR_ENV
ARG AGENT_INSTALLER_HOME_ENV
ARG AGENT_INSTALLER_NONINTERACTIVE_ENV
ARG AGENT_VERSION
ARG AGENT_COMMAND
ARG AGENT_PROBE_ARG=--version

# Profiles select one official native installer. The host resolves every
# floating publisher channel to an exact version before this build begins, so
# the version participates in both the layer cache key and image provenance.
RUN set -eu; \
    case "${AGENT_PROFILE}" in claude|codex|grok) ;; *) exit 64 ;; esac; \
    case "${AGENT_INSTALLER_URL}" in https://*) ;; *) exit 64 ;; esac; \
    case "${AGENT_INSTALLER_URL}" in *[!A-Za-z0-9._:/-]*) exit 64 ;; esac; \
    case "${AGENT_INSTALLER_SHELL}" in bash|sh) ;; *) exit 64 ;; esac; \
    printf '%s\n' "${AGENT_VERSION}" \
      | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9._-]*)?(\+[A-Za-z0-9][A-Za-z0-9._-]*)?$'; \
    case "${AGENT_COMMAND}" in ''|*[!A-Za-z0-9._-]*) exit 64 ;; esac; \
    case "${AGENT_PROBE_ARG}" in --version|-V|version) ;; *) exit 64 ;; esac; \
    for env_name in \
      "${AGENT_INSTALLER_VERSION_ENV}" \
      "${AGENT_INSTALLER_BIN_DIR_ENV}" \
      "${AGENT_INSTALLER_HOME_ENV}" \
      "${AGENT_INSTALLER_NONINTERACTIVE_ENV}"; do \
      case "$env_name" in \
        '') ;; \
        [A-Z_]*) case "$env_name" in *[!A-Z0-9_]*) exit 64 ;; esac ;; \
        *) exit 64 ;; \
      esac; \
    done; \
    case "${AGENT_PROFILE}" in \
      claude) \
        [ "${AGENT_COMMAND}" = claude ]; \
        [ "${AGENT_INSTALLER_URL}" = https://claude.ai/install.sh ]; \
        [ "${AGENT_INSTALLER_SHELL}" = bash ]; \
        [ -z "${AGENT_INSTALLER_VERSION_ENV}${AGENT_INSTALLER_BIN_DIR_ENV}${AGENT_INSTALLER_HOME_ENV}${AGENT_INSTALLER_NONINTERACTIVE_ENV}" ]; \
        ;; \
      codex) \
        [ "${AGENT_COMMAND}" = codex ]; \
        [ "${AGENT_INSTALLER_URL}" = https://chatgpt.com/codex/install.sh ]; \
        [ "${AGENT_INSTALLER_SHELL}" = sh ]; \
        [ "${AGENT_INSTALLER_VERSION_ENV}" = CODEX_RELEASE ]; \
        [ "${AGENT_INSTALLER_BIN_DIR_ENV}" = CODEX_INSTALL_DIR ]; \
        [ "${AGENT_INSTALLER_HOME_ENV}" = CODEX_HOME ]; \
        [ "${AGENT_INSTALLER_NONINTERACTIVE_ENV}" = CODEX_NON_INTERACTIVE ]; \
        ;; \
      grok) \
        [ "${AGENT_COMMAND}" = grok ]; \
        [ "${AGENT_INSTALLER_URL}" = https://x.ai/cli/install.sh ]; \
        [ "${AGENT_INSTALLER_SHELL}" = bash ]; \
        [ -z "${AGENT_INSTALLER_VERSION_ENV}${AGENT_INSTALLER_HOME_ENV}${AGENT_INSTALLER_NONINTERACTIVE_ENV}" ]; \
        [ "${AGENT_INSTALLER_BIN_DIR_ENV}" = GROK_BIN_DIR ]; \
        ;; \
    esac; \
    install_home=/opt/agent-native; \
    install_bin="$install_home/.local/bin"; \
    installer_file=/tmp/agent-native-installer; \
    install -d -m 0755 "$install_home" "$install_bin" /usr/local/bin; \
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
      --retry 5 --retry-all-errors \
      "${AGENT_INSTALLER_URL}" --output "$installer_file"; \
    chmod 0600 "$installer_file"; \
    set -- env \
      "HOME=$install_home" \
      "PATH=$install_bin:$PATH" \
      "SHELL=/bin/false" \
      "XDG_CACHE_HOME=$install_home/.cache" \
      "XDG_DATA_HOME=$install_home/.local/share" \
      "XDG_STATE_HOME=$install_home/.local/state"; \
    if [ -n "${AGENT_INSTALLER_VERSION_ENV}" ]; then \
      set -- "$@" "${AGENT_INSTALLER_VERSION_ENV}=${AGENT_VERSION}"; \
    fi; \
    if [ -n "${AGENT_INSTALLER_BIN_DIR_ENV}" ]; then \
      set -- "$@" "${AGENT_INSTALLER_BIN_DIR_ENV}=$install_bin"; \
    fi; \
    if [ -n "${AGENT_INSTALLER_HOME_ENV}" ]; then \
      set -- "$@" "${AGENT_INSTALLER_HOME_ENV}=$install_home/.codex"; \
    fi; \
    if [ -n "${AGENT_INSTALLER_NONINTERACTIVE_ENV}" ]; then \
      set -- "$@" "${AGENT_INSTALLER_NONINTERACTIVE_ENV}=1"; \
    fi; \
    set -- "$@" "${AGENT_INSTALLER_SHELL}" "$installer_file"; \
    if [ -z "${AGENT_INSTALLER_VERSION_ENV}" ]; then \
      set -- "$@" "${AGENT_VERSION}"; \
    fi; \
    "$@"; \
    test -x "$install_bin/${AGENT_COMMAND}"; \
    resolved_target=$(readlink -f "$install_bin/${AGENT_COMMAND}"); \
    case "$resolved_target" in "$install_home"/*) ;; *) exit 65 ;; esac; \
    chmod -R a+rX "$install_home"; \
    if [ "${AGENT_PROFILE}" = codex ]; then \
      codex_release="$install_home/.codex/packages/standalone/releases/${AGENT_VERSION}-aarch64-unknown-linux-musl"; \
      [ "$resolved_target" = "$codex_release/bin/codex" ]; \
      test -f "$codex_release/codex-package.json"; \
      test -x "$codex_release/bin/codex"; \
      test -x "$codex_release/bin/codex-code-mode-host"; \
      test -x "$codex_release/codex"; \
      test -x "$codex_release/codex-path/rg"; \
      test -x "$codex_release/codex-resources/bwrap"; \
      ln -s "$install_bin/${AGENT_COMMAND}" "/usr/local/bin/${AGENT_COMMAND}"; \
    else \
      install -m 0755 "$resolved_target" "/usr/local/bin/${AGENT_COMMAND}"; \
      rm -rf "$install_home"; \
    fi; \
    rm -f "$installer_file"; \
    native_file=$(file -L "/usr/local/bin/${AGENT_COMMAND}"); \
    printf '%s\n' "$native_file" | grep -Eq 'ELF 64-bit.*ARM aarch64'; \
    version_output=$("/usr/local/bin/${AGENT_COMMAND}" "${AGENT_PROBE_ARG}" 2>&1); \
    reported_version=$(printf '%s\n' "$version_output" \
      | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([A-Za-z0-9._+-]*)?' \
      | head -n 1); \
    [ "$reported_version" = "${AGENT_VERSION}" ]

ENV AGENT_CONTAINER=1 \
    IS_SANDBOX=1

RUN mkdir -p /workspace /Users \
    && chmod 0755 /workspace /Users

COPY entrypoint.sh /usr/local/bin/agent-container-entrypoint
RUN chmod 0755 /usr/local/bin/agent-container-entrypoint

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/agent-container-entrypoint"]
