# Bug: False DIVERGED on targets with generated file drift

## Problem

`git dispatch status` shows `(DIVERGED - checkout, checkin, apply)` on targets that are actually in sync content-wise for all non-generated files.

## Root Cause

Generated files (`openapi.gen.d.ts`, `swagger.json`, `api/gen/*.ts`) differ between source and target because they were regenerated at different points in time against different base states. The `_target_content_diverged()` function (line ~487) detects file content differences and tries to filter cosmetic drift via subject-line traceability, but fails because:

1. `_target_content_diverged` collects ALL files from commits with matching `Dispatch-Target-Id` on the target
2. Generated files always drift between source/target due to base state differences
3. The subject-line traceability check (lines 507-513) doesn't help because the diff is real (different generated output), even though it's irrelevant

## Evidence

On a real repo, target 1 shows DIVERGED. Checking individual files:

```
DIFF: apps/server/openapi.gen.d.ts        # generated
DIFF: apps/server/swagger.json             # generated
DIFF: apps/web/src/store/api/gen/transactions.ts  # generated
SAME: (all other files)                    # actual code
```

All non-generated files are identical between source and target.

## Flow

1. `git cherry` finds 4 candidates (commits on target not equivalent on source)
2. `_commit_effect_in_branch` / `_would_cherry_pick_be_empty_on_branch` fail to filter them (different base means different generated output)
3. `target_to_source > 0` triggers `_target_content_diverged()`
4. `_target_content_diverged` finds file diffs in generated files
5. Subject-line check can't save it because the content genuinely differs (just not meaningfully)
6. Result: false DIVERGED

## Fix

`_target_content_diverged()` should exclude files from commits that have `Dispatch-Source-Keep: true` trailer. Source-Keep already signals "this is a generated/regenerated file, auto-resolve with incoming version." These files are expected to drift and should not trigger divergence.

### Implementation

In `_target_content_diverged()` (~line 487):

1. When collecting files via `_target_id_files`, also collect Source-Keep files
2. Subtract Source-Keep files from the diff check
3. If the remaining files have no diff, return 1 (not diverged)

Alternatively, in the `target_to_source` candidate filtering (~line 1638-1676):

1. When checking candidates, skip commits that have `Dispatch-Source-Keep: true` trailer entirely
2. These commits are explicitly marked as generated/auto-resolved

### Preferred approach

Option 2 (skip Source-Keep commits from candidates) is simpler and more correct. Source-Keep commits are by definition auto-resolved and should never count as divergence evidence.

Location: `git-dispatch.sh` lines 1638-1676, inside the `target_to_source_candidates` loop. Add a check:

```bash
# In the cherry candidates loop (~line 1641-1649)
while IFS= read -r line; do
    [[ "$line" == +* ]] || continue
    local hash
    hash=$(echo "$line" | awk '{print $2}')
    if git merge-base --is-ancestor "$hash" "$base" 2>/dev/null; then
        continue
    fi
    # Skip Source-Keep commits - they are generated files, expected to drift
    local _sk
    _sk=$(git log -1 --format="%(trailers:key=Dispatch-Source-Keep,valueonly)" "$hash" 2>/dev/null | tr -d '[:space:]')
    [[ "$_sk" == "true" ]] && continue
    target_to_source_candidates+=("$hash")
done <<< "$cherry_out"
```

## Test

After fix, `git dispatch status` on the repo at:
`~/.tmux-worktree/meetsone/cyril/poc/bulk-transaction-registration-from-the-purchase-order-list`

Should show target 1 as "in sync" (not DIVERGED), since the only differing files are from Source-Keep commits.
