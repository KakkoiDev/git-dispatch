# REPORT: `sync --resolve` ergonomics make Claude Code stumble mid-operation

## Summary

`git dispatch sync --resolve` works correctly end-to-end, but the step between "resolve file" and "operation done" has three sharp edges that cost an AI agent multiple tool calls and one dead-end command. A human developer learns these on the second run. An agent re-learns them on every fresh context.

Three specific gaps observed:

1. **`continue` rejects a staged-but-not-committed resolution.** After `git checkout --ours` + `git add`, running `git dispatch continue` does nothing useful and points you back to `git -C <wt> commit`.
2. **`continue` does not cascade to remaining targets.** Resolving target 2 and running `continue` cleans up target 2's worktree and exits. Target 3 is never processed. You must re-run `sync --resolve`.
3. **No per-file auto-resolution hint for `sync`.** `Dispatch-Source-Keep` is only documented/implemented for `apply`/`checkin`. For `sync`, a generated-file conflict forces the user into the worktree to run `git checkout --ours/--theirs` by hand.

## Session context

Worktree: `bulk-transaction-registration-from-the-purchase-order-list`, 3 targets, target 1 already merged.

Sequence observed:
```
$ git dispatch sync
Merged origin/master into .../1 (46 commits)
CONFLICT in apps/web/src/store/api/gen/transactions.ts
Error: Merge conflict on .../2. Re-run with --resolve.

$ git dispatch sync --resolve
# ... 47 commits merged into source, conflict re-surfaced on target 2 in
# worktree /var/folders/.../git-dispatch-wt.vtq0EY

$ git -C <wt> checkout --ours apps/web/src/store/api/gen/transactions.ts
$ git -C <wt> add apps/web/src/store/api/gen/transactions.ts
$ git dispatch continue
Merge conflict pending on .../2
  Resolve in: /var/folders/.../git-dispatch-wt.vtq0EY
  Then run:   git -C /var/folders/.../git-dispatch-wt.vtq0EY commit
  Then run:   git dispatch continue            # <-- same advice we just tried

$ git -C <wt> commit --no-edit
$ git dispatch continue
Operation complete on .../2. Cleaning up worktree.
# ... no mention of target 3 anywhere

$ git dispatch status
  3  .../3  2 behind source                    # <-- still stale

$ git dispatch sync --resolve                  # <-- we must infer this
Merged origin/master into .../3 (47 commits)
```

Total tool calls to finish a 3-target sync with one trivial conflict: 8 (expected ~4). The dead-end `continue` call and the second `sync --resolve` are both easy to automate away.

## Gap 1: `continue` does not finalize a staged resolution

### Observed

`continue` detects `.git/MERGE_HEAD` (or equivalent) in the worktree and refuses to proceed while it exists. Staging the resolved file with `git add` is not enough; the merge commit must already be created.

### Expected

`continue` should be the single "finish this step" command. If all conflicts are resolved (no `UU`/`AA`/... paths), `continue` should create the merge commit itself and proceed.

### Current message

```
Merge conflict pending on cyril/dispatch/.../2
  Resolve in: /private/var/folders/.../git-dispatch-wt.vtq0EY
  Then run:   git -C /private/var/folders/.../git-dispatch-wt.vtq0EY commit
  Then run:   git dispatch continue
```

The message is technically correct but violates least-surprise: `continue` *looks* like the resume command, yet it requires you to run a separate `git commit` first.

### Proposed fix (tool)

In the `continue` handler, before emitting the "merge conflict pending" message:

```bash
unmerged=$(git -C "$wt" diff --name-only --diff-filter=U)
if [[ -z "$unmerged" ]] && [[ -f "$wt/.git/MERGE_HEAD" || -f "$wt/.git/CHERRY_PICK_HEAD" ]]; then
    info "All conflicts resolved. Creating merge commit."
    git -C "$wt" commit --no-edit || { err "commit failed"; exit 1; }
fi
```

Then fall through to the "operation complete" path.

### Proposed fix (skill)

If the tool fix isn't implemented, the skill should spell out the exact three-step dance in a dedicated "Sync conflict recipe" section:

```markdown
### Resolving a sync conflict

1. `git dispatch sync --resolve` -- re-enter conflict in worktree
2. `git -C <wt> checkout --ours <file>` (or --theirs) -- pick side
3. `git -C <wt> add <file>` -- stage
4. `git -C <wt> commit --no-edit` -- **required** before continue
5. `git dispatch continue` -- finalize target
6. `git dispatch sync --resolve` -- **required** to process next target
```

