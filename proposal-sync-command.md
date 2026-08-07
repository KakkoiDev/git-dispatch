# Proposal: `sync` command (replacing `apply --base`)

## Summary

Extract the base-merge logic from `apply --base` into a dedicated `sync` command. This creates a clean three-verb model for data flow:

| Command | Direction | What it does |
|---------|-----------|--------------|
| `sync` | base -> source + targets | Merge master into source and existing targets |
| `apply` | source -> targets | Cherry-pick new commits to target branches |
| `checkin` | target -> source | Cherry-pick fixes from checkout back to source |

`apply --base` is removed. `sync` fully replaces it.

---

## Motivation

### Problem 1: `apply --base` is overloaded

`apply --base` does two unrelated things in one step:
1. Merge master into source and targets (base sync)
2. Cherry-pick new source commits to targets (normal apply)

When the merge in step 1 conflicts, the user resolves it and then `apply` runs automatically. But the user might want to sync without applying (e.g. just update source, review the merge result, then apply later). There's no way to do step 1 alone.

### Problem 2: Users forget to sync

The biggest source of issues is running `apply` when source is behind master. This produces:
- Cherry-pick conflicts (old-context diffs vs current master)
- Cosmetic divergence in status
- Targets with auto-resolved content that may differ from source
- Eventual need for `apply reset` + force-push

If `sync` is a separate, visible step, it's easier to build the habit: "sync first, apply second."

### Problem 3: Mental model clarity

Today's flow direction is unclear:

```
apply --base    = base -> source + targets + source -> targets (mixed)
apply           = source -> targets
checkin         = checkout -> source
```

Proposed:

```
sync            = base -> source + targets (one direction)
apply           = source -> targets (one direction)
checkin         = checkout -> source (one direction)
```

Each command flows in exactly one direction.

---

## Command Design

### `git dispatch sync [--dry-run] [--resolve]`

**What it does:**
1. Fetch base (e.g. `git fetch origin master`)
2. Merge base into source
3. Merge base into each existing target branch

**Behavior:**
- If source is already up to date with base: "Already in sync." (no-op)
- If merge is clean: completes silently
- If merge conflicts on source: aborts by default, use `--resolve` to keep conflict active
- If merge conflicts on a target: aborts, use `--resolve` for manual resolution
- After sync, targets have current master via merge commits (no force-push needed)

**No `--rebase` flag.** Merge only. This is a deliberate design choice: merge preserves history, never requires force-push, and is always safe regardless of PR state.

**Output example:**
```
$ git dispatch sync
Fetching origin/master...
Merging origin/master into source (47 commits)
Merging origin/master into target 1 (47 commits)
Merging origin/master into target 2 (47 commits)
Merging origin/master into target 3 (47 commits)
Synced. Source and 3 targets up to date with origin/master.
```

### `apply --base` is removed

`apply` no longer accepts `--base`. Use `sync` + `apply` as separate steps. This keeps each command single-purpose.

---

## Workflow

### Daily workflow

```bash
git dispatch sync           # merge master into source + targets
# ... write code, commit with DTI trailers ...
git dispatch apply          # propagate new commits to targets
git dispatch push all       # push everything
```

### After review feedback

```bash
git dispatch checkout 2     # go to integration branch
# ... fix issue, commit ...
git dispatch checkin        # bring fix back to source
git dispatch checkout source
git dispatch apply 2        # update target 2
git dispatch push 2
```

### Keeping up with master during long review

```bash
git dispatch sync           # merge latest master
git dispatch apply          # propagate any new commits
git dispatch push all
```

---

## What can go wrong

### 1. Sync merge conflict on source

**When:** Master changed the same files as your feature (e.g. both teams modified `transactions.service.ts`).

**What happens:** `sync` stops, shows conflicted files, aborts by default.

**Fix:**
```bash
git dispatch sync --resolve    # keeps conflict active
# resolve conflicts in worktree
git dispatch continue          # finishes merge, continues to target merges
```

**Frequency:** Common when source is far behind master. Less common with frequent syncs.

### 2. Sync merge conflict on a target

**When:** Rare. Only happens if the target has changes that aren't on source (e.g. from a `checkin` that wasn't applied yet, or from direct pushes to the target branch).

**What happens:** `sync` stops at the conflicted target, shows files.

**Fix:**
```bash
git dispatch sync --resolve
# resolve in the target worktree
git dispatch continue
```

**Prevention:** Never push directly to target branches. Always go through source.

### 3. Apply fails after sync

**When:** `apply` tries to cherry-pick a source commit that modifies a file also modified by the sync merge. The cherry-pick context doesn't match because the merge changed the surrounding code.

**What happens:** Cherry-pick conflict during `apply`.

