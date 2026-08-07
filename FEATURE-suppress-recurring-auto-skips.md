# Feature Proposal: Suppress recurring `apply` auto-skips after merge

## Problem

After one target in a stack is squash-merged into base, every subsequent `git dispatch apply` re-emits the same auto-skip lines for every source commit whose patch is now resident on base. The skips are functionally harmless (the tool keeps doing the right thing) but they:

1. **Mislead agents and humans** into thinking a real conflict happened. Each line is prefixed with `CONFLICT (content):` from the underlying cherry-pick before the tool's `Auto-skipped (all-trailer):` line lands. A reader skimming output sees "CONFLICT" and pauses.
2. **Accumulate audit-log entries** indefinitely. `.git/dispatch-audit.log` now contains the same skips on every apply (3 entries -> 4 -> 6 -> ...) with no automatic rotation or de-duplication.
3. **Repeat on every apply forever** for the lifetime of the stack. There is no mechanism to mark "this commit's patch is now on base, stop checking it."

The recurring quirk surfaces every time `apply` walks the source. Today's mitigation is the manual fix:

```bash
git dispatch lint            # flag mis-tagged 'all' commits
git dispatch retarget --commit <hash> --to-target <N>  # move to actual owner
git dispatch apply
```

Cosmetic, optional, and most users skip it. Agents in particular have no way of knowing the noise is benign without reading the audit log.

## Real-world scenario

Stack with three targets. Target 1 (BE T-1) squash-merges to base. Target 2 (FE T-2) and target 3 (BE T-3) remain open.

Source history contains three commits tagged `Dispatch-Target-Id: all`:
- `1d4c472d71 chore: remove SCOPING_CHECKLIST.md symlink`
- `a7529a53a0 style: format test file after variable renames`
- one more shared utility commit

Their content all landed on base via target 1's squash-merge. From `apply`'s perspective they are still un-applied to targets 2 and 3 because their SHAs are not present on those branches. Cherry-pick re-encounters them, hits "empty" or "patch on file already matches base", auto-resolves, and emits noise.

After three applies during this PR cycle the output and audit log look like this:

```
Skipping empty cherry-pick: 1d4c472d71 [NONE-27438] chore: remove SCOPING_CHECKLIST.md symlink
CONFLICT (content): Merge conflict in apps/server/src/transactions/transactions-bulk-purchase-order.integration.spec.ts
Auto-skipped (all-trailer): a7529a53a0 [NONE-30035] style: format test file after variable renames
```

Same two lines, every time, for the duration of the stack.

## Proposed fix

Detect patch-equivalence against base BEFORE attempting cherry-pick. Use git's own primitive:

```bash
git cherry --abbrev=8 <base> <source>
```

`git cherry` reports each source commit prefixed with `+` if its patch is NOT in `<base>` or `-` if an equivalent patch is. The `-` set is the set of commits `apply` should silently skip without invoking cherry-pick at all.

### Algorithm

When walking source commits to apply onto target `N`:

1. Compute the merge base of source and base: `mb=$(git merge-base $SOURCE $BASE)`.
2. Build the equivalence set: `equiv=$(git cherry $BASE $SOURCE $mb | awk '/^-/{print $2}')`.
3. For each source commit `H` in apply order:
   - If `H` is in `equiv`, skip silently (no log line, no audit entry, no cherry-pick attempt).
   - Else, attempt the cherry-pick as today.

### Net effect

| Today | After fix |
|-------|-----------|
| Cherry-pick attempts every commit, including those already on base | Cherry-pick only attempts commits not patch-equivalent to base |
| Each apply re-emits the same skip lines | First apply detects them; subsequent applies skip silently |
| Audit log accumulates duplicate skips | Audit log only records genuine auto-resolves and one-time "patch-on-base" detections |

### Behavior nuance

The current auto-resolve catches `Dispatch-Target-Id: all` commits whose conflict is bounded to their own files. The proposed pre-check is strictly an optimization in front of that path: it removes commits whose patches are already on base, leaving the existing auto-resolve to handle the rest (cases where the patch is on the TARGET but not base, e.g. cherry-picked manually by a reviewer).

`git cherry` uses patch-id (canonical hash of the diff), which is robust to author/date/SHA churn from rebase or sync. Empty commits, format-only commits, and pure deletions all resolve correctly.

## Documentation improvements (agent-facing)

Independent of the fix, the following doc changes lower the bar for agents reading dispatch output:

### 1. Explain auto-skips in `AGENTS.md`

Add a section titled "Auto-skipped commits during apply" that says, plainly:

> When you see `Auto-skipped (all-trailer): <hash>` or `Skipping empty cherry-pick: <hash>` during `apply`, the tool detected that the commit's patch is already on the target (typically because another target in the stack squash-merged the same content via base). This is NOT a conflict. The target receives nothing new for that commit. Repeated applies will re-emit the same skip lines until the underlying source commit is retargeted or removed. Run `git dispatch lint` to identify commits whose `all` trailer is now mis-tagged.