## Gap 2: `continue` does not cascade to remaining targets

### Observed

With 3 targets and a conflict on target 2:
- `sync --resolve` stops at target 2's conflict.
- Manual resolve + `continue` finishes target 2, cleans up the worktree, prints "Operation complete on .../2", exits.
- Target 3 never gets `origin/master` merged in.
- Only `sync --resolve` (or `sync`) again picks up target 3.

`git dispatch status` after `continue` shows target 3 as "2 behind source" (actually: still N behind base), but the user gets no hint that another pass is required.

### Expected

Either:
- **A.** `continue` resumes the original sync state machine (it has the list of pending targets somewhere) and proceeds to target 3 automatically, OR
- **B.** `continue` exits with a clear "1 target remaining, run `git dispatch sync --resolve` to continue" message.

Option A is better UX; option B is cheap and unambiguous.

### Root cause

`continue` loads the conflict state for the specific target saved during `--resolve` and processes only that one. There's no persisted "sync plan" (list of pending targets) it can resume from.

### Proposed fix (tool)

Persist the sync plan in `.git/dispatch-sync-state` (or similar) when `sync --resolve` starts:

```
plan: 2 3
completed: (empty)
```

On `continue` completion for target 2, update to:
```
plan: 2 3
completed: 2
```

Then automatically invoke the sync loop for the remaining targets. If any of them conflicts, repeat the pause-and-resume dance.

Minimum-viable fallback (option B): after "Operation complete on .../2", append:

```
1 target still pending. Run `git dispatch sync --resolve` to continue.
```

### Proposed fix (skill)

Add a `Multi-target sync` caveat to the skill's conflict-handling section:

```markdown
**Note:** `git dispatch continue` only finishes the *current* target after a conflict.
If more targets remain pending, re-invoke `git dispatch sync --resolve` to process them.
Check `git dispatch status` for "N behind" indicators.
```

## Gap 3: No sync-time Source-Keep equivalent

### Observed

For `apply`, generated-file conflicts have a documented escape hatch: tag the commit with `Dispatch-Source-Keep: true` and conflicts auto-resolve with `--theirs`. For `sync`, no such escape hatch exists.

