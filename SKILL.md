---
name: git-dispatch
description: Stacked PRs without the stack. Multi-commit grouped PRs with no force-push. Code on source, apply into independent target branches, integration test with checkout, sync with checkin. Use when preparing grouped PRs from a source branch.
---

# git-dispatch - Stacked PRs Without the Stack

Multi-commit grouped PRs. No force-push. No restack. No cascade.

Unlike ghstack/spr (1 commit = 1 PR), git-dispatch groups commits by Dispatch-Target-Id into multi-commit PRs. Each target branches independently from base. `checkout <N>` provides the combined view for integration testing.

**Source** = where all edits happen. **Targets** = read-only PR branches. **Checkout** = integration testing.

## Commands

| Command | Description |
|---------|-------------|
| `git dispatch init [--base <branch>] [--target-pattern <pattern>]` | Configure dispatch (prompts interactively when args omitted) |
| `git dispatch commit "message" [--target N] [--source-keep]` | Commit with auto-managed trailers |
| `git dispatch sync [--dry-run] [--resolve]` | Merge base into source and existing targets |
| `git dispatch apply [<N>] [--dry-run] [--resolve] [--force] [--yes]` | Cherry-pick source commits to targets |
| `git dispatch apply reset <N\|all> [--yes]` | Regenerate one or all targets from scratch |
| `git dispatch checkout <N> [--dry-run] [--resolve\|--continue]` | Create integration branch with targets 1..N + "all" commits |
| `git dispatch checkout source` | Return to source branch |
| `git dispatch checkout clear [--force]` | Remove checkout branch (warns on unpicked commits) |
| `git dispatch checkin [<N>] [--dry-run] [--resolve\|--continue]` | Cherry-pick checkout commits back to source |
| `git dispatch retarget --target <id> --to-target <id> [--dry-run] [--apply]` | Move all commits from one target to another |
| `git dispatch retarget --commit <hash> --to-target <id> [--dry-run] [--apply]` | Move a single commit to another target |
| `git dispatch lint` | Flag `all`-tagged commits whose files only belong to one target (requires `.git-dispatch-targets`) |
| `git dispatch push <all\|source\|N> [--dry-run] [--force]` | Push branches to origin |
| `git dispatch delete <N\|all\|--prune> [--dry-run] [--yes]` | Delete target branches |
| `git dispatch alias [<N> <branch-name>\|clear <N>]` | List/set/clear per-target branch aliases |
| `git dispatch status` | Show mode, base, targets, sync state, divergence, merged |
| `git dispatch continue` | Resume after conflict resolution |
| `git dispatch abort` | Cancel in-progress operation, clean up, return to source |
| `git dispatch reset [--yes]` | Delete target branches and config |

## Trailers

Use `dispatch commit` to tag commits with trailers:
```bash
git dispatch commit "Add user model" --target 1
git dispatch commit "Update CI config" --target all
git dispatch commit "Regen swagger" --target 3 --source-keep
```

- Numeric: integer or decimal (1, 2, 1.5). Decimals enable mid-stack insertion.
- `all`: commit included in every target during apply.
- `--source-keep`: auto-resolve conflicts with incoming version (--theirs). Used for generated files. Works during both apply (source->target) and checkin (checkout->source).
- On checkout branches, `--target` is auto-detected from branch name.

### When to use `Dispatch-Target-Id: all`

USE for:
- Shared config changes (`.github/`, root `package.json`, `CLAUDE.md`)
- Utilities genuinely consumed by every target's code
- Generated files (OpenAPI clients, protobuf) that every target rebuilds against

DO NOT USE for:
- Formatting/lint fixes to one target's files (tag the target explicitly)
- Test-file changes for tests that only exist in one target
- "It felt easier" - if unsure, tag the specific target

**Why it matters.** Once any target in the stack is squash-merged into base, `all`-tagged
commits that semantically belonged to that target start conflicting when `apply` re-cherry-picks
them onto the remaining targets. Remaining targets have the post-merge base content, which no
longer diff-matches the original commit. Result: forced `apply reset <N>` (history rewrite + force-push).

**Recovery.** `git dispatch retarget --commit <hash> --to-target <N>` rewrites the trailer.
Safe while the target PR is still open. For an already-pushed target, requires `--force` push.

