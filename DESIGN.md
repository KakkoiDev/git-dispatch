# git-dispatch - Design Document

## Intent

git-dispatch bridges the gap between "AI built the whole feature on one branch" and "humans need to review it in focused pieces."

AI generates a complete, working feature on a single branch in minutes. Code review demands small, focused, independently-reviewable PRs. The source branch must stay demo-able. Master moves forward during review. Rebasing open PRs destroys review context.

git-dispatch solves this with one core invariant: **one number flows through everything**. Target-Id = branch name = PR.

## The stacked PRs force-push problem

Every stacked PR tool today (Graphite, ghstack, spr, Phabricator) uses the same model: child branches are stacked on parent branches. When a parent PR merges (especially via squash-merge), the parent's commit SHAs change. The child branch still carries the old SHAs. The child must be rebased, producing new SHAs, requiring a force-push. This destroys PR review context - comment anchors break, diff history resets, reviewers lose their place.

This is an industry-wide problem. Force-push after squash-merge is treated as an unavoidable cost of stacked workflows.

git-dispatch offers two modes that let the user choose their trade-off:

- **Independent mode** eliminates this problem entirely. Each target branches from base, carrying only its own commits. When a parent PR merges, sibling targets are unaffected. No rebase. No force-push. Ever. The trade-off: CI may fail on targets that depend on parent changes, because the parent's code is not in the target branch. This works well when targets touch different files or modules.

- **Stacked mode** preserves the traditional approach for cases where it is needed. Targets branch from the previous target. CI always passes. But force-push is required when a parent merges. This is the same trade-off as every other stacking tool.

The key insight: most stacking tools force you into stacked mode for all branches. git-dispatch lets you choose per-project. Many real-world features have independent tasks (schema migration, backend endpoint, frontend component) that do not need stacking. For these, independent mode gives you stacked-PR-style review workflow with zero force-push overhead.

## Concepts

| Concept | Definition |
|---------|-----------|
| **base** | master/main. The upstream merge target. |
| **source** | The single branch where all work happens. Source of truth. |
| **target** | A branch created from source, containing only commits for one Target-Id. Exists for review. |
| **Target-Id** | Mandatory numeric trailer on every commit. Determines which target a commit belongs to and the stack order. |

## Modes

| | independent (default) | stacked |
|--|----------------------|---------|
| Target branches from | base | previous target |
| PR base on GitHub | base | previous target |
| CI on target branches | May fail if target depends on parent | Always passes |
| After parent PR merge | Nothing to do | Rebase downstream + force-push |
| Force-push needed | Never (unless source history rewritten) | After every parent merge |
| Best for | Isolated tasks, different files/modules | Sequential dependent work on same code |

Choose at init time. Independent is the default - simpler mental model, no force-push surprises.

## Commands

```
git dispatch init [--base <branch>] [--prefix <str>] [--mode <independent|stacked>]
git dispatch apply [--dry-run] [--resolve] [--force]
git dispatch cherry-pick --from <x> --to <y> [--dry-run] [--resolve] [--force]
git dispatch rebase --from <x> --to <y> [--dry-run] [--resolve] [--force]
git dispatch merge --from <x> --to <y> [--dry-run] [--resolve] [--force]
git dispatch push --from <id|all|source> [--force]
git dispatch status
git dispatch reset [--force]
```

### --from/--to values

`base`, `source`, `<Target-Id>`, `all`

### Flags (unified across all propagation commands)

| Flag | Meaning |
|------|---------|
| `--dry-run` | Show plan, make no changes |
| `--resolve` | Enter conflict resolution mode (conflicts expected, user will handle them) |
| `--force` | Override safety checks (PR rewrite, force-push, skip confirmation) |

### Command reference

**init** - Configure dispatch on the current source branch.
- Stores base, prefix, mode in git config on the source branch
- Installs hooks (Target-Id enforcement on commit-msg, auto-carry on prepare-commit-msg)
- Re-running warns if config already exists and targets would be orphaned

