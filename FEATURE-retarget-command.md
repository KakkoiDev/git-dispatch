# Feature Proposal: `git dispatch retarget`

## Problem

Changing a commit's `Dispatch-Target-Id` after `apply` requires either:

1. **Interactive rebase** on source to amend the trailer. This rewrites history and requires force-push on source. Works but has side effects: all downstream targets diverge, and the stale-commit-detection issue (see `ISSUE-target-id-reassignment.md`) means old targets keep the ghost commit.

2. **Revert + re-apply pattern** on source. No rebase needed, but painful in practice:
   - Create a revert commit targeting the OLD target (to cancel the original)
   - Create a new commit with the same diff targeting the NEW target
   - The `prepare-commit-msg` hook auto-carries the previous trailer, so the revert gets the wrong `Dispatch-Target-Id` and must be manually corrected
   - If the original changes are already on source, `git cherry-pick --no-commit` produces an empty diff, so you must manually edit files
   - Error-prone, 5+ steps, easy to get wrong

Both approaches are workarounds for a missing primitive: moving commits between targets without rewriting history.

## Real-world scenario

Task 13.1 (tax code map fix) was a separate target but turned out to belong in the same PR as task 13. The developer needed all changes on one target branch for a single PR. The manual revert + re-apply took ~10 minutes and 6 commands.

## Proposed command

```bash
git dispatch retarget <from-id> <to-id> [--dry-run]
```

### Behavior

For each commit on source with `Dispatch-Target-Id: <from-id>`:

1. Create a **revert commit** with `Dispatch-Target-Id: <from-id>` (cancels the original on the old target)
2. Create a **re-apply commit** with `Dispatch-Target-Id: <to-id>` (adds the changes to the new target)

The hook is bypassed for the revert commit (or the command sets the trailer explicitly before the hook runs).

### Net effect

| Branch | Before | After |
|--------|--------|-------|
| **Source** | No diff (revert + re-apply cancel out) | Same content |
| **Old target** | Has the commits | Original + revert = empty diff |
| **New target** | Missing the commits | Gets the re-apply commits |

### Example

```bash
# Before: tax code fix is on target 13.1
git log --format="%h %(trailers:key=Dispatch-Target-Id,valueonly) %s" source
# a1b2c3d 13.1 fix(web): add purchase tax codes to transactionTaxCodeMap
# d4e5f6g 13   feat(web): add PurchaseOrderTransactionRegistrationContent

git dispatch retarget 13.1 13

# After: two new commits on source, net zero diff
git log --format="%h %(trailers:key=Dispatch-Target-Id,valueonly) %s" source
# f7g8h9i 13   fix(web): add purchase tax codes to transactionTaxCodeMap
# e6f7g8h 13.1 revert: fix(web): add purchase tax codes to transactionTaxCodeMap
# a1b2c3d 13.1 fix(web): add purchase tax codes to transactionTaxCodeMap
# d4e5f6g 13   feat(web): add PurchaseOrderTransactionRegistrationContent

git dispatch apply  # rebuilds both targets
```

### Flags

| Flag | Behavior |
|------|----------|
| `--dry-run` | Show which commits would be retargeted, make no changes |
| `--apply` | Run `dispatch apply` automatically after retargeting |

## Implementation notes

### Hook bypass

The `prepare-commit-msg` hook auto-carries the previous commit's `Dispatch-Target-Id`. The retarget command must control trailers explicitly. Options:

1. **Set trailer before hook runs**: Write the commit message with the correct `Dispatch-Target-Id` already present. The hook checks `grep -q "^Dispatch-Target-Id:" "$msg_file" && exit 0` and skips.
2. **Env var gate**: Add `DISPATCH_RETARGET=1` check to the hook to skip auto-carry.

Option 1 is simpler and requires no hook changes.

### Commit message format

Revert commit:
```
revert: <original subject>

Retargeted from <from-id> to <to-id> by `git dispatch retarget`.
This reverts the content of <original-hash>.

Dispatch-Target-Id: <from-id>
```

Re-apply commit:
```
<original subject>

Retargeted from <from-id> to <to-id> by `git dispatch retarget`.

Dispatch-Target-Id: <to-id>
```

### Multiple commits

When `<from-id>` has multiple commits, retarget all of them in order. The revert commits are created in reverse order (last commit reverted first), and re-apply commits in original order.

### Empty old target

After retargeting, the old target has pairs of (original + revert) that cancel out. On next `apply`, the old target branch still exists but produces no net diff. The command should print a note:

```
Target 13.1 is now empty (all commits retargeted to 13).
Consider: git dispatch apply reset 13.1
```

## Relationship to ISSUE-target-id-reassignment.md

The existing issue describes the problem of stale commits after rebase-based trailer changes. `retarget` is a complementary solution that avoids rebase entirely:

| Approach | History rewrite | Force-push needed | Stale commit risk |
|----------|----------------|-------------------|-------------------|
| Interactive rebase | Yes | Yes | Yes (existing issue) |
| `dispatch retarget` | No | No | No (revert cancels original) |

The stale-commit-detection system proposed in `ISSUE-target-id-reassignment.md` is still valuable for cases where developers rebase manually. `retarget` is the recommended workflow for intentional target changes.

## Edge cases

### 1. Retargeting `all` commits
Disallow. `Dispatch-Target-Id: all` commits are shared across all targets. Retargeting them would require reverting on every existing target.

### 2. Retargeting to `all`
Allow. The revert goes to the old target, and the re-apply gets `Dispatch-Target-Id: all`.

### 3. `<from-id>` has no commits
Error: `No commits found with Dispatch-Target-Id: <from-id>`.

### 4. `<to-id>` already has commits
Fine. The re-apply commits are appended after existing commits for that target.

### 5. Conflicts during retarget
The revert cherry-pick should always succeed on source (it's reverting content that exists). The re-apply should also always succeed (it's re-adding what was just removed). If somehow a conflict occurs (e.g., surrounding context changed), use the standard `--resolve`/`--continue` flow.

### 6. Retarget on checkout branch
Disallow. Retarget only works on the source branch. If on a checkout, print: `Switch to source first: git dispatch checkout source`.
