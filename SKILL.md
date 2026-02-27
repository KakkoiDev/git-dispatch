---
name: git-dispatch
description: Target-Id workflow tool. Code on a source branch with Target-Id trailers, apply into target branches, sync bidirectionally. Use when preparing clean PRs from a source branch.
---

# git-dispatch - Source to Target Branches

Code on source -> apply into target branches -> push PRs -> sync both ways.

**Target-Id = branch name = PR**

## Commands

| Command | Description |
|---------|-------------|
| `git dispatch init --base <branch> --target-pattern <pattern> [--mode <independent\|stacked>]` | Configure dispatch on source branch |
| `git dispatch apply [--dry-run]` | Create/update target branches from source commits |
| `git dispatch cherry-pick --from <source\|id> --to <source\|id\|all>` | Propagate commits between source and targets |
| `git dispatch rebase --from base --to source [--force]` | Rebase source onto base |
| `git dispatch merge --from base --to source` | Merge base into source |
| `git dispatch push --from <id\|all\|source> [--force] [--dry-run]` | Push branches to origin |
| `git dispatch status` | Show mode, base, targets, sync state |
| `git dispatch reset [--force]` | Delete target branches and config |
| `git dispatch help` | Show usage guide |

## Target-Id Trailers

Every commit needs a numeric `Target-Id` trailer:
```bash
git commit -m "Add PurchaseOrder to enum" --trailer "Target-Id=3"
```

Decimals (1.5) enable mid-stack insertion. Hook auto-carries from previous commit.

## Full Workflow

```bash
# 1. Init on source branch
git dispatch init --base origin/master --target-pattern "feature/auth-task-{id}"

# 2. Code with Target-Id trailers
git commit -m "Add enum" --trailer "Target-Id=3"
git commit -m "Create GET endpoint" --trailer "Target-Id=4"
git commit -m "Add DTOs" --trailer "Target-Id=4"
git commit -m "Implement validation" --trailer "Target-Id=5"

# 3. Create target branches
git dispatch apply

# 4. Push and create PRs
git dispatch push --from all

# 5. Iterate - add fix, re-apply
git commit -m "Fix endpoint" --trailer "Target-Id=4"
git dispatch apply
git dispatch push --from 4

# 6. Review feedback on target
git switch <source>-task-4
git commit -m "Fix review feedback" --trailer "Target-Id=4"
git dispatch cherry-pick --from 4 --to source
git dispatch apply
git dispatch push --from all

# 7. Update from base
git dispatch rebase --from base --to source   # linear history
git dispatch merge --from base --to source    # preserve history

# 8. Cleanup
git dispatch reset --force
```

## Two Modes

- **Independent** (default): targets branch from base. No force-push needed when parent merges.
- **Stacked**: targets branch from previous target. CI always passes. Force-push required on merge.

## Branch Naming

`<target-pattern>` with `{id}` placeholder - e.g., `feature/auth-task-{id}` -> `feature/auth-task-3`

## Config

- `dispatch.base` - Base branch (recommended: origin/master)
- `dispatch.targetPattern` - Target branch naming pattern (must include `{id}`)
- `dispatch.mode` - independent or stacked
- `branch.<name>.dispatchtargets` - Target branches
- `branch.<name>.dispatchsource` - Source branch

## Installation

```bash
bash install.sh                # Creates git dispatch alias
git dispatch init --base origin/master --target-pattern "feature/auth-task-{id}"   # Per-repo hooks + config
```

## Recovery Tip

If `git dispatch apply` stops with "local changes would be overwritten by checkout", clean/stash/commit your local changes and run `git dispatch apply` again. The affected target will otherwise show as behind source.
