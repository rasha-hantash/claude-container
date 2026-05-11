#!/usr/bin/env bash
set -euo pipefail

# extract-credentials.sh — Extract credentials from macOS for VPS .env file
#
# Usage:
#   ./scripts/extract-credentials.sh > /tmp/claude-vps.env
#   scp /tmp/claude-vps.env <vps-tailscale-ip>:/opt/claude/.env
#
# Then edit /opt/claude/.env on VPS to add GIT_USER_NAME and GIT_USER_EMAIL.

echo "# Claude VPS Credentials — extracted $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2

# ── Claude OAuth credentials (from macOS keychain) ──
CLAUDE_CREDS=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo "")
if [ -z "$CLAUDE_CREDS" ]; then
    echo "⚠ Could not extract Claude credentials from keychain" >&2
    echo "  Run 'claude auth login' first, or paste manually" >&2
    echo "CLAUDE_CREDENTIALS="
else
    echo "✓ Claude credentials: ${#CLAUDE_CREDS} bytes" >&2
    echo "CLAUDE_CREDENTIALS=$CLAUDE_CREDS"
fi

# ── GitHub token ──
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "✓ GitHub token found" >&2
    echo "GITHUB_TOKEN=$GITHUB_TOKEN"
else
    echo "⚠ GITHUB_TOKEN not set in environment" >&2
    echo "GITHUB_TOKEN="
fi

# ── Graphite token ──
if [ -n "${GT_AUTH_TOKEN:-}" ]; then
    echo "✓ Graphite token found" >&2
    echo "GT_AUTH_TOKEN=$GT_AUTH_TOKEN"
else
    echo "⚠ GT_AUTH_TOKEN not set in environment" >&2
    echo "GT_AUTH_TOKEN="
fi

# ── Git identity ──
GIT_NAME=$(git config user.name 2>/dev/null || echo "")
GIT_EMAIL=$(git config user.email 2>/dev/null || echo "")
echo "GIT_USER_NAME=$GIT_NAME"
echo "GIT_USER_EMAIL=$GIT_EMAIL"

# ── Repo list (default: all repos in workspace) ──
echo "REPOS=brain-os,dotfiles,debugger,cove,technical-rag,dork,claude-container,master-plan,mcp_excalidraw,nugget,k-os,ai-augmented-cs-curriculum"
echo "GITHUB_ORG=rasha-hantash"

echo "" >&2
echo "✓ Done. Pipe to a file: ./scripts/extract-credentials.sh > /tmp/claude-vps.env" >&2
