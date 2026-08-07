# BUG: `apply <N>` blocked by unrelated commit with broken trailer

## Summary

`git dispatch apply 13` fails because an unrelated commit (target 8) has a broken `Dispatch-Target-Id` trailer. The trailer exists but is not recognized because conflict markers and cherry-pick metadata appear after it, breaking git's trailer parsing.

`apply <N>` should only care about commits for target N (and `all`), not fail on commits belonging to other targets.

## Reproduction

1. Have a source branch with commits for multiple targets
2. One commit (from checkin cherry-pick) has trailing conflict markers after the trailer:

```
perf(purchase-orders): use Set for O(n+m) transaction lookup in findAll

Remove unused `type` field from select and replace O(n*m) Array.find
inside map with a pre-built Set for O(1) per-item lookup.

Dispatch-Target-Id: 8

# Conflicts:
#	apps/server/src/purchase-orders/purchase-orders.service.ts
(cherry picked from commit 7d0518eb5604ce5abadf8baec059047051dc32d6)
```

3. Run `git dispatch apply 13`

## Expected

Apply processes only commits with `Dispatch-Target-Id: 13` and `all`. Commits for other targets are skipped. The broken trailer on an unrelated target should not block the operation.

## Actual

```
Error: Commit df153160 has no Dispatch-Target-Id trailer
```

All apply variants fail - `apply 13`, `apply reset 13 --yes`, `apply reset all --yes`.

## Root Cause

Two issues:

1. **Trailer parsing**: git trailers must be the last paragraph. When `checkin` cherry-picks a commit that had conflicts, git appends `# Conflicts:` and `(cherry picked from ...)` after the trailer block, breaking trailer detection.

2. **Scope filtering**: `apply <N>` scans all source commits and hard-fails on any commit without a recognized trailer, even if that commit belongs to a different target. It should skip or warn on unrelated commits instead of aborting.

## Suggested Fix

### Issue 1 - Trailer parsing
During `checkin`, strip `# Conflicts:` and `(cherry picked from ...)` suffixes from cherry-picked commit messages before committing to source. Or use a more lenient trailer parser that scans for `Dispatch-Target-Id:` anywhere in the trailer paragraph, ignoring trailing non-trailer lines.

### Issue 2 - Scope filtering
When running `apply <N>`, only require valid trailers on commits that will actually be cherry-picked (matching target N or `all`). For other commits, log a warning but do not abort.

## Workaround

Manually amend the broken commit to remove the trailing conflict/cherry-pick lines:
```bash
git rebase -i <parent-of-broken-commit>
# mark commit as 'edit', remove trailing lines, continue
```

This requires rewriting history on the source branch.

## Environment

- git-dispatch (latest as of 2026-03-27)
- Broken commit produced by `checkin` after resolving conflicts on a checkout branch
