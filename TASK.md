# TASK: checkout/checkin commands + Dispatch-Target-Id rename

## Context

git-dispatch is a stacked PR tool that creates multi-commit PRs grouped by Dispatch-Target-Id.
Unlike ghstack/spr (1 commit = 1 PR), we support N commits = 1 PR.

Source branch = where all edits happen.
Target branches = read-only, exist only to back a PR.

This task adds checkout/checkin commands for integration testing and renames
`Target-Id` to `Dispatch-Target-Id` (consistency) and `none` to `all` (semantics).

## Subtasks

### 1. Rename Target-Id -> Dispatch-Target-Id and none -> all
**Status:** [ ] not started
**Files:** git-dispatch.sh (~40 occurrences), hooks/commit-msg (~9), hooks/prepare-commit-msg (~7), test.sh (~149)

Two renames in one pass:
- `Target-Id` -> `Dispatch-Target-Id` (consistency with `Dispatch-Source-Keep`)
- `none` -> `all` (semantic fix)

No backward compat. Clean break. 385 total occurrences across 13 files.

**Acceptance criteria:**
- All trailer references use `Dispatch-Target-Id` (code, hooks, tests, help)
- Hook accepts `Dispatch-Target-Id: all`, rejects old `Target-Id`
- Hook accepts numeric values as before (1, 2, 1.5)
- Apply includes `all` commits when cherry-picking to every target
- Status counts `all` commits as belonging to every target (not untracked)
- Dry-run displays `all` commit count
- Help text updated
- `git log --format="%(trailers:key=Dispatch-Target-Id,valueonly)"` used everywhere

**Semantic change from "none":**
- Old "none" = skip this commit during apply (source-only)
- New "all" = include this commit in EVERY target during apply
- This is a behavior change. "none" was excluded from targets. "all" is included in all targets.

### 2. git dispatch checkout <N>
**Status:** [ ] not started
**Files:** git-dispatch.sh (new cmd_checkout function)

Create an integration test branch `dispatch-checkout/<source>/<N>` containing all
source commits with Dispatch-Target-Id <= N or Dispatch-Target-Id == "all", in source commit order.

**Algorithm:**
1. Require init. Get base, source.
2. Parse source commits (base..source) into hash/tid pairs.
3. Filter: keep commits where tid <= N (numeric) OR tid == "all".
4. Create branch from base: `dispatch-checkout/<source>/<N>`.
5. Cherry-pick filtered commits in source order.
6. Open worktree for the branch.
7. Print worktree path.

**Acceptance criteria:**
- Creates branch named `dispatch-checkout/<source>/<N>`
- Includes commits with Dispatch-Target-Id 1, 1.5, 2 (all <= N) and "all"
- Excludes commits with Dispatch-Target-Id > N
- Preserves source commit order (not grouped by Dispatch-Target-Id)
- Works even if targets haven't been apply'd yet (reads from source, not targets)
- Decimal support: `checkout 3` includes 1, 1.5, 2, 2.1, 3
- Handles cherry-pick conflict with --resolve
- Errors if checkout branch already exists (must `clear` first)
- Errors if not on source branch or dispatch not initialized
- Works with both independent and stacked modes (same behavior)

### 3. git dispatch checkout source
**Status:** [ ] not started
**Files:** git-dispatch.sh (within cmd_checkout)

Navigate back to the source branch from a checkout branch.

**Algorithm:**
1. Detect current branch is `dispatch-checkout/<source>/<N>`.
2. Extract source name from branch name.
3. Switch to source worktree (or main worktree if source is there).

**Acceptance criteria:**
- Works when on a dispatch-checkout branch
- Works when on source branch (no-op, informational message)
- Errors gracefully if not on a dispatch-related branch
- Does NOT destroy the checkout worktree (user may want to return)

### 4. git dispatch checkout clear
**Status:** [ ] not started
**Files:** git-dispatch.sh (within cmd_checkout)

Remove the checkout branch and its worktree.

**Algorithm:**
1. Find dispatch-checkout branches for current source.
2. Check for unpicked commits (commits on checkout not in source).
3. If unpicked commits exist: warn and require --force.
4. Remove worktree, delete branch.

**Acceptance criteria:**
- Removes worktree and deletes the checkout branch
- Warns if checkout has commits not yet cherry-picked to source
- Requires --force to clear when unpicked commits exist
- Clears without --force when no unpicked commits
- Works when called from source branch (clears associated checkout)
- Works when called from the checkout branch itself (switches to source first)
- Handles case where no checkout exists (informational message)

### 5. git dispatch checkin
**Status:** [ ] not started
**Files:** git-dispatch.sh (new cmd_checkin function)

Cherry-pick new commits from checkout branch back to source. Does NOT auto-apply
to targets. User runs `apply` separately to propagate to targets. This keeps the
workflow explicit: checkin syncs to source, apply syncs to targets.

