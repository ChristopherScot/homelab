# Interactive Claude Code session image for in-cluster pods, driven remotely
# via /remote-control (claude.ai/code + mobile). Carries the toolset used to
# operate this homelab: git, kubectl, helm, jq, yq, gh, plus the Claude CLI.
FROM node:22-bookworm-slim

ARG CLAUDE_CODE_VERSION=2.1.146
# kubectl pinned near the cluster's k3s 1.30 (avoid large version skew).
ARG KUBECTL_VERSION=v1.30.6
# helm kept on v3 (v4 is a breaking major; chart compat).
ARG HELM_VERSION=v3.16.4
ARG YQ_VERSION=v4.53.2
ARG GO_VERSION=1.26.3
ARG TOFU_VERSION=1.12.0
ARG NVIM_VERSION=v0.12.2

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates jq openssh-client less vim ripgrep gnupg \
      tmux unzip build-essential \
      zsh fzf fd-find \
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

# Go
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
      | tar -xz -C /usr/local
ENV PATH=$PATH:/usr/local/go/bin:/home/node/go/bin
ENV GOPATH=/home/node/go

# OpenTofu (open-source Terraform; `tofu` CLI)
RUN curl -fsSLo /tmp/tofu.zip \
      "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_amd64.zip" \
    && unzip -o /tmp/tofu.zip tofu -d /usr/local/bin && rm /tmp/tofu.zip

# Claude Code CLI + TypeScript toolchain (node base already present)
RUN npm install -g \
      @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
      typescript ts-node tsx

# Neovim config: treesitter syntax highlighting + sensible defaults, via
# lazy.nvim. Bootstrapped at first `nvim` launch (plugins install on demand).
RUN mkdir -p /home/node/.config/nvim \
    && printf '%s\n' \
      'local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"' \
      'if not vim.loop.fs_stat(lazypath) then' \
      '  vim.fn.system({"git","clone","--filter=blob:none","https://github.com/folke/lazy.nvim.git","--branch=stable",lazypath})' \
      'end' \
      'vim.opt.rtp:prepend(lazypath)' \
      'vim.g.mapleader = " "' \
      'vim.opt.number = true' \
      'vim.opt.expandtab = true' \
      'vim.opt.shiftwidth = 2' \
      'vim.opt.termguicolors = true' \
      'require("lazy").setup({' \
      '  { "nvim-treesitter/nvim-treesitter", build = ":TSUpdate",' \
      '    config = function() require("nvim-treesitter.configs").setup({' \
      '      ensure_installed = {"go","typescript","javascript","tsx","hcl","terraform","yaml","json","bash","lua","dockerfile","markdown"},' \
      '      auto_install = true, highlight = { enable = true } }) end },' \
      '  { "neovim/nvim-lspconfig" },' \
      '  { "nvim-telescope/telescope.nvim", branch = "0.1.x",' \
      '    dependencies = { "nvim-lua/plenary.nvim" },' \
      '    config = function()' \
      '      vim.keymap.set("n", "<leader>ff", require("telescope.builtin").find_files)' \
      '      vim.keymap.set("n", "<leader>fg", require("telescope.builtin").live_grep)' \
      '    end },' \
      '  { "nvim-tree/nvim-tree.lua", config = function() require("nvim-tree").setup() end },' \
      '  { "catppuccin/nvim", name = "catppuccin", priority = 1000,' \
      '    config = function() vim.cmd.colorscheme("catppuccin") end },' \
      '})' \
      > /home/node/.config/nvim/init.lua \
    && chown -R 1000:1000 /home/node/.config

# Shell: oh-my-zsh + starship + zoxide + eza aliases (nexxeln-style workflow).
# Custom config goes in $ZSH_CUSTOM (sourced AFTER oh-my-zsh.sh, so our
# aliases/inits win — appending to .zshrc loaded too early and OMZ clobbered
# them). starship replaces the OMZ theme.
RUN su node -c 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended' \
    && printf '%s\n' \
      'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' \
      'export GOPATH=$HOME/go' \
      'eval "$(starship init zsh)"' \
      'eval "$(zoxide init zsh)"' \
      'alias ls="eza --icons --git"' \
      'alias ll="eza -l -g --icons --git"' \
      'alias la="eza -la -g --icons --git"' \
      'alias cd="z"' \
      'alias vim="nvim"' \
      'alias fd="fdfind"' \
      > /home/node/.oh-my-zsh/custom/zz-workflow.zsh \
    && chown -R 1000:1000 /home/node/.oh-my-zsh /home/node/.zshrc

# Default the node user to zsh (the configured shell above).
RUN chsh -s /usr/bin/zsh node

# Snapshot the baked home (oh-my-zsh, nvim config, .zshrc, etc.) to a pristine
# skeleton. At runtime /home/node is mounted on a persistent PVC, which would
# shadow these; the entrypoint seeds an empty home from /opt/home-skel on first
# boot so the dotfiles persist AND remain user-editable.
RUN cp -a /home/node /opt/home-skel && chown -R 1000:1000 /opt/home-skel

# Run as the base image's existing UID-1000 user (node). Its HOME (/home/node)
# is where Claude login/session state lives — we persist that on a PVC so the
# /remote-control login survives pod restarts.
USER node
WORKDIR /workspace

# Keepalive entrypoint: the pod stays up; you `kubectl exec -it` to attach,
# start an interactive `claude`, then run /remote-control to drive it from
# any device. (Claude isn't started here so attaching gives a clean TTY.)
CMD ["sleep", "infinity"]
