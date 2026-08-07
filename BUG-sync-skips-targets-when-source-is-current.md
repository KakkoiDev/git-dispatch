# BUG: sync skips target merges when source is already up to date

## Summary

`git dispatch sync` early-returns with "Already in sync" when source is up to date with base, even if target branches are still behind base. Targets are never checked.

## Observed behavior

```
$ git dispatch sync
Already in sync. Source is up to date with origin/master.
```

Source: 0 commits behind origin/master (correct).
Target 1: 62 commits behind origin/master (not checked, not merged).

GitHub shows the PR with "This branch has conflicts that must be resolved" and "62 commits behind."

## Expected behavior

`sync` should merge base into all targets that are behind, regardless of whether source needed merging.

Expected output:
```
Source is up to date with origin/master.
Merging origin/master into target 1 (62 commits)
Synced. 1 target updated.
```

## Root cause

`git-dispatch.sh` line 1180-1182:

```bash
base_count=$(git rev-list --count "$source..$base" 2>/dev/null || echo 0)
if [[ "$base_count" -eq 0 ]]; then
    info "Already in sync. Source is up to date with $base."
    return    # <-- exits without checking targets
fi
```

The `return` on line 1182 skips the entire target-merging block (lines 1211+). The function treats "source is current" as "everything is current."

## How it happens

This is common when source and target get synced at different times:

1. Source is behind master. You run `sync --resolve` to merge master into source.
2. Sync hits a conflict on source. You resolve it and commit.
3. Sync continues but hits a conflict on the target. You abort (or it fails).
4. You manually merge master into source (or the conflict resolution already completed the source merge).
5. You run `sync` again expecting it to retry the target.
6. Sync sees source is current, says "Already in sync", returns. Target stays stale.

Another path (what happened here):

1. Source is behind master. A previous `sync --resolve` merges master into source but not into the target (conflict on target was resolved manually outside dispatch).
2. Later, you add commits and run `apply 1` to update target.
3. `apply` cherry-picks new commits onto target but does NOT merge base into target.
4. Target is now current with source commits but 62 commits behind base.
5. `sync` sees source is current, returns. Target stays behind.

## Reproduction

```bash
# Setup: source and target 1 are both behind master

# Step 1: merge master into source only
git checkout <source>
git merge origin/master
# (resolve any conflicts, commit)

# Step 2: sync should merge into targets, but doesn't
git dispatch sync
# Output: "Already in sync. Source is up to date with origin/master."

# Step 3: verify target is still behind
git rev-list --count cyril/dispatch/.../1..origin/master
# Output: 62
```

## Workaround

Manually merge master into each stale target:

```bash
git checkout <target-branch>
git merge origin/master --no-edit
# resolve conflicts if any
git checkout <source-branch>
```

## Proposed fix

Remove the early return. Let the function always fall through to the target-merging block.

```bash
base_count=$(git rev-list --count "$source..$base" 2>/dev/null || echo 0)
if [[ "$base_count" -eq 0 ]]; then
    info "Source is up to date with $base."
    # Don't return - continue to check targets
else
    # ... existing merge-into-source logic ...
fi

# Merge base into existing targets (always reached)
```

This is a one-line change: remove `return` on line 1182 and wrap the source-merge block in an `else`.

## Impact

- Any target that fell out of sync with base stays stale until manually fixed
- GitHub shows "conflicts" and "N commits behind" on the PR
- CI may fail due to missing base changes
- `dispatch sync` gives false confidence that everything is current

## Related

- `proposal-sync-command.md` - sync design (this bug contradicts the stated behavior: "Merge base into source and existing targets")
- `BUG-checkout-conflict-after-sync-stale-targets.md` - downstream effect of stale targets
