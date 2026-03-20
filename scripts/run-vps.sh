#!/usr/bin/env bash
# run-vps.sh — Launch Claude container on VPS (mirrors scripts/run.sh for local)
#
# This is the script that cove --ssh calls on the VPS host.
# It reads credentials from .env (not macOS keychain) and runs an ephemeral container.
#
# Usage:
#   ./scripts/run-vps.sh                                    # interactive Claude session
#   ./scripts/run-vps.sh --repo cove                        # clone cove into /scratch, work there
#   ./scripts/run-vps.sh --repo brain-os claude --rc        # with Remote Control (phone access)
#   ./scripts/run-vps.sh claude -p "Fix typo in README"     # one-shot task
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

# ── Launch container ──
# Credentials are in .env (extracted from Mac via extract-credentials.sh).
# TARGET_REPO tells the entrypoint which repo to clone into /scratch.
export TARGET_REPO
exec docker compose -f docker-compose.vps.yml run --rm claude "${args[@]}"
