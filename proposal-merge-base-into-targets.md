# Proposal: Merge base into targets instead of recreating them

## Problem

When base (master) advances after targets are created, `dispatch apply --base` recreates targets by cherry-picking source commits onto the new base. This causes two issues:

1. **Silent data loss**: `--theirs` auto-resolution during cherry-pick can overwrite master's changes with the source branch's older code. The target ends up missing master features that were added since the source branch diverged.

2. **Force push required**: Recreated targets have entirely new commit SHAs. Pushing them to remote requires `--force`, which is destructive and breaks open PRs.

## Root cause

Source commits are patches authored against old master. Cherry-picking them onto new master produces different (and potentially incorrect) patches when the same files were modified on both sides.

Example observed: master refactored `handleOrderingClick` into `handleOrderingCommon` (extracted shared logic for resubmit/reissue). Source commit `212dc37ee8` replaces `handleOrderingClick` with a transaction-menu version. Cherry-pick with `--theirs` silently reverts master's refactor, losing the resubmit/reissue feature entirely.

## Proposed solution

When base updates, **merge master into each existing target branch** instead of deleting and recreating them.

### Current behavior (broken)

```
dispatch apply --base:
  1. merge master into source (user resolves conflicts)
  2. delete each target branch
  3. recreate each target by cherry-picking source commits onto new master
  -> wrong content, force push needed
```

### Proposed behavior

```
dispatch apply --base:
  1. merge master into source (user resolves conflicts)
  2. for each EXISTING target: merge master into target branch
  3. for each NEW target (not yet created): cherry-pick from scratch as today
  4. apply any new source commits to targets
  -> correct content, no force push
```

### Why this works

- **No force push**: merge is additive (forward-only), preserving existing target history
- **Correct content**: `git merge master` brings in all master changes properly, with conflict resolution in full context (both sides visible)
- **Conflict resolution is simpler**: most target merges will be clean if the source merge was resolved correctly, since the target's local changes are a subset of source's changes
- **New targets unaffected**: targets that don't exist yet are created from scratch by cherry-pick (same as today)

### Tradeoff

Target branches get merge commits, making PR history slightly less clean. But correctness and no-force-push outweigh aesthetics.

## Observed in

Worktree `cyril/poc/purchase-order-transaction-registration`. After `dispatch apply --base`:

- Target 9 was flagged DIVERGED (7 behind, 7 ahead)
- Target 8 had 1 untracked commit
- The `--theirs` auto-resolution had silently replaced master's `handleOrderingCommon` refactor with the source branch's old inline `handleOrderingClick`
- 6 other targets (11, 12, 13, 13.1, 14, 15) applied cleanly because they don't touch `hooks.ts`

## Companion proposal

See `proposal-merge-based-checkout.md`. Together these two changes eliminate all base-incompatibility issues:
- `apply --base` merges master into targets (this proposal) - keeps target content correct
- `checkout N` merges target branches instead of cherry-picking source commits - eliminates checkout conflicts

## Implementation notes

Pseudocode for the merge-into-targets step:

```bash
for target in existing_targets; do
  git checkout "$target"
  if git merge origin/master --no-edit; then
    # clean merge, done
  else
    # conflict - pause for user resolution (same UX as source merge)
    echo "Conflict merging master into $target"
    echo "Resolve and run: git dispatch apply --base --continue"
    exit 1
  fi
done
git checkout "$source_branch"
```

For targets where the merge from master is clean (most cases), this adds zero user friction compared to today.
