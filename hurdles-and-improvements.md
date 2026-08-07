# git-dispatch: Hurdles Encountered and Proposed Improvements

Real-world issues encountered during a stacked PR workflow for the Purchase Order Transaction Registration POC.

---

## Hurdle 1: `status` reports "in sync" when task branch has diverged

### What happened

4 review-fix commits were made directly on the task-6.1 branch without Task-Id trailers. `git dispatch status` reported "in sync" because it only tracks commits with trailers.

### Root cause

Status uses Task-Id trailers to determine which commits belong to which task. Commits without trailers are invisible.

### Proposed improvement

Detect untracked commits (non-merge, no Task-Id trailer) on task branches and report them:

```
cyril/feat/.../task-6.1
  in sync
  5 merge commit(s) from base (no action needed)
  4 untracked commit(s) (no Task-Id trailer)       <-- NEW
```

Detection: find non-merge commits on `task_branch ^source` that have no Task-Id trailer.

---

## Hurdle 2: `sync` fails when task branch has merge commits from base

### What happened

`git dispatch sync` tried to rebase the task-6.1 branch to amend trailers onto the 4 untracked commits. The rebase hit merge commits from base (`git merge master`) and failed with conflicts.

```
Error: Rebase failed while amending trailer on <sha> in <task-branch>. Resolve manually.
```

### Root cause

Rebase flattens merge commits. When the task branch has `git merge master` commits, rebasing replays all the merged content as individual patches, causing conflicts.

### Proposed improvement

Replace rebase-and-amend with cherry-pick when merge commits from base are detected:

```
sync(source, task_branch):
  if has_base_merge_commits(task_branch):
    cherry_pick_untracked(source, task_branch)  # new path
  else:
    rebase_and_amend(source, task_branch)        # existing path
```

Cherry-pick algorithm:
1. Find commits on task branch not on source
2. Filter out merge commits and already-tracked commits
3. Use `git patch-id` to detect duplicates
4. Cherry-pick each onto source with Task-Id inferred from branch name

See `proposal-auto-cherry-pick-untracked.md` for full spec.

---

## Hurdle 3: Agent guesses wrong trailer format

### What happened

The agent initially used `Task-Order=6.2` for Task-Id (missing `task-` prefix) before being corrected. The project convention was `Task-Id=task-6.2` (prefixed) and `Task-Order=6.2` (numeric).

### Root cause

Task-Id format varies per project. The agent didn't check existing trailers before committing.

### Proposed improvement

Add a convention-detection step to the skill instructions. Before making the first commit, always run:

```bash
git log --format="%s%n  Task-Id: %(trailers:key=Task-Id,valueonly)  Task-Order: %(trailers:key=Task-Order,valueonly)" <base>..HEAD | head -20
```

Could also be automated in `git dispatch hook install` to validate trailer format against existing conventions and warn on mismatch.

---

## Hurdle 4: `push --branch` rejects short task names

### What happened

`git dispatch push --branch task-6.2` failed with "Branch 'task-6.2' not found in dispatch stack". Required the full branch name: `--branch cyril/feat/purchase-order-transaction-registration/task-6.2`.

### Root cause

The `--branch` flag does exact matching against the dispatch stack, which stores full branch names.

### Proposed improvement

Support short names by matching against the task suffix. If `--branch task-6.2` is provided, match it against `*/task-6.2` in the dispatch stack. Same for other commands that accept `--branch`.

---

## Hurdle 5: `restack` fails when parent was squash-merged

### What happened

After task-6.1 was squash-merged to master, `git dispatch restack` failed because it tried to rebase the entire stack starting from task-6. The rebase hit conflicts since the squash-merged content already exists in master with different SHAs.

### Root cause

`restack` replays all commits from the stack base. When parent branches were squash-merged, the original commit SHAs don't match master's squash commit. Git sees them as conflicting changes.

### Proposed improvement

`restack` should detect merged parent branches and skip them:

1. For each branch in the stack (bottom-up), check if it's been merged to base
2. If merged, remove it from the stack and rebase the next child directly onto base
3. Use `--onto` rebase to transplant only the child's own commits

