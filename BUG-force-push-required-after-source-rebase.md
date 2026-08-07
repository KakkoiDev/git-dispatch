# Bug: Source rebase forces target force-push (breaking no-force-push workflow)

## Summary

When the source branch is rebased (e.g., to add trailers, flatten merge commits, or rebase onto updated base), `git dispatch apply` regenerates all target branches from scratch with new commit SHAs. The resulting targets diverge from their remote counterparts, making `git dispatch push <id>` fail with a non-fast-forward error. The only option dispatch offers is `--force`, which violates the no-force-push workflow the tool is designed to support.

## What happened

1. Source branch had 33 commits without `Dispatch-Target-Id` trailers
2. Targets (task-8 through task-15) were already created and pushed to remote
3. Source was rebased to add trailers to all commits (`git rebase --exec script origin/master`)
4. Rebase also flattened 2 merge commits, changing all SHAs
5. `git dispatch apply` regenerated all 8 targets from scratch (new SHAs)
6. `git dispatch push 9` failed: non-fast-forward
7. No way to push without `--force`

## Root cause

`git dispatch apply` does not track the relationship between source commit SHAs and target commit SHAs. When source SHAs change (rebase), dispatch treats all commits as new and rebuilds targets from base, producing entirely new target histories that diverge from remote.

The tool's core promise is "multi-commit PRs without force-push". But any source rebase breaks this promise for all existing targets.

## Why this matters

- PRs on remote targets have review history, CI status, comments
- Force-pushing targets loses the commit-by-commit review trail
- Reviewers see a completely new diff instead of incremental changes
- CI re-runs from scratch

## Workaround used

Instead of force-pushing, we:

1. Reset local target to match remote: `git branch -f <target> origin/<target>`
2. Cherry-picked only the genuinely new commit directly: `git checkout <target> && git cherry-pick <sha>`
3. Pushed (fast-forward)

This bypasses dispatch entirely for the push, but preserves the remote history.

## When this workaround fails

If the source rebase changed the CONTENT of existing commits (not just adding trailers), the remote target and source will have different file content. In that case:
- Direct cherry-pick of new commits works if they don't touch files modified by the rebased commits
- If they DO overlap, you get conflicts from the content mismatch
- Force-push becomes the only option

## Suggested fix: `dispatch apply --incremental`

Add a mode that:
1. Compares source commits to what's already on the target (by commit message or patch-id, not SHA)
2. Only cherry-picks commits that are genuinely new (not just rewritten versions of existing ones)
3. Preserves the existing target history

This would let users rebase source freely without invalidating target branches.

## Alternative: `dispatch push --rebase-remote`

Instead of force-pushing, dispatch could:
1. Fetch the remote target
2. Identify commits on remote that aren't on local (review fixes, etc.)
3. Cherry-pick those onto the new local target
4. Push as fast-forward from the remote's perspective

## Prevention

To avoid this entirely, never rebase source after targets have been pushed. Instead:
- Add trailers at commit time (use the dispatch hook)
- Use `git dispatch merge --from base --to source` instead of `git rebase origin/master`
- If you must rebase, accept that force-push is required for all targets

## Related files

- `BUG-apply-continue-drops-remaining-commits.md` - other apply bugs found in same session
- `ISSUE-target-id-reassignment.md` - similar stale-target tracking issue
