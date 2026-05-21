# Interactive Claude Code session image for in-cluster pods, driven remotely
# via /remote-control (claude.ai/code + mobile). Carries the toolset used to
# operate this homelab: git, kubectl, helm, jq, yq, gh, plus the Claude CLI.
FROM node:22-bookworm-slim

ARG CLAUDE_CODE_VERSION=2.1.146
ARG KUBECTL_VERSION=v1.30.6
ARG HELM_VERSION=v3.16.3
ARG YQ_VERSION=v4.44.3

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates jq openssh-client less vim ripgrep gnupg \
      tmux \
    && rm -rf /var/lib/apt/lists/*

# kubectl
RUN curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl

# helm
RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
      | tar -xz -C /tmp && mv /tmp/linux-amd64/helm /usr/local/bin/helm \
    && rm -rf /tmp/linux-amd64

# yq
RUN curl -fsSLo /usr/local/bin/yq \
      "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    && chmod +x /usr/local/bin/yq

# gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI (pinned)
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Run as the base image's existing UID-1000 user (node). Its HOME (/home/node)
# is where Claude login/session state lives — we persist that on a PVC so the
# /remote-control login survives pod restarts.
USER node
WORKDIR /workspace

# Keepalive entrypoint: the pod stays up; you `kubectl exec -it` to attach,
# start an interactive `claude`, then run /remote-control to drive it from
# any device. (Claude isn't started here so attaching gives a clean TTY.)
CMD ["sleep", "infinity"]
