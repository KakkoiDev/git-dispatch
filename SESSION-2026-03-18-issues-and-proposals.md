# Session 2026-03-18: Issues encountered and proposals

## Context

Working on `cyril/poc/purchase-order-transaction-registration` in a tmux-worktree setup. Source branch had 35+ commits with Dispatch-Target-Id trailers across 8 targets (8, 9, 11, 12, 13, 13.1, 14, 15). Master had advanced by 2 commits touching `apps/web/src/components/templates/PurchaseOrderDetail/hooks.ts` since the source branch diverged.

---

## Issue 1: Target pattern leaked from another worktree

**Symptom**: `git dispatch status` showed `target-pattern: fix/none-28154-large-seed-task-{id}` which belongs to a different project in worktree `fix/none-28154-add-transaction-generation`.

**Root cause**: `dispatch.targetpattern` is stored via `git config --local` which writes to the shared `.git/config`. All worktrees share this file.

**Impact**: `git dispatch apply` silently created 8 target branches with completely wrong names. No error or warning was shown. The mistake was only noticed after checking `git dispatch status` output.

**Fix applied**: `git dispatch reset` to delete wrong branches, then `git dispatch init` with correct pattern.

**Proper fix**: Use `git config --worktree` for dispatch config. Already documented in `BUG-worktree-config-collision.md` (updated with this as Incident 2).

---

## Issue 2: apply reset refused due to "target-only commits"

**Symptom**: After reset + init cycle, `git dispatch apply` reported all 8 targets as "exists but is not a dispatch target (missing dispatchsource)". Running `git dispatch apply reset <id>` for each target refused with "N target-only commit(s) that will be lost. Aborted."

**Root cause**: `dispatch reset` removed the `branch.*.dispatchsource` git config entries. The existing target branches became "foreign" branches from dispatch's perspective. `apply reset` detected commits on those branches that don't exist on source and blocked to prevent data loss.

**Fix applied**: `git dispatch apply reset <id> --force` for each target. But this only processed one at a time - after resetting target 8, dispatch ran a full apply cycle and hit the same "missing dispatchsource" error on targets 9-15. Had to run the loop again.

**Proposed improvement**: `git dispatch apply reset --all --force` to reset all targets in one pass. Or `dispatch reset` should also clean up the actual branches, not just the config, to avoid this orphaned state.

---

## Issue 3: apply --base merge conflict with incorrect auto-merge

**Symptom**: `git dispatch apply --base` triggered a merge of master into source. The merge had conflicts in `hooks.ts`. When resolved by taking master's version (`git checkout origin/master -- hooks.ts`), the auto-merged portions of the file had issues:

1. Two lines concatenated on a single line (import statement fused with `const` declaration)
2. Function bodies (`handleOrderingCommon`) were merged in, but the variable declarations they reference (`canResubmitEOrdering`, `documentPortalPurchaseOrder`, `resubmitDocumentPortalPurchaseOrder`, `setWithElectronicOrdering`) were dropped by the auto-merge

**Root cause**: Git's 3-way merge resolved some hunks automatically but got the boundaries wrong. The conflict markers only covered part of the change, while dependent code in non-conflicting sections was auto-resolved incorrectly.

**Fix applied**: Abandoned piecemeal conflict resolution. Reset the merge commit. Redid the merge and took master's entire `hooks.ts` file wholesale with `git checkout origin/master -- hooks.ts`.

**Lesson**: When a file has extensive changes on both sides, taking one side entirely is safer than trying to merge. Partial auto-merge results can be silently broken.

---

## Issue 4: Targets diverge after clean reset + fresh apply

**Symptom**: After successfully merging master into source and running a fresh `git dispatch apply`, the status showed:
- Target 8: "1 untracked"
- Target 9: "7 behind source, 7 ahead (DIVERGED)"
- Targets 11-15: "in sync"

**Root cause**: Source commits were authored against old master. When dispatch cherry-picks them onto new master, the surrounding context is different. Even with `--theirs` auto-resolution, the resulting cherry-picked commits have different patch content than the original source commits. Dispatch compares content and flags the mismatch.

For target 9 specifically: the source commit replaces `handleOrderingClick` with transaction menu logic. On old master, that function was inline. On new master, it was refactored into `handleOrderingCommon`. The `--theirs` cherry-pick takes the source version, silently reverting master's refactor. The files are not just cosmetically different - they are functionally wrong (missing resubmit/reissue features).

**Fix**: See `proposal-merge-base-into-targets.md`. Merge master into existing targets instead of recreating them via cherry-pick.

---

## Issue 5: --theirs auto-resolution silently loses master code

**Symptom**: Target 9's `hooks.ts` had the old inline `handleOrderingClick`/`handleOrderingWithSignatureClick` instead of master's refactored `handleOrderingCommon` pattern. Master's resubmit and reissue-from-delivered features were silently dropped.

