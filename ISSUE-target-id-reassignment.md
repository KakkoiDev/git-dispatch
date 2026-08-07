# Issue: Target-Id reassignment leaves stale commits on targets

## User story

As a developer using git-dispatch with independent target branches, when I reassign a commit from one Target-Id to another (e.g., via interactive rebase to amend the trailer), I expect `git dispatch apply` to detect the mismatch and rebuild the affected targets so that each target branch only contains commits matching its Target-Id.

## Real-world scenario

Working on a multi-task feature branch for purchase order transaction registration:

1. Developer adds `differFromSource` translation - initially tagged as `Target-Id: 8`
2. `git dispatch apply` cherry-picks it onto the task-8 target branch
3. PR reviewer (Claudio) flags it: "this doesn't belong to task-8, the enum value is introduced in task-15"
4. Developer amends the commit trailer from `Target-Id: 8` to `Target-Id: 15` via interactive rebase
5. `git dispatch apply` correctly cherry-picks the commit to task-15, but **does not remove the stale copy from task-8**
6. Developer pushes task-8 - reviewer sees the same unwanted commit again
7. Developer has no idea why it keeps coming back after every rebase/apply cycle

The fix required manually deleting the task-8 branch (and its worktree), then rebuilding with `dispatch apply`. This was not obvious and took debugging time.

## Problem

When a commit's `Target-Id` trailer is changed on the source branch, `git dispatch apply` does not remove the stale cherry-picked commit from the old target branch.

### Steps to reproduce

1. Commit with `Target-Id: 8` on source
2. `git dispatch apply` - commit is cherry-picked to task-8
3. Amend the commit on source (via interactive rebase) to change `Target-Id: 8` to `Target-Id: 15`
4. `git dispatch apply` - commit is cherry-picked to task-15, but task-8 still has the old copy
5. Task-8 now has a commit that doesn't belong to it
6. `git dispatch push --from 8` pushes the stale commit to the remote
7. PR reviewer sees unwanted changes

### Impact

- PRs include commits that don't belong to them
- Reviewers flag "reintroduced" changes, causing confusion and review churn
- The only workaround requires manual branch deletion and rebuild
- Developers lose trust in the tool's correctness after rebase operations

## Root cause

`dispatch apply` is incremental. It tracks which source commits have been applied to each target and only cherry-picks new ones forward. It has no mechanism to:
1. Detect that a previously applied commit was reassigned to a different Target-Id
2. Remove commits from a target that no longer match
3. Warn the user about target/source drift

After a rebase that changes trailers, the target branches are stale but `dispatch status` may show "in sync" (since no new matching commits exist to apply).

## Proposed fix

### Option A: Detect reassigned commits during apply (recommended)

During `apply`, for each existing target, compare the set of Target-Id-matching source commits against the commits already on the target. If a target has commits whose messages/patches exist on source but with a different Target-Id, the target is stale.

Behavior:
- Warn the user: `"Target task-8 has 2 commits that were reassigned to other targets on source"`
- Offer to rebuild: delete and recreate the target from base + matching source commits
- With `--force` flag: auto-rebuild without prompting

Detection approach:
- For each commit on the target (not on base), check if its patch-id or commit message matches a source commit with a DIFFERENT Target-Id
- If yes, the target is stale

### Option B: Hash-based drift detection

Store a hash of the source commits (by Target-Id grouping) after each apply. On the next apply, compare the current grouping hash against the stored one. If different, the target may be stale.

### Option C: Full rebuild mode

Add `git dispatch apply --rebuild` that always recreates targets from scratch instead of incrementally cherry-picking. Slower but guarantees consistency.

### Recommendation

Option A is the best balance of UX and correctness. Option C should also be implemented as a simple escape hatch. They are not mutually exclusive.

## Safety: destructive action handling

Rebuilding a target branch requires deleting it. If a worktree exists for that branch, the worktree must also be removed. These are destructive actions.

**Rule: never perform destructive actions silently.**

When `apply` detects a stale target that needs rebuild:

1. **Scan ALL targets first.** Before printing anything, collect the full picture across every target. The user must see the complete scope of what's wrong before deciding to pass `--force`.

