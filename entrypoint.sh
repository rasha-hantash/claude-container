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

# ═══════════════════════════════════════════════════════════════════
# VPS MODE vs LOCAL MODE
# ═══════════════════════════════════════════════════════════════════
# VPS: repos cloned from GitHub, config from dotfiles repo, ephemeral containers
# Local: repos bind-mounted from host, config mounted from host ~/.claude/

if [ "${DEPLOYMENT:-local}" = "vps" ]; then
    echo "━━━ VPS deployment mode ━━━"

    # ── Ensure volumes are writable by node ──
    chown -R node:node /workspace /scratch
    chown node:node "$NODE_HOME/.claude/projects"

    # ── Clone/sync repos from GitHub into /workspace ──
    GITHUB_ORG="${GITHUB_ORG:-rasha-hantash}"
    REPOS="${REPOS:-brain-os,dotfiles,debugger}"
    IFS=',' read -ra REPO_LIST <<< "$REPOS"

    # Configure git to use GITHUB_TOKEN for https clones
    su -c "git config --global credential.helper '!f() { echo username=x-access-token; echo password=$GITHUB_TOKEN; }; f'" node

    for repo in "${REPO_LIST[@]}"; do
        repo=$(echo "$repo" | xargs)  # trim whitespace
        repo_url="https://github.com/$GITHUB_ORG/$repo.git"

        if [ -d "/workspace/$repo/.git" ]; then
            echo "✓ /workspace/$repo exists — fetching latest"
            (cd "/workspace/$repo" && su -c "git fetch origin && git pull --ff-only origin main" node 2>&1) || \
                echo "⚠ Failed to pull $repo (may have local changes)"
        else
            echo "  Cloning $repo from GitHub..."
            su -c "git clone '$repo_url' '/workspace/$repo'" node 2>&1 && \
                echo "✓ Cloned /workspace/$repo" || \
                echo "⚠ Failed to clone $repo"
            su -c "cd '/workspace/$repo' && gt init --trunk main" node 2>/dev/null || true
        fi
    done

    # ── Copy Claude ecosystem from dotfiles repo ──
    DOTFILES="/workspace/dotfiles/claude-code"
    if [ -d "$DOTFILES" ]; then
        for dir in hooks agents skills commands; do
            if [ -d "$DOTFILES/$dir" ]; then
                rm -rf "$NODE_HOME/.claude/$dir"
                cp -r "$DOTFILES/$dir" "$NODE_HOME/.claude/$dir"
                echo "✓ Copied $dir from dotfiles"
            fi
        done
        # Memory directory (writable by node for persistence)
        if [ -d "$DOTFILES/memory" ] && [ ! -d "$NODE_HOME/.claude/memory" ]; then
            cp -r "$DOTFILES/memory" "$NODE_HOME/.claude/memory"
        fi
        chown -R node:node "$NODE_HOME/.claude"
    else
        echo "⚠ Dotfiles not found at $DOTFILES — ecosystem unavailable"
    fi

    # ── Generate settings.json from dotfiles ──
    TARGET_SETTINGS="$NODE_HOME/.claude/settings.json"
    DOTFILES_SETTINGS="$DOTFILES/settings.json"
    if [ -f "$DOTFILES_SETTINGS" ]; then
        sed \
            -e "s|\$HOME/workspace/personal/explorations|/workspace|g" \
            -e 's|~/workspace/personal/explorations|/workspace|g' \
            -e "s|/Users/rashasaadeh/workspace/personal/explorations|/workspace|g" \
            -e "s|/Users/rashasaadeh/.claude|$NODE_HOME/.claude|g" \
            -e 's|~/.cargo/bin/cove|/usr/local/bin/cove|g' \
            -e "s|~/.claude|$NODE_HOME/.claude|g" \
            -e 's|afplay .*beep.mp3.*"|echo noop-audio"|g' \
            "$DOTFILES_SETTINGS" > "$TARGET_SETTINGS"

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
        chown root:node "$TARGET_SETTINGS"
        chmod 444 "$TARGET_SETTINGS"
        echo "✓ Settings generated from dotfiles (locked)"
    else
        echo "⚠ No settings.json in dotfiles"
    fi

    # ── Generate mcp.json from dotfiles template ──
    TARGET_MCP="$NODE_HOME/.claude/mcp.json"
    MCP_TEMPLATE="$DOTFILES/mcp.json.template"
    if [ -f "$MCP_TEMPLATE" ]; then
        sed \
            -e "s|\$HOME/workspace/personal/explorations|/workspace|g" \
            -e 's|~/workspace/personal/explorations|/workspace|g' \
            -e "s|/Users/rashasaadeh/workspace/personal/explorations|/workspace|g" \
            "$MCP_TEMPLATE" > "$TARGET_MCP"
        # Replace mcp-dap-server source path with installed binary
        python3 - "$TARGET_MCP" <<'PYEOF'
import json, sys
mcp_path = sys.argv[1]
with open(mcp_path) as f:
    cfg = json.load(f)
# Point mcp-dap-server to the pre-built binary
if 'mcp-dap-server' in cfg.get('mcpServers', {}):
    cfg['mcpServers']['mcp-dap-server']['command'] = '/usr/local/bin/mcp-dap-server'
    cfg['mcpServers']['mcp-dap-server']['args'] = []
with open(mcp_path, 'w') as f:
    json.dump(cfg, f, indent=2)