**apply** - Make all targets match source.
- First run: creates all target branches from source commits grouped by Target-Id
- Subsequent runs: cherry-picks new source commits to existing targets, creates missing targets
- Reads mode from config to determine branching strategy (from base or from previous target)
- Idempotent. Safe. No history rewrite (in independent mode).

**cherry-pick** - Move specific commits between source and a target.
- `--from source --to <id>`: cherry-pick new commits for that Target-Id from source to target
- `--from <id> --to source`: cherry-pick target commits back to source
- `--from source --to all`: cherry-pick all pending commits to all targets (same as apply)
- Fails on conflict. Use --resolve to enter conflict resolution.

**rebase** - Rebase one branch onto another.
- `--from base --to source`: rebase source onto updated base
- Rewrites history. Blocked when open PRs detected on downstream targets. Use --force to override.

**merge** - Merge one branch into another.
- `--from base --to source`: merge base into source (safe, no history rewrite)
- No force-push needed. PR reviews preserved.

**push** - Push branches to remote.
- `--from <id>`: push one target
- `--from all`: push all targets
- `--from source`: push source
- `--force`: uses --force-with-lease internally

**status** - Show full state overview.
- Displays mode, base, source, and all targets with sync state and PR info.

**reset** - Delete all dispatch metadata and target branches.
- Asks for confirmation. `--force` skips confirmation.

## Flow direction

All updates flow through source:

```
base --> source --> targets
```

Targets never touch base directly. To update targets with base changes:
1. Merge or rebase base into source (explicit)
2. Apply to propagate downstream

## Safety system

### Layer 1: Conflict detection

Every propagation command fails on conflict by default. No partial state.

```
$ git dispatch cherry-pick --from source --to 3
  Conflict in src/service.ts
  Aborting. No changes made.
  Re-run with --resolve to enter conflict resolution mode.
```

### Layer 2: PR detection

Commands that rewrite history check for open PRs on affected branches.

```
$ git dispatch rebase --from base --to source
  Targets 2, 3 have open PRs. Rebase requires force-push.
  Aborting.

  Safe alternative: git dispatch merge --from base --to source
  Override: --force
```

### Layer 3: Dry run

Every command supports `--dry-run` to preview what would happen.

## Target-Id trailer

Mandatory on every commit. Enforced by commit-msg hook installed during init.

```
git commit -m "Add PurchaseOrder to enum" --trailer "Target-Id=1"
```

Rules:
- Numeric (integer or decimal): 1, 2, 3, 1.5, 3.1
- Determines which target branch the commit belongs to
- Determines stack order by numeric sort: 1 < 1.5 < 2 < 3 < 3.1 < 4
- Decimals enable mid-stack insertion for follow-up PRs
- Hook auto-carries Target-Id from previous commit when absent
- Hook rejects commits without Target-Id (including amends)

Branch naming: `<prefix><Target-Id>` where prefix is set during init.
- prefix `"task-"` + Target-Id `3` = branch `<name>/task-3`
- prefix `""` + Target-Id `3` = branch `<name>/3`

## Config (stored in git config on source branch)

| Key | Set by | Description |
|-----|--------|-------------|
| `dispatch.base` | init | Base branch (master, main, develop) |
| `dispatch.prefix` | init | Target branch prefix (task-, phase-, "") |
| `dispatch.mode` | init | independent or stacked |
| `branch.<name>.dispatchtargets` | apply | Target branches (multi-value) |
| `branch.<name>.dispatchsource` | apply | Source branch reference |

## Lifecycle

```
init --> apply --> (cherry-pick / merge / rebase / apply / push) --> reset
```

---

# User Stories

## 1. Setup

### 1.1 - Initialize dispatch (independent mode)

```
git switch -c user/source/po-transactions master
git dispatch init --base master --prefix "task-" --mode independent
```

Stores config on source branch. Installs hooks. Each target will branch from base.

