# git-dispatch

Split a source branch into stacked task branches. Keep them in sync bidirectionally. Never cherry-pick manually again.

## Problem

You write a TRD, vibe-code the whole feature on a source branch, then need clean stacked PRs for review. Manually cherry-picking and keeping branches in sync is tedious and error-prone.

## Solution

Tag commits with `Task-Id` trailers. `git dispatch split` groups them into stacked branches. `git dispatch sync` keeps everything in sync both ways.

## Quick Start

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/KakkoiDev/git-dispatch/master/install-remote.sh | bash

# Tag commits on your source branch
git checkout -b source/feature master
git commit -m "Add PurchaseOrder to enum" --trailer "Task-Id=3"
git commit -m "Create GET endpoint"       --trailer "Task-Id=4"
git commit -m "Add DTOs"                  --trailer "Task-Id=4"
git commit -m "Implement validation"      --trailer "Task-Id=5"

# Split into stacked branches
git dispatch split source/feature --base master --name feat/feature
# master
# └── feat/feature/3
#     └── feat/feature/4
#         └── feat/feature/5

# Continue working, then sync (auto-detects source from current branch)
git dispatch sync
```

## Commands

| Command | Description |
|---------|-------------|
| `git dispatch split <source> --name <prefix> --base <base>` | Split source into stacked branches by Task-Id |
| `git dispatch split <source> --name <prefix> --dry-run` | Preview split without creating branches |
| `git dispatch sync` | Auto-detect source, sync all task branches bidirectionally |
| `git dispatch sync [source]` | Sync all task branches for a specific source |
| `git dispatch sync [source] <task>` | Sync one specific task branch |
| `git dispatch status [source]` | Show pending sync counts without applying |
| `git dispatch pr [source] [--branch <name>] [--title <t>] [--body <b>] [--push] [--dry-run]` | Create stacked PRs via gh CLI |
| `git dispatch reset [source] [--branches] [--force]` | Clean up dispatch metadata |
| `git dispatch tree [branch]` | Show stack hierarchy |
| `git dispatch hook install` | Install commit-msg hook enforcing Task-Id |
| `git dispatch help` | Show usage guide |

## Task-Id Trailers

Commits use native git trailers for task linking:

```bash
git commit -m "Add feature" --trailer "Task-Id=3"
```

Parse trailers (zero regex, git-native):

```bash
git log --format="%H %(trailers:key=Task-Id,valueonly)" master..source
```

Install the hook to enforce trailers on every commit:

```bash
git dispatch hook install
```

## Example: TRD to Stacked PRs

The full workflow starts with a TRD (Technical Refinement Document). Task numbers in the TRD become `Task-Id` trailers in commits, which become stacked branches and PRs.

See [`trd-template.md`](trd-template.md) for the full template.

### The TRD

```markdown
# TRD - Purchase Order Transaction Registration

## Tasks

### Part 1 - Backend Infrastructure
#### 3. (Schema) Add PurchaseOrder to TransactionLineSource enum
#### 4. (BE) Create GET /transactions/by-purchase-order/:id endpoint
#### 5. (BE) Implement Purchase Order validation in transaction service

### Part 2 - Frontend
#### 9. (FE) Add transaction status to PO Detail header
#### 10. (FE) Add menu item with confirmation dialog
#### 11. (FE) Create transaction registration page
```

### Step 1: Vibe-code the source

Code the whole feature on one branch. Tag every commit with its TRD task number:

```bash
git checkout -b cyril/source/po-transactions master
git dispatch hook install

# Task 3 - Schema
git commit -m "Add PurchaseOrder to TransactionLineSource enum" --trailer "Task-Id=3"

# Task 4 - GET endpoint
git commit -m "Create DTOs for purchase order transaction"      --trailer "Task-Id=4"
git commit -m "Add controller and service methods"              --trailer "Task-Id=4"
git commit -m "Add tax mapping logic for debit side"            --trailer "Task-Id=4"

# Task 5 - Validation
git commit -m "Implement PO validation in transaction service"  --trailer "Task-Id=5"
git commit -m "Add optimistic locking and permission checks"    --trailer "Task-Id=5"

# Task 9 - FE status header
git commit -m "Add transaction status to PO detail header"      --trailer "Task-Id=9"

# Task 10 - FE menu item
git commit -m "Add menu item with confirmation dialog"          --trailer "Task-Id=10"
```

The source branch is demo-able. Show it to PM, get feedback, iterate.

### Step 2: Split into stacked branches

```bash
# Preview first
git dispatch split cyril/source/po-transactions \
  --base master --name cyril/feat/po-transactions --dry-run

# Split
git dispatch split cyril/source/po-transactions \
  --base master --name cyril/feat/po-transactions
