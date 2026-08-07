# Bug: `dispatch checkout` + `continue` drops remaining commits (same as apply bug)

## Summary

`git dispatch checkout <N>` creates an integration branch by cherry-picking all source commits (targets 1..N + all) onto base. When a conflict occurs mid-sequence and the user resolves it and runs `git dispatch continue`, only the conflicting cherry-pick completes. The remaining 22 of 24 commits are silently dropped. The checkout branch is left in an incomplete state with no error.

This is the same class of bug as the `apply --resolve` + `continue` issue documented in `BUG-apply-continue-drops-remaining-commits.md`, but affecting the `checkout` command.

## Exact reproduction (2026-03-17)

```
$ git dispatch checkout 9 --resolve

Creating checkout branch: dispatch-checkout/.../9 (24 commits)
[commit 1/24] chore(openapi): add differFromSource to TransactionStatus enum  -> OK

Conflict on commit 2/24: 212dc37ee8 feat(web): add transaction registration
  menu and dialog to PO detail hooks
Conflicted files:
  apps/web/src/components/templates/PurchaseOrderDetail/hooks.ts

Resolve conflicts, then run: git -C /tmp/git-dispatch-wt.5CQkoc cherry-pick --continue
Remaining commits to cherry-pick after resolution:
  [22 commits listed]

Worktree left at: /tmp/git-dispatch-wt.5CQkoc
```

User resolves:
```
$ WT="/tmp/git-dispatch-wt.5CQkoc"
$ git -C "$WT" checkout --theirs hooks.ts
$ git -C "$WT" add hooks.ts
$ git -C "$WT" cherry-pick --continue --no-edit
  -> [commit 2/24 applied successfully]

$ git dispatch continue
  -> "Operation complete on dispatch-checkout/.../9. Cleaning up worktree"
  -> "Remaining commits may not have been applied."
```

Result:
```
$ git log --oneline dispatch-checkout/.../9 -5
1801d1dd66 feat(web): add transaction registration menu and dialog to PO detail hooks
07368f0b30 chore(openapi): add differFromSource to TransactionStatus enum
0fcf5aa038 [E2E-FIX-4819] ...  <- this is from base, not from source
```

Only 2 of 24 source commits landed. The checkout branch is useless for integration testing.

## Output clue

The `continue` command itself prints a warning:

```
Remaining commits may not have been applied.
  Run: git dispatch apply  (to process any remaining commits)
```

This confirms the tool knows it didn't finish but still cleans up the worktree. Running `git dispatch apply` afterward does NOT fix the checkout branch - apply operates on target branches, not checkout branches.

## Impact

- `dispatch checkout` is unusable when ANY source commit conflicts with base
- In this project, one commit (`212dc37ee8`) ALWAYS conflicts with origin/master on `hooks.ts` due to a missing newline in the base version
- This makes the entire checkout/checkin workflow broken for this project
- The user was forced to bypass dispatch entirely: checkout target-9 directly, fix lint, cherry-pick back to source manually

## Expected behavior

After conflict resolution + `git dispatch continue`:
1. Resume cherry-picking the remaining 22 commits
2. If another conflict occurs, pause again for resolution
3. Only clean up the worktree after ALL commits are processed
4. Switch to the completed checkout branch

## Root cause (hypothesis)

`dispatch continue` runs `cherry-pick --continue` in the worktree, which completes the single conflicting commit. Then it copies the result back to the checkout branch and cleans up the worktree. It does NOT check if there were more commits queued for cherry-picking.

The "remaining commits" list was printed during `--resolve` but is not persisted anywhere for `continue` to resume from. The queue is lost when the worktree is cleaned up.

## Suggested fix

When `--resolve` creates the worktree, persist the remaining commit list (e.g., in a `.git-dispatch-queue` file in the worktree or in git config). When `continue` runs:

1. Complete the in-progress cherry-pick
2. Read the remaining queue
3. Cherry-pick each remaining commit
4. If another conflict occurs, pause again (update the queue file)
5. Only clean up when the queue is empty

## Workaround

Skip `dispatch checkout/checkin` entirely. Work on the target branch directly:

```bash
# Instead of: git dispatch checkout 9
git checkout cyril/feat/purchase-order-transaction-registration/task-9

# Make fixes, commit with trailer
git commit -m "fix: lint" --trailer "Dispatch-Target-Id=9"

# Instead of: git dispatch checkin
git checkout <source-branch>
git cherry-pick <fix-commit-sha>
```

## Environment

- git-dispatch version: latest (2026-03-17)
- Mode: independent
- Source: 34 commits, 3 with Dispatch-Target-Id: all
- Checkout target: 9 (24 total commits to cherry-pick: 8+9+all onto base)
- Conflict: hooks.ts import section (reproducible every time)
