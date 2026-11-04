# The desloppify pod's image. Independent of claude-pods/ — that image is
# for interactive sessions and the nightly ticket pipeline, and nothing
# here belongs in it.
#
# Rebuilt by .github/workflows/desloppify-image.yml: pushing to main with
# changes under desloppify-pod/ builds and pushes
# ghcr.io/christopherscot/desloppify-pod:latest. To build a branch,
# `gh workflow run desloppify-image.yml --ref <branch>`.
#
# node, not python, as the base: desloppify's TypeScript detectors shell
# out to npx, tsc, eslint, knip and vitest, and the agent runs `yarn lint`
# against the code it just changed. Python is the easier of the two to add.
FROM node:22-trixie-slim

ARG CLAUDE_CODE_VERSION=2.1.310

# git and gh for the clone and the pull requests; python for desloppify;
# build-essential because several of its analysers build native extensions.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates jq less \
      python3 python3-venv python3-dev build-essential \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# yarn 4 via corepack: the repo pins its own release in .yarn/, and
# corepack honours the packageManager field rather than overriding it.
RUN corepack enable

# The venv keeps pip clear of the site-packages Debian manages.
ENV DESLOPPIFY_VENV=/opt/desloppify-venv
RUN python3 -m venv "$DESLOPPIFY_VENV" \
    && "$DESLOPPIFY_VENV/bin/pip" install --no-cache-dir --upgrade pip \
    && "$DESLOPPIFY_VENV/bin/pip" install --no-cache-dir \
         "desloppify[full]" claude-agent-sdk
ENV PATH="/opt/desloppify-venv/bin:${PATH}"


# The Agent SDK spawns this binary, which is what authenticates the run
# against the subscription rather than the API.
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force

COPY --chmod=755 nightly-desloppify.sh verify-token-scope.sh /usr/local/bin/
COPY policy.py run.py /usr/local/share/desloppify-pod/
COPY --chmod=755 git-hooks/ /usr/local/share/desloppify-pod/git-hooks/

# Runs as the base image's node user. $HOME holds the Claude CLI's state
# and is persisted on a PVC.
USER node
ENV HOME=/home/node
WORKDIR /workspace

CMD ["sleep", "infinity"]
