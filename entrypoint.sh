#!/usr/bin/env bash
set -euo pipefail

# ── Claude credentials (from host keychain) ──
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

# ── GitHub CLI auth ──
# gh auto-detects GITHUB_TOKEN from env — no need for `gh auth login`.
# Just validate the token works.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    gh_user=$(gh api user --jq .login 2>&1) && \
        echo "✓ GitHub CLI authenticated as $gh_user" || \
        echo "⚠ GITHUB_TOKEN invalid: $gh_user"
else
    echo "⚠ GITHUB_TOKEN not set — gh commands will fail"
fi

# ── Graphite auth ──
if [ -n "${GT_AUTH_TOKEN:-}" ]; then
    mkdir -p /root/.config/graphite
    echo "{\"authToken\": \"$GT_AUTH_TOKEN\"}" > /root/.config/graphite/user_config
    echo "✓ Graphite authenticated"
else
    echo "⚠ GT_AUTH_TOKEN not set — gt submit will fail"
fi

# ── Initialize Graphite in repos ──
for repo in /workspace/*/; do
    if [ -d "$repo/.git" ] && [ ! -f "$repo/.git/.graphite_repo_config" ]; then
        (cd "$repo" && gt init --trunk main 2>/dev/null) || true
    fi
done

# ── Execute command ──
exec "$@"
