# git-dispatch

Create target branches from a source branch. Keep them in sync bidirectionally. Two modes: independent (no force-push) or stacked (CI always passes).

## Problem

You code the whole feature on one branch, then need focused PRs for review. Manually cherry-picking and keeping branches in sync is tedious and error-prone. Stacked PR tools force-push when parents merge, destroying review context.

## Solution

Tag commits with `Target-Id` trailers. `git dispatch apply` groups them into target branches. `git dispatch cherry-pick` syncs changes both ways. Independent mode means no force-push, ever.

## Quick Start

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/KakkoiDev/git-dispatch/master/install-remote.sh | bash

# Init on your source branch
git checkout -b feature/auth master
git dispatch init --base origin/master --target-pattern "feature/auth-task-{id}"

# Code with Target-Id trailers (hook auto-carries from previous commit)
git commit -m "Add PurchaseOrder to enum"      --trailer "Target-Id=3"
git commit -m "Create GET endpoint"            --trailer "Target-Id=4"
git commit -m "Add DTOs"                       --trailer "Target-Id=4"
git commit -m "Implement validation"           --trailer "Target-Id=5"

# Create target branches
git dispatch apply
# feature/auth-task-3  (1 commit, branched from master)
# feature/auth-task-4  (2 commits, branched from master)
# feature/auth-task-5  (1 commit, branched from master)

# Push and create PRs
git dispatch push --from all
```

## Two Modes

| | Independent (default) | Stacked |
|--|----------------------|---------|
| Target branches from | base | previous target |
| After parent PR merges | Nothing to do | Rebase + force-push |
| Force-push needed | Never | After every parent merge |
| CI on targets | May fail if depends on parent | Always passes |
| Best for | Isolated tasks, different files | Sequential dependent work |

Choose at init time:

```bash
git dispatch init --base origin/master --target-pattern "feature/auth-task-{id}" --mode independent   # default mode
git dispatch init --base origin/master --target-pattern "feature/auth-task-{id}" --mode stacked
```

Independent mode eliminates the industry-wide force-push problem. Each target branches from base, carrying only its own commits. When a parent PR merges, sibling targets are unaffected.

## Commands

| Command | Description |
|---------|-------------|
| `git dispatch init` | Configure dispatch on source branch |
| `git dispatch apply` | Create/update target branches from source commits |
| `git dispatch cherry-pick --from <x> --to <y>` | Propagate commits between source and targets |
| `git dispatch rebase --from base --to source` | Rebase source onto updated base |
| `git dispatch merge --from base --to source` | Merge base into source (safe, no rewrite) |
| `git dispatch push --from <id\|all\|source>` | Push branches to origin |
| `git dispatch status` | Show mode, base, targets, sync state |
| `git dispatch reset` | Delete target branches and dispatch config |
| `git dispatch help` | Show usage guide |

All propagation commands support `--dry-run`, `--resolve`, and `--force`.

## Target-Id Trailers

Every commit needs a numeric `Target-Id` trailer:

```bash
git commit -m "Add feature" --trailer "Target-Id=3"
```

Rules:
- Numeric: integer or decimal (1, 2, 1.5, 3.1)
- Determines target branch and stack order
- Decimals enable mid-stack insertion
- Hook auto-carries from previous commit
- Hook rejects commits without Target-Id

Parse trailers (zero regex, git-native):

```bash
git log --format="%H %(trailers:key=Target-Id,valueonly)" master..source
```

## Branch Naming

`<target-pattern>` where `{id}` is replaced by `Target-Id`.

| Target Pattern | Target-Id | Branch |
|---------------|-----------|--------|
| `feature/auth-task-{id}` | `3` | `feature/auth-task-3` |
| `feature/auth-{id}` | `3` | `feature/auth-3` |
| `cyril/feat/po-{id}-done` | `1` | `cyril/feat/po-1-done` |

## Example: Full Workflow

### Step 1: Init and code

```bash
git checkout -b cyril/source/po-transactions master
git dispatch init --base origin/master --target-pattern "cyril/source/po-transactions-task-{id}" --mode independent

# Task 3 - Schema
git commit -m "Add PurchaseOrder to enum" --trailer "Target-Id=3"

# Task 4 - GET endpoint (2 commits, same Target-Id)
git commit -m "Create DTOs for PO transaction" --trailer "Target-Id=4"
git commit -m "Add controller and service"     --trailer "Target-Id=4"

# Task 5 - Validation
git commit -m "Implement PO validation"        --trailer "Target-Id=5"
```

### Step 2: Apply

```bash
git dispatch apply
```

Creates one branch per Target-Id:
- `cyril/source/po-transactions-task-3` (1 commit)
- `cyril/source/po-transactions-task-4` (2 commits)
- `cyril/source/po-transactions-task-5` (1 commit)

### Step 3: Push

```bash
git dispatch push --from all
```

### Step 4: Iterate on source

Fix something on source, re-apply:

```bash
git commit -m "Fix tax mapping edge case" --trailer "Target-Id=4"
git dispatch apply          # cherry-picks new commit to task-4
git dispatch push --from 4
```

### Step 5: Review feedback on target

Fix on the target branch, cherry-pick back to source:

```bash
git switch cyril/source/po-transactions-task-4
git commit -m "Fix review feedback" --trailer "Target-Id=4"
git dispatch cherry-pick --from 4 --to source
git dispatch apply          # propagate to any other targets
git dispatch push --from all
```

### Step 6: Base moved ahead

```bash
# Safe approach (no force-push, preserves review context)
git dispatch merge --from base --to source
git dispatch apply
git dispatch push --from all

