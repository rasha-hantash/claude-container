#!/usr/bin/env bash
# run.sh — Launch Claude container with host credentials
set -euo pipefail

cd "$(dirname "$0")/.."

# Extract Claude credentials from macOS keychain
export CLAUDE_CREDENTIALS=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo "")

if [ -z "$CLAUDE_CREDENTIALS" ]; then
    echo "⚠ Could not extract Claude credentials from keychain"
    echo "  You'll need to run 'claude auth login' inside the container"
else
    echo "  Claude credentials: ${#CLAUDE_CREDENTIALS} bytes extracted from keychain"
fi

exec docker compose run --rm claude "$@"