```bash
# What restack should do internally for merged parents:
git rebase --onto origin/master HEAD~N <child-branch>
# where N = number of commits belonging to the child task only
```

Could detect merged status via:
- `git ls-remote origin <branch>` returns empty (remote deleted after merge)
- `git merge-base --is-ancestor <branch-tip> origin/master`

---

## Hurdle 6: Massive PR diff for child of merged parent

### What happened

After splitting task-6.2 (1-line comment fix), the PR on GitHub showed 1255 additions across 6 commits. The child branch carried all parent commits as ancestors.

### Root cause

`git dispatch split` stacks the child on the local parent branch. Even though the parent was merged to master, the child still has all parent commits in its history. GitHub compares against master and sees all those commits as new (different SHAs from squash merge).

### Proposed improvement

After split, automatically detect if parent branches are merged and rebase the child onto master. This could be integrated into `split` itself or into a post-split validation step:

```
split(source, base, name):
  for each task branch created:
    parent = stack_parent(task_branch)
    if is_merged_to_base(parent, base):
      rebase_onto_base(task_branch, base, commit_count)
```

---

## Hurdle 7: Auto-gen files cause false cross-dependencies between independent targets

### What happened

`git dispatch verify` flagged targets 8 and 9 as cross-dependent because both modify auto-generated files (openapi.gen.d.ts, swagger.json, generated API clients). These files are derived artifacts that get regenerated whenever API endpoints change. Each target adds different endpoints but the regeneration produces a file reflecting ALL endpoints on that branch.