# Or linear history (requires force-push on targets)
git dispatch rebase --from base --to source --force
git dispatch apply
git dispatch push --from all --force
```

### Step 7: Cleanup

```bash
git dispatch reset --force
```

## Commands Reference

### init

```bash
git dispatch init --base <branch> --target-pattern <pattern> [--mode <independent|stacked>]
```

Configure dispatch on the current source branch. Stores config in git config. Installs hooks (Target-Id enforcement + auto-carry). Re-running warns if config already exists.

Defaults: `--mode independent`.
Required: `--base` and `--target-pattern` (must include `{id}`).
Recommended base: `origin/master` (or your remote default branch).

### apply

```bash
git dispatch apply [--dry-run]
```

Create or update target branches from source commits grouped by Target-Id. First run creates all branches. Subsequent runs cherry-pick only new commits. Idempotent and safe.

If `apply` is interrupted by local uncommitted changes during branch switch, one or more targets may remain behind source (for example `1 behind source`). Fix by cleaning/stashing local changes and re-running `git dispatch apply`.

### cherry-pick

```bash
git dispatch cherry-pick --from <source|id> --to <source|id|all> [--dry-run]
```

Move commits between source and a target:

| Direction | Effect |
|-----------|--------|
| `--from source --to 4` | Cherry-pick new Target-Id=4 commits from source to target |
| `--from 4 --to source` | Cherry-pick target commits back to source (adds Target-Id trailer) |
| `--from source --to all` | Same as `apply` |

Notes for `--from <id> --to source`:
- If a target commit is already integrated in source semantically (cherry-picking it would be a no-op), dispatch skips it.
- In that case output reports either:
  - `Source already has all commits from target <id>` (filtered before pick), or
  - `No new commits applied ... (N empty/no-op)` (detected during pick).

### rebase

```bash
git dispatch rebase --from base --to source [--force] [--dry-run]
```

Rebase source onto updated base. Rewrites history. Blocked when open PRs detected on downstream targets unless `--force`.

### merge

```bash
git dispatch merge --from base --to source [--dry-run]
```

Merge base into source. No history rewrite. No force-push needed. Safe for open PRs.

### push

```bash
git dispatch push --from <id|all|source> [--force] [--dry-run]
```

Push branches to origin. `--force` uses `--force-with-lease` internally.

### status

```bash
git dispatch status
```

Show mode, base, source, and all targets with sync state.

`status` is semantic-aware for target -> source sync:
- A target commit is not counted as `ahead` when cherry-picking it onto source would be empty/no-op.
- This avoids false out-of-sync states after equivalent changes were integrated through different commit history.

### reset

```bash
git dispatch reset [--force]
```

Delete all target branches, dispatch config, and hooks. Asks for confirmation unless `--force`.

## Adding a Target Mid-Stack

Use decimal Target-Id for insertion between existing targets:

```bash
git commit -m "Add migration" --trailer "Target-Id=1.5"
git dispatch apply    # creates target between 1 and 2
```

Numeric sort: 1 < 1.5 < 2 < 3 < 3.1 < 4.

## Config

Stored in git config:

| Key | Set by | Description |
|-----|--------|-------------|
| `dispatch.base` | init | Base branch (recommended: origin/master) |
| `dispatch.targetPattern` | init | Target branch naming pattern, must include `{id}` |
| `dispatch.mode` | init | independent or stacked |
| `branch.<name>.dispatchtargets` | apply | Target branches (multi-value) |
| `branch.<name>.dispatchsource` | apply | Source branch reference |

## Hooks

Installed automatically by `git dispatch init`:

- **`prepare-commit-msg`** - auto-carries Target-Id from previous commit
- **`commit-msg`** - rejects commits without numeric Target-Id, skips merge commits

To enforce globally:

```bash
mkdir -p ~/.git-hooks
cp hooks/prepare-commit-msg hooks/commit-msg ~/.git-hooks/
git config --global core.hooksPath ~/.git-hooks
```

Bypass when needed: `git commit --no-verify -m "message"`

## Worktree Support

Cherry-pick operations are worktree-aware. If a target branch has a worktree checked out, dispatch cherry-picks directly into the worktree instead of checkout gymnastics.

## AI Integration

### Universal (AGENTS.md)

Works with Cursor, Windsurf, Codex, Aider, and other AI coding tools:

```bash
cp AGENTS.md /path/to/project/
```

### Skill (SKILL.md)

Deeper integration for Claude Code and GitHub Copilot:

```bash
# Claude Code
mkdir -p ~/.claude/skills/git-dispatch && cp SKILL.md ~/.claude/skills/git-dispatch/

# GitHub Copilot
mkdir -p ~/.copilot/skills/git-dispatch && cp SKILL.md ~/.copilot/skills/git-dispatch/
```

### Agent (Claude Code only)

Full automation with a dispatch workflow subagent:

```bash
mkdir -p ~/.claude/agents && cp AGENTS.md ~/.claude/agents/git-dispatch.md
```

## Installation

Install via curl:

```bash
curl -fsSL https://raw.githubusercontent.com/KakkoiDev/git-dispatch/master/install-remote.sh | bash
```

Or clone and install locally:

```bash
git clone git@github.com:KakkoiDev/git-dispatch.git && cd git-dispatch
bash install.sh
```

Both installers:
- Create a global git alias: `git dispatch` -> `git-dispatch.sh`.
- Do not auto-install AI agent/skill files (they print optional commands for Claude/Codex/Gemini).

Quick start (one-liner after install):

```bash
git dispatch init --base origin/master --target-pattern "$(git branch --show-current)-task-{id}" --mode independent
```

## Testing

```bash
bash test.sh    # 93 tests
```

## Requirements

- Git 2.x+
- Bash 3.2+ (macOS compatible)

## License

MIT