This single paragraph would have saved hours of agent confusion across the lifetime of every long-lived stack.

### 2. Annotate the output line itself

Today: `Auto-skipped (all-trailer): a7529a53a0 [NONE-30035] style: format test file after variable renames`

Proposed: `Auto-skipped (all-trailer, patch on base): a7529a53a0 [NONE-30035] style: format test file after variable renames`

Add the reason in parentheses. Two new reasons cover all current cases:
- `patch on base` - content delivered via a merged target
- `empty after --ours` - all conflict files staged to target's version, no net diff

### 3. Document the audit log lifecycle

`AGENTS.md` should mention `.git/dispatch-audit.log` exists, what it contains, and that it is append-only with no rotation. Suggest `git dispatch reset` clears it, or a future `git dispatch audit --rotate` command (out of scope here).

### 4. Surface skips in `git dispatch status`

When status reports auto-resolved entries (currently the one-line summary at the bottom), add a hint:

```
Auto-resolved entries: 3 skips, 00 resolves. See /Users/.../.git/dispatch-audit.log
Hint: 3 source commit(s) keep auto-skipping. Run 'git dispatch lint' to fix.
```

The hint is conditional on `lint` actually having a suggestion to make (ownership config present + flagged commits non-empty).

## Implementation sketch

The auto-skip path is in `_skip_empty_pick` and the `_auto_resolve_all_check` block (lines ~170, ~1051 in `git-dispatch.sh`). The pre-check would go in the per-commit loop inside `_apply_target_branch` (the function that walks the source commits).

```bash
# Pre-compute once per apply invocation
local _DISPATCH_PATCH_ON_BASE
_DISPATCH_PATCH_ON_BASE=$(git cherry "$base" "$source" 2>/dev/null \
    | awk '/^-/{print $2}' | tr '\n' ' ')

# Inside the per-commit loop
if [[ " $_DISPATCH_PATCH_ON_BASE " == *" $hash "* ]]; then
    # Silent skip - patch already on base
    continue
fi
```

Cache invalidates naturally each apply because the computation is per-invocation. No persistent state needed.

### Optional: first-time logging

To preserve discoverability ("I never see these auto-skips, am I sure dispatch is working?"), emit ONE summary line at the end of apply:

```
Pre-skipped 2 commit(s) whose patches are already on base. Run with --verbose to list.
```

The `--verbose` flag prints the commits. Default is the one-line summary.

## Edge cases

### 1. Source commit on base AND on target via apply

After a successful apply, source commit `H` has a patch-equivalent SHA on the target. `git cherry $BASE $SOURCE` only looks at base, not target. So `H` is still considered "to apply" by `apply`. Existing logic handles this correctly (no-op cherry-pick). The new pre-check would not change behavior here because `H` is not on base.

### 2. Force-pushed base

If base is rewritten (rebase, force-push), `git cherry` re-computes against the new base on every apply. No state lingers.

### 3. Patch-id collision

`git cherry` uses `git patch-id`. Two unrelated commits with the same patch are not real in practice (file paths matter). If it happens, the skip is still correct (target already has equivalent content).

### 4. Source-Keep commits

`Dispatch-Source-Keep: true` commits are intended to override target content with source content. If such a commit's patch happens to match base, the skip is correct (target receives nothing new, same as today).

### 5. Renamed files

`git cherry` uses patch-id which is rename-aware in the same way `git diff -M` is. No special handling needed.

## Rollout

Behind a config flag for one minor version:

```bash
git config branch.<source>.dispatchprecheckbase true   # opt-in
```

Default on in the following minor. Existing users see one-line summary on first opt-in apply ("dispatch skipped N commits already on base").

## Relationship to existing commands

| Command | Today | After fix |
|---------|-------|-----------|
| `apply` | Re-attempts cherry-pick on every patch | Pre-skips patches on base |
| `apply --strict` | Disables auto-resolve | Also disables base pre-check |
| `apply --verbose` | (new) | Lists pre-skipped commits |
| `lint` | Suggests retarget for mis-tagged `all` | Unchanged. Still the right tool to permanently fix the root cause. |
| `status` | Shows accumulated audit count | Adds hint when lint would help |
| `retarget` | Moves commits between targets | Unchanged. The permanent fix when commits really belong to one target. |

## Why this matters for agents

Agents reading dispatch output have no model for "this CONFLICT is fine, ignore it." Every CONFLICT line breaks the flow because the agent must investigate to confirm benignity. After the fix, agents see the cherry-pick attempts that genuinely need attention. The signal-to-noise ratio of `apply` output goes from "every output line could be a problem" to "every CONFLICT line IS a problem."

Doc improvements alone (without the algorithmic fix) cut roughly 80% of the agent confusion. The pre-check fix is the last 20% plus the audit-log hygiene.
