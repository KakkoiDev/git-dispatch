# Proposal: Auto cherry-pick untracked task branch commits

## Problem

When commits are made directly on a task branch without Task-Id trailers, `git dispatch sync` tries to rebase the task branch to amend trailers. This fails when the task branch has merge commits from base (e.g., `git merge master`), because rebase flattens merges and causes conflicts.

## Proposed solution

Replace the rebase-and-amend approach with cherry-pick when untracked commits are detected on a task branch.

## Algorithm

```
sync(source, task_branch):
  # 1. Find commits on task branch not on source
  candidates = git log --oneline task_branch ^source -- <paths>

  # 2. Separate merge commits from regular commits
  merge_commits = [c for c in candidates if c.parent_count > 1]
  regular_commits = [c for c in candidates if c.parent_count == 1]

  # 3. Filter out base merge commits (parent is on base branch)
  #    These are just "git merge master" — not actual work
  untracked = [c for c in regular_commits if not has_task_id_trailer(c)]

  if not untracked:
    return  # nothing to do

  # 4. Determine Task-Id from the task branch name
  task_id = extract_task_id(task_branch)  # e.g., "task-6.1"

  # 5. Infer Task-Order from existing trailers on source for this task
  task_order = extract_task_order(source, task_id)  # e.g., "6.1"

  # 6. Cherry-pick each untracked commit onto source
  git checkout source
  for commit in untracked (chronological order):
    git cherry-pick commit --no-commit
    git commit -m "$(original message)" \
      --trailer "Task-Id={task_id}" \
      --trailer "Task-Order={task_order}"
```

## Edge cases

### Cherry-pick conflict
If a cherry-pick conflicts, abort and report which commit failed. The user resolves manually. This is no worse than the current rebase failure, but more targeted (one specific commit vs the entire rebase).

### Task-Id format detection
The algorithm needs the Task-Id prefix convention. Detect from existing trailers on source:
```bash
git log --format="%(trailers:key=Task-Id,valueonly)" base..source | head -1
# "task-6" → prefix is "task-"
```

### Commits that should NOT be cherry-picked
- Merge commits from base (already filtered in step 2/3)
- Commits that already exist on source with different SHAs (use `git cherry` or patch-id comparison to detect duplicates)

### Duplicate detection
Use `git patch-id` to compare:
```bash
git show <task-commit> | git patch-id  # get patch-id
git log source --format=%H | while read sha; do
  git show $sha | git patch-id
done
# Skip cherry-pick if patch-id already exists on source
```

## Integration point

This should be a fallback path inside `git dispatch sync`. When the existing rebase-and-amend approach fails (or when merge commits from base are detected), switch to the cherry-pick approach automatically.

```
sync(source, task_branch):
  if has_base_merge_commits(task_branch):
    cherry_pick_untracked(source, task_branch)  # new path
  else:
    rebase_and_amend(source, task_branch)        # existing path
```

## Impact on `git dispatch status`

Currently, status only compares commits with Task-Id trailers. Untracked commits are invisible — status reports "in sync" even when the task branch has diverged.

Status should detect and report untracked commits:

```
cyril/feat/.../task-6.1
  in sync
  5 merge commit(s) from base (no action needed)
  4 untracked commit(s) (no Task-Id trailer)       ← new
```

The detection logic is the same as the sync algorithm steps 1-3: find non-merge commits on the task branch that are not on source and have no Task-Id trailer.

When untracked commits are present, status should also indicate whether auto cherry-pick is available:

```
  4 untracked commit(s) — run `git dispatch sync` to cherry-pick to source
```

Or if merge commits from base would block the rebase path:

```
  4 untracked commit(s) + merge commits from base — cherry-pick mode will be used
```

## Benefits

- No rebase over merge commits — avoids the root cause entirely
- Each cherry-pick is isolated — one conflict doesn't block the rest
- Source stays the single source of truth
- Backward compatible — only activates when merge commits are present
