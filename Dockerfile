FROM node:22-slim AS base

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl build-essential pkg-config libssl-dev \
    jq ripgrep fd-find tmux ca-certificates gnupg \
    python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | gpg --dearmor -o /usr/share/keyrings/githubcli.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Go
RUN curl -fsSL https://go.dev/dl/go1.24.1.linux-amd64.tar.gz | tar -C /usr/local -xzf -
ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}"

# uv (Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# Graphite CLI
RUN npm install -g @withgraphite/graphite-cli

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# fd is installed as fd-find on Debian
RUN ln -sf /usr/bin/fdfind /usr/bin/fd

# Claude config directory
RUN mkdir -p /root/.claude /root/.config/graphite

# Copy Claude config (settings, CLAUDE.md, hooks, skills, agents)
COPY claude-config/ /root/.claude/

WORKDIR /workspace

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