**Algorithm:**
1. Detect current branch is `dispatch-checkout/<source>/<N>`.
2. Determine which commits on checkout are "new" (not from the original cherry-pick).
   Compare checkout commits against source commits via patch-id matching.
3. Validate each new commit has a Dispatch-Target-Id (enforced by hook anyway).
4. Cherry-pick new commits to source branch (in order).
5. Print summary: N commits cherry-picked to source. Run `apply` to propagate.

**Acceptance criteria:**
- Only works from a dispatch-checkout branch (errors otherwise)
- Detects new commits (commits on checkout not present on source by patch-id)
- Cherry-picks new commits to source in order
- Preserves Dispatch-Target-Id trailers on cherry-picked commits
- Does NOT auto-apply to targets (user must run `apply` explicitly)
- Prints actionable summary after checkin
- Honors `Dispatch-Source-Keep: true` trailer (auto-resolve with checkout version via --strategy-option theirs)
- Handles cherry-pick conflict to source with --resolve
- No-op if no new commits on checkout (informational message)
- Works when source has advanced since checkout was created (may conflict)

### 6. Simplify push command syntax
**Status:** [ ] not started
**Files:** git-dispatch.sh (cmd_push)

Replace `--from` flag with positional argument. Simpler, more natural.

Old: `git dispatch push --from all`, `git dispatch push --from 3`, `git dispatch push --from source`
New: `git dispatch push all`, `git dispatch push 3`, `git dispatch push source`

**Acceptance criteria:**
- `git dispatch push all` pushes all targets
- `git dispatch push <N>` pushes target N
- `git dispatch push source` pushes source branch
- `--dry-run` and `--force` flags still work
- `--from` removed entirely (no backward compat needed)
- Error if no argument given

### 7. Update documentation
**Status:** [ ] not started
**Files:** git-dispatch.sh (cmd_help), hooks/commit-msg

Update `cmd_help` output to document:
- `checkout <N>` command and its purpose
- `checkout source` subcommand
- `checkout clear` subcommand
- `checkin` command
- `Dispatch-Target-Id: all` replacing `Target-Id: none` in trailer docs
- Updated workflow section showing checkout/checkin flow

Update hook error messages to reference `all` instead of `none`.

---

## Tests

### Dispatch-Target-Id: all - Hook Tests

```
test_hook_accepts_target_id_all
  Setup: init dispatch
  Action: commit with --trailer "Dispatch-Target-Id=all"
  Assert: commit succeeds (exit 0)
  Assert: commit message contains "Dispatch-Target-Id: all"

test_hook_rejects_target_id_none
  Setup: init dispatch
  Action: commit with --trailer "Dispatch-Target-Id=none"
  Assert: commit fails (exit 1)

test_hook_auto_carry_target_id_all
  Setup: init dispatch, commit with Dispatch-Target-Id: all
  Action: commit without trailer
  Assert: new commit auto-carries Dispatch-Target-Id: all from previous
```

### Dispatch-Target-Id: all - Apply Tests

```
test_target_id_all_included_in_every_target
  Setup: source with commits: tid=1, tid=all, tid=2, tid=3
  Action: apply
  Assert: target-1 has 2 commits (tid=1 + tid=all)
  Assert: target-2 has 2 commits (tid=2 + tid=all)
  Assert: target-3 has 2 commits (tid=3 + tid=all)
  Assert: "all" commit content present in every target branch

test_target_id_all_dry_run_display
  Setup: source with commits: tid=1, tid=all, tid=2
  Action: apply --dry-run
  Assert: output shows "all" commit count
  Assert: output shows it will be included in all targets

test_target_id_all_only_commits
  Setup: source with only Dispatch-Target-Id: all commits
  Action: apply
  Assert: informational message (no targets to create, all commits are shared)
  Note: no target branches created since "all" doesn't define a target by itself

test_target_id_all_incremental_apply
  Setup: apply with tid=1, tid=all. Then add new tid=all commit.
  Action: apply again
  Assert: new "all" commit cherry-picked to target-1
  Assert: no duplicate of original "all" commit

test_target_id_all_status_not_untracked
  Setup: apply with tid=1, tid=all
  Action: status
  Assert: "all" commits not reported as untracked on any target
```

### checkout <N> - Basic Tests

