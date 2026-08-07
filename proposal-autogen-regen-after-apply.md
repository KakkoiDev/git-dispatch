# Proposal: Auto-regenerate shared auto-gen files after apply

## Problem

In independent mode, `verify` detects when multiple targets modify the same auto-generated files (openapi specs, generated API clients, etc.):

```
8  depends on: target 9  shared file: apps/server/openapi.gen.d.ts
9  depends on: target 8  shared file: apps/server/openapi.gen.d.ts
```

These files are derived artifacts - their content depends on which API changes exist on the branch. Cherry-picking them between branches with different API surfaces produces wrong results. Each target needs its own regenerated version.

Currently `verify` suggests 3 options (move commits, switch to stacked, accept conflicts). None address the root cause: auto-gen files should be regenerated per-branch, not cherry-picked.

## Solution

Add a `dispatch.regenCommand` config + post-apply regeneration step.

### Config

```ini
[dispatch]
    regenCommand = pnpm openapi
```

### Behavior change in `cmd_apply`

After all cherry-picks complete for a target branch:

1. Check if any cherry-picked commit touched files that `verify` flagged as shared between targets
2. If yes, run `dispatch.regenCommand` on that target branch
3. If the regen produces different files than what was cherry-picked, amend the last commit (or create a new commit) with the regenerated files
4. Continue to next target

### Detection: which targets need regen

Reuse the cross-dependency detection from `cmd_verify`. The data is already computed there (per-target file sets, shared file detection). Extract it into a shared function:

```bash
# Returns target-ids that have shared files with other targets
_targets_with_shared_files() {
    # Same logic as verify Phase 2, but returns list of tids
}
```

During apply, after cherry-picking all commits for a target-id that is in the shared list:

```bash
if _tid_has_shared_files "$tid"; then
    local regen_cmd
    regen_cmd=$(git config dispatch.regenCommand 2>/dev/null || true)
    if [[ -n "$regen_cmd" ]]; then
        info "Regenerating auto-gen files on $branch_name..."
        eval "$regen_cmd"
        if ! git diff --quiet; then
            git add -A
            git commit -m "chore: regenerate auto-gen files for target $tid"
        fi
    else
        warn "Target $tid has shared auto-gen files but no dispatch.regenCommand configured."
        warn "Set it with: git config dispatch.regenCommand 'pnpm openapi'"
    fi
fi
```

### Verify output update

Add option 4 to the verify output:

```
Options:
  1. Move commits so dependent files share a Target-Id
  2. Switch to stacked mode: git dispatch init --mode stacked ...
  3. Accept and resolve conflicts during apply
  4. Set regen command: git config dispatch.regenCommand '<cmd>'    <-- NEW
```

### Reverse direction (sync target -> source)

When `cmd_sync --from <target> --to source` cherry-picks commits back, the same logic applies but inverted: source has ALL targets' changes, so the regen command on source produces the combined output. Same mechanism - detect shared files, run regen after cherry-pick.

## Edge cases

- **No regenCommand configured**: warn during verify, skip during apply (current behavior preserved)
- **Regen fails**: abort apply for that target, report error, continue to next target
- **Regen produces no changes**: skip commit (idempotent)
- **Dry-run mode**: report "would regenerate on target X" without running

## Complexity

Medium. The detection logic already exists in `cmd_verify`. Main work is:
1. Extract shared-file detection into reusable function
2. Add post-cherry-pick regen step in apply loop
3. Add config handling for `dispatch.regenCommand`
