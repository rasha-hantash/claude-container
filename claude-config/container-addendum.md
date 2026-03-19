## Container Environment — Overrides

You are running inside a Docker container with full permissions (`--dangerously-skip-permissions`). No permission prompts will appear.

### Workspace layout (overrides dotfiles/worktree sections above)

- `/workspace` is **read-only** — mounted from the host. You can read all repos and brain-os docs here but **cannot write**.
- `/scratch` is **writable** — your working directory for cloned repos.
- If `TARGET_REPO` was set at launch, the entrypoint has already cloned it into `/scratch/<repo>` with the correct GitHub remote and Graphite initialized. Your CWD should already be `/scratch/<repo>`.
- **Do NOT use `EnterWorktree`** — use git worktrees directly with `git worktree add` inside `/scratch/<repo>`.
- Brain-os convention docs are readable at `/workspace/brain-os/`. If you need to write to brain-os, clone it into `/scratch` first.

### Cloning additional repos

If you need to work on a repo that wasn't cloned at startup:

```bash
git clone /workspace/<repo-name> /scratch/<repo-name>
cd /scratch/<repo-name>
git remote set-url origin "$(git -C /workspace/<repo-name> remote get-url origin)"
gt init --trunk main
```

### Dotfiles and system configs (overrides dotfiles section above)

You **cannot** edit dotfiles, hooks, CLAUDE.md, settings.json, or any system-level config. These are mounted read-only from the host. Do NOT attempt to modify files under `~/.claude/hooks/`, `~/.claude/agents/`, `~/.claude/skills/`, or `~/.claude/CLAUDE.md`.

If you identify a change that should be made to dotfiles or Claude config:

1. **Create a GitHub issue** on `rasha-hantash/dotfiles` describing the change and why.
2. Move on with your current task — the host user will make the change in a host session where the symlink chain works.

Do NOT clone the dotfiles repo into `/scratch` to make changes — dotfiles are symlinked on the host and changes must propagate through those symlinks.

### Credentials

- GitHub token: loaded from Docker secret at `/run/secrets/github_token` (exported as `GITHUB_TOKEN`)
- Graphite token: loaded from Docker secret, written to `~/.config/graphite/user_config`
- Claude credentials: loaded from `CLAUDE_CREDENTIALS` env var, written to `~/.claude/.credentials.json`
