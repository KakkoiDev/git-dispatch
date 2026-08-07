# Bug: Dispatch config collides across git worktrees

## Summary

`git dispatch` stores all configuration in `git config --local`, which maps to the shared `.git/config` file. When multiple worktrees exist for the same repository, dispatch config from one worktree leaks into all others. This blocks `git dispatch init` on a second worktree and causes `git dispatch reset` to destroy config from other active worktrees.

## Root cause

`git config --local` reads/writes `$(git rev-parse --git-common-dir)/config`, which is shared across all worktrees. Git distinguishes two directories:

- `--git-dir`: per-worktree (e.g. `.git/worktrees/<name>/`)
- `--git-common-dir`: shared (e.g. `.git/`)

Dispatch uses global config keys (`dispatch.base`, `dispatch.targetPattern`, `dispatch.mode`) that have no branch or worktree qualifier, so they collide when two worktrees both run dispatch.

## Reproduction

```bash
# Main worktree: init dispatch for project A
cd ~/Code/repo
git checkout -b feature-a
git dispatch init --base origin/master --target-pattern "user/feat-a/task-{id}"
# All good

# Second worktree: init dispatch for project B
git worktree add ../repo-wt feature-b
cd ../repo-wt
git dispatch init --base origin/master --target-pattern "user/feat-b/task-{id}"
# ERROR: "Dispatch already configured" - blocked by feature-a's config
```

## Impact

1. **Cannot run dispatch in parallel worktrees.** The second `init` sees the first worktree's config and refuses. `--force` overwrites project A's config, breaking it silently.

2. **`reset` in one worktree destroys all dispatch config.** Since `dispatch.base`, `dispatch.targetPattern`, and `dispatch.mode` are global keys, `git dispatch reset` in worktree B wipes worktree A's settings.

3. **`branch.*.dispatchtargets` keys accumulate across projects.** These are keyed by branch name so they don't directly collide, but `git dispatch reset` iterates the targets and may delete branches belonging to another worktree's dispatch session.

4. **`core.hooksPath` is shared.** Installing hooks in one worktree sets `core.hooksPath` globally, affecting all worktrees. Resetting one worktree removes the hooks for all.

## Affected config keys

| Key | Scope | Collision risk |
|-----|-------|---------------|
| `dispatch.base` | Global (no qualifier) | Direct collision |
| `dispatch.targetPattern` | Global (no qualifier) | Direct collision |
| `dispatch.mode` | Global (no qualifier) | Direct collision |
| `dispatch.checkoutBranch` | Global (no qualifier) | Direct collision |
| `branch.*.dispatchtargets` | Per-branch name | Indirect (reset deletes all) |
| `branch.*.dispatchsource` | Per-branch name | Indirect (reset deletes all) |
| `core.hooksPath` | Global | Direct collision |

## Proposed fix

Use `git config --worktree` instead of `git config --local` for per-session dispatch config. This stores config in `$(git rev-parse --git-dir)/config.worktree` (per-worktree file) instead of the shared `.git/config`.

### Prerequisites

The repo must have `extensions.worktreeConfig = true` enabled. Without it, `git config --worktree` errors:

```
fatal: --worktree cannot be used with multiple working trees unless the config
extension worktreeConfig is enabled.
```

Dispatch should enable this automatically during `init` when it detects worktrees:

```bash
git config --local extensions.worktreeConfig true
```

### Migration path

1. During `init`, detect if other worktrees exist (`git worktree list --porcelain`).
2. If yes, enable `extensions.worktreeConfig` and use `--worktree` scope for dispatch-specific keys.
3. For single-worktree repos, `--local` is fine (no collision possible).
4. `reset` should only remove config from the current worktree scope.

### Hooks

`core.hooksPath` is trickier. Options:
- Use `--worktree` scope for `core.hooksPath` too (requires worktreeConfig).
- Install hooks into the per-worktree hooks directory (`$(git rev-parse --git-dir)/hooks/`) instead of the common dir. This avoids `core.hooksPath` entirely for worktree setups.

## Workaround (current)

Manually clear stale dispatch config before init:

```bash
git config --local --unset dispatch.base 2>/dev/null
git config --local --unset dispatch.targetPattern 2>/dev/null
git config --local --unset dispatch.mode 2>/dev/null
git dispatch init --base origin/master --target-pattern "..."
```

This is destructive to any other active dispatch session in the same repo.

## Observed in

### Incident 1: init blocked

Repo with tmux-worktree setup. Source branch `fix/none-28154-add-transaction-generation` in worktree could not init because config from `cyril/poc/purchase-order-transaction-registration` (main worktree) was still present.

### Incident 2: apply used wrong pattern (2026-03-18)

Worktree `cyril/poc/purchase-order-transaction-registration` ran `git dispatch apply`. The `dispatch.targetpattern` in shared config was `fix/none-28154-large-seed-task-{id}` (from the `fix/none-28154-add-transaction-generation` worktree). Apply silently created 8 target branches with the wrong names:

```
fix/none-28154-large-seed-task-8     (should have been something like feat/po-tx-task-8)
fix/none-28154-large-seed-task-9
fix/none-28154-large-seed-task-11
fix/none-28154-large-seed-task-12
fix/none-28154-large-seed-task-13
fix/none-28154-large-seed-task-13.1
fix/none-28154-large-seed-task-14
fix/none-28154-large-seed-task-15
```

No error or warning was shown. The wrong pattern was only noticed after `git dispatch status` output.

**Key difference from incident 1:** This time config wasn't blocking init - it was silently used by apply, producing wrong branch names. This is arguably worse since the damage is silent and requires manual cleanup (deleting 8 branches + re-applying).
