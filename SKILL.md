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
| `git dispatch apply [--dry-run] [--resolve] [--force] [--reset <id>]` | Create/update target branches from source commits |
| `git dispatch cherry-pick --from <source\|id> --to <source\|id\|all> [--resolve]` | Propagate commits between source and targets |
| `git dispatch rebase --from base --to source [--force] [--resolve]` | Rebase source onto base |
| `git dispatch merge --from base --to <source\|id\|all> [--resolve]` | Merge base into source or targets |
| `git dispatch push --from <id\|all\|source> [--force] [--dry-run]` | Push branches to origin |
| `git dispatch status` | Show mode, base, targets, sync state, divergence |
| `git dispatch diff --to <id>` | Show file-level diff between source and a target |
| `git dispatch verify` | Detect cross-target file dependencies (independent mode) |
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

## Conflict Handling

All conflict commands (`cherry-pick`, `apply`, `rebase`, `merge`) show conflicted files and diff on failure.

- **Default**: aborts cleanly, prints "Re-run with --resolve to keep conflict active"
- **`--resolve`**: leaves conflict active for manual resolution, shows remaining work
- Cherry-pick shows batch progress (commit X/Y) and lists remaining commits

**Resolve workflow:**
1. Run command with `--resolve` to keep conflict active
2. Edit conflicted files, `git add` them
3. Run the continue command shown in output (`cherry-pick --continue`, `rebase --continue`, or `commit`)
4. Re-run the dispatch command for any remaining work
5. Verify with `git dispatch status`

## Divergence Detection

`status` tags targets that are both behind and ahead:
- `(DIVERGED)` - file content actually differs (likely lost changes after manual conflict resolution)
- `(cosmetic)` - same file content, different commit SHAs (normal after conflict resolution). Safe to ignore, or fix with `git dispatch apply --reset <id>`.

Only files from that target's own commits are checked (avoids false positives from generated files in independent mode).

**When DIVERGED appears:**
```bash
git dispatch diff --to <id>              # see what files diverged + resolution commands
git dispatch cherry-pick --from <id> --to source --resolve   # bring target version to source
# or
git dispatch cherry-pick --from source --to <id>              # push source version to target
git dispatch apply                           # sync everything
```

## Common Fixes

| Problem | Fix |
|---------|-----|
| Target behind source | `git dispatch apply` or `cherry-pick --from source --to <id>` |
| Target ahead of source | `cherry-pick --from <id> --to source` then `apply` |
| DIVERGED after conflict | `diff --to <id>` then cherry-pick in the right direction |
| Cosmetic divergence | Safe to ignore, or `git dispatch apply --reset <id>` |
| Stale target after tid reassignment | `git dispatch apply --force` to rebuild |
| Cross-target file dependency | `git dispatch verify` to detect, then restructure or use stacked mode |
| Generated file conflict on create | Auto-resolved with `--theirs` (takes source version) |
| Cherry-pick mid-batch fail | Re-run same cherry-pick command (picks up remaining) |
| Local changes block checkout | `git stash -u` then retry |
| Need upstream changes | `rebase --from base --to source` or `merge --from base --to source` |

## Installation

```bash
bash install.sh                # Creates git dispatch alias
git dispatch init --base origin/master --target-pattern "feature/auth-task-{id}"   # Per-repo hooks + config
```
