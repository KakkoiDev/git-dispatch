# git-dispatch Improvements

Based on real-world session where getting T-1 PR CI-green took 6+ cycles of rebuild/push/fail/fix.

---

## Problem Summary

Cherry-picking source commits onto `origin/master` to build target branches produces files that differ from both source and master individually. CI catches these differences (type errors, formatting, autogeneration drift) but the only feedback loop is push-and-wait. The developer spent hours fixing issues one at a time because:

1. No local verification step before push
2. `Source-Keep: true` on non-generated files silently overwrote fixes on rebuild
3. No `sync` before `apply reset` meant cherry-picks hit avoidable merge conflicts
4. Auto-carry hook propagated wrong target IDs without warning

---

## 1. Pre-push Verification (Deterministic)

### Problem

`apply reset` + `push` without verifying the target branch compiles/passes locally. Every CI failure requires a new rebuild+push cycle (5-10 min each).

### Solution: `git dispatch verify <N>`

New command that:
1. Creates a temporary checkout of target N (like `checkout N` but single-target)
2. Runs a configurable verification command
3. Reports pass/fail
4. Cleans up the temporary checkout

```bash
# Config (set during init or manually)
git config branch.<source>.dispatchverify "mo type-check"

# Usage
git dispatch verify 1          # verify target 1
git dispatch verify 1 --fix    # verify, and if it fails, open checkout for fixing
```

**Implementation:**
- Add `cmd_verify()` function
- Reuse `_enter_branch()` to create temp worktree on target branch
- Run the configured command via `eval`
- On failure with `--fix`: leave worktree alive (like `--resolve`)
- On success: clean up worktree, print "Target N verified"

**Where in code:** After `cmd_push()` (line ~1700), add `cmd_verify()`. Also add `--verify` flag to `cmd_push()` that auto-runs verify before pushing.

```bash
git dispatch push 1 --verify   # verify then push
```

---

## 2. Auto-sync Before Apply Reset (Deterministic)

### Problem

`apply reset <N>` without a prior `sync` means the target is rebuilt from a stale base. Cherry-picks produce different merge results than what master+source would produce via merge. This caused missing imports that only appeared on the target.

### Solution: Auto-sync in `apply reset`

In `cmd_apply()`, before the reset path (line ~1394):

```bash
# Before deleting and rebuilding targets, ensure source is synced with base
local behind_count
behind_count=$(git rev-list --count "$source".."$base")
if [[ $behind_count -gt 0 ]]; then
    warn "Source is $behind_count commit(s) behind $base. Syncing first..."
    cmd_sync "$@"   # pass through --resolve/--dry-run flags
fi
```

This eliminates the class of bugs where cherry-picks onto an outdated base produce broken files.

**Flag to skip:** `--no-sync` for cases where the user intentionally wants stale base.

---

## 3. Source-Keep Guard (Deterministic)

### Problem

`Dispatch-Source-Keep: true` on a commit that modifies hand-written code causes `apply reset` to silently overwrite target-only fixes with the source version. The user added `Source-Keep` to import fix commits, which got overwritten on every rebuild.

### Solution A: Warn when Source-Keep touches non-generated files

In `_cherry_pick_commits()` (line ~757), after auto-resolving with `--theirs`:

```bash
# After successful --theirs resolution for Source-Keep
local changed_files
changed_files=$(git diff --name-only HEAD)
local non_gen=false
while IFS= read -r file; do
    case "$file" in
        */gen/*|*/generated/*|*.gen.*|swagger.json|openapi.gen.d.ts) ;;
        *) non_gen=true; warn "  Source-Keep auto-resolved non-generated file: $file" ;;
    esac
done <<< "$changed_files"
```

### Solution B: Configurable generated file patterns

```bash
# Config
git config branch.<source>.dispatchgeneratedpatterns "*/gen/*,*.gen.*,swagger.json"
```

The `commit-msg` hook could validate: if `Dispatch-Source-Keep: true` is present, check if all changed files match generated patterns. Warn (not block) if non-generated files are included.

---

## 4. Target-Only Commit Preservation on Rebuild (Deterministic)

### Problem

`apply reset` deletes and rebuilds the target from scratch, losing target-only commits (fixes that only make sense on the target, not on source). The user had to re-apply fixes after every rebuild.