In this session, the conflict was on `apps/web/src/store/api/gen/transactions.ts` - a generated OpenAPI client. We knew before the command ran which side we wanted (target's evolved version, `--ours` during the master-into-target merge). Yet we had to:

1. Run `sync --resolve`.
2. Cd into the worktree.
3. Manually run `git checkout --ours <file>`.
4. Stage, commit, continue.

### Expected

A way to pre-declare resolution policy for specific paths, similar to `.gitattributes merge=`:

```
# .gitattributes at repo root or skill config
apps/web/src/store/api/gen/**  dispatch-sync-merge=ours
apps/server/**/openapi*.d.ts   dispatch-sync-merge=theirs
```

Or a command-line flag:

```
git dispatch sync --ours=apps/web/src/store/api/gen/
```

Either form would resolve the common "generated files drift during sync" case with zero manual steps.

### Proposed fix (tool)

Option 1: honor `.gitattributes` with a `dispatch-sync-merge` attribute during the sync merge step. If set, after merge conflicts surface, auto-resolve the tagged paths before dropping into the worktree.

Option 2: accept `--ours=<pattern>` / `--theirs=<pattern>` flags on sync.

Option 3 (lightest): extend `Dispatch-Source-Keep` semantics. When sync merges base into target and the target's tip commit has `Dispatch-Source-Keep: true`, apply `--strategy-option theirs` to that merge. This is narrow but matches the existing concept.

### Proposed fix (skill)

Until the tool handles it, add to the skill a ready-to-copy command sequence for "generated file sync conflict":

```markdown
### Generated file conflict during sync

```bash
git dispatch sync --resolve
# inside the worktree path it prints:
WT=<paste path here>
git -C "$WT" checkout --ours <generated-file>   # keep target's version
# or --theirs to take master's version
git -C "$WT" add <generated-file>
git -C "$WT" commit --no-edit
git dispatch continue
# re-run sync if more targets pending:
git dispatch sync --resolve
```
```

The current skill documents Source-Keep for apply/checkin only. A sync-specific example closes the gap for agents that read the skill file but not the source.

## Claude Code-specific observations

A few things that cost the agent extra round-trips:

1. **The worktree path string is printed in red.** When Claude parses stdout, ANSI escapes show up as `[0;33m...[0m`. Works but adds noise. Consider stripping ANSI when `GIT_DISPATCH_NO_COLOR=1` or when stdout isn't a TTY.

2. **The path has a `//` doubled slash (`/T//git-dispatch-wt.vtq0EY`).** Cosmetic but it makes pattern-matching the path in follow-up commands slightly brittle. Prefer `realpath`/`readlink -f` before printing.

3. **Output is 180+ lines on a successful sync** (full file list from the merge). Fine for humans scrolling in a terminal, expensive for agents that re-read tool output. Consider a `--brief` mode for sync that prints only the per-target summary lines plus conflict info, and promote it to default when `$CLAUDE_CODE` or similar env var is set.

4. **No structured output mode.** Every "X behind", "in sync", "merged" status line is free text. A `git dispatch status --json` (like `git dispatch diff-prisma --json` in db-helper) would let agents parse state deterministically. Example:

   ```json
   {
     "source": "cyril/poc/...",
     "base": "origin/master",
     "targets": [
       {"id": "1", "branch": "...", "status": "merged"},
       {"id": "2", "branch": "...", "status": "in_sync"},
       {"id": "3", "branch": "...", "status": "behind_source", "behind_count": 2}
     ],
     "pending_sync": false
   }
   ```

## Priority ranking

| Fix | Value | Effort | Agent impact |
|-----|-------|--------|--------------|
| Gap 1 tool fix (auto-commit on clean resolve) | High | Low (~10 lines) | Saves 1 tool call + removes dead-end path |
| Gap 2 option B (pending target hint in continue output) | High | Trivial | Prevents agents (and humans) from thinking sync is done |
| Gap 3 option 3 (sync honors Source-Keep on tip commit) | Medium | Medium | Eliminates manual intervention for the generated-file case |
| `status --json` | Medium | Medium | Deterministic state parsing for automation |
| Skill: "sync conflict recipe" section | High | Trivial (docs) | Unblocks agents even before tool fixes ship |
| ANSI stripping on non-TTY | Low | Low | Mild noise reduction |

## Proposed skill change (copy-paste ready)

Add this section to `SKILL.md` after the existing `## Conflict Handling`:

```markdown
### Sync conflict recipe (generated files & drift)

When `sync` hits a conflict, a worktree is created for manual resolution.

```bash
git dispatch sync --resolve
# reads like: "Resolve conflicts in worktree: /path/to/git-dispatch-wt.XXX"

WT=<paste the path>
git -C "$WT" status                                # verify UU entries
git -C "$WT" checkout --ours <file>                # keep target (usual)
git -C "$WT" checkout --theirs <file>              # take master
git -C "$WT" add <file>
git -C "$WT" commit --no-edit                      # REQUIRED before continue
git dispatch continue                              # finalize THIS target
git dispatch sync --resolve                        # process NEXT target if any
```

**Gotchas:**
- `git dispatch continue` does NOT commit for you. Run `git commit --no-edit` first.
- `git dispatch continue` processes only the current target. Re-invoke `sync --resolve` for remaining targets.
- For `--ours` vs `--theirs`: during sync, HEAD/ours = target branch, incoming/theirs = base (origin/master).
- `Dispatch-Source-Keep: true` only auto-resolves apply/checkin conflicts, NOT sync conflicts. You must resolve sync conflicts manually (today).
```

## Related

- `BUG-sync-skips-targets-when-source-is-current.md` - companion sync issue
- `BUG-checkout-conflict-after-sync-stale-targets.md` - downstream effect when sync is incomplete
- `pitfall-cherry-pick-divergence-after-conflict.md` - similar class of "resolve then lose context" friction
- `IMPROVEMENTS.md` - general improvement backlog

## Session details

Environment: macOS 24.5.0, `git dispatch` from `~/Code/git-dispatch/git-dispatch.sh`, Claude Code Opus 4.7 (1M context).
Date: 2026-04-23.
Project: `bulk-transaction-registration-from-the-purchase-order-list` (meetsone).
Targets: 3 (1 merged, 2 needed conflict resolve, 3 auto-merged after second `sync --resolve`).
Conflict file: `apps/web/src/store/api/gen/transactions.ts` (generated OpenAPI client, 9-line semantic diff).
Resolution chosen: `--ours` (keep target 2's evolved API shape).
Outcome: correct final state, 8 tool calls, ~3 of which were avoidable with the fixes above.
