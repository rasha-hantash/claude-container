#!/usr/bin/env bash
set -euo pipefail

# ── Git identity ──
git config --global user.name "${GIT_USER_NAME:-Claude Container}"
git config --global user.email "${GIT_USER_EMAIL:-claude@container.local}"

# ── GitHub CLI auth ──
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null && \
        echo "✓ GitHub CLI authenticated" || \
        echo "⚠ GitHub CLI auth failed (token may be invalid)"
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

# ── Initialize Graphite in mounted repos ──
for repo in /workspace/*/; do
    if [ -d "$repo/.git" ] && [ ! -f "$repo/.git/.graphite_repo_config" ]; then
        (cd "$repo" && gt init --trunk main 2>/dev/null) || true
    fi
done

# ── Execute command ──
exec "$@"
