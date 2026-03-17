---
name: git-dispatch
description: Stacked PRs without the stack. Multi-commit grouped PRs with no force-push. Code on source, apply into independent target branches, integration test with checkout, sync with checkin. Use when preparing grouped PRs from a source branch.
---

# git-dispatch - Stacked PRs Without the Stack

Multi-commit grouped PRs. No force-push. No restack. No cascade.

Unlike ghstack/spr (1 commit = 1 PR), git-dispatch groups commits by Dispatch-Target-Id into multi-commit PRs. Each target branches independently from base. `checkout <N>` provides the combined view for integration testing.

**Source** = where all edits happen. **Targets** = read-only PR branches. **Checkout** = integration testing.

## Commands

| Command | Description |
|---------|-------------|
| `git dispatch init --base <branch> --target-pattern <pattern>` | Configure dispatch on source branch |
| `git dispatch apply [--dry-run] [--resolve] [--force] [--reset <id>]` | Create/update ALL target branches from source |
| `git dispatch checkout <N>` | Create integration branch with targets 1..N + "all" commits |
| `git dispatch checkout source` | Return to source branch |
| `git dispatch checkout clear [--force]` | Remove checkout branch (warns on unpicked commits) |
| `git dispatch checkin [--resolve]` | Cherry-pick new checkout commits back to source |
| `git dispatch cherry-pick --from <source\|id> --to <source\|id\|all> [--resolve]` | Move commits between source and target |
| `git dispatch rebase --from base --to source [--force] [--resolve]` | Rebase source onto base |
| `git dispatch merge --from base --to <source\|id\|all> [--resolve]` | Merge base into branches |
| `git dispatch push <all\|source\|N> [--force] [--dry-run]` | Push branches to origin |
| `git dispatch status` | Show mode, base, targets, sync state, divergence |
| `git dispatch diff --to <id>` | Show file-level diff between source and target |
| `git dispatch verify` | Detect cross-target file dependencies |
| `git dispatch continue` | Resume after conflict resolution |
| `git dispatch clean [--force]` | Remove leftover worktrees |
| `git dispatch reset [--force]` | Delete target branches and config |

## Trailers

Every commit needs a `Dispatch-Target-Id` trailer:
```bash
git commit -m "Add user model" --trailer "Dispatch-Target-Id=1"
git commit -m "Update CI config" --trailer "Dispatch-Target-Id=all"
git commit -m "Regen swagger" --trailer "Dispatch-Target-Id=3" --trailer "Dispatch-Source-Keep=true"
```

- Numeric: integer or decimal (1, 2, 1.5). Decimals enable mid-stack insertion.
- `all`: commit included in every target during apply.
- `Dispatch-Source-Keep: true`: auto-resolve conflicts with incoming version (--theirs). Used for generated files. Works during both apply (source->target) and checkin (checkout->source).
- Hook auto-carries Dispatch-Target-Id from previous commit.

## Workflows

### Basic: develop and create PRs
```bash
git dispatch init --base origin/master --target-pattern "feat/auth-{id}"
git commit -m "Add user model" --trailer "Dispatch-Target-Id=1"
git commit -m "Add auth middleware" --trailer "Dispatch-Target-Id=2"
git commit -m "Add login endpoint" --trailer "Dispatch-Target-Id=2"
git dispatch apply
git dispatch push all
```

### Integration testing
```bash
git dispatch checkout 3           # branch with targets 1..3 + all
pnpm test                         # run tests
git dispatch checkout source      # back to source
git dispatch checkout clear       # remove test branch
```

### Fix during integration
```bash
git dispatch checkout 3
# fix bug, commit with Dispatch-Target-Id
git dispatch checkin              # picks fix to source
git dispatch checkout source
git dispatch apply                # propagates to targets
git dispatch push 2
git dispatch checkout clear
```

### Generated files (OpenAPI, protobuf)
```bash
# Option A: regen on source with Source-Keep
pnpm openapi
git commit -m "regen" --trailer "Dispatch-Target-Id=all" --trailer "Dispatch-Source-Keep=true"
git dispatch apply

# Option B: regen for failing target via checkout
git dispatch checkout 3
pnpm openapi
git commit -m "regen swagger" --trailer "Dispatch-Target-Id=3" --trailer "Dispatch-Source-Keep=true"
git dispatch checkin             # Source-Keep auto-resolves conflict
git dispatch checkout source
git dispatch apply
git dispatch push 3
```

### Review feedback
```bash
git commit -m "Rename field per review" --trailer "Dispatch-Target-Id=2"
git dispatch apply
git dispatch push 2
```

### Keep up with main
```bash
git dispatch merge --from base --to source
git dispatch apply
git dispatch push all
```

## Apply vs Cherry-pick

| Want | Command |
|------|---------|
| Create new targets + update all | `git dispatch apply` |
| Update one existing target | `git dispatch cherry-pick --from source --to <id>` |
| Bring target commits to source | `git dispatch cherry-pick --from <id> --to source` |
| Regenerate one target from scratch | `git dispatch apply --reset <id>` |

## Config

- `dispatch.base` - Base branch (recommended: origin/master)
- `dispatch.targetPattern` - Target branch naming pattern (must include `{id}`)
- `dispatch.checkoutBranch` - Active checkout branch (set by checkout command)
- `branch.<name>.dispatchtargets` - Target branches
- `branch.<name>.dispatchsource` - Source branch

## Conflict Handling

All propagation commands support `--resolve` to leave conflicts active for manual resolution.

- **Default**: aborts cleanly, prints re-run hint
- **`--resolve`**: leaves conflict active in worktree, shows remaining work
- **Dispatch-Source-Keep**: auto-resolves with `--strategy-option theirs`

## Divergence Detection

`status` tags targets:
- `(DIVERGED)` - file content differs (changes may be lost)
- `(cosmetic)` - same content, different SHAs (safe to ignore)

Fix: `git dispatch diff --to <id>` then cherry-pick in correct direction.

## Common Fixes

| Problem | Fix |
|---------|-----|
| Target behind source | `git dispatch apply` |
| Target ahead of source | `cherry-pick --from <id> --to source` then `apply` |
| DIVERGED after conflict | `diff --to <id>` then cherry-pick correct direction |
| Stale target after tid reassignment | `git dispatch apply --force` |
| Cross-target file dependency | `git dispatch verify` to detect |
| Generated file conflict | Add `Dispatch-Source-Keep=true` trailer |
| Target CI fails (missing swagger) | `checkout <N>`, regen, `checkin`, `apply` |
| Insert task between existing | Use decimal: `Dispatch-Target-Id=1.5` |

## Installation

```bash
bash install.sh                # Creates git dispatch alias
git dispatch init --base origin/master --target-pattern "feat/auth-{id}"
```
