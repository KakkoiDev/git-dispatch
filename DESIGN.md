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
git dispatch init --base <branch> --target-pattern <pattern>
git dispatch apply [--dry-run] [--resolve] [--force] [--reset <id>]
git dispatch checkout <N>
git dispatch checkout source
git dispatch checkout clear [--force]
git dispatch checkin [--resolve]
git dispatch cherry-pick --from <x> --to <y> [--dry-run] [--resolve]
git dispatch merge --from base --to <source|id|all> [--resolve]
git dispatch push <all|source|N> [--force] [--dry-run]
git dispatch status
git dispatch diff --to <id>
git dispatch verify
git dispatch continue
git dispatch clean [--force]
git dispatch reset [--force]
```

### Flags (unified across propagation commands)

| Flag | Meaning |
|------|---------|
| `--dry-run` | Show plan, make no changes |
| `--resolve` | Leave conflict active for manual resolution |
| `--force` | Override safety checks |

### Command Reference

**init** - Configure dispatch on current source branch. Stores config in git config. Installs hooks.

**apply** - Create or update target branches from source commits grouped by Dispatch-Target-Id. Idempotent. Detects stale targets via patch-id matching after Dispatch-Target-Id reassignment.

**checkout <N>** - Create integration branch `dispatch-checkout/<source>/<N>` with all source commits having Dispatch-Target-Id <= N or "all". Cherry-picks from source in source order. For testing combined targets.

**checkout source** - Return to source branch from checkout or target.

**checkout clear** - Remove checkout branch and worktree. Warns if unpicked commits exist (use `--force` to discard, or `checkin` first).

**checkin** - Cherry-pick new commits from checkout branch back to source. Uses patch-id to identify which commits are new. Honors `Dispatch-Source-Keep` for auto-conflict resolution. Does NOT auto-apply to targets.

**cherry-pick** - Move commits between source and a target bidirectionally.

**push** - Push branches. Positional arg: `push all`, `push source`, `push 3`.

**status** - Show mode, base, source, all targets with sync state, divergence, stale detection.

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

| Key | Set by | Description |
|-----|--------|-------------|
| `dispatch.base` | init | Base branch |
| `dispatch.targetPattern` | init | Target branch pattern (must include `{id}`) |
| `dispatch.checkoutBranch` | checkout | Active checkout branch |
| `branch.<name>.dispatchtargets` | apply | Target branches (multi-value) |
| `branch.<name>.dispatchsource` | apply | Source branch reference |

## Safety System

### Layer 1: Conflict detection
Every propagation command fails on conflict by default. No partial state.

### Layer 2: PR detection
Commands that rewrite history check for open PRs on affected branches.

### Layer 3: Dry run
Every command supports `--dry-run`.

### Layer 4: Checkout unpicked commit detection
`checkout clear` warns when checkout has commits not yet cherry-picked to source.

## Lifecycle

```
init --> apply --> push
     \-> checkout <N> --> checkin --> checkout source --> apply --> push
     \-> cherry-pick / merge --> apply --> push
     \-> reset
```

---

# User Stories

## 1. Setup

```bash
git checkout -b feat/auth master
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
# Safe (no force-push)
git dispatch merge --from base --to source
git dispatch apply
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
git dispatch reset --force
```

## 11. Insert task mid-stack

```bash
git commit -m "Add migration" --trailer "Dispatch-Target-Id=1.5"
git dispatch apply    # creates target between 1 and 2
```

---

# Recipes

### Initial setup
```bash
git checkout -b feat/auth master
git dispatch init --base origin/master --target-pattern "feat/auth-{id}"
# code with Dispatch-Target-Id trailers
git dispatch apply
git dispatch push all
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
git dispatch merge --from base --to source
git dispatch apply
git dispatch push all
```

### After parent PR merged
Nothing. Other targets are unaffected. That's the point.