2. **Print a full report.** Show every stale target, every destructive action, and every risk in a single summary. The user should never be surprised by a second issue after passing `--force` for the first one.

   Example output (without `--force`):
   ```
   Stale targets detected (3 targets affected):

     task-8: 2 commits reassigned to other targets
       - branch will be deleted and rebuilt
       - worktree: /Users/.../task-8 (3 modified files)
       - open PR: #21152 (force-push will orphan review comments)

     task-9: 1 commit reassigned to other targets
       - branch will be deleted and rebuilt
       - no worktree

     task-12: 1 commit reassigned to other targets
       - branch will be deleted and rebuilt
       - worktree: /Users/.../task-12 (clean)
       - WARNING: 2 unpushed target-only commits not on source
         a1b2c3d fix review feedback on validation
         d4e5f6g address nit on naming

   Total: 3 branches deleted, 2 worktrees removed, 1 PR affected, 2 commits at risk

   Re-run with --force to confirm all destructive actions.
   To cherry-pick target-only commits back to source first:
     git dispatch cherry-pick --from 12 --to source
   ```

3. **Never perform partial destruction.** `--force` means "I reviewed the full report and accept all consequences". The tool should not process some targets and then stop mid-way on another. Either all stale targets are rebuilt or none are.

4. **Require `--force` to proceed.** Only with `--force` (or `--rebuild --force`) should the tool delete worktrees and branches.

5. **Same rule for `--rebuild`.** Even the explicit rebuild flag should require `--force` when worktrees or branches with unpushed commits would be destroyed.

This matches the existing pattern in `cmd_rebase` (which requires `--force` for open PRs) and `cmd_reset`.

## Current workaround

```bash
# 1. Remove worktree if one exists
git worktree remove --force <worktree-path>

# 2. Delete the stale target branch
git branch -D <target-branch>

# 3. Rebuild from scratch
git dispatch apply

# 4. Force-push to update remote
git dispatch push --from <id> --force
```

This is error-prone and requires knowing which targets are stale.

## Edge cases and implementation notes

### 1. Open PRs on stale targets
Rebuilding a target and force-pushing rewrites PR history. Review comments tied to specific commits get orphaned on GitHub. When a stale target has an open PR, the warning message should include the PR number and URL.

### 2. Unpushed target-only commits
A developer may have committed directly on a target branch (e.g., addressing review feedback via `git dispatch cherry-pick --from <id> --to source`). If those commits weren't cherry-picked back to source before rebuild, they would be destroyed. Before rebuilding, check for target-only commits that don't exist on source (by patch-id). If found, refuse rebuild and tell the user to cherry-pick them back first.

### 3. Distinguishing "ahead" from "stale" in status
Currently `dispatch status` shows "N ahead" for targets with commits not on source. This is ambiguous:
- **Legitimate ahead**: target-only commits (review feedback) not yet cherry-picked to source
- **Stale ahead**: commits whose Target-Id was reassigned on source

Use `git patch-id` to distinguish: if a target-only commit's patch matches a source commit with a DIFFERENT Target-Id, it's stale. If no matching patch exists on source at all, it's legitimate target-only work.

### 4. Patch-id matching for detection
Commit hashes change on rebase, so matching by hash won't work. Use `git patch-id` (content-based hash) to correlate target commits with source commits. This is the same mechanism git uses internally during `rebase` to detect "already applied" commits.

## Affected areas to update

### 1. git-dispatch.sh - `cmd_apply()`
- Add stale commit detection logic
- Add `--rebuild` flag for full rebuild mode
- Add warning when drift is detected, stop execution, require `--force` for destructive actions
- Handle worktree removal when `--force` is passed (check for modified/untracked files, warn before deleting)

### 2. git-dispatch.sh - `cmd_status()`
- Show "stale" indicator when a target has commits that no longer match source Target-Ids
- Currently only shows "in sync", "N behind source", "N ahead"
- Add: "stale (N commits reassigned)" state

### 3. Help text (`cmd_help()`)
- Document `--rebuild` flag under `apply`
- Add troubleshooting section for Target-Id reassignment

### 4. README / documentation
- Add section: "Changing Target-Id after apply"
- Explain what happens and how to fix it
- Document `--rebuild` as the recommended approach

### 5. Claude skill file (`.claude/skills/git-dispatch/`)
- Update the skill description to mention `--rebuild` flag
- Add guidance for when to use it (after interactive rebase that changes trailers)

### 6. Test coverage (`test.sh`)
- Test: apply, change trailer on source, apply again - verify detection/warning
- Test: `--rebuild` flag recreates target correctly
- Test: status shows "stale" for affected targets
