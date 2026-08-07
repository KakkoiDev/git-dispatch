# Restacking after parent PR is merged

## Problem

When a parent task branch (e.g., task-6.1) gets merged to master and you create a child branch (e.g., task-6.2) stacked on top of it, the PR diff on GitHub will be massive. This happens because:

1. GitHub squash-merges PRs, creating a single new SHA on master
2. The child branch still carries the parent's original commits as ancestors
3. GitHub sees all parent commits as "new" since their SHAs don't match master's squash SHA

The PR shows hundreds of lines changed even if the child only has a 1-line fix.

## Solution

Rebase the child branch directly onto updated master, dropping the already-merged parent commits.

```bash
# 1. Fetch latest master
git fetch origin master

# 2. Checkout the child branch
git checkout <child-task-branch>

# 3. Rebase only the child's own commits onto master
#    HEAD~N where N = number of commits belonging to the child task only
git rebase --onto origin/master HEAD~1

# 4. Force push
git push --force-with-lease origin <child-task-branch>
```

### Why `--onto HEAD~1` instead of plain `rebase`

Plain `git rebase origin/master` replays ALL ancestor commits (including the parent's). These conflict with master because the content already exists (via squash merge) but with different SHAs.

`git rebase --onto origin/master HEAD~1` says: "take only the last 1 commit and put it on master". It skips the parent's commits entirely.

## When `git dispatch restack` works vs doesn't

`git dispatch restack` is designed for this scenario but can fail when:

- The parent branch has merge commits from base (same rebase-flattening issue)
- The parent branch was squash-merged, causing content conflicts during rebase

In these cases, the manual `--onto` rebase above is the reliable fallback.

## When to apply

After creating a new task branch via `git dispatch split`, always check if the parent branches have been merged to master:

```bash
# Check if remote branch still exists (deleted = merged and cleaned up)
git ls-remote origin <parent-branch>

# Or check if parent tip is ancestor of master
git fetch origin master
git merge-base --is-ancestor origin/<parent-branch> origin/master
```

If merged, rebase the new child onto master before pushing or creating a PR.

## Full workflow for post-merge child task

```bash
# 1. Make fix on source branch with trailers
git checkout <source>
git commit -m "fix: address review comment" \
  --trailer "Task-Id=task-6.2" \
  --trailer "Task-Order=6.2"

# 2. Split to create child branch (stacks on local parent)
git dispatch split <source> --base master --name <prefix>

# 3. Parent is merged - rebase child onto master directly
git fetch origin master
git checkout <prefix>/task-6.2
git stash  # if needed
git rebase --onto origin/master HEAD~1
git stash pop  # if needed

# 4. Force push the rebased branch
git push --force-with-lease origin <prefix>/task-6.2

# 5. Create PR (base = master, not parent branch)
git dispatch pr --branch <prefix>/task-6.2
```

The PR will now show only the child's own commits.
