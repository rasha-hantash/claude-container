#!/usr/bin/env bash
set -euo pipefail

# vps-setup.sh — One-time VPS provisioning for Claude workstation
#
# Run on a fresh Ubuntu 22.04/24.04 VPS:
#   curl -fsSL https://raw.githubusercontent.com/rasha-hantash/claude-container/main/scripts/vps-setup.sh | bash
#
# Or manually: scp this file to the VPS and run it.

echo "━━━ Claude Workstation VPS Setup ━━━"

# ── 1. Install Docker ──
if command -v docker &>/dev/null; then
    echo "✓ Docker already installed: $(docker --version)"
else
    echo "  Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    echo "✓ Docker installed"
fi

# ── 2. Install Tailscale ──
if command -v tailscale &>/dev/null; then
    echo "✓ Tailscale already installed: $(tailscale version | head -1)"
else
    echo "  Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "✓ Tailscale installed"
fi

# ── 3. Connect to Tailscale with SSH ──
echo "  Connecting to Tailscale (this will open an auth URL)..."
sudo tailscale up --ssh
echo "✓ Tailscale connected with SSH enabled"

# ── 4. Firewall — only allow Tailscale traffic ──
echo "  Configuring firewall..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on tailscale0
# Keep standard SSH open temporarily in case Tailscale disconnects
sudo ufw allow 22/tcp comment "fallback SSH — remove after verifying Tailscale"
sudo ufw --force enable
echo "✓ Firewall configured (Tailscale + fallback SSH)"
echo "  ⚠ After verifying Tailscale SSH works, run: sudo ufw delete allow 22/tcp"

# ── 5. Create deployment directory ──
DEPLOY_DIR="/opt/claude"
if [ -d "$DEPLOY_DIR" ]; then
    echo "✓ $DEPLOY_DIR already exists"
else
    sudo mkdir -p "$DEPLOY_DIR"
    sudo chown "$USER:$USER" "$DEPLOY_DIR"
    echo "✓ Created $DEPLOY_DIR"
fi

# ── 6. Clone claude-container repo ──
if [ -d "$DEPLOY_DIR/.git" ]; then
    echo "✓ claude-container repo already cloned"
    (cd "$DEPLOY_DIR" && git pull --ff-only origin main) || true
else
    git clone https://github.com/rasha-hantash/claude-container.git "$DEPLOY_DIR"
    echo "✓ Cloned claude-container to $DEPLOY_DIR"
fi

# ── 7. Install claude-attach wrapper ──
sudo cp "$DEPLOY_DIR/scripts/claude-attach" /usr/local/bin/claude-attach
sudo chmod +x /usr/local/bin/claude-attach
echo "✓ claude-attach installed to /usr/local/bin/"

# ── 8. Create .env template ──
ENV_FILE="$DEPLOY_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    echo "✓ .env already exists — not overwriting"
else
    cat > "$ENV_FILE" <<'EOF'
# Claude VPS Credentials
# Extract from Mac using: ./scripts/extract-credentials.sh
CLAUDE_CREDENTIALS=<paste from extract-credentials.sh>
GITHUB_TOKEN=<paste from extract-credentials.sh>
GT_AUTH_TOKEN=<paste from extract-credentials.sh>
GIT_USER_NAME=<your name>
GIT_USER_EMAIL=<your email>

# Repos to clone (comma-separated, no spaces around commas)
REPOS=brain-os,dotfiles,debugger,cove,technical-rag,dork,claude-container,master-plan,mcp_excalidraw,nugget,k-os,ai-augmented-cs-curriculum
GITHUB_ORG=rasha-hantash
EOF
    echo "✓ .env template created at $ENV_FILE"
fi

echo ""
echo "━━━ Setup complete! Next steps: ━━━"
echo ""
echo "1. On your Mac, run:"
echo "   cd ~/workspace/personal/explorations/claude-container"
echo "   ./scripts/extract-credentials.sh > /tmp/claude-vps.env"
echo ""
echo "2. Copy credentials to VPS:"
echo "   scp /tmp/claude-vps.env <vps-tailscale-ip>:/opt/claude/.env"
echo ""
echo "3. Edit /opt/claude/.env to add GIT_USER_NAME and GIT_USER_EMAIL"
echo ""
echo "4. Start the container:"
echo "   cd /opt/claude && docker compose -f docker-compose.vps.yml up -d"
echo ""
echo "5. Connect from anywhere:"
echo "   ssh <vps-tailscale-ip> claude-attach"
echo ""
echo "6. After verifying Tailscale SSH works, lock down public SSH:"
echo "   sudo ufw delete allow 22/tcp"
