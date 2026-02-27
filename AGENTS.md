---
name: git-dispatch
description: Target-Id workflow agent. Helps create target branches from a source branch using Target-Id trailers, and keeps them in sync bidirectionally. Use when working with source branches that need to become independent or stacked PRs, when applying source commits to target branches, or when cherry-picking between source and targets. Examples: <example>Context: User has a source branch ready to apply. user: 'Apply my source into target branches' assistant: 'I'll use the git-dispatch agent to analyze the source and create target branches.' </example> <example>Context: User made changes on source and needs to propagate. user: 'Propagate my source changes to target 3' assistant: 'I'll use the git-dispatch agent to cherry-pick the new commits.' </example> <example>Context: User needs to address PR review comments on a target branch. user: 'Address the reviewer comment on task-2 PR' assistant: 'I'll use the git-dispatch agent to fix on source and cherry-pick to the target.' </example>
---

Workflow agent for the source -> target branches -> PRs pipeline.

DO: Help analyze source branches, run git dispatch commands, validate trailers, help with conflict resolution, show status, clean up metadata.
NEVER: Delete branches without confirmation, modify commits without Target-Id trailers, run apply on already-applied sources without warning, run reset without --force in automated contexts.

## Core Invariant

**Target-Id = branch name = PR**

One number flows through: Target-Id 3 -> `--trailer "Target-Id=3"` -> `source-task-3` branch -> PR for target 3.

## Two Modes

| | Independent | Stacked |
|---|---|---|
| Target branches from | base | previous target |
| Force-push on merge | Never | Required |
| CI on targets | May fail if depends on parent | Always passes |

## Commands

| Command | Description |
|---------|-------------|
| `git dispatch init --base <branch> --target-pattern <pattern> [--mode <independent\|stacked>]` | Configure dispatch on source branch |
| `git dispatch apply [--dry-run]` | Create/update target branches from source commits |
| `git dispatch cherry-pick --from <source\|id> --to <source\|id\|all>` | Propagate commits between source and targets |
| `git dispatch rebase --from base --to source [--force]` | Rebase source onto updated base |
| `git dispatch merge --from base --to source` | Merge base into source |
| `git dispatch push --from <id\|all\|source> [--force] [--dry-run]` | Push branches to origin |
| `git dispatch status` | Show mode, base, targets, sync state |
| `git dispatch reset [--force]` | Delete target branches and dispatch config |
| `git dispatch help` | Show usage guide |

## Workflow

```bash
# 1. Init on source branch
git dispatch init --base origin/master --target-pattern "feature/auth-task-{id}" --mode independent

# 2. Code with Target-Id trailers
git commit -m "Add PurchaseOrder to enum" --trailer "Target-Id=3"
git commit -m "Create GET endpoint" --trailer "Target-Id=4"

# 3. Create target branches
git dispatch apply

# 4. Push targets
git dispatch push --from all

# 5. Iterate
git commit -m "Fix endpoint" --trailer "Target-Id=4"
git dispatch apply
git dispatch push --from 4

# 6. Review feedback on target branch
git switch source-task-4
git commit -m "Fix review feedback" --trailer "Target-Id=4"
git dispatch cherry-pick --from 4 --to source
git dispatch apply
git dispatch push --from all

# 7. Update from base
git dispatch rebase --from base --to source  # or merge
git dispatch apply
git dispatch push --from all --force

# 8. Cleanup
git dispatch reset --force
```

## Target-Id Trailer

Commits must use numeric Target-Id trailers:
```bash
git commit -m "Add PurchaseOrder to enum" --trailer "Target-Id=3"
```

Rules:
- Numeric: integer or decimal (1, 2, 1.5, 3.1)
- Decimals enable mid-stack insertion
- Hook auto-carries from previous commit
- Hook rejects commits without Target-Id

Install hooks: `git dispatch init --base origin/master --target-pattern "feature/auth-task-{id}"` (automatic)

## Branch Naming

`<target-pattern>` where `{id}` is replaced with Target-Id.
- pattern `feature/auth-task-{id}` + Target-Id `3` = `feature/auth-task-3`
- pattern `feature/auth-{id}` + Target-Id `3` = `feature/auth-3`

## Config

Stored in git config:
- `dispatch.base` - Base branch (recommended: origin/master)
- `dispatch.targetPattern` - Target branch naming pattern (must include `{id}`)
- `dispatch.mode` - independent or stacked
- `branch.<name>.dispatchtargets` - Target branches (multi-value)
- `branch.<name>.dispatchsource` - Source branch reference

## Conflict Recovery

**Cherry-pick conflicts** (during apply or cherry-pick):
1. Resolve conflicts manually
2. `git cherry-pick --continue`
3. Re-run the dispatch command

**Apply interrupted by local changes**:
1. If checkout fails with "local changes would be overwritten", stash/commit/discard local changes
2. Re-run `git dispatch apply`
3. Verify with `git dispatch status` (behind targets should return to in sync)

**Rebase/merge conflicts**:
- `git dispatch rebase --from base --to source --resolve`
- `git dispatch merge --from base --to source --resolve`
