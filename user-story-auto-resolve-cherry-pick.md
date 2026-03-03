# User Story: Auto-resolve generated file conflicts in cherry-pick

## Problem

When cherry-picking between source and target branches (via `cherry-pick` or `_cherry_pick_with_trailers`), generated files (OpenAPI specs, API clients) cause conflicts because each branch has a different derived version. The `apply` command already had a `--theirs` retry pattern for fresh target creation, but `cherry-pick` and `_cherry_pick_with_trailers` did not.

This meant:
- `git dispatch cherry-pick --from <id> --to source` would fail on generated file conflicts
- The failure left orphaned state on worktrees
- Users had to manually resolve trivially-resolvable conflicts

## Solution

### 1. --theirs retry in cherry-pick functions

When a cherry-pick fails and `dispatch.postApply` is configured, abort and retry with `--strategy-option theirs` before falling through to conflict handling. The postApply config signals that the project has generated files that will be regenerated after apply.

Affected functions:
- `cherry_pick_into` - used by `apply` for updating existing targets
- `_cherry_pick_with_trailers` - used by `cherry-pick` command (both matching and non-matching tid paths)

### 2. Worktree-aware _run_post_apply

`_run_post_apply` now accepts an optional third parameter for worktree path, using `git -C` and `cd` for cross-worktree operation.

### 3. resolve_source in cmd_apply

`cmd_apply` now uses `resolve_source` instead of `current_branch`, allowing it to work when invoked from a target branch (it resolves back to the source via `dispatchsource` config).

### 4. Base-ancestor skip in cmd_apply

`cmd_apply` now skips commits that are ancestors of the base branch, matching the filter already present in `cherry-pick`. This prevents processing commits that were already integrated into base.

## Acceptance Criteria

- cherry-pick auto-resolves with --theirs when postApply is configured
- _cherry_pick_with_trailers auto-resolves in both tid paths
- _run_post_apply works with worktree path argument
- apply resolves source when run from a target branch
- apply skips base-ancestor commits
- All existing tests pass
- New tests cover each behavior
