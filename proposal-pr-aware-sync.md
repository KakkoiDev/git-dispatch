# Proposal: PR-Aware Sync Strategy

## Problem

When task branches have open PRs with active reviews, `git dispatch` operations that rewrite history (rebase, re-split) cause:

- Force push required, which resets PR diff views
- Review comment threads lose their anchor commits
- Reviewer confusion when the commit history changes under them

Currently, the documentation suggests "rebase source on master, then re-split" as the way to bring source up to date. This is only safe **before** PRs are opened. Once a PR is under review, it destroys the review context.

## Observed Scenario

1. Source branch has 15 task branches split from it
2. Task-7 PR is opened and under review
3. Reviewer finds code using removed imports (source is behind master)
4. Fix is committed directly on task-7 branch
5. Need to sync fix back to source and update source with master
6. `git rebase origin/master` on source rewrites all 30 commits
7. Re-splitting would force-push task-7, losing review comments
8. Aborting rebase via `git reflog`, using `git merge` instead works cleanly

## Proposed Feature: `--pr-aware` mode

### Detection

`git dispatch` should detect open PRs for task branches:

```bash
# Check if any task branch has an open PR
gh pr list --head <task-branch> --state open --json number,url
```

Store PR state in dispatch metadata:

```
branch.<task-branch>.dispatchpr = <pr-number>
```

### Behavior Changes

When open PRs are detected:

| Operation | Current Behavior | PR-Aware Behavior |
|-----------|-----------------|-------------------|
| Source update | Rebase on master | **Merge** master into source |
| Re-split | Recreates all task branches | **Refuse** for branches with open PRs. Suggest sync instead |
| Sync (task to source) | Cherry-pick | Cherry-pick (unchanged) |
| Sync (source to task) | Cherry-pick | Cherry-pick (unchanged) |
| Push | Normal push | Normal push (no force needed since no rewrite) |

### New Commands / Flags

```bash
# Check PR state for all task branches
git dispatch pr-status

# Update source with master using merge (safe for open PRs)
git dispatch update-base [--merge|--rebase]
# Default: --merge when open PRs detected, --rebase otherwise

# Split with PR awareness
git dispatch split --pr-aware
# Skips branches with open PRs, only creates/updates branches without PRs
```

### Workflow: Sync After PR Review Feedback

```bash
# 1. Fix on task branch (where the PR review happened)
git checkout task-7
# ... make fix ...
git commit -m "fix: address review feedback" --trailer "Task-Id=7"
git push

# 2. Sync fix back to source
git dispatch sync source task-7    # cherry-picks fix to source

# 3. Update source with master (merge, not rebase)
git checkout source
git merge master

# 4. Source now has: original work + review fixes + master changes
# No force push needed anywhere
```

### Edge Case: Merge Commits in Sync

When task branches merge master (e.g., from GitHub UI "Update branch"), sync tries to cherry-pick those master commits back to source. This causes conflicts with unrelated files.

**Fix:** `git dispatch sync` should:
1. Detect merge commits on task branches
2. Skip commits whose parent is from base branch (not task-owned)
3. Only cherry-pick commits that were authored on the task branch

Current `resolve` command partially handles this, but sync should filter automatically.

### Implementation Steps

1. Add `git dispatch pr-status` command (query `gh pr list` for each task branch)
2. Cache PR numbers in git config metadata
3. Add `git dispatch update-base` command with merge/rebase modes
4. Modify `split` to warn/refuse when open PRs exist
5. Modify `sync` to skip merge-sourced commits automatically
6. Update AGENTS.md and SKILL.md documentation

## Priority

Medium-high. This is a real workflow pain point when working with reviewers. The merge-commit filtering in sync (step 5) is the most impactful fix since it caused the initial sync failure that led to the rebase attempt.
