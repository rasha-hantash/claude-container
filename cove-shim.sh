#!/usr/bin/env bash
# cove-shim.sh — Lightweight replacement for cove binary inside Docker.
# Handles "cove hook <event>" by writing JSONL events.
# All other cove commands are silently ignored.
set -euo pipefail

if [[ "${1:-}" != "hook" ]]; then
    exit 0  # Silently ignore non-hook commands
fi

EVENT="${2:-}"
EVENTS_DIR="${COVE_EVENTS_DIR:-/root/.local/state/cove/events}"
PANE_ID="${TMUX_PANE:-}"

# Read JSON from stdin
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")
TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || echo "")

if [[ -z "$SESSION_ID" ]]; then
    exit 0
fi

# Determine state from event + tool_name
ASKING_TOOLS="AskUserQuestion ExitPlanMode EnterPlanMode"
case "$EVENT" in
    user-prompt|ask-done|post-tool) STATE="working" ;;
    stop)                           STATE="idle" ;;
    session-end)                    STATE="end" ;;
    ask)                            STATE="asking" ;;
    pre-tool)
        if echo "$ASKING_TOOLS" | grep -qw "$TOOL_NAME"; then
            STATE="asking"
        else
            STATE="waiting"
        fi
        ;;
    *)                              exit 0 ;;
esac

# Suppress initial "idle" if no "working" event exists yet
EVENT_FILE="$EVENTS_DIR/$SESSION_ID.jsonl"
if [[ "$STATE" == "idle" ]] && ! grep -q '"state":"working"' "$EVENT_FILE" 2>/dev/null; then
    exit 0
fi

# Write event
mkdir -p "$EVENTS_DIR"
TS=$(date +%s)
echo "{\"state\":\"$STATE\",\"cwd\":\"$CWD\",\"pane_id\":\"$PANE_ID\",\"ts\":$TS}" >> "$EVENT_FILE"
