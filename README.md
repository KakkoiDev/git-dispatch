# git-dispatch

**Stacked PRs without the stack.**

Multi-commit grouped PRs. Code on one source branch, group commits by `Dispatch-Target-Id`, apply into independent target branches for focused PRs. Integration test with `checkout`. No force-push. No restack. No cascade. Ever.

Unlike ghstack/spr (1 commit = 1 PR), git-dispatch supports N commits = 1 PR.

## Problem

You code the whole feature on one branch, then need focused PRs for review. Every stacked PR tool today (Graphite, ghstack, spr) stacks branches on top of each other. When a parent PR merges, all children must be rebased and force-pushed. Review context is destroyed.

## Solution

Don't stack. Each target branches independently from base, carrying only its own commits. When any PR merges, sibling targets are unaffected. No rebase. No force-push.

"But CI needs the combined code to pass." That's what `checkout <N>` is for. It creates an ephemeral integration branch combining targets 1..N for testing, without permanently stacking the branches.

Tag commits with `Dispatch-Target-Id` trailers to group them. `apply` creates target branches. `checkout` tests them together. `checkin` brings fixes back.

## Quick Start

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/KakkoiDev/git-dispatch/master/install-remote.sh | bash

# Init on your source branch (interactive - prompts for base and pattern)
git checkout -b feature/auth master
git dispatch init

# Or with explicit flags
git dispatch init --base origin/master --target-pattern "feature/auth-{id}"

# Code with dispatch commit
git dispatch commit "Add user model"        --target 1
git dispatch commit "Add auth middleware"   --target 2
git dispatch commit "Add login endpoint"    --target 2
git dispatch commit "Add validation"        --target 3

# Create target branches and push
git dispatch apply
git dispatch push all
# feature/auth-1  (1 commit)
# feature/auth-2  (2 commits)
# feature/auth-3  (1 commit)
```

## Commands

| Command | Description |
|---------|-------------|
| `git dispatch init [--base <branch>] [--target-pattern <pattern>]` | Configure dispatch (prompts when args omitted) |
| `git dispatch commit "message" [--target N] [--source-keep]` | Commit with auto-managed trailers |
| `git dispatch sync [--dry-run] [--resolve]` | Merge base into source and existing targets |
| `git dispatch apply [<N>] [--dry-run] [--resolve] [--force] [--yes]` | Cherry-pick source commits to targets |
| `git dispatch apply reset <N\|all> [--yes]` | Regenerate one or all targets from scratch |
| `git dispatch checkout <N> [--dry-run] [--resolve\|--continue]` | Integration branch with targets 1..N |
| `git dispatch checkout source` | Return to source branch |
| `git dispatch checkout clear [--force]` | Remove checkout branch (--force discards unpicked commits) |
| `git dispatch checkin [<N>] [--dry-run] [--resolve\|--continue]` | Cherry-pick checkout commits back to source |
| `git dispatch retarget --target <id> --to-target <id> [--dry-run] [--apply]` | Move all commits from one target to another |
| `git dispatch retarget --commit <hash> --to-target <id> [--dry-run] [--apply]` | Move a single commit to another target |
| `git dispatch push <all\|source\|N> [--dry-run] [--force]` | Push branches to origin (--force uses force-with-lease) |
| `git dispatch delete <N\|all\|--prune> [--dry-run] [--yes]` | Delete target branches |
| `git dispatch status` | Show sync state, divergence, merged targets |
| `git dispatch continue` | Resume after conflict resolution |
| `git dispatch abort` | Cancel in-progress operation, clean up |
| `git dispatch reset [--yes]` | Delete targets and config |

## Trailers

Use `dispatch commit` to tag commits with trailers:

```bash
git dispatch commit "Add feature" --target 3
git dispatch commit "Update CI config" --target all
git dispatch commit "Regen swagger" --target 3 --source-keep
```

| Value | Meaning |
|-------|---------|
| Numeric (1, 2, 1.5) | Assigns commit to target N. Decimals for mid-stack insertion. |
| `all` | Included in every target during apply. For shared infra, CI configs. |
| `--source-keep` | Auto-resolve conflicts with incoming version. For generated files. |

On checkout branches, `--target` is optional - auto-detected from branch name.

## Workflow: Develop and Create PRs

```bash
# 1. Init (interactive or with flags)
git dispatch init
# or: git dispatch init --base origin/master --target-pattern "feat/auth-{id}"

