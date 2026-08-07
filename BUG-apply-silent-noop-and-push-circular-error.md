# BUG: `apply <N>` silent no-op + `push <N>` circular error

## Summary

When `apply <N>` fails to create the target branch (source behind base, or no commits with tid=N), the output looks like a benign success. The user then runs `push <N>`, gets "Target branch does not exist. Run: git dispatch apply" - but running apply again produces the same silent no-op. Infinite loop with no clear actionable error.

## Reproduction

Source branch 33 commits behind `origin/master`, no commits tagged `Dispatch-Target-Id: 17`:

```
% git dispatch apply 17
  \ Refreshing base... Base origin/master updated (3 new commits)
Source is 33 commit(s) behind origin/master. Run: git dispatch sync

Summary: 0 created, 0 updated, 0 in sync

% git dispatch push 17
Error: Target branch 'cyril/feat/purchase-order-transaction-registration/task-17' does not exist locally. Run: git dispatch apply

% git dispatch apply 17
Source is 33 commit(s) behind origin/master. Run: git dispatch sync

Summary: 0 created, 0 updated, 0 in sync

% git dispatch push 17
Error: Target branch '...task-17' does not exist locally. Run: git dispatch apply
```

Re-running `apply` and `push` produces identical output forever.

## Expected

One of:

1. `apply <N>` fails loud when it cannot produce target N:
   ```
   Error: Cannot apply target 17 - source is 33 commit(s) behind origin/master.
   Run: git dispatch sync
   ```
   Non-zero exit, no misleading "Summary: 0 created" line.

2. `apply <N>` fails when no commits target N:
   ```
   Error: No commits on source have Dispatch-Target-Id: 17
   ```

3. `push <N>` checks the upstream condition and suggests the correct action:
   ```
   Error: Target branch 'task-17' does not exist locally.
   Source is 33 commit(s) behind origin/master. Run: git dispatch sync, then git dispatch apply 17
   ```

## Actual

Three failure modes silently swallowed:

### Mode A: Source behind base (drift warning, apply continues)

At `git-dispatch.sh:1294`:
```bash
warn "Source is $_drift_count commit(s) behind $base. Run: git dispatch sync"
```

`warn` prints yellow text but does not exit. Apply continues, but:
- The cherry-pick range `$base..$source` may produce commits that were already on base before drift, causing confusing behavior downstream.
- Or the target never gets created because apply reaches the "no matching commits" path without erroring.

Combined with the `Summary: 0 created, 0 updated, 0 in sync` epilogue, user sees "succeeded with nothing to do" when in reality the tool refused to act.

### Mode B: No commits target N

At `git-dispatch.sh:1370-1372`:
```bash
while IFS= read -r tid; do
    target_ids+=("$tid")
done < <(awk '$2 != "all" && !seen[$2]++ {print $2}' "$commit_file" | sort -t. -k1,1n -k2,2n)
```

If `apply_target=17` is passed but no commit has `Dispatch-Target-Id: 17`, the target_ids loop has nothing to process for 17. No error, just "0 created".

Looking at how `apply_target` filters the target_ids loop - if the user explicitly asked for target 17 and no commits tag it, that should be an error, not silence.

### Mode C: push N - circular suggestion

At `git-dispatch.sh:1812`:
```bash
die "Target branch '$target_branch' does not exist locally. Run: git dispatch apply"
```

`push` gives this message blindly without checking:
- Is source behind base? (need sync first)
- Do any commits target N? (need to commit with trailer first)
- Was apply actually run? (maybe user forgot)

All three have different fixes. Current message points at the one that won't work.

## Root Cause

Two design gaps:

1. **`warn` vs `die` for drift in apply**: `apply <N>` with source behind base should be a hard error for the non-reset path. `cmd_sync` is not interactive, so user can run it. Continuing with a warning creates the misleading "0 created" epilogue.

2. **`apply <N>` does not validate that commits exist for N**: When the user explicitly targets N, the tool should verify at least one commit has `Dispatch-Target-Id: N` before the work phase. Absence of such commits should be a loud error, not silent "0 created".

3. **`push <N>` does not diagnose why the target is missing**: The die message hardcodes "Run: git dispatch apply" without verifying that apply would work.

## Suggested Fix

### Fix 1 - Make drift a hard error in apply (non-reset)

At line 1293-1295:
```bash
else
    die "Source is $_drift_count commit(s) behind $base. Run: git dispatch sync"
fi
```

Change `warn` to `die`. If user wants to force it, they already have `--force`.

Keep the auto-sync path for `apply reset` unchanged.

### Fix 2 - Validate target N exists in source commits

After building `target_ids`, if `apply_target` is set:
```bash
if [[ -n "$apply_target" ]]; then
    local found=false
    for t in "${target_ids[@]}"; do
        [[ "$t" == "$apply_target" ]] && { found=true; break; }
    done
    $found || die "No commits on source have Dispatch-Target-Id: $apply_target"
fi
```

### Fix 3 - Diagnose why push cannot find target

At line 1811-1812, expand the check:
```bash
if ! git rev-parse --verify "refs/heads/$target_branch" &>/dev/null; then
    # Diagnose root cause for a better suggestion
    local _drift
    _drift=$(git rev-list --count "$source..$base" 2>/dev/null || echo 0)
    if [[ "$_drift" -gt 0 ]]; then
        die "Target branch '$target_branch' does not exist. Source is $_drift commit(s) behind $base. Run: git dispatch sync, then git dispatch apply $target"
    fi
    local _has_commits
    _has_commits=$(git log "$base..$source" --format="%B" | grep -c "^Dispatch-Target-Id: $target$" || true)
    if [[ "$_has_commits" -eq 0 ]]; then
        die "Target branch '$target_branch' does not exist. No commits on source have Dispatch-Target-Id: $target"
    fi
    die "Target branch '$target_branch' does not exist locally. Run: git dispatch apply $target"
fi
```

## Workaround

Users must mentally parse the warning line (easy to miss, yellow text amid normal output) and manually run `sync` before `apply`.

## Environment

- git-dispatch.sh (HEAD as of 2026-04-13)
- Bash 5.x on macOS
- Scenario: feature branch 33 commits behind `origin/master`, no commits tagged for target id being applied
