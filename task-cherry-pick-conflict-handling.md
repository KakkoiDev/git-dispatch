# Task: Cherry-pick conflict handling with --resolve flag

## Problem

When `git dispatch cherry-pick` hits a merge conflict:
1. The `--resolve` flag is parsed but never used in `cmd_cherry_pick()`
2. The abort in `_cherry_pick_with_trailers()` / `cherry_pick_into()` doesn't always clean up properly - leaves files in UU (both-modified) state
3. Previously successful commits in the same batch are already committed, so partial state remains
4. No conflict details are shown - just a generic "Resolve manually" message

## Desired behavior

### Always (conflict occurs)
- Show conflict details: file names, line numbers, full diff (`git diff` on conflicted files)
- Show which commit caused the conflict (SHA + oneline)
- Show how many commits were already applied before the conflict

### Without --resolve (default)
- Abort the failing cherry-pick cleanly (no UU state left)
- Previously committed cherry-picks in the batch remain (this is correct - they succeeded)
- Print: "Aborted. Re-run with --resolve to keep conflict active for manual resolution."
- Exit non-zero

### With --resolve
- Leave the cherry-pick active (do NOT abort)
- Print: "Resolve conflicts, then run: git cherry-pick --continue"
- Print remaining commits that still need to be cherry-picked (SHAs + oneline)
- Exit non-zero

## Affected functions

All in `git-dispatch.sh`:

### `_cherry_pick_with_trailers()` (line ~178)
Used for target-to-source cherry-picks. On conflict (lines 214-227, 230-241):
- Currently: `cherry-pick --abort` then `die`
- Needs: conflict diff display, then conditional abort based on resolve flag
- The `resolve` flag must be passed as a parameter (currently not passed)

### `cherry_pick_into()` (line ~278)
Used for source-to-target cherry-picks. On conflict (lines 299-310):
- Same issue as above
- Currently: `cherry-pick --abort` then `die`

### `cmd_cherry_pick()` (line ~701)
- Parses `--resolve` at line 711 but never passes it to the cherry-pick functions
- Must pass `resolve` to `_cherry_pick_with_trailers` and `cherry_pick_into`

## Implementation notes

### Showing conflict diff
When `git cherry-pick` fails with conflict, before aborting:
```bash
# List conflicted files
git diff --name-only --diff-filter=U

# Show the conflict diff (includes markers)
git diff
```

### Clean abort
Current code does `cherry-pick --abort 2>/dev/null || true` but sometimes the cherry-pick state is already gone. Ensure:
```bash
git cherry-pick --abort 2>/dev/null || git reset --merge 2>/dev/null || true
```

### Parameter threading
Both `_cherry_pick_with_trailers` and `cherry_pick_into` need a `resolve` boolean parameter.
Suggested: add it as the first positional parameter or use an env var like `DISPATCH_RESOLVE=true`.

## Reproduction

```bash
# On a source branch with dispatch configured
git dispatch cherry-pick --from 8 --to source
# If task-8 has commits that conflict with source, observe:
# - UU files left in working tree
# - No conflict details shown
# - Generic "Resolve manually" message
```
