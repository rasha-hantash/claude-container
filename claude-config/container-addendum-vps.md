## Container Environment — VPS Overrides

You are running inside a Docker container on a VPS with full permissions (`--dangerously-skip-permissions`). No permission prompts will appear.

### Workspace layout (overrides dotfiles/worktree sections above)

- `/workspace` is **writable** — repos are cloned from GitHub into this persistent volume.
- `/scratch` is **writable** — your working directory for active development (worktrees, temporary clones).
- **Do NOT use `EnterWorktree`** — use git worktrees directly with `git worktree add` inside `/scratch/<repo>`.
- Brain-os convention docs are at `/workspace/brain-os/`.

### Cloning additional repos

If you need a repo that wasn't cloned at startup:

```bash
git clone https://github.com/rasha-hantash/<repo-name>.git /workspace/<repo-name>
cd /workspace/<repo-name>
gt init --trunk main
```

For writable working copies, clone from the local workspace:

```bash
git clone /workspace/<repo-name> /scratch/<repo-name>
cd /scratch/<repo-name>
git remote set-url origin "$(git -C /workspace/<repo-name> remote get-url origin)"
gt init --trunk main
```

### Dotfiles and system configs (read-only)

You **cannot** edit hooks, CLAUDE.md, settings.json, or system-level config. These are copied from the dotfiles repo at startup and locked.

If you identify a change that should be made to dotfiles or Claude config:

1. **Create a GitHub issue** on `rasha-hantash/dotfiles` describing the change and why.
2. Move on with your current task.

### Credentials

- GitHub token: loaded from Docker secret at `/run/secrets/github_token` (exported as `GITHUB_TOKEN`)
- Graphite token: loaded from Docker secret, written to `~/.config/graphite/user_config`
- Claude credentials: loaded from `CLAUDE_CREDENTIALS` env var, written to `~/.claude/.credentials.json`
