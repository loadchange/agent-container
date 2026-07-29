ARG BASE_IMAGE=docker.io/library/node:22-bookworm-slim@sha256:6c74791e557ce11fc957704f6d4fe134a7bc8d6f5ca4403205b2966bd488f6b3
FROM ${BASE_IMAGE}

ARG AGENT_PACKAGE
ARG AGENT_VERSION
ARG AGENT_COMMAND
ARG AGENT_PROBE_ARG=--version

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
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
        util-linux \
    && rm -rf /var/lib/apt/lists/*

# A profile selects one pinned Linux Agent CLI. Validate every build argument
# before the shell uses it; profiles are data, never shell fragments.
RUN case "${AGENT_PACKAGE}" in ''|*[!A-Za-z0-9@._/-]*) exit 64 ;; esac \
    && case "${AGENT_VERSION}" in ''|*[!A-Za-z0-9._+-]*) exit 64 ;; esac \
    && case "${AGENT_COMMAND}" in ''|*[!A-Za-z0-9._-]*) exit 64 ;; esac \
    && case "${AGENT_PROBE_ARG}" in --version|-V|version) ;; *) exit 64 ;; esac \
    && npm install --global "${AGENT_PACKAGE}@${AGENT_VERSION}" \
    && command -v "${AGENT_COMMAND}" \
    && "${AGENT_COMMAND}" "${AGENT_PROBE_ARG}"

ENV AGENT_CONTAINER=1 \
    IS_SANDBOX=1 \
    NODE_OPTIONS=--max-old-space-size=3072

RUN mkdir -p /workspace /Users \
    && chmod 0755 /workspace /Users

COPY entrypoint.sh /usr/local/bin/agent-container-entrypoint
RUN chmod 0755 /usr/local/bin/agent-container-entrypoint

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/agent-container-entrypoint"]
