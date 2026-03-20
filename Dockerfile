FROM node:20

ARG CLAUDE_CODE_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    less git procps fzf zsh man-db unzip gnupg2 gh \
    build-essential pkg-config libssl-dev \
    ripgrep fd-find tmux ca-certificates \
    python3 python3-pip python3-venv curl wget jq nano vim \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Rust globally (accessible by all users)
ENV RUSTUP_HOME="/usr/local/rustup" CARGO_HOME="/usr/local/cargo"
ENV PATH="/usr/local/cargo/bin:${PATH}"
RUN set -eux; curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | bash -s -- -y --no-modify-path

# Install Go globally
RUN set -eux; curl -fsSL https://go.dev/dl/go1.24.1.linux-amd64.tar.gz \
    | tar -C /usr/local -xzf -
ENV PATH="/usr/local/go/bin:${PATH}"

# Install uv globally (not in /root/.local which is inaccessible to node user)
RUN set -eux; curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin bash

RUN ln -sf /usr/bin/fdfind /usr/bin/fd

# Install Claude Code via native installer (npm is deprecated)
# Install as root first, then copy binary + version data to node user's paths
# so Claude sees a valid native install and auto-updates work.
RUN curl -fsSL https://claude.ai/install.sh | bash -s ${CLAUDE_CODE_VERSION} \
    && mkdir -p /home/node/.local/bin /home/node/.local/share \
    && cp /root/.local/bin/claude /home/node/.local/bin/claude \
    && cp -r /root/.local/share/claude /home/node/.local/share/claude \
    && chown -R node:node /home/node/.local
RUN npm install -g @withgraphite/graphite-cli @debugmcp/mcp-debugger mcp-js-debugger

# Pre-install MCP servers so first VPS run is fast
RUN uv tool install arxiv-mcp-server

ENV DEVCONTAINER=true
# DEPLOYMENT: "local" (Mac, default) or "vps" (headless VPS)
ENV DEPLOYMENT=local

# Create directories as root, then hand ownership to node user (uid 1000).
# This follows Anthropic's reference devcontainer pattern: install as root, run as node.
RUN mkdir -p /workspace /scratch \
    /home/node/.claude /home/node/.config/graphite \
    /home/node/.local/share /home/node/.local/state/cove/events \
    /home/node/go \
    && chown -R node:node /home/node /scratch

WORKDIR /workspace

# Copy config as root, then chown to node
COPY claude-config/ /home/node/.claude/
RUN chown -R node:node /home/node/.claude

# Cove hook shim (lightweight replacement for cove binary)
COPY cove-shim.sh /usr/local/bin/cove
RUN chmod +x /usr/local/bin/cove

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Go and local bin paths for node user
ENV GOPATH="/home/node/go"
ENV PATH="/home/node/go/bin:/home/node/.local/bin:${PATH}"

# Entrypoint runs as root to write settings.json and lock it,
# then drops to node user via exec gosu/su before launching Claude.
# This means node user never has write access to settings.json.

ENTRYPOINT ["/entrypoint.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
