# git-dispatch - Design Document

## Intent

git-dispatch bridges the gap between "AI built the whole feature on one branch" and "humans need to review it in focused pieces."

AI generates a complete, working feature on a single branch in minutes. Code review demands small, focused, independently-reviewable PRs. The source branch must stay demo-able. Master moves forward during review.

Unlike ghstack/spr (1 commit = 1 PR), git-dispatch groups commits by `Dispatch-Target-Id` into multi-commit PRs. N commits = 1 PR.

## Stacked PRs without the stack

Every stacked PR tool today (Graphite, ghstack, spr, Phabricator) uses the same model: child branches stacked on parent branches. When a parent PR merges (especially via squash-merge), the child must be rebased, requiring a force-push. This destroys PR review context.

git-dispatch solves this by not stacking at all. Each target branches independently from base, carrying only its own commits. When any PR merges, sibling targets are unaffected. No rebase. No force-push. No cascade. Ever.

"But CI needs the combined code to pass." That's what `checkout <N>` is for. It creates an ephemeral integration branch combining targets 1..N for testing, without permanently stacking branches. You get the CI guarantee of stacked mode without any of the downsides.

## Concepts

| Concept | Definition |
|---------|-----------|
| **base** | master/main. The upstream merge target. |
| **source** | Single branch where all work happens. Source of truth. Read-write. |
| **target** | Branch per Dispatch-Target-Id, containing only its commits. Read-only. Exists for PRs. |
| **checkout** | Ephemeral integration branch combining targets 1..N for testing. |
| **Dispatch-Target-Id** | Mandatory trailer on every commit. Groups commits into targets. |

## Core Invariant

**One number flows through everything.** Dispatch-Target-Id 3 -> trailer on commits -> `feat/auth-3` branch -> PR for target 3.

## Flow Direction

```
base --> source --> targets
                \-> checkout (ephemeral, for testing)
                      \-> checkin (back to source)
```

Source is the single point of truth. Targets never touch base directly. Checkout is ephemeral.

## Commands

```
git dispatch init [--base <branch>] [--target-pattern <pattern>]
git dispatch init --hooks
git dispatch apply [<N>] [--base] [--dry-run] [--resolve|--continue] [--force] [-y|--yes]
git dispatch apply reset <N|all> [--force] [-y|--yes]
git dispatch checkout <N> [--dry-run] [--resolve|--continue]
git dispatch checkout source
git dispatch checkout clear [--force]
git dispatch checkin [<N>] [--dry-run] [--resolve|--continue]
git dispatch push <all|source|N> [--dry-run] [--force]
git dispatch delete <N|all|--prune> [--dry-run] [-y|--yes]
git dispatch status
git dispatch continue
git dispatch abort
git dispatch reset [--force] [-y|--yes]
```

### Flags (unified across propagation commands)

| Flag | Meaning |
|------|---------|
| `--dry-run` | Show plan, make no changes |
| `--resolve`, `--continue` | Leave conflict active for manual resolution |
| `--force` | Override safety checks |
| `--all` | Include merged targets in sync/apply |
| `-y`, `--yes` | Auto-confirm prompts (for scripting) |

### Command Reference

**init** - Configure dispatch on current source branch. Stores config in branch-scoped git config. Installs hooks. Prompts interactively when `--base` or `--target-pattern` are omitted.

**apply** - Create or update target branches from source commits grouped by Dispatch-Target-Id. Idempotent. Detects stale targets via patch-id matching after Dispatch-Target-Id reassignment. With `--base`, merges base into source AND existing targets (no force-push needed).

**apply reset <N|all>** - Delete and regenerate one target (`reset <N>`) or all targets (`reset all`). `reset all` also finds orphaned branches matching the target pattern.

**checkout <N>** - Create integration branch `dispatch-checkout/<source>/<N>` with all source commits having Dispatch-Target-Id <= N or "all". Cherry-picks from source in source order. For testing combined targets.

**checkout source** - Return to source branch from checkout or target.

**checkout clear** - Remove checkout branch and worktree. Warns if unpicked commits exist (use `--force` to discard, or `checkin` first).

