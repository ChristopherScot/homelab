# Interactive Claude Code session image for in-cluster pods, driven remotely
# via /remote-control (claude.ai/code + mobile). Carries the toolset used to
# operate this homelab: git, kubectl, helm, jq, yq, gh, plus the Claude CLI.
# trixie (Debian 13, GLIBC 2.41) — bookworm's GLIBC 2.36 is too old for the
# tree-sitter CLI LazyVim/nvim-treesitter use (needs GLIBC_2.39+), which broke
# grammar builds + cascaded into LSP/parse errors.
FROM node:22-trixie-slim

ARG CLAUDE_CODE_VERSION=2.1.152
# kubectl pinned near the cluster's k3s 1.30 (avoid large version skew).
ARG KUBECTL_VERSION=v1.30.6
# helm kept on v3 (v4 is a breaking major; chart compat).
ARG HELM_VERSION=v3.16.4
ARG YQ_VERSION=v4.53.2
ARG GO_VERSION=1.26.3
ARG TOFU_VERSION=1.12.0
ARG NVIM_VERSION=v0.12.2
# Rootless image builds in-pod (buildkit + rootlesskit). Daemonless, unprivileged
# — no Docker-in-Docker, no privileged container. Needs uidmap (installed above)
# + /etc/subuid mapping (present in the base node image as node:100000:65536).
ARG BUILDKIT_VERSION=v0.18.2
ARG ROOTLESSKIT_VERSION=v2.3.1

