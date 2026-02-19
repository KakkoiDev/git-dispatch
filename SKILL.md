---
name: git-dispatch
description: TRD-to-stacked-PRs workflow tool. Write a TRD with numbered tasks, vibe-code on a source branch with Task-Id trailers, split into stacked branches, create PRs, sync bidirectionally. Use when preparing clean PRs from a source branch or writing TRDs.
---

# git-dispatch - TRD to Stacked PRs

Write TRD -> vibe-code source -> split into branches -> create PRs -> sync both ways.

**TRD task number = Task-Id trailer = branch name = PR**

## Commands

| Command | Description |
|---------|-------------|
| `git dispatch split <source> --name <prefix> --base <base>` | Split source into stacked branches by Task-Id |
| `git dispatch split <source> --name <prefix> --dry-run` | Preview split without creating branches |
| `git dispatch sync` | Auto-detect source, sync all task branches bidirectionally |
| `git dispatch sync [source]` | Sync all task branches for a specific source |
| `git dispatch sync [source] <task>` | Sync one specific task branch |
| `git dispatch status [source]` | Show pending sync counts without applying |
| `git dispatch pr [source] [--branch <name>] [--title <t>] [--body <b>] [--push] [--dry-run]` | Create stacked PRs via gh CLI |
| `git dispatch reset [source] [--branches] [--force]` | Clean up dispatch metadata |
| `git dispatch tree [branch]` | Show stack hierarchy |
| `git dispatch hook install` | Install hooks (auto-carry Task-Id + enforce Task-Id) |
| `git dispatch help` | Show usage guide |

## Task-Id Trailers

Every commit needs a `Task-Id` trailer matching its TRD task number:
```bash
git commit -m "Add PurchaseOrder to enum" --trailer "Task-Id=3"
```

Task→source sync adds missing trailers automatically.

## Task-Order Trailer

Optional trailer to control stack position during split:
```bash
git commit -m "fix" --trailer "Task-Id=task-13.1" --trailer "Task-Order=8"
```

Three modes (backward compatible):
- **No Task-Order** — commit order (default)
- **Partial** — ordered tasks sort first, unordered follow in commit order
- **Full** — all tasks sorted by explicit order

## Full Workflow

```bash
# 1. Write TRD with numbered tasks (see trd-template.md)

# 2. Vibe-code source, tagging commits with TRD task numbers
git checkout -b cyril/source/feature master
git dispatch hook install
git commit -m "Add PurchaseOrder to enum"      --trailer "Task-Id=3"
git commit -m "Create GET endpoint"            --trailer "Task-Id=4"
git commit -m "Add DTOs"                       --trailer "Task-Id=4"
git commit -m "Implement validation"           --trailer "Task-Id=5"

# 3. Split into stacked branches (one per TRD task)
git dispatch split cyril/source/feature --base master --name cyril/feat/feature

# 4. Create stacked PRs (each PR = one TRD task)
git dispatch pr --push

# 5. Keep iterating -- check status, then sync
git dispatch status
git dispatch sync

# 6. View stack
git dispatch tree

# 7. Cleanup when done
git dispatch reset --force
```

## TRD Template

Available at `trd-template.md`. Key: task numbers become Task-Id trailer values.

## Stack Metadata

Stored in git config:
- `branch.<name>.dispatchtasks` -- task branches
- `branch.<name>.dispatchsource` -- source branch

## Installation

```bash
bash install.sh                # Creates git dispatch alias
git dispatch hook install      # Per-repo Task-Id enforcement
```