### 1.2 - Initialize dispatch (stacked mode)

```
git switch -c user/source/po-transactions master
git dispatch init --base master --prefix "task-" --mode stacked
```

Same setup, but targets branch from previous target. CI passes on all targets, but force-push required when parent merges.

### 1.3 - Mode trade-offs

| | independent | stacked |
|--|-------------|---------|
| Branch from | base | previous target |
| PR base on GitHub | base | previous target |
| CI on target branches | May fail if target depends on parent | Always passes |
| After parent PR merge | Nothing to do | Rebase downstream + force-push |
| Force-push needed | Never (unless source history rewritten) | After every parent merge |
| Best for | Isolated tasks, different files/modules | Sequential dependent work on same code |

Independent is the default. Choose stacked when targets build on each other and CI must pass on every target.

### 1.4 - Re-initialize (change config)

```
$ git dispatch init --base develop --prefix "phase-"
  Warning: dispatch already configured on this branch:
    mode:   independent
    base:   master
    prefix: task-
    targets: 3 branches exist

  Overwriting config will orphan existing target branches.
  Proceed? [y/N]
```

### 1.5 - Verify setup

```
$ git dispatch status
  mode:   independent
  base:   master
  source: user/source/po-transactions  (no targets)
```

---

## 2. Build (vibe-code on source)

### 2.1 - Tag every commit with Target-Id (mandatory)

```
git commit -m "Add PurchaseOrder to enum"    --trailer "Target-Id=1"
git commit -m "Create GET endpoint"          --trailer "Target-Id=2"
git commit -m "Add DTOs"                     --trailer "Target-Id=2"
git commit -m "Implement validation"         --trailer "Target-Id=3"
```

Target-Id is mandatory on every commit. The hook rejects commits without it.

### 2.2 - Switch to next target (explicit bump)

```
# Last commit was Target-Id=2, now starting Target-Id=3
git commit -m "Add permission checks" --trailer "Target-Id=3"
```

The hook auto-carries Target-Id from the previous commit when the trailer is absent. Adding it explicitly is recommended to avoid accidentally grouping a commit with the wrong target.

### 2.3 - Commit without Target-Id (rejected)

```
$ git commit -m "Quick fix"
  Target-Id trailer required.
  Add: --trailer "Target-Id=<id>"
  Last used Target-Id: 2
```

### 2.4 - Amend removes Target-Id (rejected)

```
$ git commit --amend -m "Renamed method"
  Target-Id trailer required.
  Add: --trailer "Target-Id=<id>"
```

---

## 3. Create targets (first apply)

### 3.1 - Preview target creation

Independent mode:
```
$ git dispatch apply --dry-run
  mode: independent (targets branch from base)

  create target 1    task-1    (1 commit from source)
  create target 2    task-2    (2 commits from source)
  create target 3    task-3    (1 commit from source)
```

Stacked mode:
```
$ git dispatch apply --dry-run
  mode: stacked (targets branch from previous target)

  create target 1    task-1    base -> task-1         (1 commit)
  create target 2    task-2    task-1 -> task-2       (2 commits)
  create target 3    task-3    task-2 -> task-3       (1 commit)
```

### 3.2 - Create all targets

```
$ git dispatch apply
  mode: independent

  Created task-1 (1 commit)
  Created task-2 (2 commits)
  Created task-3 (1 commit)
```

### 3.3 - Push targets, open PRs manually

```
git dispatch push --from all
# user opens PRs on GitHub
# independent mode: all PRs have base = master
# stacked mode: each PR has base = previous target
```

### 3.4 - Cherry-pick conflict during apply (independent mode)

When a target's commits depend on a parent target's changes, the cherry-pick onto base may fail:

```
$ git dispatch apply
  Created task-1 (1 commit)
  Conflict creating task-2: src/service.ts
    task-2 depends on changes from task-1.

  Options:
    1. Switch to stacked mode: git dispatch init --mode stacked
    2. Resolve: git dispatch apply --resolve
    3. Restructure commits so targets are independent
```

