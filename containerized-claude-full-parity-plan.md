# Full-Parity Containerized Claude — Same TUI, Sandboxed Backend

Make the containerized Claude Code experience identical to native: same cove TUI, same sidebar state tracking, same audio notifications, same brain-os context injection, same learnings capture. The only difference is Claude runs inside a Docker container for sandboxing.

## Architecture

```
Host (macOS)                              Container (Linux)
────────────                              ──────────────────
Cove TUI (tmux)                           Claude Code process
├── Pane .1: docker run claude  ←stdin/stdout→  ├── Full hooks ecosystem
│   (interactive TTY via tmux)                   ├── brain-os context injection
│                                                ├── Learnings capture → gt submit
├── Pane .2: cove sidebar                        ├── cove-shim writes events
│   ├── Reads event files ←── volume mount ──────┘
│   ├── Shows: "your turn" / spinner / "approve…"
│   └── Plays beep on idle transition (afplay on host)
│
└── Volume mounts:
    ├── ~/explorations:/workspace (repos)
    ├── ~/.claude/hooks → /root/.claude/hooks (ro)
    ├── ~/.claude/agents → /root/.claude/agents (ro)
    ├── ~/.claude/skills → /root/.claude/skills (ro)
    ├── ~/.claude/commands → /root/.claude/commands (ro)
    ├── ~/.local/state/cove/events → /root/.local/state/cove/events (rw)
    └── entrypoint.sh → /entrypoint.sh (ro)
```

## Pre-validation Results

All assumptions validated empirically before planning:

| #   | Assumption                                          | Result                                       |
| --- | --------------------------------------------------- | -------------------------------------------- |
| 1   | Docker stdin/stdout works interactively in tmux     | Validated — tty:true + stdin_open:true       |
| 2   | $TMUX_PANE available and passable to container      | Validated — TMUX_PANE=%3                     |
| 3   | Bash shim can replicate cove hook event writing     | Validated — simple JSONL format              |
| 4   | Event files visible across container/host via mount | Validated — wrote in container, read on host |
| 5   | claude --worktree works inside container            | Validated — returned correct output          |
| 6   | ~ resolves to /root in container                    | Validated                                    |
| 7   | Container startup latency                           | Validated — 1.6s                             |
| 8   | Multiple concurrent containers                      | Validated — --name flag                      |
| 9   | Sidebar can spawn processes (for audio)             | Validated — uses thread::spawn               |
| 10  | Cove launch code is a single function               | Validated — tmux.rs:45-51                    |

## Changes

### 1. Add volume mounts for full ecosystem (docker-compose.yml)

Mount hooks, agents, skills, commands read-only. Mount cove events read-write. Pass TMUX_PANE.

```yaml
services:
  claude:
    build: .
    env_file: .env
    environment:
      - CLAUDE_CREDENTIALS=${CLAUDE_CREDENTIALS:-}
      - TMUX_PANE=${TMUX_PANE:-}
      - BRAIN_OS_PATH=/workspace/brain-os
    volumes:
      - ~/workspace/personal/explorations:/workspace
      - claude-state:/root/.claude/projects
      - /tmp/cove-events:/tmp/cove-events
      - ./entrypoint.sh:/entrypoint.sh:ro
      # Full Claude ecosystem
      - ~/.claude/hooks:/root/.claude/hooks:ro
      - ~/.claude/agents:/root/.claude/agents:ro
      - ~/.claude/skills:/root/.claude/skills:ro
      - ~/.claude/commands:/root/.claude/commands:ro
      # Cove event sharing (sidebar reads these on host)
      - ~/.local/state/cove/events:/root/.local/state/cove/events
    stdin_open: true
    tty: true
    deploy:
      resources:
        limits:
          memory: 8g
          cpus: "4"
```

### 2. Create cove-shim.sh for container (claude-container repo)

A lightweight bash script that replaces the `cove` binary inside the container. Handles `cove hook <event>` by writing the same JSONL format.

**File:** `claude-container/cove-shim.sh`

```bash
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
```

Install in container: `COPY cove-shim.sh /usr/local/bin/cove` + `chmod +x`.

### 3. Generate container settings.json (entrypoint.sh)

The entrypoint merges the host's settings.json (mounted via hooks volume) with container-specific overrides. Key changes:

- Replace all `/Users/rashasaadeh/...` paths with container equivalents
- Replace `~/.cargo/bin/cove` with `/usr/local/bin/cove` (the shim)
- Replace `afplay ...` hooks with no-ops (audio moves to cove sidebar)
- Keep deny rules for `gt merge` / `gh pr merge`
- Keep `defaultMode: bypassPermissions`

**Approach:** The entrypoint reads the host settings.json from the mounted hooks dir (or a separate mount), does the path replacements with `sed`, merges with container permissions, and writes to `/root/.claude/settings.json`.

Add to entrypoint.sh:

```bash
# ── Merge settings.json ──
HOST_SETTINGS="/root/.claude/hooks/../settings.json"  # Mounted from host
if [ -f "/root/.claude-host/settings.json" ]; then
    # Path remap + container overrides
    sed \
        -e 's|/Users/rashasaadeh/workspace/personal/explorations|/workspace|g' \
        -e 's|/Users/rashasaadeh/.claude|/root/.claude|g' \
        -e 's|~/.cargo/bin/cove|/usr/local/bin/cove|g' \
        -e 's|~/.claude|/root/.claude|g' \
        -e 's|afplay [^"]*|echo noop-audio|g' \
        /root/.claude-host/settings.json > /root/.claude/settings.json

    # Inject container-specific deny rules
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
" 2>/dev/null || echo "⚠ Failed to merge settings.json"
fi
```

