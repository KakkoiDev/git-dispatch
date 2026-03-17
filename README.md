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

# Init on your source branch
git checkout -b feature/auth master
git dispatch init --base origin/master --target-pattern "feature/auth-{id}"

# Code with Dispatch-Target-Id trailers (hook auto-carries from previous commit)
git commit -m "Add user model"        --trailer "Dispatch-Target-Id=1"
git commit -m "Add auth middleware"   --trailer "Dispatch-Target-Id=2"
git commit -m "Add login endpoint"    --trailer "Dispatch-Target-Id=2"
git commit -m "Add validation"        --trailer "Dispatch-Target-Id=3"

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
| `git dispatch init --base <branch> --target-pattern <pattern>` | Configure dispatch on source branch |
| `git dispatch apply` | Create/update target branches from source |
| `git dispatch checkout <N>` | Integration branch with targets 1..N |
| `git dispatch checkout source` | Return to source branch |
| `git dispatch checkout clear` | Remove checkout branch |
| `git dispatch checkin` | Cherry-pick checkout commits back to source |
| `git dispatch cherry-pick --from <x> --to <y>` | Move commits between source and targets |
| `git dispatch merge --from base --to <source\|id\|all>` | Merge base into branches |
| `git dispatch push <all\|source\|N>` | Push branches to origin |
| `git dispatch status` | Show sync state, divergence |
| `git dispatch diff --to <id>` | File-level diff between source and target |
| `git dispatch verify` | Detect cross-target file dependencies |
| `git dispatch continue` | Resume after conflict resolution |
| `git dispatch clean` | Remove leftover worktrees |
| `git dispatch reset` | Delete targets and config |

All propagation commands support `--dry-run`, `--resolve`, and `--force`.

## Trailers

Every commit needs a `Dispatch-Target-Id` trailer:

```bash
git commit -m "Add feature" --trailer "Dispatch-Target-Id=3"
git commit -m "Update CI config" --trailer "Dispatch-Target-Id=all"
git commit -m "Regen swagger" --trailer "Dispatch-Target-Id=3" --trailer "Dispatch-Source-Keep=true"
```

| Value | Meaning |
|-------|---------|
| Numeric (1, 2, 1.5) | Assigns commit to target N. Decimals for mid-stack insertion. |
| `all` | Included in every target during apply. For shared infra, CI configs. |
| `Dispatch-Source-Keep: true` | Auto-resolve conflicts with incoming version. For generated files. |

Hook auto-carries `Dispatch-Target-Id` from previous commit. Hook rejects commits without it.

## Workflow: Develop and Create PRs

```bash
# 1. Init
git dispatch init --base origin/master --target-pattern "feat/auth-{id}"

# 2. Code with trailers
git commit -m "Add user model"      --trailer "Dispatch-Target-Id=1"
git commit -m "Add auth middleware"  --trailer "Dispatch-Target-Id=2"
git commit -m "Add login endpoint"   --trailer "Dispatch-Target-Id=2"

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
git commit -m "Fix auth race" --trailer "Dispatch-Target-Id=2"
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
git commit -m "regen" --trailer "Dispatch-Target-Id=all" \
  --trailer "Dispatch-Source-Keep=true"
git dispatch apply               # Source-Keep forces through per-target
```

### Regen for specific failing target

```bash
git dispatch checkout 3
pnpm openapi                     # correct swagger for targets 1..3
git commit -m "regen swagger" --trailer "Dispatch-Target-Id=3" \
  --trailer "Dispatch-Source-Keep=true"
git dispatch checkin             # Source-Keep auto-resolves conflict
git dispatch checkout source
git dispatch apply
git dispatch push 3
```

## Workflow: Review Feedback

```bash
git commit -m "Rename field per review" --trailer "Dispatch-Target-Id=2"
git dispatch apply
git dispatch push 2
```

## Workflow: Keep Up With Main

```bash
git dispatch merge --from base --to source
git dispatch apply
git dispatch push all
```

## Apply vs Cherry-pick

| Want | Command |
|------|---------|
| Create new targets + update all | `git dispatch apply` |
| Update one existing target | `git dispatch cherry-pick --from source --to <id>` |
| Bring target commits to source | `git dispatch cherry-pick --from <id> --to source` |
| Regenerate one target | `git dispatch apply --reset <id>` |

`apply` is the only command that creates new target branches.

## Branch Naming

`<target-pattern>` where `{id}` is replaced by `Dispatch-Target-Id`.

| Pattern | Id | Branch |
|---------|----|--------|
| `feature/auth-{id}` | `3` | `feature/auth-3` |
| `feat/po-task-{id}` | `1.5` | `feat/po-task-1.5` |

Checkout branches: `dispatch-checkout/<source>/<N>`

## Conflict Handling

All commands show conflicted files and diff on failure.

- **Default**: aborts cleanly, no changes made
- **`--resolve`**: leaves conflict active in worktree for manual resolution
- **`Dispatch-Source-Keep`**: auto-resolves with `--strategy-option theirs`
- **`git dispatch continue`**: checks for pending resolutions

## Divergence Detection

`status` tags targets:
- `(DIVERGED)` - file content differs. Changes may be lost.
- `(cosmetic)` - same content, different SHAs. Safe to ignore.

Fix: `git dispatch diff --to <id>` then cherry-pick in correct direction.

## Stale Target Detection

When a commit's `Dispatch-Target-Id` is changed on source (e.g., during interactive rebase), `apply` detects stale targets via patch-id matching:

```bash
git dispatch apply              # reports stale targets
git dispatch apply --force      # rebuilds them
```

## Config

| Key | Description |
|-----|-------------|
| `dispatch.base` | Base branch |
| `dispatch.targetPattern` | Target branch pattern (must include `{id}`) |
| `dispatch.checkoutBranch` | Active checkout branch |
| `branch.<name>.dispatchtargets` | Target branches |
| `branch.<name>.dispatchsource` | Source branch reference |

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
bash test.sh    # 254 tests
```

## Requirements

- Git 2.x+
- Bash 3.2+ (macOS compatible)

## License

MIT