This conflict at creation time tells you the targets are not independent. Consider switching to stacked mode.

### 3.5 - Apply interrupted by local changes while switching target branches

`apply` checks out each target branch to cherry-pick commits. If your working tree has local changes that would be overwritten, Git blocks checkout and `apply` stops mid-run.

Example:
```
$ git dispatch apply
  Created task-8 (2 commits)
  ...
  Created task-14 (1 commit)
  error: Your local changes to the following files would be overwritten by checkout:
          apps/web/src/lib/tax.ts
  Aborting
```

Status will then show only the interrupted target as pending:
```
$ git dispatch status
  ...
  15    user/feat/.../task-15    1 behind source
```

Recovery:
```
git status
git stash -u        # or commit/discard local changes intentionally
git dispatch apply
git dispatch status
```

This is expected behavior: the target is behind because checkout/cherry-pick for that target never happened.

---

## 4. Review feedback (target to source)

### 4.1 - Fix on target, sync back, propagate to all targets

```
git switch <prefix>/task-2
# fix the issue
git commit -m "Fix stale import" --trailer "Target-Id=2"
git dispatch cherry-pick --from 2 --to source
git dispatch apply
git dispatch push --from all
```

Apply propagates the change to any other targets that need it.

### 4.2 - Same thing, surgical approach (only affected target)

```
git switch <prefix>/task-2
# fix the issue
git commit -m "Fix stale import" --trailer "Target-Id=2"
git dispatch cherry-pick --from 2 --to source
git dispatch push --from 2
```

Use this when you know the fix only affects target 2.

### 4.3 - Cherry-pick conflict when syncing back

```
$ git dispatch cherry-pick --from 2 --to source
  Conflict in src/service.ts
  Aborting. No changes made.
  Re-run with --resolve to enter conflict resolution mode.

$ git dispatch cherry-pick --from 2 --to source --resolve
  Conflict in src/service.ts
  Resolve conflicts, then: git cherry-pick --continue
```

---

## 5. New work on source (source to targets)

### 5.1 - Add commits to existing target, use apply

```
git switch <source>
git commit -m "Handle edge case" --trailer "Target-Id=2"
git dispatch apply
git dispatch push --from 2
```

Apply detects the new commit belongs to target 2 and cherry-picks it.

### 5.2 - Add commits to existing target, surgical approach

```
git switch <source>
git commit -m "Handle edge case" --trailer "Target-Id=2"
git dispatch cherry-pick --from source --to 2
git dispatch push --from 2
```

Same result, explicit operation.

### 5.3 - Add new target mid-stack

```
git commit -m "Add migration" --trailer "Target-Id=1.5"
git dispatch apply
git dispatch push --from 1.5
# user opens PR for task-1.5 manually
```

Apply creates the missing target branch. Decimal Target-Id sorts between 1 and 2.

---

## 6. Base moved forward

### 6.1 - Update source, no PRs open (rebase safe)

```
$ git dispatch rebase --from base --to source
  Rebase source (4 commits) onto master.
  History rewrite. No open PRs detected.
  Proceed? [y/N] y

$ git dispatch apply
$ git dispatch push --from all --force
```

### 6.2 - Update source, PRs open (merge only)

```
$ git dispatch rebase --from base --to source
  Rebase rewrites history on source.
  Targets 2, 3 have open PRs. Downstream force-push required.
  Aborting.

  Safe alternative: git dispatch merge --from base --to source

$ git dispatch merge --from base --to source
  Merge master (5 commits) into source.
  No history rewrite. No force-push needed.
  Proceed? [y/N] y

$ git dispatch apply
$ git dispatch push --from all
```

### 6.3 - Independent mode: apply after base update

```
$ git dispatch merge --from base --to source
$ git dispatch apply
  cherry-pick 1 commit to target 2 (from source)
  skip target 1    in sync
  skip target 3    in sync
```

