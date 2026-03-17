#!/usr/bin/env bash
set -euo pipefail

# ── Helper: read Docker secret from file, fall back to env var ──
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
    mkdir -p /root/.claude
    echo "$CLAUDE_CREDENTIALS" > /root/.claude/.credentials.json
    echo "✓ Claude credentials loaded (${#CLAUDE_CREDENTIALS} bytes)"
else
    echo "⚠ CLAUDE_CREDENTIALS not set — run: claude auth login"
fi

# ── Git identity ──
git config --global user.name "${GIT_USER_NAME:-Claude Container}"
git config --global user.email "${GIT_USER_EMAIL:-claude@container.local}"

# ── GitHub CLI auth (from Docker secret) ──
GITHUB_TOKEN=$(read_secret "github_token")
if [ -n "$GITHUB_TOKEN" ]; then
    export GITHUB_TOKEN
    gh_user=$(gh api user --jq .login 2>&1) && \
        echo "✓ GitHub CLI authenticated as $gh_user" || \
        echo "⚠ GITHUB_TOKEN invalid: $gh_user"
else
    echo "⚠ GITHUB_TOKEN not set — gh commands will fail"
fi

# ── Graphite auth (from Docker secret) ──
GT_AUTH_TOKEN=$(read_secret "gt_auth_token")
if [ -n "$GT_AUTH_TOKEN" ]; then
    mkdir -p /root/.config/graphite
    echo "{\"authToken\": \"$GT_AUTH_TOKEN\"}" > /root/.config/graphite/user_config
    echo "✓ Graphite authenticated"
else
    echo "⚠ GT_AUTH_TOKEN not set — gt submit will fail"
fi

# ── Merge settings.json from host ──
if [ -f "/root/.claude-host/settings.json" ]; then
    # Path remap + container overrides
    sed \
        -e 's|/Users/rashasaadeh/workspace/personal/explorations|/workspace|g' \
        -e 's|/Users/rashasaadeh/.claude|/root/.claude|g' \
        -e 's|~/.cargo/bin/cove|/usr/local/bin/cove|g' \
        -e 's|~/.claude|/root/.claude|g' \
        -e 's|afplay [^"]*|echo noop-audio|g' \
        /root/.claude-host/settings.json > /root/.claude/settings.json

    # Inject container-specific deny rules and set bypassPermissions
    python3 -c "
import json
with open('/root/.claude/settings.json') as f:
    cfg = json.load(f)
cfg.setdefault('permissions', {})
cfg['permissions']['defaultMode'] = 'bypassPermissions'
deny = cfg['permissions'].setdefault('deny', [])
for rule in ['Bash(gt merge*)', 'Bash(gh pr merge*)']:
    if rule not in deny:
        deny.append(rule)
with open('/root/.claude/settings.json', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null && echo "✓ Settings merged from host" || echo "⚠ Failed to merge settings.json"
else
    echo "ℹ No host settings.json mounted — using container defaults"
fi

# ── On-demand repo clone into /scratch ──
# TARGET_REPO can be a repo name ("cove") or full path ("/workspace/cove").
# Clones from the read-only /workspace mount into writable /scratch.
if [ -n "${TARGET_REPO:-}" ]; then
    repo_name=$(basename "$TARGET_REPO")
    src="/workspace/$repo_name"

    if [ ! -d "$src/.git" ]; then
        echo "⚠ $src is not a git repo — skipping clone"
    elif [ -d "/scratch/$repo_name/.git" ]; then
        # Already cloned from a previous run — just pull latest
        echo "✓ /scratch/$repo_name already exists — pulling latest"
        (cd "/scratch/$repo_name" && git fetch origin && git reset --hard origin/main 2>/dev/null) || true
    else
        echo "  Cloning $src → /scratch/$repo_name ..."
        git clone "$src" "/scratch/$repo_name"

        # Rewrite remote to GitHub so push goes to the real upstream
        cd "/scratch/$repo_name"
        origin_url=$(git -C "$src" remote get-url origin 2>/dev/null || echo "")
        if [ -n "$origin_url" ]; then
            git remote set-url origin "$origin_url"
            echo "✓ Remote set to $origin_url"
        fi

        # Initialize Graphite
        gt init --trunk main 2>/dev/null || true
        echo "✓ Cloned and initialized /scratch/$repo_name"
    fi

    # Set working directory for Claude
    cd "/scratch/$repo_name" 2>/dev/null || true
else
    echo "  No TARGET_REPO set — /workspace is read-only, use TARGET_REPO to clone a repo into /scratch"
fi

# ── Execute command ──
exec "$@"