**Root cause**: Dispatch uses `--theirs` (source wins) for auto-resolution during cherry-pick. When the source commit modifies a region that master also modified, source's version overwrites master's entirely. There is no warning that master code was lost.

**Impact**: A PR created from this target would silently revert merged master features. This could pass code review if reviewers only look at the PR diff (which shows "additions") without checking for missing master code.

**Fix**: Same as Issue 4 - merge-based approach guarantees master code is preserved.

---

## Issue 6: No consistent abort mechanism

**Symptom**: Multiple times during the session, dispatch operations stopped mid-way due to conflicts or errors. Recovering required knowing which git primitive was stuck:

| Dispatch operation | Stuck state | Required manual abort |
|-------------------|-------------|----------------------|
| `apply --base` | Merge conflict on source | `git merge --abort` |
| `checkout 11` | Cherry-pick conflict on checkout branch | `git dispatch checkout clear` |
| `apply reset` loop | Some targets deleted, others orphaned | Manual `git branch -D` for each |

**Root cause**: Dispatch delegates to git primitives (merge, cherry-pick) but doesn't provide a unified abort mechanism when they fail.

**Proposed solution**: See proposal below.

---

## Issue 7: --continue vs --resolve flag confusion

**Symptom**: After resolving the merge conflict from `apply --base`, tried `git dispatch apply --base --continue`. Got "Error: Unknown flag: --continue". The correct flag was `git dispatch apply --resolve`.

**Impact**: Minor, but confusing in the middle of conflict resolution. Git itself uses `--continue` for merge/rebase/cherry-pick, so users expect the same pattern.

**Proposed improvement**: Accept `--continue` as an alias for `--resolve`, or standardize on one name across all dispatch commands.

---

## Proposal: git dispatch abort

### Problem

When a dispatch operation fails mid-way (conflict, error, user changes mind), there is no single command to cleanly undo the in-progress operation. The user must:

1. Figure out what git primitive is stuck (merge? cherry-pick? on which branch?)
2. Run the appropriate git abort command
3. Switch back to the source branch
4. Hope dispatch state is consistent

This is error-prone and was a source of multiple missteps during this session.

### Proposed command

```
git dispatch abort
```

### Behavior

1. Detect what operation is in progress:
   - Check for `.git/MERGE_HEAD` (merge in progress from `apply --base`)
   - Check for `.git/CHERRY_PICK_HEAD` (cherry-pick in progress from `apply` or `checkout`)
   - Check for dispatch-checkout branch (checkout in progress)
   - Check for partially-applied targets (some created, some not)

2. Abort the operation:
   - Merge: `git merge --abort`
   - Cherry-pick: `git cherry-pick --abort`
   - Checkout: delete the checkout branch (same as `dispatch checkout clear`)

3. Return to source branch:
   - `git checkout <source-branch>`

4. Restore dispatch state:
   - If targets were partially deleted during `apply reset`, restore config consistency
   - If target branches were partially created, either keep completed ones or roll back all

### Examples

```bash
# apply --base stops at merge conflict
$ git dispatch apply --base
CONFLICT in hooks.ts
$ git dispatch abort
Merge aborted. Returned to source branch.

# checkout stops at cherry-pick conflict
$ git dispatch checkout 11
CONFLICT on commit 2/26
$ git dispatch abort
Cherry-pick aborted. Checkout branch deleted. Returned to source branch.

# apply stops mid-way through targets
$ git dispatch apply
Created target-8 (9 commits)
CONFLICT on target-9 commit 2/19
$ git dispatch abort
Cherry-pick aborted on target-9. Target-8 kept (completed). Returned to source branch.
```

### Note on flags

`git dispatch reset` accepts `--yes` to skip confirmation prompts. Piped input (`yes |`, `echo y |`) does not work. The `--force` flag also skips the prompt but returns exit code 1 (minor bug).

### Edge cases

- **No operation in progress**: Print "Nothing to abort" and exit cleanly
- **On source branch with clean state**: Same as above
- **Partially completed multi-target apply**: Keep fully-created targets, abort the one in progress. This matches the principle of preserving completed work.
- **User made manual commits during conflict resolution**: Warn before aborting ("You have N uncommitted changes. Abort will discard them. Proceed? [y/N]")

### Relationship to --continue/--resolve

These three commands form a complete conflict-handling interface:

| Command | When to use |
|---------|-------------|
| `git dispatch abort` | Give up on the current operation, return to clean state |
| `git dispatch apply --continue` | Resume after resolving a conflict (or alias: `--resolve`) |
| `git dispatch apply --base --continue` | Resume base merge after resolving conflicts |

This mirrors git's own `--abort` / `--continue` pattern for merge, rebase, and cherry-pick.
