# Bug: apply reset N cascades to other targets

## Summary

`git dispatch apply reset 8 --force` successfully regenerates target 8, then automatically attempts to apply other targets (9, etc.) and hits a conflict. The command should only touch the specified target.

## Reproduction

```bash
git dispatch status
# 8     ...task-8     1 untracked
# 9     ...task-9     7 behind source, 7 ahead (DIVERGED)
# 11-15 in sync

git dispatch apply reset 8 --force
# Created cyril/feat/purchase-order-transaction-registration/task-8 (9 commits)
#
# CONFLICT on commit 1/8: 212dc37ee8 ... (this is target 9's commit)
# Aborted.
```

Target 8 was regenerated correctly. But dispatch continued to process target 9 unprompted and hit a conflict.

## Expected behavior

`apply reset 8` should:
1. Delete target 8
2. Recreate target 8 from source commits
3. Stop

It should NOT process any other target unless explicitly requested (`apply reset all`).

## Actual behavior

After regenerating target 8, dispatch runs a full `apply` cycle on all remaining targets. This triggers conflicts on unrelated targets and aborts the entire operation.

## Impact

- User asked to fix one target, got an unrelated conflict error
- Confusing: the error appears to be about target 8 but is actually about target 9
- If target 9 has a known-unfixable conflict, there's no way to cleanly reset just target 8 without also hitting target 9's conflict

## Observed in

Session 2026-03-18, worktree `cyril/poc/purchase-order-transaction-registration`.
