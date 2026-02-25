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
| `git dispatch push [source] [--branch <name>] [--force] [--dry-run]` | Push task branches to origin |
| `git dispatch pr [source] [--branch <name>] [--title <t>] [--body <b>] [--push] [--dry-run]` | Create stacked PRs via gh CLI |
| `git dispatch resolve` | Convert merge commit on task branch to regular commit with Task-Id |
| `git dispatch restack [source] [--dry-run]` | Rebase stack onto updated base after merge |
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

# 5b. If task branch needs to merge base to resolve conflicts
git checkout cyril/feat/feature/4
git merge master              # resolve conflicts, commit
git dispatch resolve          # converts merge to regular commit

# 5c. After a PR is merged, rebase downstream branches
git dispatch restack          # rebase stack onto updated master
git dispatch push --force     # force-push rebased branches

# 6. View stack
git dispatch tree

# 7. Cleanup when done
git dispatch reset --force
```

## Addressing PR Feedback

When a reviewer comments on a stacked PR and the fix needs a new commit (whether the task branch exists or not):

### 1. Detect conventions on the source branch

```bash
git log --format="%s%n  Task-Id: %(trailers:key=Task-Id,valueonly)  Task-Order: %(trailers:key=Task-Order,valueonly)%n---" <base>..<source>
```

Match the established format (numeric `3` vs prefixed `task-3`, with or without `Task-Order`).

### 2. Fix on source branch (single source of truth)

```bash
git checkout <source-branch>
# ... make changes ...
git commit -m "fix: address PR comment" --trailer "Task-Id=<id>" [--trailer "Task-Order=<order>"]
```

- Use existing task ID if the fix belongs to an existing task
- Use a new sub-ID (e.g., `task-6.2`) if it's a new reviewable unit

### 3. Split or sync

| Scenario | Command |
|----------|---------|
| Task branch **does not exist** (new task or after reset) | `git dispatch split <source> --base <base> --name <prefix>` |
| Task branch **exists** | `git dispatch sync` |

### 4. Push

```bash
git dispatch push --branch <task-branch>       # single branch
git dispatch push --force                       # if rebased by split
```

## TRD Template

Available at `trd-template.md`. Key: task numbers become Task-Id trailer values.

## Stack Metadata

Stored in git config:
- `branch.<name>.dispatchtasks` -- task branches
- `branch.<name>.dispatchsource` -- source branch

## Config

Optional git config keys to enforce trailer conventions:

```bash
git config dispatch.taskIdPattern '^task-[0-9]+$'   # regex Task-Id must match
git config dispatch.requireTaskOrder true            # require Task-Order on every commit
```

| Key | Type | Default | Common patterns |
|-----|------|---------|-----------------|
| `dispatch.taskIdPattern` | regex | (unset = any) | `^task-[0-9]+$`, `^[0-9]+$`, `^[0-9]{3,}$` |
| `dispatch.requireTaskOrder` | bool | `false` | `true` |

Validated by commit-msg hook and at split time. Task-Order format (numeric/decimal) is always validated when present.

## Installation

```bash
bash install.sh                # Creates git dispatch alias
git dispatch hook install      # Per-repo Task-Id enforcement
```
