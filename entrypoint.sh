#!/usr/bin/env bash
set -euo pipefail

# This entrypoint runs as root to write config files, then drops to
# the node user (uid 1000) before executing Claude. This means Claude
# cannot modify settings.json, system files, or escalate privileges.

NODE_HOME="/home/node"

# ── Helper: read Docker secret from file ──
read_secret() {
    local name="$1"
    local secret_file="/run/secrets/$name"
    if [ -f "$secret_file" ]; then
        cat "$secret_file"
    else
        echo ""
    fi
}

# ── Claude credentials (from host keychain via env var) ──
if [ -n "${CLAUDE_CREDENTIALS:-}" ]; then
    mkdir -p "$NODE_HOME/.claude"
    echo "$CLAUDE_CREDENTIALS" > "$NODE_HOME/.claude/.credentials.json"
    chown node:node "$NODE_HOME/.claude/.credentials.json"
    echo "✓ Claude credentials loaded (${#CLAUDE_CREDENTIALS} bytes)"
else
    echo "⚠ CLAUDE_CREDENTIALS not set — run: claude auth login"
fi

# ── Git identity (written as root, readable by node) ──
su -c "git config --global user.name '${GIT_USER_NAME:-Claude Container}'" node
su -c "git config --global user.email '${GIT_USER_EMAIL:-claude@container.local}'" node

# ── GitHub CLI auth (from Docker secret) ──
GITHUB_TOKEN=$(read_secret "github_token")
if [ -n "$GITHUB_TOKEN" ]; then
    export GITHUB_TOKEN
    gh_user=$(su -c "GITHUB_TOKEN='$GITHUB_TOKEN' gh api user --jq .login" node 2>&1) && \
        echo "✓ GitHub CLI authenticated as $gh_user" || \
        echo "⚠ GITHUB_TOKEN invalid: $gh_user"
else
    echo "⚠ GITHUB_TOKEN not set — gh commands will fail"
fi

# ── Graphite auth (from Docker secret) ──
GT_AUTH_TOKEN=$(read_secret "gt_auth_token")
if [ -n "$GT_AUTH_TOKEN" ]; then
    mkdir -p "$NODE_HOME/.config/graphite"
    echo "{\"authToken\": \"$GT_AUTH_TOKEN\"}" > "$NODE_HOME/.config/graphite/user_config"
    chown -R node:node "$NODE_HOME/.config/graphite"
    echo "✓ Graphite authenticated"
else
    echo "⚠ GT_AUTH_TOKEN not set — gt submit will fail"
fi

# ── Merge settings.json from host (written as root, owned by root) ──
HOST_SETTINGS="$NODE_HOME/.claude-host/settings.json"
TARGET_SETTINGS="$NODE_HOME/.claude/settings.json"
if [ -f "$HOST_SETTINGS" ]; then
    # Path remap + container overrides
    sed \
        -e 's|/Users/rashasaadeh/workspace/personal/explorations|/workspace|g' \
        -e "s|/Users/rashasaadeh/.claude|$NODE_HOME/.claude|g" \
        -e 's|~/.cargo/bin/cove|/usr/local/bin/cove|g' \
        -e "s|~/.claude|$NODE_HOME/.claude|g" \
        -e 's|afplay .*beep.mp3.*"|echo noop-audio"|g' \
        "$HOST_SETTINGS" > "$TARGET_SETTINGS"

    # Inject container-specific deny rules and set bypassPermissions
    python3 - "$TARGET_SETTINGS" <<'PYEOF'
import json, sys
settings_path = sys.argv[1]
with open(settings_path) as f:
    cfg = json.load(f)
cfg.setdefault('permissions', {})
cfg['permissions']['defaultMode'] = 'bypassPermissions'
deny = cfg['permissions'].setdefault('deny', [])
for rule in ['Bash(gt merge*)', 'Bash(gh pr merge*)']:
    if rule not in deny:
        deny.append(rule)
with open(settings_path, 'w') as f:
    json.dump(cfg, f, indent=2)
PYEOF
    if [ $? -eq 0 ]; then echo "✓ Settings merged from host"; else echo "⚠ Failed to merge settings.json"; fi

    # Lock settings.json — owned by root, readable by node, not writable.
    # Since Claude runs as node, it cannot chmod or chown this file.
    chown root:node "$TARGET_SETTINGS"
    chmod 444 "$TARGET_SETTINGS"
    echo "✓ settings.json locked (root-owned, read-only)"
else
    echo "ℹ No host settings.json mounted — using container defaults"
fi

# ── On-demand repo clone into /scratch ──
if [ -n "${TARGET_REPO:-}" ]; then
    repo_name=$(basename "$TARGET_REPO")
    src="/workspace/$repo_name"

    if [ ! -d "$src/.git" ]; then
        echo "⚠ $src is not a git repo — skipping clone"
    elif [ -d "/scratch/$repo_name/.git" ]; then
        echo "✓ /scratch/$repo_name already exists — pulling latest"
        (cd "/scratch/$repo_name" && su -c "git fetch origin && git reset --hard origin/main" node 2>/dev/null) || true
    else
        echo "  Cloning $src → /scratch/$repo_name ..."
        su -c "git clone '$src' '/scratch/$repo_name'" node

        origin_url=$(git -C "$src" remote get-url origin 2>/dev/null || echo "")
        if [ -n "$origin_url" ]; then
            su -c "git -C '/scratch/$repo_name' remote set-url origin '$origin_url'" node
            echo "✓ Remote set to $origin_url"
        fi

        su -c "cd '/scratch/$repo_name' && gt init --trunk main" node 2>/dev/null || true
        echo "✓ Cloned and initialized /scratch/$repo_name"
    fi
fi

# ── Drop to node user and execute command ──
# All setup is done as root. Claude runs as node (uid 1000).
if [ -n "${TARGET_REPO:-}" ]; then
    cd "/scratch/$(basename "$TARGET_REPO")" 2>/dev/null || true
fi

# Write a temporary runner script that preserves argument quoting
RUNNER=$(mktemp)
cat > "$RUNNER" <<RUNEOF
#!/bin/bash
export HOME="$NODE_HOME"
export GITHUB_TOKEN="$GITHUB_TOKEN"
cd "$(pwd)"
exec "\$@"
RUNEOF
chmod +x "$RUNNER"
chown node:node "$RUNNER"
exec su -s "$RUNNER" node -- "$@"
