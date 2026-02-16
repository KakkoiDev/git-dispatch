# git-dispatch

Split a POC branch into stacked task branches. Keep them in sync bidirectionally. Never cherry-pick manually again.

## Problem

You write a TRD, vibe-code the whole feature on a POC branch, then need clean stacked PRs for review. Manually cherry-picking and keeping branches in sync is tedious and error-prone.

## Solution

Tag commits with `Task-Id` trailers. `git dispatch split` groups them into stacked branches. `git dispatch sync` keeps everything in sync both ways.

## Quick Start

```bash
# Install
bash install.sh

# Tag commits on your POC
git checkout -b poc/feature master
git commit -m "Add PurchaseOrder to enum" --trailer "Task-Id=3"
git commit -m "Create GET endpoint"       --trailer "Task-Id=4"
git commit -m "Add DTOs"                  --trailer "Task-Id=4"
git commit -m "Implement validation"      --trailer "Task-Id=5"

# Split into stacked branches
git dispatch split poc/feature --base master --name feat/feature
# master
# └── feat/feature/task-3
#     └── feat/feature/task-4
#         └── feat/feature/task-5

# Continue working, then sync
git dispatch sync poc/feature
```

## Commands

| Command | Description |
|---------|-------------|
| `git dispatch split <poc> --name <prefix> --base <base>` | Split POC into stacked branches by Task-Id |
| `git dispatch split <poc> --name <prefix> --dry-run` | Preview split without creating branches |
| `git dispatch sync <poc>` | Sync all task branches bidirectionally |
| `git dispatch sync <poc> <child>` | Sync one specific task branch |
| `git dispatch tree [branch]` | Show stack hierarchy |
| `git dispatch hook install` | Install commit-msg hook enforcing Task-Id |
| `git dispatch help` | Show usage guide |

## Task-Id Trailers

Commits use native git trailers for task linking:

```bash
git commit -m "Add feature" --trailer "Task-Id=3"
```

Parse trailers (zero regex, git-native):

```bash
git log --format="%H %(trailers:key=Task-Id,valueonly)" master..poc
```

Install the hook to enforce trailers on every commit:

```bash
git dispatch hook install
```

## Workflow

### 1. Code on POC

Work on your POC branch as usual. Tag each commit with the task it belongs to:

```bash
git checkout -b cyril/poc/po-transactions master
git commit -m "Add PurchaseOrder to enum" --trailer "Task-Id=3"
git commit -m "Create GET endpoint"       --trailer "Task-Id=4"
git commit -m "Add DTOs"                  --trailer "Task-Id=4"
git commit -m "Implement validation"      --trailer "Task-Id=5"
```

### 2. Split

Preview first, then split:

```bash
git dispatch split cyril/poc/po-transactions --base master --name cyril/feat/po-transactions --dry-run
git dispatch split cyril/poc/po-transactions --base master --name cyril/feat/po-transactions
```

### 3. Sync

Sync is always bidirectional. New commits on POC flow to the right child branch, fixes on child branches flow back to POC:

```bash
# Sync all children
git dispatch sync cyril/poc/po-transactions

# Sync one child
git dispatch sync cyril/poc/po-transactions cyril/feat/po-transactions/task-4
```

Uses `git cherry` (patch-id comparison) to detect what's already applied -- no duplicate cherry-picks.

### 4. View stack

```bash
git dispatch tree master
# master
# └── cyril/feat/po-transactions/task-3
#     └── cyril/feat/po-transactions/task-4
#         └── cyril/feat/po-transactions/task-5
```

### 5. Create PRs

Create PRs manually with correct `--base` for each branch:

```bash
gh pr create --base master                                --head cyril/feat/po-transactions/task-3
gh pr create --base cyril/feat/po-transactions/task-3     --head cyril/feat/po-transactions/task-4
gh pr create --base cyril/feat/po-transactions/task-4     --head cyril/feat/po-transactions/task-5
```

## Worktree Support

Sync is worktree-aware. If a child branch has a worktree checked out, `git dispatch sync` cherry-picks directly into the worktree instead of doing checkout gymnastics.

## Conflict Recovery

When a cherry-pick conflict occurs during split or sync:

1. Resolve the conflict
2. `git cherry-pick --continue`
3. Re-run the dispatch command

## Stack Metadata

Stored in git config (survives rebases, no extra files):

- `branch.<name>.dispatchchildren` -- child branches (multi-value)
- `branch.<name>.dispatchpoc` -- source POC branch

## AI Integration

### Universal (AGENTS.md)

Works with Cursor, Windsurf, Codex, Aider, and other AI coding tools:

```bash
cp AGENTS.md /path/to/project/
```

### Skill (SKILL.md)

Deeper integration for Claude Code and GitHub Copilot:

```bash
# Claude Code
mkdir -p ~/.claude/skills/git-dispatch && cp SKILL.md ~/.claude/skills/git-dispatch/

# GitHub Copilot
mkdir -p ~/.copilot/skills/git-dispatch && cp SKILL.md ~/.copilot/skills/git-dispatch/
```

### Agent (Claude Code only)

Full automation with a dispatch workflow subagent:

```bash
mkdir -p ~/.claude/agents && cp AGENTS.md ~/.claude/agents/git-dispatch.md
```

## Installation

```bash
git clone <repo-url> && cd git-dispatch
bash install.sh
```

This creates a global git alias: `git dispatch` -> `git-dispatch.sh`.

## Testing

```bash
bash test.sh
```

## Requirements

- Git 2.x+
- Bash 3.2+ (macOS compatible)

## License

MIT
