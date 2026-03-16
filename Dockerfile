FROM node:20

ARG CLAUDE_CODE_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    less git procps fzf zsh man-db unzip gnupg2 gh \
    build-essential pkg-config libssl-dev \
    ripgrep fd-find tmux ca-certificates \
    python3 python3-pip python3-venv curl wget jq nano vim \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV RUSTUP_HOME="/usr/local/rustup" CARGO_HOME="/usr/local/cargo"
ENV PATH="/usr/local/cargo/bin:${PATH}"
RUN set -eux; curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | bash -s -- -y --no-modify-path

RUN set -eux; curl -fsSL https://go.dev/dl/go1.24.1.linux-amd64.tar.gz \
    | tar -C /usr/local -xzf -
ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}"

RUN set -eux; curl -LsSf https://astral.sh/uv/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"

RUN ln -sf /usr/bin/fdfind /usr/bin/fd

RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
RUN npm install -g @withgraphite/graphite-cli

ENV DEVCONTAINER=true

RUN mkdir -p /workspace /root/.claude /root/.config/graphite

WORKDIR /workspace

COPY claude-config/ /root/.claude/

# Cove hook shim (lightweight replacement for cove binary)
COPY cove-shim.sh /usr/local/bin/cove
RUN chmod +x /usr/local/bin/cove

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
