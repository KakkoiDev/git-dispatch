---
name: git-dispatch
description: Stacked PRs without the stack. Multi-commit grouped PRs with no force-push. Code on source, apply into independent target branches, integration test with checkout, sync with checkin. Use when preparing grouped PRs from a source branch.
---

# git-dispatch

Multi-commit grouped PRs. No force-push, restack, or cascade.

vs ghstack/spr (1 commit = 1 PR): groups by `Dispatch-Target-Id` trailer. Targets branch independently from base. `checkout <N>` = integration view.

Source = edit. Targets = read-only PRs. Checkout = integration test.

## Agent Cheat Sheet

On `source`, CI fails on target `N`:
1. Source-owned file (lint/format/type-check): fix on source. `sync`. `apply <N>`. `push <N>`.
2. Target-owned file (gen, swagger, codegen output): `checkout <N>`. Fix. `commit`. `checkin`. `checkout source`. `sync`. `apply <N>`. `push <N>`. `checkout clear`.
3. Cross-target test failure: `checkout <N>` to verify, then route fix per 1 or 2.

On `source`, ship new PRs:
1. `commit --target <N>` per change.
2. `sync` if base moved.
3. `apply`.
4. `push all`.

Stuck: `git dispatch abort` returns to source clean.

## Decision Triage

| Symptom | Path |
|---------|------|
| `apply` refuses: "source behind base" | `sync` then `apply <N>` |
| Target CI fails (lint/format/type-check), source CI green | `checkout <N>` -> fix -> `commit` -> `checkin` -> `apply <N>` -> `push <N>` |
| Auto-gen file (gen/, swagger, prisma, openapi) diverges target<>source | `checkout <N>` -> run codegen -> `commit --source-keep` -> `checkin` -> `apply` -> `push <N>` |
| Source `apply` produces no diff but target still broken | Target has divergent state source cannot reach. Use `checkout <N>` flow. |
| Same change applies to every target | Commit on source with `--target all`, then `apply` |
| Verify multi-target integration before shipping | `checkout <N>` -> run tests -> `checkout source` -> `checkout clear` |
| Stuck mid-operation | `git dispatch abort` |

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

Tag via `dispatch commit`:
```bash
git dispatch commit "Add user model" --target 1
git dispatch commit "Update CI config" --target all
git dispatch commit "Regen swagger" --target 3 --source-keep
```

- Numeric: int or decimal (1, 2, 1.5). Decimals = mid-stack insertion.
- `all`: commit included in every target during apply.
- `--source-keep`: auto-resolve conflicts with incoming (`--theirs`). For gen files. Works in apply + checkin.
- On checkout branches, `--target` auto-detected from branch name.

### When to use `Dispatch-Target-Id: all`

USE for:
- Shared config (`.github/`, root `package.json`, `CLAUDE.md`)
- Utilities consumed by every target's code
- Generated files (OpenAPI clients, protobuf) every target rebuilds against

DO NOT USE for:
- Format/lint fixes to one target's files (tag target explicitly)
- Test-file changes for tests only in one target
- "Felt easier" - if unsure, tag specific target

**Why.** Once any target squash-merges into base, `all`-tagged commits semantically belonging to that target conflict when `apply` re-cherry-picks onto remaining (post-merge) targets. Forces `apply reset <N>` (history rewrite + force-push).

**Recovery.** `git dispatch retarget --commit <hash> --to-target <N>` rewrites trailer. Safe while PR open; already-pushed needs `--force`.

### Ownership config (`.git-dispatch-targets`)

Optional file at repo root. Maps paths to targets. Powers `git dispatch lint` + `status` post-merge hint.

```
# .git-dispatch-targets
1: apps/server/**
1: packages/api/**
2: apps/web/**
shared: docs/**
shared: .github/**
shared: package.json
```

One `<tid-or-"shared">: <glob>` per line. `#` = comment. Globs: `**` (dirs), `*` (segment), `?` (char). Repeat `tid:` for multiple globs. Missing file: `lint` exits 0.

`git dispatch lint` walks every `all`-tagged source commit, flags those whose changed files all belong to one target (touch nothing shared/unmatched). Suggests exact `git dispatch retarget` fix per commit.

## Workflows

### Basic: develop and create PRs
```bash
git dispatch init --base origin/master --target-pattern "feat/auth-{id}"
# or: git dispatch init  (prompts interactively)
git dispatch commit "Add user model" --target 1
git dispatch commit "Add auth middleware" --target 2
git dispatch commit "Add login endpoint" --target 2
git dispatch apply
git dispatch push all
```