PYEOF
        chown node:node "$TARGET_MCP"
        echo "✓ mcp.json generated from dotfiles template"
    else
        echo "⚠ No mcp.json.template in dotfiles"
    fi

    # ── Restore .claude.json from persistent volume (alphaxiv OAuth, theme) ──
    PERSIST_JSON="$NODE_HOME/.claude-json-persist/.claude.json"
    if [ -f "$PERSIST_JSON" ]; then
        cp "$PERSIST_JSON" "$NODE_HOME/.claude.json"
        chown node:node "$NODE_HOME/.claude.json"
        echo "✓ .claude.json restored from persistent volume"
    fi

    # ── Build mcp-dap-server from source (if available) ──
    DAP_SRC="/workspace/debugger/mcp-dap-server"
    DAP_BIN="/usr/local/bin/mcp-dap-server"
    if [ -d "$DAP_SRC" ] && [ ! -f "$DAP_BIN" ]; then
        echo "  Building mcp-dap-server from source..."
        (cd "$DAP_SRC" && GOMODCACHE=/tmp/gomodcache go build -mod=readonly -o "$DAP_BIN" .) 2>&1
        if [ -f "$DAP_BIN" ]; then
            chmod +x "$DAP_BIN"
            echo "✓ mcp-dap-server built and installed"
        else
            echo "⚠ mcp-dap-server build failed"
        fi
    elif [ -f "$DAP_BIN" ]; then
        echo "✓ mcp-dap-server already installed"
    fi

    # ── Build CLAUDE.md from dotfiles + VPS addendum ──
    TARGET_CLAUDE="$NODE_HOME/.claude/CLAUDE.md"
    DOTFILES_CLAUDE="$DOTFILES/CLAUDE.md"
    VPS_ADDENDUM="$NODE_HOME/.claude/container-addendum-vps.md"
    if [ -f "$DOTFILES_CLAUDE" ]; then
        cat "$DOTFILES_CLAUDE" > "$TARGET_CLAUDE"
        if [ -f "$VPS_ADDENDUM" ]; then
            printf "\n\n" >> "$TARGET_CLAUDE"
            cat "$VPS_ADDENDUM" >> "$TARGET_CLAUDE"
        fi
        chown root:node "$TARGET_CLAUDE"
        chmod 444 "$TARGET_CLAUDE"
        echo "✓ CLAUDE.md built from dotfiles + VPS addendum (locked)"
    fi

    # ── Save .claude.json on shutdown (trap) ──
    save_claude_json() {
        if [ -f "$NODE_HOME/.claude.json" ]; then
            mkdir -p "$NODE_HOME/.claude-json-persist"
            cp "$NODE_HOME/.claude.json" "$PERSIST_JSON"
            echo "✓ .claude.json saved to persistent volume"
        fi
    }
    trap save_claude_json EXIT

    # ── On-demand repo clone into /scratch (same as local mode) ──
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

    # ── Drop to node user and execute command (same as local mode) ──
    if [ -n "${TARGET_REPO:-}" ]; then
        cd "/scratch/$(basename "$TARGET_REPO")" 2>/dev/null || true
    fi

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

else
    # ═══════════════════════════════════════════════════════════════
    # LOCAL MODE (Mac) — existing behavior, unchanged
    # ═══════════════════════════════════════════════════════════════

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

    # ── Merge mcp.json from host (path remapping for container) ──
    HOST_MCP="$NODE_HOME/.claude-host/mcp.json"
    TARGET_MCP="$NODE_HOME/.claude/mcp.json"
    if [ -f "$HOST_MCP" ]; then
        sed \
            -e 's|/Users/rashasaadeh/workspace/personal/explorations|/workspace|g' \
            -e "s|/Users/rashasaadeh/.claude|$NODE_HOME/.claude|g" \
            "$HOST_MCP" > "$TARGET_MCP"
        chown node:node "$TARGET_MCP"
        echo "✓ mcp.json merged from host"
    else
        echo "ℹ No host mcp.json mounted — MCP servers unavailable"
    fi

    # ── Build mcp-dap-server from source (if available) ──
    DAP_SRC="/workspace/debugger/mcp-dap-server"
    DAP_BIN="/usr/local/bin/mcp-dap-server"
    if [ -d "$DAP_SRC" ] && [ ! -f "$DAP_BIN" ]; then
        echo "  Building mcp-dap-server from source..."
        (cd "$DAP_SRC" && GOMODCACHE=/tmp/gomodcache go build -mod=readonly -o "$DAP_BIN" .) 2>&1
        if [ -f "$DAP_BIN" ]; then
            chmod +x "$DAP_BIN"
            echo "✓ mcp-dap-server built and installed"
        else
            echo "⚠ mcp-dap-server build failed"
        fi
    elif [ -f "$DAP_BIN" ]; then
        echo "✓ mcp-dap-server already installed"
    fi

    # ── Build CLAUDE.md from host + container addendum ──
    HOST_CLAUDE="$NODE_HOME/.claude-host/CLAUDE.md"
    ADDENDUM="/claude-config/container-addendum.md"
    TARGET_CLAUDE="$NODE_HOME/.claude/CLAUDE.md"
    if [ -f "$HOST_CLAUDE" ]; then
        cat "$HOST_CLAUDE" > "$TARGET_CLAUDE"
        if [ -f "$ADDENDUM" ]; then
            printf "\n\n" >> "$TARGET_CLAUDE"
            cat "$ADDENDUM" >> "$TARGET_CLAUDE"
        fi
        chown root:node "$TARGET_CLAUDE"
        chmod 444 "$TARGET_CLAUDE"
        echo "✓ CLAUDE.md merged with container addendum (locked)"
    else
        echo "ℹ No host CLAUDE.md mounted"
    fi

    # ── Ensure volumes are writable by node ──
    chown node:node /scratch
    chown node:node "$NODE_HOME/.claude/projects"

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
    if [ -n "${TARGET_REPO:-}" ]; then
        cd "/scratch/$(basename "$TARGET_REPO")" 2>/dev/null || true
    fi

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
fi
