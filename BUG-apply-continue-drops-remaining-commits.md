# Bug: `dispatch continue` after conflict resolution drops remaining commits

## Summary

When `git dispatch apply --resolve` encounters a conflict mid-way through a multi-commit cherry-pick sequence for a target, and the user resolves the conflict and runs `git dispatch continue`, the continue command only finishes the conflicting cherry-pick but does NOT process the remaining commits in the queue. The user believes apply completed successfully, but the target branch is missing commits.

## Real-world scenario

Source branch has 34 commits. 1 new commit (`09152a78c3`, tid=9) was added after previous apply.

1. Run `git dispatch apply`
2. Apply starts processing target-9 (2 pending commits for this target)
3. Commit 1/2 (`212dc37ee8`, tid=9) conflicts on `hooks.ts` - same import conflict that happens every time this commit is cherry-picked onto origin/master base
4. Apply aborts. Re-run with `--resolve`
5. Conflict left active in dispatch worktree at `/tmp/git-dispatch-wt.XXX`
6. User resolves conflict: `git -C $WT checkout --theirs hooks.ts && git -C $WT add hooks.ts && git -C $WT cherry-pick --continue`
7. User runs `git dispatch continue`
8. Output: `Operation complete on task-9. Cleaning up worktree`
9. But commit 2/2 (`09152a78c3` fix: restore suppressHeaderContent guard) was never applied

The user had to discover the missing commit via `git log` and manually run `git dispatch cherry-pick --from source --to 9` to get the commit onto the target.

## Root cause (hypothesis)

`dispatch continue` likely only completes the in-progress cherry-pick operation in the worktree. It does not check if there were additional commits queued after the conflicting one. Once the cherry-pick finishes, it cleans up the worktree and reports success without processing the rest of the queue.

## Expected behavior

After conflict resolution + `dispatch continue`, all remaining commits for the target should be cherry-picked (not just the conflicting one). If there are more targets to process, those should continue too.

## Workaround

After `dispatch continue`, check the target branch log to verify all expected commits landed. If commits are missing, use:

```bash
git dispatch cherry-pick --from source --to <id>
```

## Related issue: persistent "stale (3 commits reassigned)" warning

### Symptom

After a complete fresh init + apply cycle (no prior state), `git dispatch status` shows every target as `stale (3 commit(s) reassigned)`. Running `apply --force` or `apply --reset <id> --force` does not clear the warning.

### Context

The source branch has 3 commits with `Dispatch-Target-Id: all`. These are openapi/generated file commits that should be included in every target.

During apply, these commits ARE correctly cherry-picked to every target. But the status command permanently marks all targets as stale with "3 commits reassigned".

### Hypothesis

The status tracking logic may be treating `all` commits as belonging to a literal "all" target (the status even shows `all   task-all   not created`). When these commits appear on other targets, they're counted as "reassigned" from the non-existent task-all.

### Impact

- Status is always red/stale even when content is correct
- `apply --force` triggers unnecessary full rebuilds
- Full rebuilds re-encounter the same hooks.ts conflict every time (see above), creating a cycle of manual conflict resolution
- User loses trust in the status command

## Related issue: `apply --force` processes ALL targets, not just the one being reset

### Symptom

When running `git dispatch apply --reset 11 --force`, the command deletes task-11 and starts rebuilding. But it also tries to rebuild task-9 (which had the hooks.ts conflict), causing the entire operation to abort.

### Expected behavior

`apply --reset <id>` should only rebuild the specified target, not process other targets that happen to be stale.

## Reproduction steps (for the continue bug)

```bash
# Setup: source has commits with Dispatch-Target-Id trailers
# One commit (tid=9) modifies hooks.ts which conflicts with origin/master

# 1. Add a new commit on source
git commit -m "fix something" --trailer "Dispatch-Target-Id=9"

# 2. Apply
git dispatch apply
# -> Conflict on hooks.ts for the earlier tid=9 commit

# 3. Resolve with --resolve
git dispatch apply --resolve
# -> Worktree left at /tmp/git-dispatch-wt.XXX

# 4. Resolve conflict
git -C /tmp/git-dispatch-wt.XXX checkout --theirs hooks.ts
git -C /tmp/git-dispatch-wt.XXX add hooks.ts
git -C /tmp/git-dispatch-wt.XXX cherry-pick --continue --no-edit

# 5. Continue
git dispatch continue
# -> "Operation complete on task-9"

# 6. Check
git log --oneline task-9 -3
# -> The new fix commit is MISSING
```

## Environment

- git-dispatch version: latest (2026-03-17)
- Mode: independent
- 8 target branches (task-8 through task-15)
- 34 source commits, 3 with Dispatch-Target-Id: all