### Ownership config (`.git-dispatch-targets`)

Optional file at repo root. Maps paths to targets; powers `git dispatch lint` and informs the
`git dispatch status` post-merge hint.

```
# .git-dispatch-targets
1: apps/server/**
1: packages/api/**
2: apps/web/**
shared: docs/**
shared: .github/**
shared: package.json
```

- One `<tid-or-"shared">: <glob>` pairing per line.
- `#` starts a comment.
- Globs support `**` (span directories), `*` (single segment), `?` (single char).
- Multiple globs per target allowed (repeat the `tid:` prefix).
- Missing file: `lint` reports "No ownership config" and exits 0.

`git dispatch lint` walks every `all`-tagged source commit and flags those whose
changed files all belong to a single target (and touch nothing shared or unmatched).
It suggests the exact `git dispatch retarget` command to fix each.

## Workflows

### Basic: develop and create PRs
```bash
git dispatch init --base origin/master --target-pattern "feat/auth-{id}"
# or just: git dispatch init  (prompts interactively)
git dispatch commit "Add user model" --target 1
git dispatch commit "Add auth middleware" --target 2
git dispatch commit "Add login endpoint" --target 2
git dispatch apply
git dispatch push all
```

### Integration testing
```bash
git dispatch checkout 3           # branch with targets 1..3 + all
pnpm test                         # run tests
git dispatch checkout source      # back to source
git dispatch checkout clear       # remove test branch
```

### Fix during integration
```bash
git dispatch checkout 3
# fix bug
git dispatch commit "Fix"         # auto-detects target from checkout branch
git dispatch checkin              # picks fix to source
git dispatch checkout source
git dispatch apply                # propagates to targets
git dispatch push 2
git dispatch checkout clear
```

### Generated files (OpenAPI, protobuf)
```bash
# Option A: regen on source with Source-Keep
pnpm openapi
git dispatch commit "regen" --target all --source-keep
git dispatch apply

# Option B: regen for failing target via checkout
git dispatch checkout 3
pnpm openapi
git dispatch commit "regen swagger" --source-keep    # auto-detects target 3
git dispatch checkin             # Source-Keep auto-resolves conflict
git dispatch checkout source
git dispatch apply
git dispatch push 3
```

### Retarget commits (change Dispatch-Target-Id)
```bash
git dispatch retarget --target 8 --to-target 15       # moves all commits from target 8 to 15
git dispatch retarget --commit abc123 --to-target 15  # moves a single commit
git dispatch apply                                     # updates both targets
```

### Alias target branch names (map target-id to custom branch name)
```bash
git dispatch alias 17 kakkoidev/fix/Ticket-1234    # target 17 -> ticket branch
git dispatch alias                                 # list all aliases
git dispatch alias clear 17                        # revert to pattern name
```
Existing local branches are renamed. Remote push/delete is manual. Aliases survive `apply reset`; `delete`/`reset` clear them.

### Review feedback
```bash
git dispatch commit "Rename field per review" --target 2
git dispatch apply
git dispatch push 2
```

### Keep up with main
```bash
git dispatch apply --base        # merges base into source AND existing targets
git dispatch push all
```

### Abort a stuck operation
```bash
git dispatch abort               # cleans up conflicts, worktrees, returns to source
```

## Apply Options

| Want | Command |
|------|---------|
| Create new targets + update all | `git dispatch apply` |
| Update one existing target | `git dispatch apply <N>` |
| Regenerate one target from scratch | `git dispatch apply reset <N>` |
| Regenerate all targets from scratch | `git dispatch apply reset all` |
| Merge base into source and targets | `git dispatch apply --base` |

## Config

Config is branch-scoped (per-source-branch) to support multiple worktrees:

| Key | Description |
|-----|-------------|
| `branch.<source>.dispatchbase` | Base branch (e.g., origin/master) |
| `branch.<source>.dispatchtargetpattern` | Target branch pattern (must include `{id}`) |
| `branch.<source>.dispatchtargetalias-<tid>` | Per-target branch name override |
| `branch.<source>.dispatchcheckoutbranch` | Active checkout branch |
| `branch.<target>.dispatchsource` | Source branch reference |