# 2. Code with dispatch commit
git dispatch commit "Add user model"      --target 1
git dispatch commit "Add auth middleware"  --target 2
git dispatch commit "Add login endpoint"   --target 2

# 3. Apply and push
git dispatch apply
git dispatch push all
```

## Workflow: Integration Testing

Target branches in independent mode may not compile alone (missing dependencies from other targets). Checkout creates an integration branch combining targets 1..N.

```bash
git dispatch checkout 3           # branch with targets 1..3 + "all" commits
pnpm test                         # run integration tests
git dispatch checkout source      # back to source
git dispatch checkout clear       # remove test branch
```

## Workflow: Fix During Integration

```bash
git dispatch checkout 3
# fix bug
git dispatch commit "Fix auth race"       # auto-detects target from checkout branch
git dispatch checkin              # cherry-picks fix to source
git dispatch checkout source
git dispatch apply                # propagates to target-2
git dispatch push 2
git dispatch checkout clear
```

## Workflow: Generated Files (OpenAPI, Protobuf)

Generated files need the combined codebase. Two approaches:

### Regen on source (for all targets)

```bash
pnpm openapi
git dispatch commit "regen" --target all --source-keep
git dispatch apply               # Source-Keep forces through per-target
```

### Regen for specific failing target

```bash
git dispatch checkout 3
pnpm openapi                     # correct swagger for targets 1..3
git dispatch commit "regen swagger" --source-keep    # auto-detects target 3
git dispatch checkin             # Source-Keep auto-resolves conflict
git dispatch checkout source
git dispatch apply
git dispatch push 3
```

## Workflow: Retarget Commits (Change Target-Id)

When a commit was assigned to the wrong target (e.g., reviewer says "this belongs in task-15, not task-8"), use `retarget` instead of interactive rebase:

```bash
git dispatch retarget --target 8 --to-target 15    # moves all commits from target 8 to 15
git dispatch retarget --commit abc123 --to-target 15  # moves a single commit
git dispatch apply                                  # updates both targets
```

No history rewrite. No force-push. The original commit stays on source, paired with a revert (on old target) and re-apply (on new target).

## Workflow: Review Feedback

```bash
git dispatch commit "Rename field per review" --target 2
git dispatch apply
git dispatch push 2
```

## Workflow: Keep Up With Main

`apply --base` merges base into source AND existing targets. No force-push needed.

```bash
git dispatch apply --base        # merges base into source and all existing targets
git dispatch push all
```

New targets (not yet created) are still cherry-picked from scratch. Existing targets get a merge commit from base, preserving their history and open PRs.

## Workflow: Abort a Stuck Operation

```bash
git dispatch abort               # cleans up everything, returns to source
```

Handles cherry-pick conflicts, merge conflicts, checkout branches, and dispatch temp worktrees.

## Apply Options

| Want | Command |
|------|---------|
| Create new targets + update all | `git dispatch apply` |
| Update one existing target | `git dispatch apply <N>` |
| Regenerate one target from scratch | `git dispatch apply reset <N>` |
| Regenerate all targets from scratch | `git dispatch apply reset all` |
| Merge base into source and targets | `git dispatch apply --base` |

## Branch Naming

`<target-pattern>` where `{id}` is replaced by `Dispatch-Target-Id`.

| Pattern | Id | Branch |
|---------|----|--------|
| `feature/auth-{id}` | `3` | `feature/auth-3` |
| `feat/po-task-{id}` | `1.5` | `feat/po-task-1.5` |

Checkout branches: `dispatch-checkout/<source>/<N>`

## Flags

| Flag | Meaning |
|------|---------|
| `--dry-run` | Show plan, make no changes |
| `--resolve`, `--continue` | Leave conflict active for manual resolution |
| `--yes` | Skip confirmation prompts (required for scripting/CI) |
| `--all` | Include merged targets in sync/apply (skipped by default) |
| `--force` | Safety override: `apply` rebuilds stale, `push` force-pushes, `checkout clear` discards |

## Conflict Handling

All commands show conflicted files and diff on failure.

- **Default**: aborts cleanly, no changes made
- **`--resolve`/`--continue`**: leaves conflict active in worktree for manual resolution
- **`git dispatch abort`**: cancel operation, clean up, return to source
- **`Dispatch-Source-Keep`**: auto-resolves with `--strategy-option theirs`
- **`git dispatch continue`**: checks for pending resolutions

## Merged Target Detection

When a target's PR is merged (regular or squash-merge), `status` shows it as `merged`. `sync` and `apply` skip merged targets automatically since there's no point updating branches already in base.

- `--all` overrides the skip: `git dispatch sync --all` or `git dispatch apply --all`
- Merged detection is content-based (compares file content against base), not GitHub API

### Clean up merged targets

```bash
git dispatch delete 3             # delete specific target
git dispatch delete all           # delete all targets
git dispatch delete --prune       # delete targets whose tid no longer exists in source
```

### Revert recovery

If a merged PR gets reverted on base, the target is no longer detected as merged. Normal `apply` resumes working on it. If the target branch is stale, regenerate it:

```bash
git dispatch apply reset 3        # regenerate target from scratch
git dispatch apply 3              # now works normally
git dispatch push 3
```

## Divergence Detection

`status` tags targets:
- `(DIVERGED)` - target has commits not traceable to source. Someone pushed directly to the target.
- `(cosmetic)` - same logical changes, different SHAs or base drift. Safe to ignore.

Base drift (source behind master) no longer causes false DIVERGED. When all target commits trace back to source commits by subject, the difference is recognized as cosmetic.

Fix real divergence: use `checkout`/`checkin` flow to reconcile, then `apply`.
Fix base drift: `git dispatch sync` to merge master into source and targets.

## Data Flow

Each command flows in one direction:

| Command | Direction | What it does |
|---------|-----------|--------------|
| `sync` | base -> source + targets | Merge master into source and existing targets |
| `apply` | source -> targets | Cherry-pick new commits to target branches |
| `checkin` | checkout -> source | Cherry-pick fixes from checkout back to source |
| `retarget` | source (in-place) | Revert + re-apply commits with new target id |

## apply vs apply reset

`apply <N>` is **incremental**: cherry-picks only new commits not yet on the target. Push stays fast-forward.

`apply reset <N>` **recreates from scratch**: deletes the target and replays all commits. Requires `push --force` afterward since history is rewritten.

### The force-push trap

1. Source is behind master (base drift)
2. `apply` creates targets with different SHAs (cosmetic divergence)
3. Later `apply <N>` can't match SHAs, re-applies everything, conflicts
4. Only fix: `apply reset <N>` -> needs `push --force`

### How to avoid it

**Always `sync` before `apply` when source is behind master.**

```bash
git dispatch sync            # merge master into source + existing targets
git dispatch apply           # targets created with stable SHAs
# ... later, add a commit ...
git dispatch apply 1         # incremental, works, no conflicts
git dispatch push 1          # fast-forward, no --force needed
```

## Stale Target Detection

When a commit's `Dispatch-Target-Id` is changed on source (e.g., during interactive rebase), `apply` detects stale targets via patch-id matching:

```bash
git dispatch apply              # reports stale targets
git dispatch apply --force      # rebuilds them
```

Preferred alternative: use `retarget` instead of interactive rebase to avoid stale targets entirely:

```bash
git dispatch retarget --target 8 --to-target 15   # no history rewrite, no force-push needed
git dispatch apply
```

## Config

Config is branch-scoped (per-source-branch) to support multiple worktrees:

| Key | Description |
|-----|-------------|
| `branch.<source>.dispatchbase` | Base branch |
| `branch.<source>.dispatchtargetpattern` | Target branch pattern (must include `{id}`) |
| `branch.<source>.dispatchcheckoutbranch` | Active checkout branch |
| `branch.<target>.dispatchsource` | Source branch reference |

When multiple worktrees are detected, `extensions.worktreeConfig` is enabled automatically.

## AI Integration

### Universal (AGENTS.md)

Works with Cursor, Windsurf, Codex, Aider:

```bash
cp AGENTS.md /path/to/project/
```

### Claude Code (skill + agent)

```bash
mkdir -p ~/.claude/skills/git-dispatch ~/.claude/agents
cp SKILL.md ~/.claude/skills/git-dispatch/SKILL.md
cp AGENTS.md ~/.claude/agents/git-dispatch.md
```

### Or use the installer

```bash
bash install.sh --ai
```

## Installation

```bash
# Remote install
curl -fsSL https://raw.githubusercontent.com/KakkoiDev/git-dispatch/master/install-remote.sh | bash

# Local install
git clone git@github.com:KakkoiDev/git-dispatch.git && cd git-dispatch
bash install.sh
```

## Testing

```bash
bash test.sh    # 365 tests
```

## Requirements

- Git 2.x+
- Bash 3.2+ (macOS compatible)

## License

MIT