### Integration testing
```bash
git dispatch checkout 3           # branch with targets 1..3 + all
<run tests>                       # e.g. pnpm test, cargo test, bazel test //...
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

### Generated files (OpenAPI, protobuf, prisma, codegen)

Trigger phrases (agent scan):
- "regen", "regenerate", "auto-gen", "code-gen", "swagger", "openapi", "prisma"
- "stale gen file on target", "drift between branches"
- "target CI fails, source CI passes" on generated path
- "no diff on source" but target needs fix
- "force-update gen on target without touching source"

Rule: auto-gen files owned by branch that ran generator. Source `apply` cannot push no-diff change. Target's gen file wrong -> regen on target.

```bash
# Option A: regen on source with Source-Keep
<run codegen>                     # e.g. pnpm openapi, make proto, prisma generate
git dispatch commit "regen" --target all --source-keep
git dispatch apply

# Option B: regen for failing target via checkout
git dispatch checkout 3
<run codegen>
git dispatch commit "regen swagger" --source-keep    # auto-detects target 3
git dispatch checkin             # Source-Keep auto-resolves conflict
git dispatch checkout source
git dispatch apply
git dispatch push 3
```

### Retarget commits (change Dispatch-Target-Id)
```bash
git dispatch retarget --target 8 --to-target 15       # moves all commits from target 8 to 15
git dispatch retarget --commit abc123 --to-target 15  # moves single commit
git dispatch apply                                     # updates both targets
```

### Alias target branches (custom branch names)
```bash
git dispatch alias 17 kakkoidev/fix/Ticket-1234    # target 17 -> ticket branch
git dispatch alias                                 # list all aliases
git dispatch alias clear 17                        # revert to pattern name
```
Local branches renamed. Remote push/delete manual. Aliases survive `apply reset`; `delete`/`reset` clear them.

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

### Post-merge: continue after a target merges

When `git dispatch status` shows target `merged`, run before editing other targets:
```bash
git dispatch status                # confirm merged target + 'all' warning
git dispatch sync                  # pull base into source + remaining targets
git dispatch lint                  # flag 'all' commits whose content now lives on base
git dispatch retarget --commit <hash> --to-target <N>     # fix each, then re-apply
git dispatch checkout <N>          # integration branch for target to edit
# edits, tests
git dispatch commit "fix: ..."     # auto-detects target N
git dispatch checkin               # picks fixes back to source
git dispatch checkout source
git dispatch apply <N>             # incremental, fast-forward
git dispatch checkout clear
git dispatch push <N>
```
Use `apply <N>`, not `apply reset <N>` (reset rewrites history -> `push --force`).

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

**Default `apply <N>`** (incremental, fast-forward push). Use `apply reset <N>` only when `apply <N>` itself conflicts and neither `retarget` nor `--source-keep` resolves it. Reset rewrites history, forces `push --force`. Never preemptively reset.

## Config

Branch-scoped (per-source-branch) for multi-worktree support:

| Key | Description |
|-----|-------------|
| `branch.<source>.dispatchbase` | Base branch (e.g., origin/master) |
| `branch.<source>.dispatchtargetpattern` | Target branch pattern (must include `{id}`) |
| `branch.<source>.dispatchtargetalias-<tid>` | Per-target branch name override |
| `branch.<source>.dispatchcheckoutbranch` | Active checkout branch |
| `branch.<source>.dispatchautoresolveall` | Auto-resolve mode for `all`-trailer cherry-pick conflicts: `skip` (default), `prompt`, `off` |
| `branch.<target>.dispatchsource` | Source branch reference |

## Flags

| Flag | Meaning |
|------|---------|
| `--dry-run` | Show plan, no changes |
| `--resolve`, `--continue` | Leave conflict active for manual resolution |
| `--yes` | Skip confirmation prompts (required for scripting/CI) |
| `--all` | Include merged targets in sync/apply (skipped by default) |
| `--force` | Safety override: `apply` rebuilds stale, `push` force-pushes, `checkout clear` discards |
| `--strict` | apply: disable auto-resolve of `all`-trailer conflicts for one invocation |

## Conflict Handling

All propagation commands support `--resolve`/`--continue` to leave conflicts active for manual resolution.

- **Default**: abort cleanly, print re-run hint
- **`--resolve`/`--continue`**: leave conflict active in worktree
- **`git dispatch abort`**: cancel, clean up, return to source
- **Dispatch-Source-Keep**: auto-resolves keeping source version (apply/checkin: `--strategy-option theirs`; sync: file-scoped `--ours` on target)
- **Auto-resolve `all`-trailer post-merge**: on `apply`, `Dispatch-Target-Id: all` cherry-pick conflicting only on its own files resolved with `--ours` per file. Empty result auto-skips; non-empty auto-commits. Config: `branch.<source>.dispatchautoresolveall` = `skip` (default) / `prompt` / `off`. Override: `--strict`. Audit: `.git/dispatch-audit.log` (last 500).

### Sync conflict flow

1. `git dispatch sync --resolve` hits conflict, leaves worktree at printed path.
2. Resolve files there (`git -C <wt> checkout --ours/--theirs <file>` or edit).
3. `git -C <wt> add <resolved>` (staging enough; no commit needed).
4. `git dispatch continue` auto-commits merge, resumes remaining targets.

`Dispatch-Source-Keep: true` on target commit auto-resolves sync conflicts on files that commit touched (keeps target's side; same intent as apply/checkin).

## Divergence Detection

`status` tags targets:
- `(DIVERGED)` = target has commits not traceable to source (e.g., manual push)
- `(cosmetic)` = same logical changes, different SHAs or base drift (safe to ignore)

Check uses commit-message traceability: every target subject matching source subject = cosmetic, not DIVERGED. Base drift never produces false DIVERGED.

## Data Flow

| Command | Direction | What it does |
|---------|-----------|--------------|
| `sync` | base -> source + targets | Merge master into source and existing targets |
| `apply` | source -> targets | Cherry-pick new commits to target branches |
| `checkin` | checkout -> source | Cherry-pick fixes from checkout back to source |
| `retarget` | source (in-place) | Revert + re-apply commits with new target id |

## apply vs apply reset

- `apply <N>` = incremental (new commits only). Push stays fast-forward.
- `apply reset <N>` = recreate from scratch. Requires `push --force` (history rewritten).

**Force-push trap**: source behind master -> `apply` creates targets w/ different SHAs (cosmetic) -> later `apply <N>` can't match SHAs, re-applies everything, conflicts -> forced into `apply reset <N>` -> needs `push --force`.

**Prevention**: always `sync` before `apply` when source behind master. Keeps SHAs stable; incremental `apply <N>` works; push stays fast-forward.

## Anti-Patterns

| Don't | Why | Do instead |
|-------|-----|------------|
| Edit auto-gen file on source to push diff to target | Source has no real diff. Cherry-pick to target empty. | `checkout <N>` -> regen -> `checkin` |
| Run `apply` while source behind base | Cosmetic SHA drift, future `apply` conflicts, forces `apply reset` + `push --force` | `sync` first |
| Use `Dispatch-Target-Id: all` for one target's format fix | Once any target merges, `all` cherry-picks conflict on remaining targets | Tag specific target |
| `apply reset <N>` preemptively | Rewrites history, forces `push --force`, breaks PR review comments | Only when `apply <N>` itself conflicts and `retarget`/`--source-keep` cannot fix |
| Manually push target branches | Drift from source; `dispatch status` flags as `(DIVERGED)` | `git dispatch push <N>` |

## Common Fixes

| Problem | Fix |
|---------|-----|
| Target behind source | `git dispatch apply` |
| Target ahead of source | `checkout`, `checkin`, then `apply` |
| `apply <N>` conflicts on diverged target | `git dispatch apply reset <N>` |
| DIVERGED (real) | `checkout`, reconcile, `checkin`, `apply` |
| Source behind base | `git dispatch sync` |
| Move commit to different target | `git dispatch retarget --target <from> --to-target <to>` then `apply` |
| Stale target after tid reassignment (rebase) | `git dispatch apply --force` (rebuilds stale target from scratch) |
| Generated file conflict | `dispatch commit --source-keep` |
| Target CI fails (missing swagger) | `checkout <N>`, regen, `checkin`, `apply` |
| Insert task between existing | Use decimal: `Dispatch-Target-Id=1.5` |
| All targets need regeneration | `git dispatch apply reset all --yes` |
| Stuck operation/conflict | `git dispatch abort` |
| Clean up merged targets | `git dispatch delete <N>` or `delete --prune` |
| Merged PR reverted on base | `git dispatch apply reset <N>` then `apply` |
| Force sync/apply on merged targets | `--all` flag |
| PR branch needs ticket-based name | `git dispatch alias <N> <team>/fix/Ticket-1234` |

## Installation

```bash
bash install.sh                # Creates git dispatch alias
git dispatch init              # Interactive setup
```