No rebase of targets. No force-push. Targets only receive their own new commits.

### 6.4 - Stacked mode: apply after base update

```
$ git dispatch merge --from base --to source
$ git dispatch apply
  cherry-pick 1 commit to target 2 (from source)
  rebase target 2  (source updated, stacked rebuild)
  rebase target 3  (cascade)
  skip target 1    in sync
  Targets 2, 3 have open PRs. Force-push required.
```

Stacked mode must rebuild the stack when source changes. This is the trade-off.

### 6.5 - Force rebase despite open PRs (edge case)

```
$ git dispatch rebase --from base --to source --force
$ git dispatch apply
$ git dispatch push --from all --force
```

User acknowledges the consequences. PRs may need to be recreated.

---

## 7. PR merged, update downstream

### 7.1 - Independent mode: nothing to do

```
$ git dispatch status
  mode:   independent
  base:   master (updated, includes task-1)
  source: user/source/po  (1 behind base)

  #     Branch    Status         Remote
  1     task-1    merged         PR #51 merged
  2     task-2    in sync        pushed [PR #52]
  3     task-3    in sync        pushed [PR #53]
```

Target 2 and 3 are unaffected. No rebase. No force-push.

### 7.2 - Stacked mode: rebase downstream

```
$ git dispatch status
  mode:   stacked
  base:   master (updated, includes task-1)
  source: user/source/po  (1 behind base)

  #     Branch    Status                    Remote
  1     task-1    merged                    PR #51 merged
  2     task-2    stale (parent merged)     pushed [PR #52]
  3     task-3    stale (parent merged)     pushed [PR #53]

$ git dispatch merge --from base --to source
$ git dispatch apply
  skip target 1      merged
  rebase target 2    onto base (parent merged)
  rebase target 3    onto target 2 (cascade)
  Targets 2, 3 need force-push.

$ git dispatch push --from all --force
```

### 7.3 - Multiple targets merged (stacked mode)

```
$ git dispatch merge --from base --to source
$ git dispatch apply
  skip target 1      merged
  skip target 2      merged
  rebase target 3    onto base (all parents merged)
  Target 3 needs force-push.

$ git dispatch push --from 3 --force
```

### 7.4 - Multiple targets merged (independent mode)

```
$ git dispatch status
  #     Branch    Status         Remote
  1     task-1    merged         PR #51 merged
  2     task-2    merged         PR #52 merged
  3     task-3    in sync        pushed [PR #53]
```

Nothing to do. Target 3 is independent.

---

## 8. Status

### 8.1 - Full overview (independent mode)

```
$ git dispatch status
  mode:   independent
  base:   master
  source: user/source/po  (3 ahead, 0 behind base)

  #     Branch    Status              Remote
  1     task-1    in sync             pushed
  2     task-2    2 behind source     pushed [PR #52]
  3     task-3    in sync             pushed [PR #53]
  1.5   task-1.5  not created         -
```

### 8.2 - Full overview (stacked mode)

```
$ git dispatch status
  mode:   stacked
  base:   master
  source: user/source/po  (3 ahead, 2 behind base)

  #     Branch      Stacked on    Status              Remote
  1     task-1      base          in sync             pushed
  2     task-2      task-1        2 behind source     pushed [PR #52]
  3     task-3      task-2        in sync             pushed [PR #53]
  1.5   task-1.5    -             not created         -
```

---

## 9. Cleanup

### 9.1 - Reset after all PRs merged

```
$ git dispatch reset
  This will delete:
    - dispatch config on source branch
    - target branches: task-1, task-2, task-3
    - hooks from .git/hooks

  Proceed? [y/N] y
  Cleaned up.
```

### 9.2 - Reset and recreate

```
git dispatch reset --force
# edit commits, change Target-Ids
git dispatch apply
```

---

## 10. Edge cases

### 10.1 - Wrong Target-Id on a commit

Option A - Reset and re-apply (simple, nuclear):