This requires an additional volume mount:

```yaml
- ~/.claude/settings.json:/root/.claude-host/settings.json:ro
```

### 4. Mount host CLAUDE.md (docker-compose.yml)

Replace the stub CLAUDE.md with the host's rich global instructions:

```yaml
- ~/.claude/CLAUDE.md:/root/.claude/CLAUDE.md:ro
```

The Dockerfile's `COPY claude-config/CLAUDE.md` serves as fallback if not mounted.

### 5. Add BRAIN_OS_PATH env var to hooks (dotfiles repo)

Modify 4 hooks to use `os.environ.get("BRAIN_OS_PATH", ...)` instead of hardcoded paths:

**brain-os-context.py** (~line 17-18):

```python
BRAIN_OS_PATH = Path(os.environ.get(
    "BRAIN_OS_PATH",
    os.path.expanduser("~/workspace/personal/explorations/brain-os")
))
```

**brain-os-capture.py** (~line 26-30): Same pattern.

**capture-learnings.py** (~line 17-22): Same pattern.

**pre-compact.py**: Check for any brain-os path references, apply same pattern.

This is backwards-compatible — on the host, the env var isn't set, so it falls back to the default path.

### 6. Add audio to cove sidebar on state transition (cove repo)

**File:** `cove/src/sidebar/app.rs` or `state.rs`

When the sidebar detects a window transition from non-idle → idle ("your turn"), spawn `afplay ~/.claude/assets/audio/beep.mp3` in a detached thread.

```rust
// In the state update loop
if previous_state != WindowState::Idle && new_state == WindowState::Idle {
    std::thread::spawn(|| {
        let _ = std::process::Command::new("afplay")
            .arg(expand_tilde("~/.claude/assets/audio/beep.mp3"))
            .spawn();
    });
}
```

This replaces the `afplay` hooks in Claude Code's settings.json. Benefits:

- Works for both native and containerized sessions
- Sound always plays on the host where speakers exist
- One place to configure notification behavior

### 7. Update cove to support docker launch mode (cove repo)

**File:** `cove/src/tmux.rs` (lines 45-51)

Add a docker launch mode. When enabled, cove wraps the claude command in `docker compose run`:

```rust
fn claude_cmd_and_window_name(name: &str, dir: &str, docker: bool) -> (String, String) {
    if docker {
        let cmd = format!(
            "cd {} && docker compose run --rm --name claude-{} claude claude --worktree {}",
            CLAUDE_CONTAINER_DIR, name, name
        );
        (cmd, format!("{name}(docker)"))
    } else if is_git_repo(dir) {
        (format!("claude --worktree {name}"), format!("{name}(wt)"))
    } else {
        ("claude".to_string(), name.to_string())
    }
}
```

The `CLAUDE_CONTAINER_DIR` points to `~/workspace/personal/explorations/claude-container/`.

`scripts/run.sh` handles CLAUDE_CREDENTIALS extraction, so cove would call that script instead of `docker compose run` directly. Or cove could extract the credentials itself.

### 8. Update Dockerfile (claude-container repo)

Add the cove shim:

```dockerfile
# Cove hook shim (lightweight replacement for cove binary)
COPY cove-shim.sh /usr/local/bin/cove
RUN chmod +x /usr/local/bin/cove
```

## Stack structure (2 PRs)

**PR 1: Container ecosystem parity** (claude-container repo)

- docker-compose.yml: volume mounts, env vars
- entrypoint.sh: settings.json merge logic
- cove-shim.sh: new file
- Dockerfile: add cove shim

**PR 2: Host-side changes** (dotfiles + cove repos)

- dotfiles: BRAIN_OS_PATH env var in 4 hooks
- cove: docker launch mode in tmux.rs
- cove: audio notification in sidebar on idle transition

## Verification

### Smoke test: Brain-os context injection

```bash
# Inside container, verify brain-os context appears in a session
docker compose run --rm claude claude -p \
  "What brain-os conventions apply to Rust error handling?"
# Should reference rust/rust-conventions.md content
```

### Smoke test: Cove state tracking

1. Launch a session via cove with docker mode
2. Sidebar should show spinner while Claude works
3. When Claude stops, sidebar shows "your turn" + beep plays

### Smoke test: Learnings capture

1. Run a session that discovers something non-obvious
2. On session end, `brain-os-capture.py` fires inside container
3. A brain-os PR appears on Graphite

### Smoke test: Audio

1. Launch native and container sessions side by side
2. Both should play beep when transitioning to idle
3. Sound comes from cove sidebar (host), not Claude hooks (container)

## Progress

- [ ] PR 1: Container ecosystem parity
  - [ ] docker-compose.yml volume mounts and env vars
  - [ ] cove-shim.sh
  - [ ] Dockerfile update
  - [ ] entrypoint.sh settings.json merge
- [ ] PR 2: Host-side changes
  - [ ] BRAIN_OS_PATH env var in hooks (dotfiles)
  - [ ] Cove docker launch mode (cove)
  - [ ] Cove sidebar audio on state transition (cove)
- [ ] Smoke tests
  - [ ] Brain-os context injection
  - [ ] Cove state tracking
  - [ ] Learnings capture
  - [ ] Audio notifications
