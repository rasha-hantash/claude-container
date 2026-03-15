# Claude Container

Run Claude Code autonomously inside a Docker container. The container is the sandbox — full permissions inside, scoped credentials outside.

## Quick start

1. Create .env from template: `cp .env.template .env` (fill in GITHUB_TOKEN, GT_AUTH_TOKEN)
2. Build: `docker compose build`
3. Run: `./scripts/run.sh` (auto-extracts Claude credentials from macOS keychain)
4. One-shot task: `./scripts/run.sh claude -p "Fix the typo in README.md" --max-turns 5`

## How it works

- **Container = sandbox**: `--dangerously-skip-permissions` is safe because the container boundary prevents host damage
- **No network firewall**: Full outbound network access — WebFetch, npm install, cargo build, pip install, go get all work without restriction
- **Repos mounted from host via volume mount**: Claude uses `--worktree` flag to isolate changes — your working tree stays untouched
- **Credentials scoped**: Fine-grained GitHub PAT + Graphite token injected at runtime
- **Safety model**: Container isolation + scoped credentials + GitHub branch protection. The container can't touch the host, tokens are least-privilege, and branch protection prevents direct pushes to main

## Files

| File                          | Purpose                                                     |
| ----------------------------- | ----------------------------------------------------------- |
| `Dockerfile`                  | Full toolchain: Node, Rust, Go, Python, gh, gt, Claude Code |
| `docker-compose.yml`          | Volume mounts, env vars, resource limits                    |
| `entrypoint.sh`               | Configures git, gh, gt auth from env vars                   |
| `scripts/run.sh`              | Extracts Claude credentials from host keychain and launches |
| `claude-config/settings.json` | Bypass permissions (container is the sandbox)               |
| `claude-config/CLAUDE.md`     | Autonomous mode instructions                                |
| `.env.template`               | Template for secrets                                        |

## Resource limits

Default: 8GB memory, 4 CPUs. Adjust in `docker-compose.yml` if cargo/go builds need more.