```
test_checkout_creates_branch
  Setup: create_source (commits: tid=3, tid=4, tid=5)
  Action: checkout 4
  Assert: branch dispatch-checkout/source/feature/4 exists
  Assert: branch contains commits from tid=3 and tid=4
  Assert: branch does NOT contain tid=5 commit
  Assert: worktree created and path printed

test_checkout_includes_all_commits
  Setup: source with tid=1, tid=all, tid=2, tid=3
  Action: checkout 2
  Assert: checkout branch has commits for tid=1, tid=all, tid=2
  Assert: checkout branch does NOT have tid=3

test_checkout_preserves_source_order
  Setup: source with commits in order: A(tid=2), B(tid=1), C(tid=2), D(tid=1)
  Action: checkout 2
  Assert: all 4 commits present
  Assert: commit order matches source order (A, B, C, D), not grouped by target

test_checkout_decimal_targets
  Setup: source with tid=1, tid=1.5, tid=2, tid=3
  Action: checkout 2
  Assert: includes tid=1, tid=1.5, tid=2
  Assert: excludes tid=3

test_checkout_works_without_apply
  Setup: create source with commits, init dispatch, do NOT apply
  Action: checkout 3
  Assert: succeeds (cherry-picks from source, not from target branches)
  Assert: branch created with correct commits

test_checkout_errors_if_exists
  Setup: create source, checkout 3
  Action: checkout 3 again
  Assert: error "checkout branch already exists" with hint to clear

test_checkout_errors_if_not_initialized
  Setup: create branch with commits, no init
  Action: checkout 3
  Assert: error "Not initialized"

test_checkout_empty_range
  Setup: source with only tid=5, tid=6
  Action: checkout 3
  Assert: error or info "No commits with Dispatch-Target-Id <= 3"
```

### checkout <N> - Edge Cases

```
test_checkout_with_conflict
  Setup: source with tid=1 and tid=2 both modifying same file differently
  Note: in independent mode, these would conflict when combined
  Action: checkout 2
  Assert: if conflict, shows conflict details
  Assert: --resolve flag leaves cherry-pick active for manual resolution

test_checkout_from_non_source_branch
  Setup: create source, apply, switch to a target branch
  Action: checkout 3
  Assert: error "must be on source branch" (or auto-detect source from config)

test_checkout_stacked_mode_same_behavior
  Setup: init with --mode stacked, add commits
  Action: checkout 3
  Assert: same behavior as independent mode (checkout always cumulative)

test_checkout_large_N_includes_all
  Setup: source with tid=1, tid=2, tid=3
  Action: checkout 999
  Assert: includes all commits (1, 2, 3 all <= 999)
```

### checkout source - Tests

```
test_checkout_source_returns_to_source
  Setup: create source, checkout 3
  Action: checkout source
  Assert: current branch is source branch
  Assert: checkout worktree/branch still exists (not destroyed)

test_checkout_source_noop_on_source
  Setup: create source (already on source)
  Action: checkout source
  Assert: informational message "Already on source"
  Assert: exit 0

test_checkout_source_from_unrelated_branch
  Setup: create source, switch to unrelated branch
  Action: checkout source
  Assert: error or detects source from config and switches
```

### checkout clear - Tests

```
test_checkout_clear_removes_branch
  Setup: create source, checkout 3
  Action: checkout clear
  Assert: branch dispatch-checkout/<source>/3 deleted
  Assert: worktree removed
  Assert: returned to source branch

test_checkout_clear_warns_unpicked_commits
  Setup: create source, checkout 3, make new commit on checkout branch
  Action: checkout clear (without --force)
  Assert: warning about N unpicked commits
  Assert: branch NOT deleted
  Assert: hint to use --force or checkin

test_checkout_clear_force_with_unpicked
  Setup: create source, checkout 3, make new commit on checkout branch
  Action: checkout clear --force
  Assert: branch deleted despite unpicked commits
  Assert: worktree removed

test_checkout_clear_no_checkout_exists
  Setup: create source (no checkout created)
  Action: checkout clear
  Assert: informational message "No checkout branch found"
  Assert: exit 0

test_checkout_clear_from_checkout_branch
  Setup: create source, checkout 3, stay on checkout branch
  Action: checkout clear
  Assert: switches to source first
  Assert: then removes checkout branch and worktree

test_checkout_clear_clean_no_force_needed
  Setup: create source, checkout 3 (no new commits on checkout)
  Action: checkout clear
  Assert: clears without needing --force
```

### push - Simplified Syntax Tests

```
test_push_positional_all
  Setup: create source, apply
  Action: push all --dry-run
  Assert: output shows all target branches being pushed

test_push_positional_single
  Setup: create source, apply
  Action: push 3 --dry-run
  Assert: output shows only target-3 branch

test_push_positional_source
  Setup: create source
  Action: push source --dry-run
  Assert: output shows source branch

test_push_no_argument_errors
  Setup: create source
  Action: push (no args)
  Assert: error message
```

### checkin - Basic Tests

