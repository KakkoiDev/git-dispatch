# BUG: checkin replays all checkout commits, not just new ones

## Summary

`git dispatch checkin` after `checkout <N>` tries to cherry-pick ALL commits from the checkout branch back to source, including the original target commits that source already has. This causes massive conflicts and is unusable.

## Reproduction

```bash
# Target 1 has 15 commits. Create checkout branch.
git dispatch checkout 1

# Make a small fix (1 new commit)
git commit -m "fix: restore missing imports" --trailer "Dispatch-Target-Id=1"

# Try to bring just the fix back to source
git dispatch checkin
# EXPECTED: cherry-picks only the 1 new commit
# ACTUAL: tries to cherry-pick 4 commits (target merge + original commits + fix)
#         conflicts immediately on commit 1/4
```

## Root cause

`checkin` identifies "new" commits by comparing the checkout branch against the source using patch-id matching. But after `checkout <N>`, the checkout branch was created by merging target branches (which were created by cherry-picking source commits onto master). These cherry-picked commits have different patch-ids than the source commits because:

1. Source commits were authored against old master context
2. Target commits were cherry-picked onto current master (different context = different patch-id)
3. Checkout merges the target branch (fast-forward or merge)

So `checkin` sees the target's cherry-picked commits as "new" (unmatched patch-ids) and tries to replay them back to source, where they conflict with the originals.

## Expected behavior

`checkin` should only cherry-pick commits that were authored ON the checkout branch (after checkout was created). It should skip:
- Commits that existed on the target before checkout
- Merge commits from the checkout creation process
- Commits traceable to source by subject line (even if patch-id differs)

## Current workaround

Don't use `checkin`. Instead, commit directly on the target branch and push:

```bash
git checkout cyril/dispatch/bulk-transaction-registration/1
# make fix
git commit -m "fix: ..."
git push origin cyril/dispatch/bulk-transaction-registration/1
```

This bypasses source entirely. The fix lives only on the target. To bring it to source, manually cherry-pick by SHA:

```bash
git checkout source-branch
git cherry-pick <commit-sha-from-target>
```

## Suggested fix

### Option A: Track checkout creation point

When `checkout <N>` creates the branch, store the HEAD SHA in config:

```bash
branch.<checkout>.dispatchcheckoutbase = <SHA>
```

Then `checkin` only cherry-picks commits after that SHA:

```bash
git log --no-merges <checkout-base>..<checkout-branch>
```

### Option B: Use commit timestamp

Only cherry-pick commits authored AFTER the checkout branch was created. Fragile but simple.

### Option C: Subject-line deduplication

Before cherry-picking, check if the source already has a commit with the same subject line. Skip if found. This handles the patch-id mismatch from cherry-pick context differences.

### Recommendation

Option A is the most reliable. The checkout base SHA is known at creation time and uniquely identifies the boundary between "existing target commits" and "new work on checkout."

## Impact

- `checkin` is unusable after `checkout <N>` when targets have cosmetic divergence from source
- Users are forced to commit directly on target branches, bypassing the source-as-truth model
- The documented workflow (`checkout` -> fix -> `checkin` -> `apply`) is broken for this case

## Related

- `BUG-false-diverged-after-fresh-apply.md` - cosmetic divergence causes patch-id mismatch
- `proposal-sync-command.md` - sync reduces but doesn't eliminate cosmetic divergence
- `pitfall-cherry-pick-divergence-after-conflict.md` - same root cause (cherry-pick produces different patches)