```

Result:
```
master
└── cyril/feat/po-transactions/3   (1 commit)
    └── cyril/feat/po-transactions/4   (3 commits)
        └── cyril/feat/po-transactions/5   (2 commits)
            └── cyril/feat/po-transactions/9   (1 commit)
                └── cyril/feat/po-transactions/10  (1 commit)
```

Each branch contains only its task's commits, stacked on top of the previous task. Reviewer reads one branch = one TRD task.

### Step 3: Create stacked PRs

```bash
# Preview what would be created
git dispatch pr --dry-run

# Push branches and create PRs
git dispatch pr --push
```

### Step 4: Keep iterating

Fix something on the source? Sync pushes it to the right task:

```bash
git checkout cyril/source/po-transactions
git commit -m "Fix tax mapping edge case" --trailer "Task-Id=4"
git dispatch sync
```

Fix something on a task branch? Sync pushes it back to source:

```bash
git checkout cyril/feat/po-transactions/5
git commit -m "Fix permission check"
git dispatch sync
# Task-Id=5 trailer added automatically, synced back to source
```

Source stays demo-able. PRs stay clean. Reviewer reads commit-by-commit.

## Commands Reference

### split

```bash
git dispatch split <source> --name <prefix> [--base <base>] [--dry-run]
```

Parse `Task-Id` trailers from source, group commits by task, create stacked branches named `<prefix>/<task-id>`. Each branch stacks on the previous.

### sync

```bash
git dispatch sync                    # auto-detect source, sync all
git dispatch sync [source]           # explicit source, sync all
git dispatch sync [source] <task>    # sync one task
```

Bidirectional sync using `git cherry` (patch-id comparison). Source->task: new commits for the task appear in the task branch. Task->source: fixes flow back (Task-Id trailer added if missing). Auto-detects source from current branch context.

### status

```bash
git dispatch status              # auto-detect source
git dispatch status [source]     # explicit source
```

Show pending sync counts per task branch without applying changes. Quick preview before running `sync`.

### pr

```bash
git dispatch pr                  # auto-detect, create all PRs
git dispatch pr [source]         # explicit source
git dispatch pr --branch feat/4        # target a single branch
git dispatch pr --title "My PR" --body "Description"  # custom title/body
git dispatch pr --push           # push branches first, then create PRs
git dispatch pr --dry-run        # show what would be created
```

Create stacked PRs with correct `--base` flags via `gh` CLI. Walks the dispatch stack in order. PR title defaults to the first commit subject of each task. `--branch` targets a single branch instead of all tasks. `--title` and `--body` override the auto-generated title and empty body. Requires `gh` CLI.

### reset

```bash
git dispatch reset               # auto-detect source, clean metadata
git dispatch reset [source]      # explicit source
git dispatch reset --branches    # also delete task branches
git dispatch reset --force       # skip confirmation prompt
```

Clean up dispatch metadata (`dispatchsource`, `dispatchtasks`) from git config. Use when re-splitting or abandoning a dispatch stack.

### tree

```bash
git dispatch tree [branch]
```

Show the dispatch stack hierarchy.

### hook install

```bash
git dispatch hook install
```

Install `commit-msg` hook that rejects commits without a `Task-Id` trailer. This is per-repo.

To enforce `Task-Id` globally across all repos:

```bash
mkdir -p ~/.git-hooks
cp hooks/commit-msg ~/.git-hooks/
git config --global core.hooksPath ~/.git-hooks
```

This will reject commits without `Task-Id` in every repo, including ones that don't use git-dispatch. To bypass when needed:

```bash
git commit --no-verify -m "message without trailer"
```

## Worktree Support

Sync is worktree-aware. If a task branch has a worktree checked out, `git dispatch sync` cherry-picks directly into the worktree instead of doing checkout gymnastics.

## Conflict Recovery

When a cherry-pick conflict occurs during split or sync:

1. Resolve the conflict
2. `git cherry-pick --continue`
3. Re-run the dispatch command

## Stack Metadata

Stored in git config (survives rebases, no extra files):

- `branch.<name>.dispatchtasks` -- task branches (multi-value)
- `branch.<name>.dispatchsource` -- source branch

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

```bash
curl -fsSL https://raw.githubusercontent.com/KakkoiDev/git-dispatch/master/install-remote.sh | bash
```

Or clone and install locally:

```bash
git clone git@github.com:KakkoiDev/git-dispatch.git && cd git-dispatch
bash install.sh
```

This creates a global git alias: `git dispatch` -> `git-dispatch.sh`.

## Testing

```bash
bash test.sh
```

## Requirements

- Git 2.x+
- Bash 3.2+ (macOS compatible)

## License

MIT