**checkin [<N>]** - Cherry-pick new commits from checkout branch back to source. Optional `<N>` to cherry-pick only commits for a specific target. Uses patch-id to identify which commits are new. Honors `Dispatch-Source-Keep` for auto-conflict resolution. Does NOT auto-apply to targets.

**push** - Push branches. Positional arg: `push all`, `push source`, `push 3`.

**delete** - Delete target branches. `delete 3` deletes one target, `delete all` deletes all targets, `delete --prune` auto-detects and deletes targets whose tid no longer exists in source. Unlike `reset`, does not touch dispatch config or hooks.

**status** - Show mode, base, source, all targets with sync state, divergence, stale detection. Shows `merged` for targets whose content is already in base.

**continue** - Resume after conflict resolution.

**abort** - Cancel in-progress operation. Aborts cherry-pick/merge in dispatch worktrees, removes temp worktrees, cleans up checkout branches, returns to source.

**reset** - Delete all targets and config. Prompts for confirmation (skip with `--force` or `--yes`). Preserves hooks when other dispatch sessions are active.

## Dispatch-Target-Id Trailer

Mandatory on every commit. Enforced by commit-msg hook.

```bash
git commit -m "Add feature" --trailer "Dispatch-Target-Id=1"
git commit -m "Shared config" --trailer "Dispatch-Target-Id=all"
git commit -m "Regen files" --trailer "Dispatch-Target-Id=3" --trailer "Dispatch-Source-Keep=true"
```

Rules:
- Numeric (integer or decimal): 1, 2, 1.5, 3.1
- `all`: included in every target during apply (shared infra, CI configs, merge-from-main)
- Determines target branch and stack order (numeric sort)
- Decimals enable mid-stack insertion
- Hook auto-carries from previous commit
- `Dispatch-Source-Keep: true`: auto-resolve conflicts with incoming version (--strategy-option theirs). Works in both apply (source->target) and checkin (checkout->source).

## Config

Config is branch-scoped (per-source-branch) to avoid collisions across worktrees:

| Key | Set by | Description |
|-----|--------|-------------|
| `branch.<source>.dispatchbase` | init | Base branch |
| `branch.<source>.dispatchtargetpattern` | init | Target branch pattern (must include `{id}`) |
| `branch.<source>.dispatchcheckoutbranch` | checkout | Active checkout branch |
| `branch.<target>.dispatchsource` | apply | Source branch reference |

### Worktree Support

When multiple worktrees are detected:
- `extensions.worktreeConfig` is enabled automatically
- `core.hooksPath` is scoped per-worktree (avoids collision)
- `reset` preserves hooks and global config when other dispatch sessions are active

## Safety System

### Layer 1: Conflict detection
Every propagation command fails on conflict by default. No partial state.

### Layer 2: PR detection
Commands that rewrite history check for open PRs on affected branches.

### Layer 3: Dry run
Every command supports `--dry-run`.

### Layer 4: Checkout unpicked commit detection
`checkout clear` warns when checkout has commits not yet cherry-picked to source.

### Layer 5: Abort
`git dispatch abort` cancels any in-progress operation and returns to a clean state.

### Layer 6: Base merge into targets
`apply --base` merges base into existing targets (no recreate, no force-push) preserving PR history.

### Layer 7: Merged target skip
`sync` and `apply` skip targets whose content is already in base (PR was merged). Content-based detection via file diff against base. `--all` overrides to force processing. If a merged PR is reverted, the target is no longer detected as merged and normal processing resumes.

## Lifecycle

```
init --> apply --> push --> [PR merged] --> delete <N> (cleanup)
```

```
init --> apply --> push
     \-> checkout <N> --> checkin --> checkout source --> apply --> push
     \-> abort (from any stuck state)
     \-> reset
```

---

# User Stories

## 1. Setup

```bash
git checkout -b feat/auth master
git dispatch init
# Prompts: Base branch [origin/master]: <enter>
# Prompts: Target pattern (must include {id}): feat/auth-{id}

# Or non-interactive:
git dispatch init --base origin/master --target-pattern "feat/auth-{id}"
```

