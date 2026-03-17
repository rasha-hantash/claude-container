#!/usr/bin/env bash
# run.sh — Launch Claude container with host credentials
#
# Usage:
#   ./scripts/run.sh                          # interactive, no target repo
#   ./scripts/run.sh --repo cove              # clone cove into /scratch, work there
#   ./scripts/run.sh --repo brain-os claude -p "count TODOs"  # one-shot task
set -euo pipefail

cd "$(dirname "$0")/.."

# ── Parse --repo flag ──
TARGET_REPO=""
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            TARGET_REPO="$2"
            shift 2
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done

# ── Extract Claude credentials from macOS keychain ──
export CLAUDE_CREDENTIALS=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo "")

if [ -z "$CLAUDE_CREDENTIALS" ]; then
    echo "⚠ Could not extract Claude credentials from keychain"
    echo "  You'll need to run 'claude auth login' inside the container"
else
    echo "  Claude credentials: ${#CLAUDE_CREDENTIALS} bytes extracted from keychain"
fi

# ── Launch container ──
# Tokens are read from .env by compose, passed as Docker secrets (file-mounted).
# TARGET_REPO tells the entrypoint which repo to clone into /scratch.
export TARGET_REPO
exec docker compose run --rm claude "${args[@]}"
