# git-dispatch Pitfalls

## Untracked commits on task branches

When commits are made directly on a task branch without a `Task-Id` trailer (e.g., addressing PR review feedback), `git dispatch sync` does not see them. `git dispatch status` reports "in sync" even though the source branch is missing those commits.

### Why sync fails in this case

`git dispatch sync` attempts to rebase the task branch to amend Task-Id trailers onto untracked commits. If the task branch has **merge commits from base** (e.g., `git merge master` to resolve conflicts), the rebase flattens those merges and causes conflicts.

The error looks like:
```
Error: Rebase failed while amending trailer on <sha> in <task-branch>. Resolve manually.
```

### Manual recovery: cherry-pick to source

When sync fails, cherry-pick the untracked commits onto the source branch manually:

```bash
# 1. Identify commits on task branch not on source
git log --oneline <task-branch> ^<source-branch> -- <relevant-path>

# 2. Filter out merge commits from base — only pick the actual review fixes

# 3. Cherry-pick each onto source with trailers
git checkout <source-branch>
git cherry-pick <sha> --no-commit
git commit -m "$(git log -1 --format=%B <sha>)" \
  --trailer "Task-Id=task-X" \
  --trailer "Task-Order=X"

# 4. Repeat for each commit, then split or sync as usual
```

### Prevention

To avoid this situation entirely:

1. **Always commit on source, not on task branches** — source is the single source of truth
2. **Always include Task-Id trailers** — even for review-fix commits, so sync can track them
3. **Avoid merging base into task branches** — merge commits on task branches block sync's rebase. If you must merge base, use `git dispatch resolve` to convert the merge commit first

## Trailer convention mismatch

`Task-Id` and `Task-Order` use **different formats**. The agent must check existing trailers on the source branch before committing — never guess.

### How to check

```bash
git log --format="%s%n  Task-Id: %(trailers:key=Task-Id,valueonly)  Task-Order: %(trailers:key=Task-Order,valueonly)" <base>..HEAD
```

### Common conventions

| Trailer | Format | Example |
|---------|--------|---------|
| Task-Id | Prefixed string | `task-6.2` |
| Task-Order | Numeric | `6.2` |

The prefix in Task-Id (e.g., `task-`) varies per project. Task-Order is always numeric.

### The pitfall

An agent unfamiliar with the project might use `6.2` for Task-Id instead of `task-6.2`, or add a prefix to Task-Order. Either mismatch causes split to create branches with wrong names or wrong stacking order.

**Rule: always inspect existing trailers before the first commit.**
