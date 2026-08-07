# BUG: False DIVERGED after fresh `apply` when source is behind base

## Summary

`git dispatch status` reports `(DIVERGED)` on all targets immediately after a successful `git dispatch apply reset all`, even though targets were just created. The divergence is a false positive caused by base drift (source branch behind `origin/master`).

## Reproduction

```bash
# Source branch is 458 commits behind origin/master
git log --oneline HEAD..origin/master | wc -l  # 458

# Fresh apply - all targets created successfully
git dispatch apply reset all --force -y
# Summary: 3 created, 0 updated, 0 in sync

# Status shows DIVERGED on all targets
git dispatch status
# 1  cyril/dispatch/bulk-transaction-registration/1  2 behind source, 2 ahead (DIVERGED)
# 2  cyril/dispatch/bulk-transaction-registration/2  1 behind source, 2 ahead (DIVERGED)
# 3  cyril/dispatch/bulk-transaction-registration/3  1 behind source, 1 ahead (DIVERGED)
```

## What is actually happening

The DIVERGED flag is misleading. The targets are correct. Here's what happened:

1. The source branch forked from master 458 commits ago
2. `apply` cherry-picks source commits onto **current** `origin/master`
3. Some cherry-picks hit conflicts on files that were modified on both master and source (e.g. `transactions.service.ts` was modified by another team's invoice feature on master, and by our PO bulk feature on source)
4. Auto-resolve with `--theirs` produces the correct merge result on the target

The targets have the right content: `current master + feature changes`. But `dispatch status` compares the target's file content against the source branch's file content. These differ because:

- **Source** has: `old master (458 commits behind) + ALL feature changes (DTI=1,2,3)`
- **Target 1** has: `current master + DTI=1 changes only`

The status check sees different bytes and flags `(DIVERGED)`, even though the target is exactly what `apply` should produce.

## What files are affected

Only files modified on **both** master and the source branch trigger this:
- `transactions.service.ts` - another team added `createManyFromInvoices()` on master; our branch added `bulkCreateFromPurchaseOrders()`
- `transactions.controller.ts` - same (new endpoint added on master)
- `purchase-orders.service.ts` - modified on master and source
- Generated files (`openapi.gen.d.ts`, `swagger.json`) - always diverge when source is behind because they contain the full API schema

New files created exclusively by the feature (DTOs, modal components, test file) are fine - they show as OK.

## Specific example

`transactions.service.ts` on target 1 includes a `createManyFromInvoices()` method added to master by another team. Source branch doesn't have it (hasn't been rebased). The diff between source and target:

```diff
-import { TransactionStatus } from '@/lib/constant'
+import { OrderStatusEnum, TransactionStatus } from '@/lib/constant'
```

This is correct on the target (master has this import). But status flags it as diverged because source doesn't match.

## How to fix the immediate issue

Run `apply --base` to merge master into source and update targets:

```bash
# Step 1: Merge base into source (and update existing targets)
git dispatch apply --base

# Step 2: Verify - status should now show in sync
git dispatch status
```

This eliminates the base drift. After merging master into source, both source and targets share the same base code, and file content for each target's own files will match.

If `apply --base` hits conflicts:
```bash
# Resolve conflicts, then continue
git dispatch apply --base --resolve
# fix conflicts manually
git dispatch continue
```

To prevent this issue entirely, run `apply --base` periodically (or before every `apply`) to keep source up to date with master.

## Expected behavior (the real bug in dispatch)

After a fresh `apply` (or `apply reset all`), status should show targets as "in sync" or at most "(cosmetic)". The DIVERGED flag should only appear when a target was modified independently of the apply flow (e.g. someone pushed directly to a target branch).

The core issue is that `dispatch status` divergence check compares source file content vs target file content directly, without accounting for the base difference. It should compare target content against "what apply would produce given current base + source DTI commits" - not against source itself.

## Suggested fix for dispatch

**Option A**: Re-run the cherry-pick simulation during status (expensive but accurate). Compare target tree against what `apply --dry-run` would produce.

**Option B**: Only flag DIVERGED when the target has commits not traceable to a source commit (by message or patch-id). The "behind/ahead" counts already use patch-id matching. If all "ahead" commits on the target are auto-resolved versions of source commits, mark as "(cosmetic)" not "(DIVERGED)".

**Option C**: Track applied commits. After `apply`, store a mapping of `source-SHA -> target-SHA` in git config or a ref. Status checks this mapping instead of comparing file content.

**Option D**: Warn in `apply` output when source is behind base. Something like: "Warning: source is 458 commits behind base. Run `git dispatch apply --base` first for clean status."

## Impact

- **User confusion**: Fresh apply looks broken (all DIVERGED) when it's actually fine
- **Trust erosion**: Users learn to ignore DIVERGED, which means they'll miss real divergence
- **Extra steps**: Forces `apply --base` before every `apply` as a workaround

## Related

- `pitfall-cherry-pick-divergence-after-conflict.md` - similar divergence issue but after manual conflict resolution
- `proposal-merge-base-into-targets.md` - alternative apply strategy that would avoid this