```
test_checkin_picks_new_commits_to_source
  Setup: create source with tid=1, tid=2. checkout 2.
         Make new commit on checkout branch with tid=2.
  Action: checkin
  Assert: source branch has the new commit
  Assert: new commit on source has Dispatch-Target-Id: 2
  Assert: checkout branch unchanged

test_checkin_no_new_commits
  Setup: create source, checkout 2 (no new commits made)
  Action: checkin
  Assert: informational message "No new commits to pick"
  Assert: exit 0

test_checkin_multiple_commits_different_targets
  Setup: checkout 3. Make commit A (tid=2), commit B (tid=3).
  Action: checkin
  Assert: both commits cherry-picked to source in order
  Assert: commit A on source has Dispatch-Target-Id: 2
  Assert: commit B on source has Dispatch-Target-Id: 3

test_checkin_does_not_auto_apply
  Setup: create source with tid=1, apply. checkout 1.
         Make new commit on checkout with tid=1.
  Action: checkin
  Assert: source has new commit
  Assert: target-1 does NOT have new commit (not auto-applied)
  Assert: output suggests "run apply to propagate"

test_checkin_errors_if_not_on_checkout
  Setup: create source (on source branch, no checkout)
  Action: checkin
  Assert: error "Not on a checkout branch"
```

### checkin - Edge Cases

```
test_checkin_conflict_with_source
  Setup: checkout 2. Make commit on checkout. Also make new commit on source.
         Both modify same file.
  Action: checkin
  Assert: conflict detected
  Assert: --resolve leaves cherry-pick active for resolution

test_checkin_source_keep_auto_resolves_conflict
  Setup: source with tid=1, tid=2 (both touch swagger.json). checkout 2.
         Modify swagger.json on checkout, commit with Dispatch-Target-Id: 2 + Dispatch-Source-Keep: true.
         Also modify swagger.json on source (so cherry-pick will conflict).
  Action: checkin
  Assert: no conflict (auto-resolved with checkout version via theirs)
  Assert: source swagger.json matches checkout version
  Assert: commit on source has both trailers preserved

test_checkin_skips_original_commits
  Setup: create source with tid=1, tid=2. checkout 2.
         Make one new commit on checkout.
  Action: checkin
  Assert: only the new commit is cherry-picked (not the original 2)
  Assert: source does not have duplicate commits
```

### Integration Tests

```
test_checkout_then_apply_independent
  Setup: source with tid=1, tid=2, tid=3
  Action: apply, then checkout 2
  Assert: checkout branch has same file content as combined target-1 + target-2
  Assert: targets unaffected by checkout operation

test_checkout_full_lifecycle
  Setup: source with tid=1, tid=all, tid=2, tid=3
  Action: checkout 2 -> verify content -> checkout source -> checkout clear
  Assert: each step works in sequence
  Assert: clean state after clear (no leftover branches or worktrees)

test_checkin_then_apply_lifecycle
  Setup: source with tid=1, tid=2. apply. checkout 2.
         Make new commit on checkout (tid=1).
  Action: checkin -> checkout source -> apply
  Assert: checkin puts commit on source
  Assert: apply propagates to target-1
  Assert: target-2 unaffected (commit was tid=1)

test_checkout_does_not_affect_targets
  Setup: source with tid=1, tid=2, apply
  Action: checkout 2, make changes on checkout branch
  Assert: target branches unchanged
  Assert: source branch unchanged

test_checkout_with_target_id_all_and_decimal
  Setup: source with tid=1, tid=all, tid=1.5, tid=2, tid=all, tid=3
  Action: checkout 2
  Assert: includes tid=1, first tid=all, tid=1.5, tid=2, second tid=all
  Assert: excludes tid=3
  Assert: order matches source order
```

---

## Implementation Notes

- Reuse `_enter_branch` / `_leave_branch` worktree primitives
- Reuse `_cherry_pick_commits` for cherry-picking to checkout branch
- Branch naming: `dispatch-checkout/<source>/<N>` where source may contain slashes
- Use `git config dispatch.checkoutBranch` to track active checkout (for `source` and `clear`)
- The rename touches 385 occurrences across 13 files (git-dispatch.sh, hooks, tests, docs)
- "all" commits during apply: iterate target_ids, for each target cherry-pick
  its own commits PLUS all "all" commits (in source order)
- For checkout, parse commit list once, filter by numeric comparison using awk/bc
- For checkin, use `_build_source_patch_id_map` to identify which checkout commits
  are new (not matching any source patch-id). Cherry-pick only those to source.
- checkin reuses `_cherry_pick_commits` for the source cherry-pick
- Command routing: `checkin` is a top-level command, not a checkout subcommand

## Open Questions

- Should `checkout <N>` also accept a target branch name instead of just a number?
  (e.g., `checkout source/feature-3` resolving to N=3)
- Should we allow multiple checkouts per source? Current plan: one at a time, clear first.
- Exact behavior of "all" in status: show as "(all)" annotation or count per-target?