```
git commit --amend --trailer "Target-Id=3"
git dispatch reset --force
git dispatch apply
git dispatch push --from all --force
# all open PRs get force-pushed
```

Option B - Cherry-pick directly (surgical, preserves other targets):

```
# move commit to correct target
git switch <prefix>/task-3
git cherry-pick <sha>

# remove from wrong target
git switch <prefix>/task-2
git rebase -i HEAD~N    # drop the wrong commit

# fix source
git switch <source>
git commit --amend --trailer "Target-Id=3"

# push only affected targets
git dispatch push --from 2 --force
git dispatch push --from 3 --force
```

More steps, but only force-pushes affected targets. Other open PRs untouched.

### 10.2 - Apply conflict on existing target

```
$ git dispatch apply
  skip target 1      in sync
  Conflict on target 2: src/dto.ts
    Stopped. Other targets unchanged.
    Resolve: git dispatch cherry-pick --from source --to 2 --resolve
```

### 10.3 - Someone clicked "Update branch" on GitHub

GitHub merges base into a target remotely. Local target is now behind remote.

Option A - Overwrite remote with clean local (preserves PR reviews):

```
$ git dispatch status
  #     Branch    Status              Remote
  2     task-2    remote diverged     [PR #52]

  Target 2 remote has merge commit not in source.

# local target is clean, force-push to overwrite remote
$ git dispatch push --from 2 --force
```

No commit hash changes on local side. Force-push removes the unwanted merge commit from remote.

Option B - If target actually needs base updates, flow through source:

```
$ git dispatch merge --from base --to source
$ git dispatch apply
$ git dispatch push --from 2
```

Always flow updates through source, not directly into targets.

### 10.4 - Switch from independent to stacked (or vice versa)

```
git dispatch reset --force
git dispatch init --mode stacked
git dispatch apply
git dispatch push --from all --force
```

Three existing commands. No special logic needed.

---

## Recipes (quick reference)

### Initial setup

```
git switch -c user/source/feature master
git dispatch init --base master --prefix "task-" --mode independent
# vibe-code with Target-Id trailers
git dispatch apply
git dispatch push --from all
# open PRs on GitHub manually
```

### Daily iteration (source to targets)

```
git switch <source>
git commit -m "Fix edge case" --trailer "Target-Id=2"
git dispatch apply
git dispatch push --from 2
```

### Review feedback (target to source)

```
git switch <prefix>/task-2
git commit -m "Fix review feedback" --trailer "Target-Id=2"
git dispatch cherry-pick --from 2 --to source
git dispatch apply
git dispatch push --from all
```

### Base moved forward (PRs open)

```
git dispatch merge --from base --to source
git dispatch apply
git dispatch push --from all
```

### Base moved forward (no PRs open)

```
git dispatch rebase --from base --to source
git dispatch apply
git dispatch push --from all --force
```

### After parent PR merged (independent mode)

Nothing. Other targets are unaffected.

### After parent PR merged (stacked mode)

```
git dispatch merge --from base --to source
git dispatch apply
git dispatch push --from all --force
```

### Full lifecycle

```
# 1. Setup
git switch -c user/source/feature master
git dispatch init --base master --prefix "task-"

# 2. Build
git commit -m "Schema change" --trailer "Target-Id=1"
git commit -m "Backend endpoint" --trailer "Target-Id=2"
git commit -m "Frontend component" --trailer "Target-Id=3"

# 3. Create targets and push
git dispatch apply
git dispatch push --from all
# open PRs manually

# 4. Iterate (review feedback, new work, base updates)
git dispatch cherry-pick --from 2 --to source    # review fix
git dispatch apply                                 # propagate
git dispatch merge --from base --to source         # base update
git dispatch apply                                 # propagate
git dispatch push --from all                       # ship

# 5. PRs merge one by one
# independent mode: nothing to do between merges
# stacked mode: apply + push --force after each parent merge

# 6. Cleanup
git dispatch reset --force
```