# UTF-8 locale so multibyte glyphs (starship ❯, eza/nvim icons) render instead
# of garbling to "__". The slim base leaves LANG unset -> programs default to
# the C locale and mangle UTF-8. C.UTF-8 is built in, no locale-gen needed.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates jq openssh-client less vim ripgrep gnupg \
      tmux unzip build-essential \
      zsh fzf fd-find \
      uidmap \
    && rm -rf /var/lib/apt/lists/*

# Neovim — latest from the official release tarball (Debian's apt nvim is far
# too old for modern lazy.nvim/treesitter/telescope).
RUN curl -fsSL "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-x86_64.tar.gz" \
      | tar -xz -C /opt \
    && ln -s /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim

# eza (modern ls) — from the official apt repo
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
      | gpg --dearmor -o /etc/apt/keyrings/gierens.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
      > /etc/apt/sources.list.d/gierens.list \
    && apt-get update && apt-get install -y --no-install-recommends eza \
    && rm -rf /var/lib/apt/lists/*

# BuildKit + RootlessKit for in-pod image builds (build + push to a registry;
# no local container runtime). Driven by the `dbuild` wrapper, which starts a
# rootless buildkitd on demand. Verified the rootless path works on the k3s
# nodes given uidmap + the base image's /etc/subuid mapping.
RUN curl -fsSL "https://github.com/moby/buildkit/releases/download/${BUILDKIT_VERSION}/buildkit-${BUILDKIT_VERSION}.linux-amd64.tar.gz" \
      | tar -xz -C /usr/local bin/buildctl bin/buildkitd bin/buildkit-runc \
    && curl -fsSL "https://github.com/rootless-containers/rootlesskit/releases/download/${ROOTLESSKIT_VERSION}/rootlesskit-x86_64.tar.gz" \
      | tar -xz -C /usr/local/bin rootlesskit \
    && chmod +x /usr/local/bin/buildctl /usr/local/bin/buildkitd /usr/local/bin/buildkit-runc /usr/local/bin/rootlesskit

# starship prompt + zoxide (smart cd) — official installers to /usr/local/bin
RUN curl -fsSL https://starship.rs/install.sh | sh -s -- -y \
    && curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh \
      | sh -s -- --bin-dir /usr/local/bin

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

# Google Cloud SDK (gcloud) — for the GCP deployment target: Secret Manager,
# Artifact Registry, GCE. Core + gke-gcloud-auth-plugin (GKE auth) + gsutil.
# One image serves both homelab (kubectl/helm) and GCP envs.
RUN curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
      > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin \
    && rm -rf /var/lib/apt/lists/*

# Go
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
      | tar -xz -C /usr/local
ENV PATH=$PATH:/usr/local/go/bin:/home/node/go/bin
ENV GOPATH=/home/node/go

# Go LSP + tooling installed to /usr/local/bin so they are ALWAYS on PATH,
# independent of the (PVC-mounted) home shell config. gopls = the Go LSP that
# LazyVim attaches; gofumpt/goimports for formatting. (dlv installed below.)
RUN GOBIN=/usr/local/bin /usr/local/go/bin/go install golang.org/x/tools/gopls@latest \
    && GOBIN=/usr/local/bin /usr/local/go/bin/go install golang.org/x/tools/cmd/goimports@latest \
    && GOBIN=/usr/local/bin /usr/local/go/bin/go install mvdan.cc/gofumpt@latest \
    && /usr/local/go/bin/go clean -cache -modcache

# OpenTofu (open-source Terraform; `tofu` CLI)
RUN curl -fsSLo /tmp/tofu.zip \
      "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_amd64.zip" \
    && unzip -o /tmp/tofu.zip tofu -d /usr/local/bin && rm /tmp/tofu.zip

# Dev-experience CLI tools:
#   lazygit  — git TUI (heavy git workflow in these pods)
#   delta    — syntax-highlighted git diffs/pager
#   direnv   — per-repo env via .envrc
ARG LAZYGIT_VERSION=0.44.1
ARG DELTA_VERSION=0.18.2
ARG DIRENV_VERSION=2.35.0
RUN curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz" \
      | tar -xz -C /usr/local/bin lazygit \
    && curl -fsSL "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/delta-${DELTA_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
      | tar -xz -C /tmp \
    && mv "/tmp/delta-${DELTA_VERSION}-x86_64-unknown-linux-gnu/delta" /usr/local/bin/ \
    && rm -rf "/tmp/delta-${DELTA_VERSION}-x86_64-unknown-linux-gnu" \
    && curl -fsSLo /usr/local/bin/direnv \
      "https://github.com/direnv/direnv/releases/download/v${DIRENV_VERSION}/direnv.linux-amd64" \
    && chmod +x /usr/local/bin/direnv

# Go debugger (delve) for in-editor DAP debugging of Go.
RUN GOBIN=/usr/local/bin /usr/local/go/bin/go install github.com/go-delve/delve/cmd/dlv@latest \
    && /usr/local/go/bin/go clean -cache -modcache

# croc — secure relay-based file transfer between any two networks (no inbound
# connectivity needed). Used to pull files into a pod from a laptop on a
# different network: `croc send <file>` there, `croc --yes <code>` here.
ARG CROC_VERSION=v10.4.4
RUN curl -fsSL "https://github.com/schollz/croc/releases/download/${CROC_VERSION}/croc_${CROC_VERSION}_Linux-64bit.tar.gz" \
      | tar -xz -C /tmp croc && mv /tmp/croc /usr/local/bin/croc \
    && chmod +x /usr/local/bin/croc

# VS Code CLI for `code tunnel` — remote VS Code over Microsoft's tunnel infra
# (no inbound network needed, same survivability story as the RC loop). Connect
# from desktop VS Code (Remote Tunnels extension) or vscode.dev/tunnel/<name>.
# First boot needs a one-time GitHub device-code login: `tmux attach -t vscode`,
# follow the URL, detach. Login state + downloaded VS Code Server live under
# $HOME (persistent PVC), so the tunnel auto-resumes across restarts.
RUN curl -fsSL "https://code.visualstudio.com/sha/download?build=stable&os=cli-linux-x64" \
      -o /tmp/vscode-cli.tar.gz \
    && tar -xz -C /usr/local/bin -f /tmp/vscode-cli.tar.gz \
    && rm /tmp/vscode-cli.tar.gz \
    && chmod +x /usr/local/bin/code

# Claude Code CLI + TypeScript toolchain (node base already present).
# agent-browser = browser-automation CLI for agents. NO `agent-browser install`
# here: it would download a local Chrome, but this image ships no browser/display
# and runs rootless — the browser lives in Kernel's cloud (kernel.sh) and
# agent-browser connects out over CDP. See the `kernel` skill + `kbrowser`.
RUN npm install -g \
      @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
      agent-browser \
      typescript ts-node tsx

# Neovim: LazyVim distribution — full IDE-grade setup (LSP, autocomplete via
# mason, treesitter, telescope, lazygit integration, formatters, DAP debugging,
# neotest) preconfigured + maintained. We enable language + tooling EXTRAS via
# lazyvim.json: Go (gopls + delve DAP + neotest-go), TypeScript (ts LSP +
# js-debug DAP + vitest), Terraform, plus the dap, neotest, and formatting
# extras. Plugins themselves install on first `nvim` launch (network needed).
COPY nvim-options.lua /tmp/nvim-options.lua
RUN git clone --depth 1 https://github.com/LazyVim/starter /home/node/.config/nvim \
    && rm -rf /home/node/.config/nvim/.git \
    && cat /tmp/nvim-options.lua >> /home/node/.config/nvim/lua/config/options.lua \
    && rm /tmp/nvim-options.lua \
    && printf '%s\n' \
      '{' \
      '  "extras": [' \
      '    "lazyvim.plugins.extras.coding.yanky",' \
      '    "lazyvim.plugins.extras.dap.core",' \
      '    "lazyvim.plugins.extras.test.core",' \
      '    "lazyvim.plugins.extras.editor.telescope",' \
      '    "lazyvim.plugins.extras.formatting.prettier",' \
      '    "lazyvim.plugins.extras.lang.go",' \
      '    "lazyvim.plugins.extras.lang.typescript",' \
      '    "lazyvim.plugins.extras.lang.terraform",' \
      '    "lazyvim.plugins.extras.lang.json",' \
      '    "lazyvim.plugins.extras.lang.docker",' \
      '    "lazyvim.plugins.extras.lang.markdown"' \
      '  ],' \
      '  "news": { "NEWS.md": "10000" },' \
      '  "version": 8' \
      '}' \
      > /home/node/.config/nvim/lazyvim.json \
    && chown -R 1000:1000 /home/node/.config
# Disable yanky's system-clipboard sync (a FocusGained OSC 52 read that popped
# the macOS "attempting to read from the clipboard" prompt). See nvim-options.lua.
COPY --chown=1000:1000 nvim-clipboard.lua /home/node/.config/nvim/lua/plugins/clipboard.lua

# Shell: oh-my-zsh + starship + zoxide + eza aliases (nexxeln-style workflow).
# PATH/exports/aliases/starship go in $ZSH_CUSTOM (sourced after oh-my-zsh.sh).
# BUT zoxide + direnv MUST init at the very END of .zshrc (they warn / mis-hook
# otherwise — $ZSH_CUSTOM runs mid-omz, not last), so those two are appended to
# the tail of .zshrc instead.
RUN su node -c 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended' \
    && printf '%s\n' \
      'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' \
      'export GOPATH=$HOME/go' \
      'eval "$(starship init zsh)"' \
      'alias ls="eza --icons --git"' \
      'alias ll="eza -l -g --icons --git"' \
      'alias la="eza -la -g --icons --git"' \
      'alias cd="z"' \
      'alias vim="nvim"' \
      'alias fd="fdfind"' \
      'alias lg="lazygit"' \
      > /home/node/.oh-my-zsh/custom/zz-workflow.zsh \
    && printf '%s\n' \
      '' \
      '# direnv + zoxide at the END of .zshrc. Both hook precmd/chpwd; the zoxide' \
      '# doctor warns unless ITS hook is registered LAST, so zoxide MUST init' \
      '# after direnv (and everything else).' \
      'eval "$(direnv hook zsh)"' \
      'eval "$(zoxide init zsh)"' \
      >> /home/node/.zshrc \
    && chown -R 1000:1000 /home/node/.oh-my-zsh /home/node/.zshrc

# Global git config: delta as pager + diff highlighter (nice colored diffs).
RUN git config --system core.pager delta \
    && git config --system interactive.diffFilter "delta --color-only" \
    && git config --system delta.navigate true \
    && git config --system delta.line-numbers true \
    && git config --system merge.conflictStyle zdiff3

# tmux config: focus-events (Claude Code wants it), UTF-8, mouse, big
# scrollback, sane keybindings, a clean status bar, and tmux-resurrect/
# continuum for session persistence. tpm is vendored into the skel home; the
# entrypoint installs the plugins on first boot.
COPY tmux.conf /home/node/.tmux.conf
RUN git clone --depth 1 https://github.com/tmux-plugins/tpm /home/node/.tmux/plugins/tpm \
    && chown -R 1000:1000 /home/node/.tmux.conf /home/node/.tmux

# Baked base ~/.claude.json with NON-SECRET UX flags so fresh homes skip the
# interactive prompts the auto-start `claude remote-control` server can't
# answer: /workspace trust + the Remote Control enable dialog + onboarding.
# The personal login (oauthAccount / .credentials.json) is NEVER baked — it's
# added per-user by interactive `/login`, which merges into this base (seeding
# is no-clobber and only runs on an empty home, so login state wins).
RUN printf '%s\n' \
      '{' \
      '  "hasCompletedOnboarding": true,' \
      '  "remoteDialogSeen": true,' \
      '  "projects": {' \
      '    "/workspace": {' \
      '      "hasTrustDialogAccepted": true,' \
      '      "hasCompletedProjectOnboarding": true' \
      '    }' \
      '  }' \
      '}' \
      > /home/node/.claude.json \
    && chown 1000:1000 /home/node/.claude.json

# Default the node user to zsh (the configured shell above).
RUN chsh -s /usr/bin/zsh node

# Claude skills baked into the home so fresh pods discover them (seeded to $HOME
# from /opt/home-skel on first boot): the `kernel` skill routes browser work to
# a Kernel cloud browser via `kbrowser`, and the `agent-browser` stub points at
# the bundled CLI guide. Both deliberately avoid a local `agent-browser install`
# (no browser/display/root in this image).
COPY --chown=1000:1000 skills/ /home/node/.claude/skills/

# Snapshot the baked home (oh-my-zsh, nvim config, .zshrc, etc.) to a pristine
# skeleton. At runtime /home/node is mounted on a persistent PVC, which would
# shadow these; the entrypoint seeds an empty home from /opt/home-skel on first
# boot so the dotfiles persist AND remain user-editable.
RUN cp -a /home/node /opt/home-skel && chown -R 1000:1000 /opt/home-skel

# Work-layout script for the `rclaude N` command (nvim + claude + shell).
COPY rclaude-layout.sh /usr/local/bin/rclaude-layout
# tmux-sessionizer: fzf-jump to a per-repo tmux session (<prefix>f).
COPY tmux-sessionizer.sh /usr/local/bin/tmux-sessionizer
# dp: deploy-ephemeral wrapper (deploy to webapp--$OWNER or an explicit env).
COPY dp.sh /usr/local/bin/dp
# Boot orchestration — the pod's entrypoint (was an inline command in the
# StatefulSet; baked here now that it's stable + testable).
COPY entrypoint.sh /usr/local/bin/entrypoint
# kbrowser: provision a Kernel cloud browser + wire agent-browser to it over CDP
# (this image has no local browser). Reads KERNEL_API_KEY from the env.
COPY kbrowser.sh /usr/local/bin/kbrowser
# dbuild: rootless in-pod image build + push (buildkit under rootlesskit).
COPY dbuild.sh /usr/local/bin/dbuild
RUN chmod +x /usr/local/bin/rclaude-layout /usr/local/bin/tmux-sessionizer /usr/local/bin/dp /usr/local/bin/entrypoint /usr/local/bin/kbrowser /usr/local/bin/dbuild

# Run as the base image's existing UID-1000 user (node). Its HOME (/home/node)
# is where Claude login/session state lives — we persist that on a PVC so the
# /remote-control login survives pod restarts.
USER node
WORKDIR /workspace

# Keepalive entrypoint: the pod stays up; you `kubectl exec -it` to attach,
# start an interactive `claude`, then run /remote-control to drive it from
# any device. (Claude isn't started here so attaching gives a clean TTY.)
CMD ["sleep", "infinity"]
