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
| `git dispatch init [--base <branch>] [--target-pattern <pattern>]` | Configure dispatch (prompts interactively when args omitted) |
| `git dispatch init --hooks` | Install hooks only |
| `git dispatch apply [<N>] [--base] [--dry-run] [--resolve] [--force] [--yes]` | Create/update target branches from source |
| `git dispatch apply reset <N\|all> [--yes]` | Regenerate one or all targets from scratch |
| `git dispatch checkout <N> [--dry-run] [--resolve\|--continue]` | Create integration branch with targets 1..N + "all" commits |
| `git dispatch checkout source` | Return to source branch |
| `git dispatch checkout clear [--force]` | Remove checkout branch (warns on unpicked commits) |
| `git dispatch checkin [<N>] [--dry-run] [--resolve\|--continue]` | Cherry-pick checkout commits back to source |
| `git dispatch push <all\|source\|N> [--dry-run] [--force]` | Push branches to origin |
| `git dispatch status` | Show mode, base, targets, sync state, divergence |
| `git dispatch continue` | Resume after conflict resolution |
| `git dispatch abort` | Cancel in-progress operation, clean up, return to source |
| `git dispatch reset [--yes]` | Delete target branches and config |

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
# or just: git dispatch init  (prompts interactively)
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
git dispatch apply --base        # merges base into source AND existing targets
git dispatch push all
```

### Abort a stuck operation
```bash
git dispatch abort               # cleans up conflicts, worktrees, returns to source
```

## Apply Options

| Want | Command |
|------|---------|
| Create new targets + update all | `git dispatch apply` |
| Update one existing target | `git dispatch apply <N>` |
| Regenerate one target from scratch | `git dispatch apply reset <N>` |
| Regenerate all targets from scratch | `git dispatch apply reset all` |
| Merge base into source and targets | `git dispatch apply --base` |

## Config

Config is branch-scoped (per-source-branch) to support multiple worktrees:

| Key | Description |
|-----|-------------|
| `branch.<source>.dispatchbase` | Base branch (e.g., origin/master) |
| `branch.<source>.dispatchtargetpattern` | Target branch pattern (must include `{id}`) |
| `branch.<source>.dispatchcheckoutbranch` | Active checkout branch |
| `branch.<target>.dispatchsource` | Source branch reference |

## Flags

| Flag | Meaning |
|------|---------|
| `--dry-run` | Show plan, make no changes |
| `--resolve`, `--continue` | Leave conflict active for manual resolution |
| `--yes` | Skip confirmation prompts (required for scripting/CI) |
| `--force` | Safety override: `apply` rebuilds stale, `push` force-pushes, `checkout clear` discards |

## Conflict Handling

All propagation commands support `--resolve` (or `--continue`) to leave conflicts active for manual resolution.

- **Default**: aborts cleanly, prints re-run hint
- **`--resolve`/`--continue`**: leaves conflict active in worktree, shows remaining work
- **`git dispatch abort`**: cancel operation, clean up, return to source
- **Dispatch-Source-Keep**: auto-resolves with `--strategy-option theirs`

## Divergence Detection

`status` tags targets:
- `(DIVERGED)` - target has commits not traceable to source (e.g., manual push to target)
- `(cosmetic)` - same logical changes, different SHAs or base drift (safe to ignore)

Base drift (source behind master) produces cosmetic differences, not false DIVERGED. The check uses commit-message traceability: if every target commit subject matches a source commit, the difference is from base drift or auto-conflict resolution.

## apply vs apply reset

`apply <N>` = incremental (new commits only). Push stays fast-forward.
`apply reset <N>` = recreate from scratch. Requires `push --force` (history rewritten).

**Force-push trap**: source behind master -> `apply` creates targets with different SHAs (cosmetic) -> later `apply <N>` can't match SHAs, re-applies everything, conflicts -> forced into `apply reset <N>` -> needs `push --force`.

**Prevention**: always `apply --base` before `apply` when source is behind master. This merges master into source and targets, keeping SHAs stable so incremental `apply <N>` works and push stays fast-forward.

## Common Fixes

| Problem | Fix |
|---------|-----|
| Target behind source | `git dispatch apply` |
| Target ahead of source | `checkout`, `checkin`, then `apply` |
| `apply <N>` conflicts on diverged target | `git dispatch apply reset <N>` |
| DIVERGED (real) | `checkout`, reconcile, `checkin`, `apply` |
| Source behind base (cosmetic) | `git dispatch apply --base` |
| Stale target after tid reassignment | `git dispatch apply --force` |
| Generated file conflict | Add `Dispatch-Source-Keep=true` trailer |
| Target CI fails (missing swagger) | `checkout <N>`, regen, `checkin`, `apply` |
| Insert task between existing | Use decimal: `Dispatch-Target-Id=1.5` |
| All targets need regeneration | `git dispatch apply reset all --yes` |
| Stuck operation/conflict | `git dispatch abort` |

## Installation

```bash
bash install.sh                # Creates git dispatch alias
git dispatch init              # Interactive setup
```