### Solution: Detect and replay target-only commits

In `cmd_apply()` reset path (line ~1441), before deleting the target:

```bash
# Save target-only commits (not traceable to source)
local target_only_hashes=()
# Use existing _find_new_commits_for_target logic in reverse:
# commits on target that have no matching subject in source
while IFS= read -r hash; do
    local subject
    subject=$(git log -1 --format="%s" "$hash")
    if ! git log --format="%s" "$source" | grep -qF "$subject"; then
        target_only_hashes+=("$hash")
    fi
done < <(git rev-list "$base".."$target")

# After rebuild, replay target-only commits
if [[ ${#target_only_hashes[@]} -gt 0 ]]; then
    info "Replaying ${#target_only_hashes[@]} target-only commit(s)..."
    _cherry_pick_commits "$resolve" "$target" "${target_only_hashes[@]}"
fi
```

**Flag to skip:** `--no-replay` to drop target-only commits intentionally.

**Warning before delete (current behavior, line 1460):** Already warns about target-only commits. Enhancement: show their subjects and ask confirmation.

---

## 5. Hook: Trailer Target Validation (Deterministic)

### Problem

The `prepare-commit-msg` hook auto-carries the previous commit's `Dispatch-Target-Id`. When the user commits a T-3 file right after a T-1 commit, the hook assigns `Dispatch-Target-Id: 1` silently. The user doesn't notice until CI fails on the wrong target.

### Solution A: File-path-based target suggestion

Add an optional config mapping file patterns to expected targets:

```bash
# .dispatch-targets (in repo root, optional)
# pattern -> expected target id
apps/web/src/store/api/enhancedApis/* 3
apps/web/src/components/templates/PurchaseOrderList/BulkTransactionRegistrationModal/* 2
apps/web/src/components/templates/PurchaseOrderList/PurchaseOrderListFooter/* 3
```

In `prepare-commit-msg` hook, after auto-carrying:
```bash
# Check if staged files suggest a different target
staged_files=$(git diff --cached --name-only)
if [[ -f ".dispatch-targets" ]]; then
    suggested_tid=$(match_staged_files_to_targets "$staged_files")
    if [[ -n "$suggested_tid" && "$suggested_tid" != "$prev_target" ]]; then
        # Replace the auto-carried trailer with the suggested one
        # Or: add a warning comment that gets stripped by commit-msg
        echo "# WARNING: staged files suggest Dispatch-Target-Id=$suggested_tid (auto-carried=$prev_target)" >> "$1"
    fi
fi
```

### Solution B: Cross-target file overlap detection in `apply`

During `apply`, detect when a commit's changed files overlap with files changed by commits in a different target:

```bash
# In apply, after grouping commits by target
for tid in "${!target_commits[@]}"; do
    for hash in ${target_commits[$tid]}; do
        files=$(git diff-tree --no-commit-id --name-only -r "$hash")
        for other_tid in "${!target_commits[@]}"; do
            [[ "$other_tid" == "$tid" ]] && continue
            for other_hash in ${target_commits[$other_tid]}; do
                other_files=$(git diff-tree --no-commit-id --name-only -r "$other_hash")
                overlap=$(comm -12 <(echo "$files" | sort) <(echo "$other_files" | sort))
                if [[ -n "$overlap" ]]; then
                    warn "Commit $hash (target $tid) modifies files also in target $other_tid: $overlap"
                fi
            done
        done
    done
done
```

---

## 6. Hook Behavior on Checkout Branches (Deterministic)

### Problem

The `prepare-commit-msg` hook auto-carries `Dispatch-Target-Id` from the previous commit. On checkout branches, commits from multiple targets are interleaved (target 1, target 2, "all" commits). The hook picks up whatever the last merged commit's trailer was, which is often wrong.

This caused `Dispatch-Target-Id: 1` to be assigned to a T-3 file when committing on the checkout branch.

### Solution: Detect checkout branch and skip auto-carry

In `prepare-commit-msg` hook, add checkout branch detection:

```bash
# Detect if we're on a checkout branch
current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
if [[ "$current_branch" == dispatch-checkout/* ]]; then
    # On checkout branches, don't auto-carry - require explicit trailer
    # The interleaved commits from multiple targets make auto-carry unreliable
    echo "# On checkout branch - set Dispatch-Target-Id explicitly" >> "$1"
    exit 0
fi
```