**Fix:** This is the cherry-pick-on-merged-base problem. The auto-resolve (`--theirs`) usually handles it. If it produces wrong content, use `apply --resolve` for manual resolution.

**Frequency:** Only on the first `apply` after a large sync. Subsequent applies (for new commits authored after the sync) will have matching context.

### 4. User runs `apply` without `sync` (source behind master)

**When:** User forgets to sync. Source is behind master. Apply cherry-picks old-context commits onto current master.

**What happens:** Auto-resolved cherry-picks produce cosmetic divergence. Status shows `(cosmetic)`. Content is usually correct but may have artifacts on shared files.

**Mitigation options:**
- (a) `apply` warns when source is behind base: "Source is 47 commits behind origin/master. Run `git dispatch sync` first."
- (b) `apply` auto-runs sync when source is behind (opt-in via config)
- (c) Documentation and habit-building

**Recommendation:** Option (a). Warn but don't block. The user might intentionally skip sync (e.g. working offline, testing locally).

### 5. Sync during active checkout

**When:** User is on a checkout branch and runs `sync`.

**What happens:** Sync needs to modify source and target branches, but the user is on checkout.

**Fix:** `sync` should refuse if a checkout is active: "Cannot sync while checkout is active. Run `git dispatch checkout source` first."

### 6. Concurrent sync + apply race

**When:** User runs `sync` in one terminal and `apply` in another.

**What happens:** Lock file prevents concurrent operations (existing behavior).

### 7. GitHub "Update branch" on target PR

**When:** Someone clicks "Update with base branch" on a target's PR in GitHub UI. This creates a merge commit on the target that's not tracked by dispatch.

**What happens:** Next `apply` might skip commits that look like they're already on the target. Or `checkin` might try to cherry-pick the merge commit.

**Mitigation:** `status` should detect merge commits on targets that aren't from dispatch and warn: "Target 2 has untracked merge commits. This may cause issues with apply."

---

## Implementation

### Changes to `git-dispatch.sh`

1. **New `sync` function** (~50 lines): Extract lines 890-980 from the `apply` function (the `--base` block) into a standalone `sync()` function.

2. **Wire `sync` into command dispatch**: Add `sync` case to the main command router.

3. **Remove `--base` from `apply`**: Delete the flag, the `merge_base` variable, and the entire `if $merge_base` block. `apply` becomes purely source -> targets.

4. **Add drift warning to `apply`**: Before cherry-picking, check `git rev-list --count source..base`. If > 0, warn: "Source is N commits behind base. Run: git dispatch sync"

5. **Block sync during checkout**: Check for active checkout branch, refuse if found.

### Changes to SKILL.md

Update command table:
- Add: `| git dispatch sync [--dry-run] [--resolve] | Merge base into source and existing targets |`
- Remove `--base` from `apply` description
- Update all workflow examples to show `sync` + `apply` as separate steps

### Changes to DESIGN.md

Update flow direction diagram:
```
base --> source --> targets        (sync, then apply)
                \-> checkout       (ephemeral, for testing)
                      \-> source   (checkin)
```

Update command reference with `sync` entry.

---

## Flags

| Flag | Behavior |
|------|----------|
| `--dry-run` | Show what would be merged, don't execute |
| `--resolve` | On conflict, leave active for manual resolution |
| (no `--rebase`) | Intentionally omitted. Merge only. |
| (no `--force`) | Nothing to force. Merge is always additive. |

---

## FAQ

**Q: Why not add `--rebase` to sync?**
A: Rebase rewrites source history, requiring force-push of source and all targets. This violates the core no-force-push invariant. The merge approach is always safe, even with open PRs.

**Q: What about the `(cosmetic)` status after sync + apply?**
A: Cosmetic divergence comes from cherry-pick SHA differences, not content differences. After sync, targets have the same base as source (via merge), so content matches. The `(cosmetic)` tag means "safe to ignore." Future improvement: suppress `(cosmetic)` when it's purely from auto-resolved cherry-picks after sync.

**Q: Should sync auto-run before apply?**
A: No. Sync modifies branches (creates merge commits). The user should explicitly choose when to sync. `apply` warns when source is behind but doesn't auto-sync.

**Q: Does sync replace `apply reset`?**
A: No. `apply reset` is for broken targets (real divergence, corrupted state). `sync` is for routine maintenance. They serve different purposes:
- `sync` = keep up with master (routine, safe, no force-push)
- `apply reset` = nuclear option (recreate from scratch, force-push required)

---

## Migration

1. Extract `sync()` function from the `apply --base` block
2. Wire `sync` into command router
3. Remove `--base` flag from `apply`
4. Add drift warning to `apply`
5. Update SKILL.md, DESIGN.md, README.md