## 2. Develop

```bash
git commit -m "Add user model"      --trailer "Dispatch-Target-Id=1"
git commit -m "Add auth middleware"  --trailer "Dispatch-Target-Id=2"
git commit -m "Add login endpoint"   --trailer "Dispatch-Target-Id=2"
git commit -m "Update CI config"    --trailer "Dispatch-Target-Id=all"
```

## 3. Create PRs

```bash
git dispatch apply
git dispatch push all
```

## 4. Integration testing

```bash
git dispatch checkout 3           # dispatch-checkout/feat/auth/3
pnpm test                         # test targets 1..3 combined
git dispatch checkout source      # back to source
git dispatch checkout clear       # cleanup
```

## 5. Fix during integration

```bash
git dispatch checkout 3
# fix bug
git commit -m "Fix auth race" --trailer "Dispatch-Target-Id=2"
git dispatch checkin              # picks fix to source
git dispatch checkout source
git dispatch apply                # propagates to target-2
git dispatch push 2
git dispatch checkout clear
```

## 6. Generated files

```bash
# Regen for failing target
git dispatch checkout 3
pnpm openapi
git commit -m "regen swagger" --trailer "Dispatch-Target-Id=3" \
  --trailer "Dispatch-Source-Keep=true"
git dispatch checkin             # Source-Keep auto-resolves
git dispatch checkout source
git dispatch apply
git dispatch push 3

# Or regen on source for all targets
pnpm openapi
git commit -m "regen" --trailer "Dispatch-Target-Id=all" \
  --trailer "Dispatch-Source-Keep=true"
git dispatch apply
```

## 7. Review feedback

```bash
git commit -m "Rename field" --trailer "Dispatch-Target-Id=2"
git dispatch apply
git dispatch push 2
```

## 8. Base moved forward

```bash
# Merges base into source AND existing targets (no force-push)
git dispatch apply --base
git dispatch push all
```

## 9. Iterate

```bash
git commit -m "Fix edge case" --trailer "Dispatch-Target-Id=2"
git dispatch apply
git dispatch push 2
```

## 10. Cleanup

```bash
git dispatch reset --yes          # or --force
```

## 11. Insert task mid-stack

```bash
git commit -m "Add migration" --trailer "Dispatch-Target-Id=1.5"
git dispatch apply    # creates target between 1 and 2
```

## 12. Regenerate all targets

```bash
git dispatch apply reset all --yes
```

## 13. Abort a stuck operation

```bash
git dispatch abort
```

---

# Recipes

### Initial setup
```bash
git checkout -b feat/auth master
git dispatch init     # interactive prompts
# code with Dispatch-Target-Id trailers
git dispatch apply
git dispatch push all
```

### Scripted setup
```bash
git dispatch init --base origin/master --target-pattern "feat/auth-{id}" --yes
```

### Daily iteration
```bash
git commit -m "Fix edge case" --trailer "Dispatch-Target-Id=2"
git dispatch apply
git dispatch push 2
```

### Integration test
```bash
git dispatch checkout 3
pnpm test
git dispatch checkout source
git dispatch checkout clear
```

### Fix + checkin
```bash
git dispatch checkout 3
# fix bug
git commit -m "Fix" --trailer "Dispatch-Target-Id=2"
git dispatch checkin
git dispatch checkout source
git dispatch apply
git dispatch push 2
git dispatch checkout clear
```

### Generated files for failing target
```bash
git dispatch checkout 3
pnpm openapi
git commit -m "regen" --trailer "Dispatch-Target-Id=3" --trailer "Dispatch-Source-Keep=true"
git dispatch checkin
git dispatch checkout source
git dispatch apply
git dispatch push 3
git dispatch checkout clear
```

### Base update
```bash
git dispatch apply --base
git dispatch push all
```

### Reset all targets
```bash
git dispatch apply reset all --yes
```

### After parent PR merged
Nothing. Other targets are unaffected. That's the point.