Alternatively, on checkout branches the hook could prompt with the list of active targets to choose from, or infer from the staged files using the `.dispatch-targets` mapping from improvement #5.

---

## 7. LLM Skill Instructions (Non-deterministic)

### Problem

The Claude skill for git-dispatch doesn't enforce the correct workflow. Claude made several mistakes:
- Used `apply reset` without `sync`
- Added `Source-Keep: true` to non-generated files
- Pushed without verifying locally
- Did not check trailer IDs when committing files outside the current task's scope

### Solution: Add rules to the skill file

Add to the git-dispatch skill/CLAUDE.md instructions:

```markdown
## Mandatory Workflow

### Before pushing a target:
1. ALWAYS `sync` before `apply reset`
2. ALWAYS `checkout N` and run the project's type-check/lint before `push`
3. NEVER push a target without local verification

### Trailer rules:
- `Dispatch-Source-Keep: true` is ONLY for generated files (gen/*.ts, swagger.json, openapi.gen.d.ts)
- NEVER use Source-Keep on hand-written code - it will be overwritten on every rebuild
- ALWAYS verify the auto-carried Dispatch-Target-Id matches the task scope
- When committing files that belong to a different task, manually set the correct target ID

### Target-only fixes:
- If a fix is only needed on the target (e.g., missing imports from master merge),
  commit it directly on the checkout branch and push the target directly
- Do NOT try to cherry-pick target-only fixes via source - they will be empty
- Do NOT use apply reset after adding target-only fixes - they will be lost

### Fix cycle:
1. checkout N
2. Run project verification (type-check, lint, autogeneration check)
3. Fix issues, commit on checkout
4. If fix is source-applicable: checkin, apply, push
5. If fix is target-only: update target ref directly, push
```

---

## 7. Autogeneration Check Simulation (Deterministic)

### Problem

CI's `check-autogeneration` step runs `pnpm openapi` then `git diff --exit-code`. The developer has no local equivalent. Formatting differences (Biome), generated file differences (prisma generate), and missing openapi regen only surface on CI.

### Solution: `git dispatch check <N>`

New command that simulates the CI autogeneration check:

```bash
# Config
git config branch.<source>.dispatchcheck "pnpm openapi && pnpm exec biome check --write . && git diff --exit-code"

# Usage
git dispatch check 1           # run check on target 1
git dispatch check 1 --fix     # run check and auto-commit any diffs
```

**Implementation:**
1. Create temp worktree on target
2. Run configured check command
3. If `--fix`: stage and commit changes with `Dispatch-Target-Id: N`
4. Clean up

This catches the exact issues CI catches, locally, before pushing.

---

## 8. Sync-aware Apply Reset (Deterministic)

### Problem

After `sync`, `apply reset` cherry-picks produce different results because the base has moved. Commits that were previously cleanly applied now conflict differently. `Source-Keep` auto-resolution masks real conflicts.

### Solution: Use merge-based target creation instead of cherry-pick

Alternative approach for `apply reset`:

```bash
# Instead of cherry-picking source commits onto base:
# 1. Create target from base
# 2. Merge source into target with --no-commit
# 3. Remove files not related to this target's commits
# 4. Commit

# This avoids cherry-pick conflict resolution entirely
# and produces the same result as master + your changes
```

This is a larger architectural change. The simpler fix is: always auto-sync before reset (improvement #2).

---

## Priority

| # | Improvement | Type | Impact | Effort |
|---|-------------|------|--------|--------|
| 2 | Auto-sync before apply reset | Deterministic | High | Low |
| 1 | Pre-push verification (`verify`) | Deterministic | High | Medium |
| 3 | Source-Keep guard for non-generated files | Deterministic | High | Low |
| 6 | Disable auto-carry on checkout branches | Deterministic | High | Low |
| 7 | LLM skill instructions | Instructions | High | Low |
| 5 | Trailer target validation hook | Deterministic | Medium | Medium |
| 8 | Autogeneration check simulation | Deterministic | Medium | Medium |
| 4 | Target-only commit preservation | Deterministic | Medium | High |
| 9 | Merge-based target creation | Deterministic | Low | High |
