# BUG: checkout conflicts after sync when targets have stale cherry-picks

## Summary

After `sync` merges base into source and targets, `checkout <N>` can still produce merge conflicts between targets. This happens when a target was rebuilt via `apply reset` with auto-conflict-resolution (`--theirs`), causing the target's file content to diverge from the base+other-targets version of the same file.

## Observed behavior

1. `sync` merges origin/master into source (resolving conflicts manually)
2. `sync` merges origin/master into each target independently
3. `checkout 15` merges all targets into one integration branch
4. Target 15 conflicts with other targets on `transactions.integration.spec.ts`

The conflict occurs because:
- Master introduced a `createApiHarness` refactor to the test file
- Target 15 had a commit adding PO permission tests using the OLD API pattern
- `apply reset 15` cherry-picked that commit onto the new master base
- The cherry-pick conflicted, and auto-resolve took `--theirs` (the source commit's version)
- This produced a file with BOTH the old pattern (from cherry-pick) AND the new pattern (from master base), creating **duplicate test blocks**
- When checkout merges target 15 with other targets (which have the clean master version), the duplicates/old-pattern code conflicts

## Root cause

`apply reset` auto-resolves cherry-pick conflicts with `--theirs` (the source commit version) even for commits without `Dispatch-Source-Keep`. This is triggered by the `--force` flag on stale targets.

The `--theirs` resolution is correct for generated files (Source-Keep), but for hand-written code it can:
1. Overwrite master's refactored code with the old pattern from the source commit
2. Create duplicate blocks when the cherry-pick partially applies and partially conflicts
3. Produce lint errors (unused variables) from the old code pattern

## Reproduction

```bash
# Setup: source has commits for target 15 written BEFORE a master refactor
# Master then refactors the same file (e.g., introduces createApiHarness helper)

git dispatch sync                    # merge master into source + targets
git dispatch apply reset 15 --yes    # rebuild target 15 from scratch
# Auto-resolves conflict with --theirs, creating duplicates

git dispatch checkout 15             # CONFLICT on the duplicated file
```

## Current workaround

After `apply reset` creates a bad target, fix it by committing directly on the target branch:

```bash
# 1. Checkout the target branch directly (not via dispatch)
git checkout cyril/feat/.../task-15

# 2. Fix the file (remove duplicates, fix lint)
# ... edit the file ...

# 3. Commit as a target-only commit
git commit -m "fix: remove duplicate test blocks from auto-resolve"

# 4. Return to source
git checkout <source-branch>

# 5. Checkout now works cleanly
git dispatch checkout 15
```

Target-only commits are detected and replayed on future `apply reset` runs. However, the next `apply reset` will recreate the duplicates, then replay the fix - a fragile cycle.

**Important:** Do NOT try to `checkin` this fix. The checkout->source cherry-pick will conflict because source has a different version of the file (source has the clean merged version, target has the old-pattern version). Source-Keep on the checkin commit does not help because `--theirs` during checkin means the checkout version wins, which would overwrite source's correct code with the old pattern.

## Why sync alone does not prevent this

`sync` merges base into each target independently. This resolves base-vs-target conflicts within each target. But it does NOT address:
- Cross-target conflicts (where two targets touch the same file differently)
- Stale cherry-picks that were auto-resolved badly before sync ran

The conflict surfaces during `checkout` because that's when targets are merged together for the first time.

## Proposed fix

### Option A: Prompt on conflict during apply reset (recommended)

When `apply reset` encounters a cherry-pick conflict and the commit does NOT have `Dispatch-Source-Keep`, instead of auto-resolving with `--theirs`:
1. Pause and show the conflict
2. Let the user resolve manually (like `--resolve` does for other commands)
3. Only auto-resolve with `--theirs` when `Dispatch-Source-Keep=true`

This would prevent bad auto-merges for hand-written code while preserving the fast path for generated files.

### Option B: Detect duplicates after apply reset

After rebuilding a target, run a post-check:
1. Scan for duplicate `it(` / `describe(` / `test(` blocks (for test files)
2. Scan for repeated function definitions
3. Flag if the file grew significantly more than expected from the cherry-picked diff
4. Warn the user and suggest manual review

### Option C: Use merge instead of cherry-pick for apply reset

Instead of cherry-picking source commits one by one (which loses context), merge the source branch (filtered to target-id commits) into a fresh target branch from base. This preserves the three-way merge context and avoids the `--theirs` problem.

This aligns with the existing `proposal-merge-based-checkout.md` approach.

## Related files

- `proposal-merge-based-checkout.md` - related merge-based approach for checkout
- `task-cherry-pick-conflict-handling.md` - existing cherry-pick conflict handling design
- `user-story-auto-resolve-cherry-pick.md` - auto-resolve behavior spec
- `pitfall-cherry-pick-divergence-after-conflict.md` - related divergence pitfall

## Session context

Observed during the purchase-order-transaction-registration project. Target 15 had PO permission test commits written before master's `createApiHarness` refactor. After sync + apply reset 15, checkout 15 failed with 4 conflicts in `transactions.integration.spec.ts`. Fixed by committing dedup directly on the target branch. The target-only commit is replayed on future resets but the underlying issue recurs each time.
