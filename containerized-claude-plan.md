# Containerized Claude — Autonomous AI Coding with Reduced Blast Radius

## Goal

Run Claude Code in a Docker container with full autonomy (`bypassPermissions`), using the container boundary as the safety sandbox instead of client-side hooks. The container has repos, tools, and credentials — but destructive operations can't escape it.

## Why

Current setup requires staying near the terminal to approve permissions. A container lets Claude work fully autonomously while the safety guarantee shifts from "hooks block dangerous commands" to "the container is disposable and credentials are scoped."

## Architecture

```
Host machine
├── .env (secrets: GH_TOKEN, ANTHROPIC_API_KEY, GT_TOKEN)
├── docker-compose.yml
├── Dockerfile
└── volumes/
    ├── repos/        ← mounted from ~/workspace/personal/explorations/
    ├── claude-home/  ← persistent ~/.claude state
    └── output/       ← artifacts Claude produces
```

## Key Design Decisions

### 1. Container = sandbox (no client-side safety hooks needed)

| Hook/setting             | Local            | Container           | Why                           |
| ------------------------ | ---------------- | ------------------- | ----------------------------- |
| `branch-guard.py`        | Required         | Remove              | Container is disposable       |
| `validate-bash.py`       | Required         | Remove              | No host to protect            |
| `permissions.allow/deny` | Carefully scoped | `bypassPermissions` | Container is the blast radius |
| `defaultMode`            | `acceptEdits`    | `bypassPermissions` | Full autonomy                 |

### 2. Credential boundary (the real safety layer)

GitHub fine-grained PAT scoped to your repos with:

- Read/write for `contents` (push branches)
- Read/write for `pull_requests` (create PRs)
- **No** main branch push (branch protection rule on GitHub)
- **No** delete repos, manage settings, or admin access

This means even with `bypassPermissions`, Claude can't:

- Push directly to main (GitHub blocks it)
- Merge PRs (no merge permission, or require approval)
- Delete repos or change settings
- Access repos outside the scoped set

### 3. Repos — volumes vs clones

**Option A: Mount as volumes** (chosen)

- Real-time sync — Claude sees your latest local changes
- The `--worktree` flag provides isolation: Claude's writes go to a separate worktree, your working tree stays untouched
- No clone overhead — instant startup
- Changes reach host via PR (worktree pushes branches)

**Option B: Clone fresh at container start**

- Fully isolated — host repos untouched
- Claude pushes branches, you review PRs
- Slower startup (clone time)
- Better for "fire and forget" autonomous tasks

**Decision:** Option A chosen with `--worktree` isolation. Repos are mounted from host via volume mount. Claude can see your latest local changes but writes go to a separate worktree, keeping your working tree untouched. Changes reach the host via PR.

### 4. What goes in the container

**From Brewfile (build-time):**

- `git`, `gh`, `gt` (Graphite)
- `rust`/`cargo`, `go`, `node`/`npm`, `python`/`uv`
- `jq`, `fzf`, `ripgrep`, `fd`
- `neovim` (for LSP servers if needed)

**From dotfiles (build-time):**

- `~/.claude/CLAUDE.md` (global instructions)
- `~/.claude/hooks/` — only non-safety hooks (brain-os-context.py, pre-compact.py)
- `~/.claude/skills/`, `~/.claude/agents/`
- Stripped `settings.json` with `bypassPermissions`

**At runtime (env vars):**

- `ANTHROPIC_API_KEY`
- `GITHUB_TOKEN` (fine-grained PAT)
- `GT_TOKEN` (Graphite auth)

## Files to Create

| File                             | Purpose                                                                  |
| -------------------------------- | ------------------------------------------------------------------------ |
| `Dockerfile`                     | Base image with all tools, Claude Code CLI                               |
| `docker-compose.yml`             | Volume mounts, env vars, networking                                      |
| `claude-container/settings.json` | Stripped settings — bypass permissions, no safety hooks                  |
| `claude-container/CLAUDE.md`     | Modified global instructions (no worktree rules, no permission concerns) |
| `entrypoint.sh`                  | Configure git identity, gh/gt auth, start Claude                         |
| `.env.template`                  | Template for secrets                                                     |

## Rough Dockerfile

```dockerfile
FROM ubuntu:24.04

# System deps
RUN apt-get update && apt-get install -y \
    git curl build-essential pkg-config libssl-dev \
    jq ripgrep fd-find tmux neovim

# Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Go
RUN curl -fsSL https://go.dev/dl/go1.24.1.linux-amd64.tar.gz | tar -C /usr/local -xzf -
ENV PATH="/usr/local/go/bin:${PATH}"

# Node (via nvm)
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
RUN bash -c "source ~/.nvm/nvm.sh && nvm install 22"

# Python + uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh

# Graphite
RUN npm install -g @withgraphite/graphite-cli

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Claude config
COPY claude-container/ /root/.claude/

WORKDIR /workspace

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

## Rough docker-compose.yml

```yaml
services:
  claude:
    build: .
    env_file: .env
    volumes:
      # Mount repos (Option A)
      - ~/workspace/personal/explorations:/workspace
      # Persist Claude state between runs
      - claude-home:/root/.claude/projects
    stdin_open: true
    tty: true

volumes:
  claude-home:
```

### 5. Cove integration

Cove currently launches Claude sessions by running `respawn-pane -t .1 -k claude` in tmux (see `cove/src/tmux.rs:126`). The change is small:

**What changes in cove:**

- Add a `--container` flag (or config option `runtime: "local" | "docker"`)
- In `tmux.rs`, swap the `"claude"` command for `docker run -it --rm --env-file ~/.env -v {dir}:/workspace claude-container`
- ~50 lines of Rust

**Cove sidebar status detection:**
Cove detects session state (Working/Idle/Asking) via hook scripts that write event files. Inside a container, these hooks would write to a mounted volume that the host-side sidebar can read.

- Mount a shared events dir: `-v /tmp/cove-events:/tmp/cove-events`
- Container hooks write to `/tmp/cove-events/` (same path, mounted from host)
- Sidebar reads from `/tmp/cove-events/` (unchanged)
- The `session_id` in event filenames already disambiguates concurrent sessions

**Kill flow:**
`cove all-kill` currently sends `C-c` + `/exit` to tmux panes. With containers:

- Same `send_keys` approach works — tmux sends to the pane, which is running `docker run -it`
- Claude exits → container stops (since `--rm`)
- If graceful exit fails, `docker kill` as fallback instead of tmux `kill-pane`

## Known Unknowns

### Validated (2026-03-14)

- [x] Cove launches Claude via `respawn-pane -k claude` in tmux — confirmed in `tmux.rs:126`
- [x] Claude Code CLI is available as npm package (`@anthropic-ai/claude-code`) — confirmed in Brewfile
- [x] `gh` supports fine-grained PATs — documented in GitHub docs
- [x] Docker `--rm` auto-removes container on exit — standard Docker behavior
- [x] **Claude Code has `--dangerously-skip-permissions`** — confirmed via `claude --help`. Also has `--permission-mode bypassPermissions`. Both work.
- [x] **Graphite auth is file-based** — token at `~/.config/graphite/user_config` as JSON `{"authToken": "..."}`. No env var support. Entrypoint must write this file from an env var, or mount `~/.config/graphite/`.
- [x] **GitHub branch protection requires Pro plan ($4/mo)** — free personal repos return 403 on branch protection API. This is a real gap in the safety model.

### Validated (2026-03-14, probe round 2)

- [x] **Claude Code runs inside Docker** — `docker run --rm claude-container claude --version` returns `2.1.76`. Pipe mode also works: `claude -p "Say hello"` returns a response.
- [x] **Entrypoint auth works** — gh auth, gt auth (file-write), git config all run correctly in container.
- [x] **Volume mounts work** — repos at `/workspace/` are accessible and writable from inside the container.

### Unvalidated — needs probing

- [ ] **Claude Code interactive mode in Docker via tmux** — `docker run -it` through a tmux pane (the actual cove path). Pipe mode works, but interactive TUI needs testing inside tmux.
- [ ] **Claude Code session persistence in containers** — session state lives in `~/.claude/projects/`. Volume mount in docker-compose.yml preserves it, but untested.
- [ ] **MCP servers inside containers** — context7, Graphite MCP, etc. are configured as local commands in `settings.json`. Do they work inside the container?
- [ ] **Hook event files across container boundary** — docker-compose.yml mounts `/tmp/cove-events` but sidebar code hasn't been tested with it.
- [ ] **`brain-os-context.py` hook path resolution** — hardcoded to `~/workspace/personal/explorations/brain-os/`. Container has repos at `/workspace/brain-os/`. Needs env var or path update.
- [ ] **Fine-grained PAT branch scoping** — can a PAT be restricted to exclude pushing to `main`?

### Blockers

- [x] ~~**TTY forwarding**~~ **RESOLVED.** Claude Code runs in Docker. Pipe mode confirmed. Interactive TUI via tmux still needs testing but is not a hard blocker (pipe mode is sufficient for autonomous tasks).
- [x] ~~**GitHub branch protection**~~ **CONFIRMED GAP.** Free repos don't support branch rules. Mitigations:
  1. **Upgrade to GitHub Pro** ($4/mo) — enables branch protection + required approvals
  2. **Fine-grained PAT branch restriction** — may be able to exclude `main` push (needs probing)
  3. **Graphite merge queue** — if PRs only merge via Graphite with required approvals, Claude can't self-merge
  4. **CLAUDE.md soft guard** — instructions say use Graphite, but this is advisory not enforced
  5. **`git push` in deny list** — the container `settings.json` could still deny `git push` while allowing `gt submit`. This is a client-side guard but works if Claude respects its own settings.

## Open Questions

- [ ] Should the container have internet access beyond GitHub API? (for npm install, cargo build, etc. — probably yes)
- [ ] Multiple concurrent containers for parallel tasks? (each on a different worktree/repo)
- [ ] How to surface results? Push PR + notification? Write to a shared volume?
- [ ] Cost guardrails — max tokens per session, session timeout?
- [ ] Should container sessions use `claude -p` (pipe mode, non-interactive) for fully autonomous tasks, or interactive mode for tasks that might need human input?

## Progress

- [x] **Probe: TTY forwarding** — Docker runs commands, pipe mode works (2026-03-14)
- [x] **Probe: Claude in Docker** — v2.1.76 installs and runs, pipe mode responds (2026-03-14)
- [x] **Probe: gh/gt auth** — entrypoint writes gt config, gh auth via token pipe (2026-03-14)
- [x] **Probe: branch protection** — free repos don't support it, gap documented (2026-03-14)
- [x] Create Dockerfile with full toolchain (2026-03-14)
- [x] Create stripped settings.json for container mode (2026-03-14)
- [x] Create entrypoint.sh with auth setup (2026-03-14)
- [x] Create docker-compose.yml with volume mounts (2026-03-14)
- [x] Create .env.template (2026-03-14)
- [ ] Test: create .env with real credentials, run `docker compose run --rm claude`
- [ ] Test: autonomous task — have Claude create a branch, make a change, push a PR
- [ ] Set up GitHub branch protection rules (requires Pro upgrade)
- [ ] Cove integration: add `--container` flag and Docker launch path
- [ ] Test: interactive TUI mode via tmux pane