## Flags

| Flag | Meaning |
|------|---------|
| `--dry-run` | Show plan, make no changes |
| `--resolve`, `--continue` | Leave conflict active for manual resolution |
| `--yes` | Skip confirmation prompts (required for scripting/CI) |
| `--all` | Include merged targets in sync/apply (skipped by default) |
| `--force` | Safety override: `apply` rebuilds stale, `push` force-pushes, `checkout clear` discards |

## Conflict Handling

All propagation commands support `--resolve` (or `--continue`) to leave conflicts active for manual resolution.

- **Default**: aborts cleanly, prints re-run hint
- **`--resolve`/`--continue`**: leaves conflict active in worktree, shows remaining work
- **`git dispatch abort`**: cancel operation, clean up, return to source
- **Dispatch-Source-Keep**: auto-resolves keeping the source-originated version (apply/checkin: `--strategy-option theirs`; sync: file-scoped `--ours` on target)

### Sync conflict flow

1. `git dispatch sync --resolve` hits conflict, leaves worktree at printed path.
2. Resolve files there (`git -C <wt> checkout --ours <file>`, `--theirs <file>`, or edit).
3. `git -C <wt> add <resolved>` - staging is enough; no `git commit` needed.
4. `git dispatch continue` - auto-commits the merge, then resumes any remaining targets.

`Dispatch-Source-Keep: true` on a target commit auto-resolves sync conflicts on files
that commit touched (keeps the target's side, same intent as apply/checkin: "source owns this file").

## Divergence Detection

`status` tags targets:
- `(DIVERGED)` - target has commits not traceable to source (e.g., manual push to target)
- `(cosmetic)` - same logical changes, different SHAs or base drift (safe to ignore)

Base drift (source behind master) produces cosmetic differences, not false DIVERGED. The check uses commit-message traceability: if every target commit subject matches a source commit, the difference is from base drift or auto-conflict resolution.

## Data Flow

| Command | Direction | What it does |
|---------|-----------|--------------|
| `sync` | base -> source + targets | Merge master into source and existing targets |
| `apply` | source -> targets | Cherry-pick new commits to target branches |
| `checkin` | checkout -> source | Cherry-pick fixes from checkout back to source |
| `retarget` | source (in-place) | Revert + re-apply commits with new target id |

## apply vs apply reset

`apply <N>` = incremental (new commits only). Push stays fast-forward.
`apply reset <N>` = recreate from scratch. Requires `push --force` (history rewritten).

**Force-push trap**: source behind master -> `apply` creates targets with different SHAs (cosmetic) -> later `apply <N>` can't match SHAs, re-applies everything, conflicts -> forced into `apply reset <N>` -> needs `push --force`.

**Prevention**: always `sync` before `apply` when source is behind master. Keeps SHAs stable so incremental `apply <N>` works and push stays fast-forward.

## Common Fixes

| Problem | Fix |
|---------|-----|
| Target behind source | `git dispatch apply` |
| Target ahead of source | `checkout`, `checkin`, then `apply` |
| `apply <N>` conflicts on diverged target | `git dispatch apply reset <N>` |
| DIVERGED (real) | `checkout`, reconcile, `checkin`, `apply` |
| Source behind base | `git dispatch sync` |
| Move commit to different target | `git dispatch retarget --target <from> --to-target <to>` then `apply` |
| Stale target after tid reassignment (rebase) | `git dispatch apply --force` |
| Generated file conflict | `dispatch commit --source-keep` |
| Target CI fails (missing swagger) | `checkout <N>`, regen, `checkin`, `apply` |
| Insert task between existing | Use decimal: `Dispatch-Target-Id=1.5` |
| All targets need regeneration | `git dispatch apply reset all --yes` |
| Stuck operation/conflict | `git dispatch abort` |
| Clean up merged targets | `git dispatch delete <N>` or `delete --prune` |
| Merged PR reverted on base | `git dispatch apply reset <N>` then `apply` |
| Force sync/apply on merged targets | `--all` flag |
| PR branch needs a ticket-based name | `git dispatch alias <N> <team>/fix/Ticket-1234` |

## Installation

```bash
bash install.sh                # Creates git dispatch alias
git dispatch init              # Interactive setup
```
