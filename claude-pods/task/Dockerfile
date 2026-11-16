# Task-worker image: the dispatcher-commanded author/test/merge stages and
# nothing interactive. Built by .github/workflows/claude-task-image.yml
# with context claude-pods/, so the stage entrypoints, lib/, prompts/ and
# skills/ below are the same files ../Dockerfile (the interactive session
# image) copies. README.md here owns the inventory, the image sizes and
# what still has to happen before the dispatcher execs into this image.

# Built from the reviewed dispatcher source; shares its typed wire contract.
#
# Every ARG pin below that ../Dockerfile also carries must match it while
# both images ship the worker; tests/image-pins.sh fails the suite when
# one is bumped without the other.
FROM golang:1.27 AS kaneo-worker
ARG KANEO_WORKER_REF=2c1a1ef40b73a15701cff586798bd5de95c610f3
RUN CGO_ENABLED=0 GOBIN=/out go install github.com/ChristopherScot/kaneo-dispatcher/cmd/kaneo-worker@${KANEO_WORKER_REF}

FROM node:22-trixie-slim

ARG CLAUDE_CODE_VERSION=2.1.325
# kubectl pinned near the cluster's k3s 1.30 (avoid large version skew).
ARG KUBECTL_VERSION=v1.30.6
# helm kept on v3 (v4 is a breaking major; chart compat).
ARG HELM_VERSION=v3.16.4
ARG YQ_VERSION=v4.53.2
ARG GO_VERSION=1.26.3
ARG TOFU_VERSION=1.12.0
# UTF-8 so tool output with multibyte glyphs is not mangled to "__".
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# git + gh for checkout and pull requests; jq/curl/ripgrep for the agent's
# allow-listed shell; build-essential so `go test` can build cgo packages
# and `make` targets run. flock, setsid and nohup (util-linux) and timeout
# (coreutils) come with the base: the dispatcher's launch line and busy
# probe need them, and image-smoke.sh checks they are there.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates jq ripgrep build-essential unzip \
    && rm -rf /var/lib/apt/lists/*

# gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# kubectl, helm, yq, tofu: the agent's allow-list (prompts/nightly-settings.json)
# permits all four, and the homelab tests call kubectl and yq directly.
RUN curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl \
    && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
      | tar -xz -C /tmp && mv /tmp/linux-amd64/helm /usr/local/bin/helm \
    && rm -rf /tmp/linux-amd64 \
    && curl -fsSLo /usr/local/bin/yq \
      "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    && chmod +x /usr/local/bin/yq \
    && curl -fsSLo /tmp/tofu.zip \
      "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_amd64.zip" \
    && unzip -o /tmp/tofu.zip tofu -d /usr/local/bin && rm /tmp/tofu.zip

# Go toolchain for the repos' own `go test ./...`. No gopls/dlv/goimports:
# those served the editor in the interactive image.
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
      | tar -xz -C /usr/local
ENV PATH=$PATH:/usr/local/go/bin:/home/node/go/bin
ENV GOPATH=/home/node/go

# Claude Code CLI, the TypeScript toolchain the agent is allowed to run, and
# agent-browser for cloud-browser work through `kbrowser` (no local browser
# or display here, same as the interactive image).
RUN npm install -g \
      @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
      agent-browser \
      typescript tsx \
    && npm cache clean --force

# claude-code ships its native binary twice (bin/claude.exe and the platform
# package). Hardlink them in the same layer: identical bytes once on disk.
# No chown of the npm tree: nothing in this image updates Claude Code at
# runtime (DISABLE_UPDATES below), so uid 1000 never needs to write there.
RUN set -eu; \
    a=/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe; \
    b=/usr/local/lib/node_modules/@anthropic-ai/claude-code/node_modules/@anthropic-ai/claude-code-linux-x64/claude; \
    if [ -f "$a" ] && [ -f "$b" ] && cmp -s "$a" "$b"; then ln -f "$a" "$b"; fi

# Version bumps are an image rebuild. The interactive image carries this in
# ~/.claude/settings.json and re-syncs it onto the home PVC every boot; an
# environment variable needs no home at all and survives any PVC state.
ENV DISABLE_UPDATES=1

# git authenticates through gh, and gh reads GH_TOKEN: the worker puts that
# token into every tool's environment (git, gh, claude) and the entrypoint
# exports it for its boot-time clones, so no login step, hosts.yml or
# ~/.git-credentials is needed. System scope, not global: $HOME may be a
# fresh PVC. The empty helper first is git's idiom for "reset the inherited
# helper list", so a PVC's global `credential.helper store` cannot be
# consulted ahead of gh.
RUN git config --system --add credential.https://github.com.helper '' \
    && git config --system --add credential.https://github.com.helper '!gh auth git-credential' \
    && git config --system --add credential.https://gist.github.com.helper '' \
    && git config --system --add credential.https://gist.github.com.helper '!gh auth git-credential'

# Every COPY source below must also be in claude-task-image.yml's paths:
# filter, or a change to it will not rebuild the image.
#
# The worker and its three entrypoints. Prompt instructions and task
# context come from immutable dispatcher commands; only the local tool
# permission settings ship here.
COPY --from=kaneo-worker /out/kaneo-worker /usr/local/bin/kaneo-worker
COPY --chmod=0755 stage-author.sh /usr/local/bin/stage-author
COPY --chmod=0755 stage-merge.sh /usr/local/bin/stage-merge
COPY --chmod=0755 stage-test.sh  /usr/local/bin/stage-test
# Paths are the worker's defaults (NIGHTLY_SETTINGS, and the maintenance
# script it looks for by name). lib/claude-account.sh is not copied: the
# Go worker does its own account failover, and that file serves desloppify.
COPY lib/maintenance.sh /usr/local/share/claude-pods/lib/maintenance.sh
COPY prompts/nightly-settings.json /usr/local/share/claude-pods/prompts/nightly-settings.json
# kbrowser + the two skills that route browser work to a Kernel cloud
# browser. The entrypoint copies skills from TASK_SKILLS_DIR into
# $HOME/.claude on every boot; the image decides the path once, here.
COPY --chmod=0755 kbrowser.sh /usr/local/bin/kbrowser
ENV TASK_SKILLS_DIR=/opt/claude-task/skills
COPY skills/ ${TASK_SKILLS_DIR}/
COPY --chmod=0755 task/entrypoint.sh /usr/local/bin/entrypoint

USER node
ENV HOME=/home/node
WORKDIR /workspace

# Clone the pod's repo list, then idle until the dispatcher execs a stage.
CMD ["/usr/local/bin/entrypoint"]