On source (which has both targets' code), the auto-gen files are correct. But when cherry-picked to an independent target that only has one target's endpoints, the auto-gen files are wrong for that target's API surface.

### Root cause

Auto-gen files are derived from code. Cherry-picking them between branches with different code produces incorrect results. The verify command correctly detects the shared modification but offers no automated solution.

### Proposed improvement

Add `dispatch.regenCommand` config and post-apply regeneration:

1. User configures: `git config dispatch.regenCommand 'pnpm openapi'`
2. During `apply`, after cherry-picking all commits for a target that has shared auto-gen files, run the regen command on that target branch
3. If output differs, commit the regenerated files
4. Same logic applies in reverse (`sync target -> source`)

Detection reuses the existing cross-dependency analysis from `cmd_verify` (per-target file sets, shared file detection), extracted into a reusable function.

See `proposal-autogen-regen-after-apply.md` for full spec.

---

## Hurdle 8: `apply` loops on already-cherry-picked commit after merge-from-base

### What happened

1. Source branch has 3 commits with `Target-Id=9`
2. Target task-9 already had independent work (8 commits ahead, PR open)
3. User merged latest master into source via `git dispatch merge --from base --to source`
4. User ran `git dispatch apply` to propagate to targets
5. First 2 commits cherry-picked to task-9 successfully
6. Third commit conflicted. User resolved and continued cherry-pick
7. The cherry-pick result was empty (changes already existed on task-9)
8. User skipped the empty cherry-pick with `git cherry-pick --skip`
9. On next `git dispatch apply`, dispatch tried to cherry-pick the same commit AGAIN
10. This loop continued indefinitely - dispatch never recognized the commit as applied

### Root cause

`git dispatch apply` determines "behind" commits by comparing source vs target using `git cherry` (patch-id matching). When a commit was cherry-picked but resolved as empty (skipped), no corresponding commit exists on the target. The patch-id check sees the original commit on source with no matching patch on target, so it perpetually considers it "unapplied".

The `--skip` leaves no trace. There is no mechanism for dispatch to record "this commit was intentionally skipped because its content already exists on the target."

### Why this is especially painful

- In stacked mode, ALL subsequent targets are blocked until the current one is in sync
- The user cannot force-push task-9 because it has an open PR with reviews
- Switching to independent mode doesn't help because `apply` still processes targets sequentially and fails on the same commit
- The only workaround is `--reset <id>` which rebuilds the target from scratch (requires force-push)

### Proposed improvement

**Option A: Detect empty cherry-pick and auto-skip**

When a cherry-pick results in an empty commit (after conflict resolution), dispatch should:
1. Detect the "nothing to commit" state
2. Record the skipped commit SHA in dispatch metadata (e.g. `branch.<name>.dispatchskipped`)
3. On subsequent `apply` runs, skip commits in the skip-list
4. Report skipped commits in `status`:
   ```
   9   task-9   in sync (1 skipped)
   ```

**Option B: Content-aware "behind" detection**

Instead of relying solely on `git cherry` (patch-id), also check if the target branch's file content already includes the changes from the "behind" commits:
1. For each "behind" commit, get its file diff
2. Check if those changes already exist in the target (content comparison, not SHA)
3. If the target already has the content, mark the commit as "absorbed" rather than "behind"

**Option C: Skip-list flag for apply**

Add `git dispatch apply --skip-commit <sha>` to explicitly tell dispatch to ignore specific commits for a target:
```bash
git dispatch apply --skip-commit 8d761fa510
```
This records the skip and future `apply` runs respect it.

**Recommended**: Option A (auto-detect) combined with Option C (manual override). Option B is more robust but significantly more complex.

---

## Hurdle 9: `status` is painfully slow on large repos

### What happened

Running `git dispatch status` on a monorepo with a long commit history takes 10+ seconds. With 9 target IDs (some not yet created), each `status` call is noticeably laggy, breaking the feedback loop.

### Root cause

The status command has multiple O(n) passes over the full `base..source` commit range, plus per-target expensive operations:

1. **Full commit scan for Target-Id trailers** (lines 1521-1528): Iterates every commit in `base..source` with individual `git log -1 --format="%(trailers:...)"` calls. On a long-lived branch with hundreds of commits from merged master, this is extremely slow.

2. **`git cherry` per target** (lines 1581, 1625): Runs twice per existing target - once source-to-target, once target-to-source. Each `git cherry` computes patch-ids for the full commit range.

3. **`_commit_semantically_in_branch` per candidate** (lines 1609, 1655): For each candidate commit, this does another expensive operation. Called inside a loop.

4. **`_target_content_diverged`** (line 1686): Runs `git diff` on all files touched by that target's commits. File collection involves `git diff-tree` per commit.

5. **Untracked commit scan** (lines 1665-1674): Per-target loop over `parent..branch` with individual `git log -1` for trailer extraction.

6. **`_get_open_prs`** (line 1538): GitHub API call on every status invocation.

7. **Sequential processing**: All targets are processed one at a time. No parallelism.

### Proposed improvements

**Quick wins (Low complexity):**

- **Cache Target-Id extraction**: The `base..source` commit scan (step 1) already collects all commit hashes and their Target-Ids. Reuse this data instead of re-extracting trailers in later loops.
- **Batch trailer extraction**: Replace individual `git log -1 --format="%(trailers:...)"` calls with a single `git log --format="%H %(trailers:key=Target-Id,valueonly)" base..source` pass.
- **Cache GitHub PR data**: Store PR info in a temp file with TTL (e.g. 60s). Skip the API call if cache is fresh. Or add `--no-pr` flag to skip entirely.
- **Skip non-existent branches early**: For "not created" targets, skip all expensive checks (cherry, semantic, divergence). Currently this is already done (line 1560-1563) but the trailer scan still runs for all commits upfront.

**Medium wins:**

- **Parallelize per-target checks**: Run `git cherry` and divergence checks for each target in parallel (background subshells). Collect results after all complete.
- **Fast-path for clean targets**: If `git merge-base source target == target` (target is ancestor of source), it's trivially "behind source" with an exact count from `git rev-list --count target..source`. No cherry/semantic checks needed.
- **Replace `git cherry` with `git rev-list --cherry-pick`**: The `--cherry-pick` flag is a built-in equivalent that may be faster for certain topologies.

**Bigger wins (Higher complexity):**

- **Incremental status cache**: Store the last-known status per target (behind/ahead counts, commit SHAs). On re-run, only recompute if the source or target HEAD changed since last check.
- **`--quick` flag**: Show only branch existence and simple ahead/behind counts (from `git rev-list --left-right --count`). Skip semantic checks, divergence detection, stale detection. Good for quick orientation.

---

## Task: README rewrite and source-only workflow documentation

### Context

The current README and workflow documentation assume bidirectional sync (source <-> target). Real-world usage revealed that bidirectional cherry-picking causes endless conflict loops (see Hurdle 8). The recommended workflow is now one-way: source -> targets.

### Core value proposition

**"Atomic commits, logical PRs."** You code with atomic commits on a single source branch. Target-Id trailers group them into focused PRs for review. Your reviewer sees clean, atomic commit history per PR. You don't manage N separate branches.

This is what differentiates git-dispatch from ghstack/spr (1 commit = 1 PR) and Graphite (stacked, force-push cascade).

### Source-only workflow to document

```
1. Work on source branch with Target-Id trailers
2. git dispatch apply           -> create/update target branches
3. git dispatch push --from all -> push targets, open PRs
4. Continue working on source   -> more commits with Target-Id
5. git dispatch apply           -> update targets
6. git dispatch push --from all -> push updates
7. Need to fix task-9 at task-16? Commit fix on source with Target-Id=9, re-apply.
```

Rules:
- NEVER commit directly on target branches
- ALL edits happen on source
- Targets are derived artifacts, like build output

### Test worktrees for targets

Targets are for PRs, not for testing. To test a target's code in isolation:

```bash
git dispatch test --to 9    # creates a temp worktree for task-9
# run tests there, read-only
git dispatch test --cleanup  # removes all test worktrees
```

### The dependency problem

In independent mode, task-10 branches from master. If task-10's code depends on task-9 (e.g., uses a hook that task-9 introduced), the test worktree would fail.

**Proposed: `git dispatch test` with cumulative mode**

```bash
git dispatch test --to 10                # independent: only task-10 on master
git dispatch test --to 10 --cumulative   # stacked: task-8 + task-9 + task-10 on master
```

Implementation for `--cumulative`:
1. Create temp branch from base
2. Cherry-pick all target commits up to and including the requested target (ordered by Target-Id)
3. Create worktree from this branch
4. Mark as read-only / test-only

This gives the best of both worlds:
- PRs are independent (no force-push cascade when task-8 merges)
- Test worktrees are cumulative (CI-complete, all dependencies present)

The cumulative test branch is ephemeral - never pushed, never reviewed. It exists only for local testing.

### README rewrite outline

1. **Tagline**: "Atomic commits, logical PRs"
2. **Problem**: coding on one branch, need grouped PRs. Existing tools: 1 commit = 1 PR or force-push cascades
3. **Solution**: Target-Id groups commits. Independent mode = no force-push. Source is single source of truth
4. **Quick Start**: init, commit with trailers, apply, push
5. **Workflow**: source-only, one-way dispatch, test worktrees
6. **Commands**: current reference (simplified)
7. **Modes**: independent (default, for PRs) vs cumulative test worktrees (for testing)
8. **Drop/demote**: bidirectional sync docs (cherry-pick --from target --to source) to "advanced/escape hatch" section

---

## Summary of proposed improvements

| # | Area | Improvement | Complexity |
|---|------|------------|------------|
| 1 | `status` | Report untracked commits on task branches | Low |
| 2 | `sync` | Cherry-pick fallback when merge commits present | Medium |
| 3 | Skill/hooks | Auto-detect and validate trailer format convention | Low |
| 4 | `push` | Support short branch names (task suffix matching) | Low |
| 5 | `restack` | Skip merged parents, use `--onto` rebase | Medium |
| 6 | `split` | Auto-rebase child when parent is merged | Medium |
| 7 | `apply` | Auto-regenerate shared auto-gen files after cherry-pick | Medium |
| 8 | `apply` | Detect empty cherry-pick results and stop re-applying | Medium |
| 9 | `status` | Batch trailer extraction, parallel target checks, caching | Low-High |
| 10 | README | Rewrite with "atomic commits, logical PRs" positioning | Low |
| 11 | workflow | Document source-only one-way workflow as primary | Low |
| 12 | `test` | New command: cumulative test worktrees for local testing | Medium |
