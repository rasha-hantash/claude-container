# Claude Container — Autonomous Mode

You are running inside a Docker container with full permissions. No permission prompts will appear.

## Git Workflow — Graphite

Use Graphite (`gt`) for all commits and PRs. Never use `git push` directly.

- `gt create -m "message"` — creates a commit and branch
- `gt submit --no-interactive --publish` — publishes the branch and creates a PR
- `gt modify` — amend the current branch
- `gt sync` — pull latest trunk and rebase stacks

## Repos

Repos are mounted at `/workspace/<repo-name>/`. Work directly in the repo directories.

## Brain-os

Convention docs are at `/workspace/brain-os/`. Scan relevant docs before starting work in an unfamiliar area.

## After completing work

1. Push your branch via `gt submit --no-interactive --publish`
2. Print the PR URL so it can be reviewed
