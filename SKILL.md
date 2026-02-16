---
name: git-dispatch
description: POC-to-stacked-branches workflow tool. Split a POC branch into task-based stacked branches and keep them in sync bidirectionally. Use when preparing clean PRs from a POC branch.
---

# git-dispatch - POC to Stacked Branches

Split a POC branch into clean stacked task branches. Bidirectional sync via patch-id comparison.

## Commands

| Command | Description |
|---------|-------------|
| `git dispatch split <poc> --name <prefix> --base <base>` | Split POC into stacked branches by Task-Id |
| `git dispatch split <poc> --name <prefix> --dry-run` | Preview split without creating branches |
| `git dispatch sync` | Auto-detect POC, sync all task branches bidirectionally |
| `git dispatch sync [poc]` | Sync all task branches for a specific POC |
| `git dispatch sync [poc] <child>` | Sync one specific task branch |
| `git dispatch tree [branch]` | Show stack hierarchy |
| `git dispatch hook install` | Install commit-msg hook enforcing Task-Id |
| `git dispatch help` | Show usage guide |

## Task-Id Trailers

Every commit needs a `Task-Id` trailer:
```bash
git commit -m "Add feature" --trailer "Task-Id=3"
```

Parse trailers:
```bash
git log --format="%H %(trailers:key=Task-Id,valueonly)" master..poc
```

## Typical Workflow

```bash
# 1. Code on POC with trailers
git checkout -b poc/feature master
git commit -m "Add enum" --trailer "Task-Id=3"
git commit -m "Add endpoint" --trailer "Task-Id=4"
git commit -m "Add DTOs" --trailer "Task-Id=4"

# 2. Split into stacked branches
git dispatch split poc/feature --base master --name feat/feature

# 3. Sync after more POC work (auto-detects POC from current branch)
git dispatch sync

# 4. View stack
git dispatch tree master
```

## Stack Metadata

Stored in git config:
- `branch.<name>.dispatchchildren` -- child branches
- `branch.<name>.dispatchpoc` -- source POC branch

## Installation

```bash
bash install.sh                # Creates git dispatch alias
git dispatch hook install      # Per-repo Task-Id enforcement
```
