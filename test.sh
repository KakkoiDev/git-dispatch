#!/bin/bash
set -euo pipefail

# git-dispatch test suite
# Usage: bash test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/git-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0
TMPDIR=""

setup() {
    TMPDIR=$(mktemp -d)
    cd "$TMPDIR"
    git init --initial-branch=master -q
    git commit --allow-empty -m "init" -q
}

teardown() {
    cd /
    rm -rf "$TMPDIR"
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "  ${GREEN}PASS${NC} $msg"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} $msg"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "  ${GREEN}PASS${NC} $msg"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} $msg"
        echo "    expected to contain: $needle"
        echo "    actual: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo -e "  ${GREEN}PASS${NC} $msg"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} $msg"
        echo "    expected NOT to contain: $needle"
        echo "    actual: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_branch_exists() {
    local branch="$1" msg="${2:-branch $1 exists}"
    if git rev-parse --verify "$branch" >/dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC} $msg"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} $msg"
        FAIL=$((FAIL + 1))
    fi
}

assert_branch_not_exists() {
    local branch="$1" msg="${2:-branch $1 does not exist}"
    if git rev-parse --verify "$branch" >/dev/null 2>&1; then
        echo -e "  ${RED}FAIL${NC} $msg"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} $msg"
        PASS=$((PASS + 1))
    fi
}

# Create a source branch with trailer-tagged commits and init dispatch
create_source() {
    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add enum$(printf '\n\nDispatch-Target-Id: 3')" -q

    echo "b" > api.txt; git add api.txt
    git commit -m "Create GET endpoint$(printf '\n\nDispatch-Target-Id: 4')" -q

    echo "c" > dto.txt; git add dto.txt
    git commit -m "Add DTOs$(printf '\n\nDispatch-Target-Id: 4')" -q

    echo "d" > validate.txt; git add validate.txt
    git commit -m "Implement validation$(printf '\n\nDispatch-Target-Id: 5')" -q

    # Init dispatch
    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
}

# ---------- init tests ----------

test_init_basic() {
    echo "=== test: init basic ==="
    setup

    git checkout -b source/feature master -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" --mode independent

    local base mode target_pattern
    base=$(git config dispatch.base)
    mode=$(git config dispatch.mode)
    target_pattern=$(git config dispatch.targetPattern)

    assert_eq "master" "$base" "dispatch.base set"
    assert_eq "independent" "$mode" "dispatch.mode set"
    assert_eq "source/feature-task-{id}" "$target_pattern" "dispatch.targetPattern set"

    teardown
}

test_init_requires_base() {
    echo "=== test: init requires --base ==="
    setup

    git checkout -b source/feature master -q

    local output
    output=$(bash "$DISPATCH" init --target-pattern "source/feature-task-{id}" 2>&1) || true
    assert_contains "$output" "Missing required flags: --base and --target-pattern" "init shows combined required-flags error"

    teardown
}

test_init_requires_target_pattern() {
    echo "=== test: init requires --target-pattern ==="
    setup

    git checkout -b source/feature master -q

    local output
    output=$(bash "$DISPATCH" init --base master 2>&1) || true
    assert_contains "$output" "Missing required flags: --base and --target-pattern" "init shows combined required-flags error"

    teardown
}

test_init_stacked_mode() {
    echo "=== test: init stacked mode ==="
    setup

    git checkout -b source/feature master -q

    bash "$DISPATCH" init --base master --mode stacked --target-pattern "source/feature-task-{id}"

    local mode
    mode=$(git config dispatch.mode)
    assert_eq "stacked" "$mode" "mode set to stacked"

    teardown
}

test_init_custom_pattern() {
    echo "=== test: init custom target pattern ==="
    setup

    git checkout -b source/feature master -q

    bash "$DISPATCH" init --base master --target-pattern "custom/path-{id}-done"

    local target_pattern
    target_pattern=$(git config dispatch.targetPattern)
    assert_eq "custom/path-{id}-done" "$target_pattern" "custom target pattern set"

    teardown
}

test_init_reinit_warns() {
    echo "=== test: init reinit warns ==="
    setup

    git checkout -b source/feature master -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    local output
    output=$(echo "n" | bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" 2>&1) || true

    assert_contains "$output" "already configured" "warns about existing config"

    teardown
}

test_init_installs_hooks() {
    echo "=== test: init installs hooks ==="
    setup

    git checkout -b source/feature master -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    local hook_dir
    hook_dir="$(git rev-parse --git-dir)/hooks"

    if [[ -f "$hook_dir/commit-msg" ]]; then
        echo -e "  ${GREEN}PASS${NC} commit-msg hook installed"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} commit-msg hook not found"
        FAIL=$((FAIL + 1))
    fi

    if [[ -f "$hook_dir/prepare-commit-msg" ]]; then
        echo -e "  ${GREEN}PASS${NC} prepare-commit-msg hook installed"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} prepare-commit-msg hook not found"
        FAIL=$((FAIL + 1))
    fi

    if [[ -f "$hook_dir/post-merge" ]]; then
        echo -e "  ${RED}FAIL${NC} post-merge hook should not be installed"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} post-merge hook correctly absent"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_init_hooks_only() {
    echo "=== test: init --hooks installs hooks without config ==="
    setup

    bash "$DISPATCH" init --hooks >/dev/null 2>&1

    local hooks_path
    hooks_path=$(git config core.hooksPath 2>/dev/null || echo "")
    if [[ -n "$hooks_path" ]] && [[ -f "$hooks_path/commit-msg" ]]; then
        echo -e "  ${GREEN}PASS${NC} hooks installed via --hooks"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} hooks not installed"
        FAIL=$((FAIL + 1))
    fi

    # No dispatch config should exist
    local base
    base=$(git config dispatch.base 2>/dev/null || echo "")
    if [[ -z "$base" ]]; then
        echo -e "  ${GREEN}PASS${NC} no dispatch config created"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} dispatch config should not exist"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

# ---------- hook tests ----------

test_hook_rejects_missing_trailer() {
    echo "=== test: hook rejects commit without Dispatch-Target-Id ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" >/dev/null 2>&1

    echo "x" > x.txt; git add x.txt
    if git commit -m "no trailer" 2>/dev/null; then
        echo -e "  ${RED}FAIL${NC} hook should reject commit without Dispatch-Target-Id"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} hook rejects commit without Dispatch-Target-Id"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_hook_allows_valid_trailer() {
    echo "=== test: hook allows commit with Dispatch-Target-Id ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" >/dev/null 2>&1

    echo "x" > x.txt; git add x.txt
    git commit -m "with trailer$(printf '\n\nDispatch-Target-Id: 1')" -q
    if [[ $? -eq 0 ]]; then
        echo -e "  ${GREEN}PASS${NC} hook allows commit with Dispatch-Target-Id"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_hook_rejects_non_numeric_target_id() {
    echo "=== test: hook rejects non-numeric Dispatch-Target-Id ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" >/dev/null 2>&1

    echo "x" > x.txt; git add x.txt
    if git commit -m "bad id$(printf '\n\nDispatch-Target-Id: task-3')" 2>/dev/null; then
        echo -e "  ${RED}FAIL${NC} hook should reject non-numeric Dispatch-Target-Id"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} hook rejects non-numeric Dispatch-Target-Id"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_hook_allows_decimal_target_id() {
    echo "=== test: hook allows decimal Dispatch-Target-Id ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" >/dev/null 2>&1

    echo "x" > x.txt; git add x.txt
    git commit -m "decimal$(printf '\n\nDispatch-Target-Id: 1.5')" -q
    if [[ $? -eq 0 ]]; then
        echo -e "  ${GREEN}PASS${NC} hook allows decimal Dispatch-Target-Id"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_hook_auto_carry_target_id() {
    echo "=== test: hook auto-carries Dispatch-Target-Id from previous commit ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" >/dev/null 2>&1

    echo "a" > a.txt; git add a.txt
    git commit -m "first$(printf '\n\nDispatch-Target-Id: 3')" -q

    echo "b" > b.txt; git add b.txt
    git commit -m "second" -q

    local carried
    carried=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" | tr -d '[:space:]')
    assert_eq "3" "$carried" "Dispatch-Target-Id auto-carried from previous commit"

    teardown
}

test_hook_auto_carry_no_override() {
    echo "=== test: hook does not override explicit Dispatch-Target-Id ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" >/dev/null 2>&1

    echo "a" > a.txt; git add a.txt
    git commit -m "first$(printf '\n\nDispatch-Target-Id: 3')" -q

    echo "b" > b.txt; git add b.txt
    git commit -m "second" --trailer "Dispatch-Target-Id=4" -q

    local target_id
    target_id=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" | tr -d '[:space:]')
    assert_eq "4" "$target_id" "explicit Dispatch-Target-Id not overridden by auto-carry"

    teardown
}

test_worktree_shares_hooks_via_hookspath() {
    echo "=== test: worktree shares hooks via core.hooksPath ==="
    setup
    create_source

    # Verify core.hooksPath is set to an absolute path
    local hooks_path
    hooks_path=$(git config core.hooksPath 2>/dev/null || echo "")
    if [[ -n "$hooks_path" ]] && [[ "$hooks_path" == /* ]] && [[ -f "$hooks_path/commit-msg" ]]; then
        echo -e "  ${GREEN}PASS${NC} core.hooksPath is absolute with hooks"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} core.hooksPath not absolute or hooks missing (got: $hooks_path)"
        FAIL=$((FAIL + 1))
    fi

    # Create worktree from master (no Dispatch-Target-Id on HEAD) to test rejection
    local wt_path="$TMPDIR/worktree-test"
    git worktree add "$wt_path" -b wt-branch master -q 2>/dev/null

    # Verify commit without Dispatch-Target-Id is rejected from the worktree
    (cd "$wt_path" && echo "wt" > wt.txt && git add wt.txt)
    local wt_err
    if wt_err=$(git -C "$wt_path" commit -m "no trailer" 2>&1); then
        echo -e "  ${RED}FAIL${NC} worktree should reject commit without Dispatch-Target-Id"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} worktree rejects commit without Dispatch-Target-Id"
        PASS=$((PASS + 1))
    fi

    # Verify commit with Dispatch-Target-Id works from the worktree
    if git -C "$wt_path" commit -m "with trailer" --trailer "Dispatch-Target-Id=1" -q 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC} worktree allows commit with Dispatch-Target-Id"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} worktree should allow commit with Dispatch-Target-Id"
        FAIL=$((FAIL + 1))
    fi

    git worktree remove --force "$wt_path" 2>/dev/null || true
    teardown
}

# ---------- apply tests ----------

test_apply_creates_targets() {
    echo "=== test: apply creates target branches ==="
    setup
    create_source

    bash "$DISPATCH" apply

    assert_branch_exists "source/feature-3" "target-3 branch created"
    assert_branch_exists "source/feature-4" "target-4 branch created"
    assert_branch_exists "source/feature-5" "target-5 branch created"

    # target-3: 1 commit
    local count3
    count3=$(git log --oneline master..source/feature-3 | wc -l | tr -d ' ')
    assert_eq "1" "$count3" "target-3 has 1 commit"

    # target-4: 2 commits (independent - only own commits, from base)
    local count4
    count4=$(git log --oneline master..source/feature-4 | wc -l | tr -d ' ')
    assert_eq "2" "$count4" "target-4 has 2 commits"

    # target-5: 1 commit
    local count5
    count5=$(git log --oneline master..source/feature-5 | wc -l | tr -d ' ')
    assert_eq "1" "$count5" "target-5 has 1 commit"

    # Source association
    local src3
    src3=$(git config branch.source/feature-3.dispatchsource 2>/dev/null || true)
    assert_eq "source/feature" "$src3" "target-3 linked to source"

    # No upstream tracking inherited from base
    local upstream
    upstream=$(git config branch.source/feature-3.remote 2>/dev/null || echo "none")
    assert_eq "none" "$upstream" "target does not inherit upstream from base"

    teardown
}

test_apply_dry_run() {
    echo "=== test: apply --dry-run ==="
    setup
    create_source

    local output
    output=$(bash "$DISPATCH" apply --dry-run)

    assert_contains "$output" "create" "dry-run shows create"
    assert_contains "$output" "source/feature-3" "dry-run shows target-3"
    assert_contains "$output" "source/feature-4" "dry-run shows target-4"

    assert_branch_not_exists "source/feature-3" "dry-run did not create branches"

    teardown
}

test_apply_incremental() {
    echo "=== test: apply incremental (new commit) ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    # Add a new commit to source for target 4
    echo "fix" > fix.txt; git add fix.txt
    git commit -m "Fix DTO validation$(printf '\n\nDispatch-Target-Id: 4')" -q

    local before
    before=$(git log --oneline master..source/feature-4 | wc -l | tr -d ' ')

    bash "$DISPATCH" apply

    local after
    after=$(git log --oneline master..source/feature-4 | wc -l | tr -d ' ')

    assert_eq "$((before + 1))" "$after" "new source commit cherry-picked into target"

    teardown
}

test_apply_new_target_mid_stack() {
    echo "=== test: apply creates new target mid-stack ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add A$(printf '\n\nDispatch-Target-Id: 1')" -q

    echo "c" > c.txt; git add c.txt
    git commit -m "Add C$(printf '\n\nDispatch-Target-Id: 3')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    assert_branch_exists "source/feature-1" "target-1 created"
    assert_branch_exists "source/feature-3" "target-3 created"

    # Add target 2 (mid-stack insert via numeric sort)
    echo "b" > b.txt; git add b.txt
    git commit -m "Add B$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" apply >/dev/null

    assert_branch_exists "source/feature-2" "target-2 created (mid-stack)"

    teardown
}

test_apply_idempotent() {
    echo "=== test: apply is idempotent ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    local tip3 tip4 tip5
    tip3=$(git rev-parse source/feature-3)
    tip4=$(git rev-parse source/feature-4)
    tip5=$(git rev-parse source/feature-5)

    bash "$DISPATCH" apply >/dev/null

    assert_eq "$tip3" "$(git rev-parse source/feature-3)" "target-3 unchanged"
    assert_eq "$tip4" "$(git rev-parse source/feature-4)" "target-4 unchanged"
    assert_eq "$tip5" "$(git rev-parse source/feature-5)" "target-5 unchanged"

    teardown
}

test_apply_stacked_mode() {
    echo "=== test: apply stacked mode ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add enum$(printf '\n\nDispatch-Target-Id: 1')" -q

    echo "b" > api.txt; git add api.txt
    git commit -m "Create endpoint$(printf '\n\nDispatch-Target-Id: 2')" -q

    echo "c" > validate.txt; git add validate.txt
    git commit -m "Add validation$(printf '\n\nDispatch-Target-Id: 3')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" --mode stacked >/dev/null 2>&1
    bash "$DISPATCH" apply

    assert_branch_exists "source/feature-1" "target-1 created"
    assert_branch_exists "source/feature-2" "target-2 created"
    assert_branch_exists "source/feature-3" "target-3 created"

    # In stacked mode: target-2 branches from target-1, so it has 1's commits + 2's commits
    local count2
    count2=$(git log --oneline master..source/feature-2 | wc -l | tr -d ' ')
    assert_eq "2" "$count2" "target-2 has 2 commits (stacked on target-1)"

    local count3
    count3=$(git log --oneline master..source/feature-3 | wc -l | tr -d ' ')
    assert_eq "3" "$count3" "target-3 has 3 commits (stacked on target-2)"

    teardown
}

test_apply_conflict_aborts() {
    echo "=== test: apply conflict aborts cleanly ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add file$(printf '\n\nDispatch-Target-Id: 1')" -q

    echo "b" > file.txt; git add file.txt
    git commit -m "Modify file$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    # Advance master with conflicting content
    git checkout master -q
    echo "conflict" > file.txt; git add file.txt
    git commit --no-verify -m "Master changes file" -q

    git checkout source/feature -q

    # Apply in independent mode - target-2 will conflict (it modifies file.txt that doesn't exist on base in same state)
    local output
    output=$(bash "$DISPATCH" apply 2>&1) || true

    # target-1 should still be created
    assert_branch_exists "source/feature-1" "target-1 created before conflict"

    teardown
}

test_apply_create_auto_resolves_with_theirs() {
    echo "=== test: apply create auto-resolves conflicts with --theirs ==="
    setup

    # Create a file on master that will conflict
    echo "base-generated-content" > generated.txt; git add generated.txt
    git commit --no-verify -m "Base generated file" -q

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    # Commit 1: modify generated file (will conflict since master has different content after next step)
    echo "source-v1" > generated.txt; git add generated.txt
    git commit -m "Update generated file$(printf '\n\nDispatch-Target-Id: 1')" -q

    # Commit 2: another change to same target
    echo "source-v2" > generated.txt; git add generated.txt
    git commit -m "Update generated again$(printf '\n\nDispatch-Target-Id: 1')" -q

    # Advance master so the file diverges from base
    git checkout master -q
    echo "master-diverged" > generated.txt; git add generated.txt
    git commit --no-verify -m "Master diverges generated file" -q

    git checkout source/feature -q

    # Apply - target branches from master, cherry-pick will conflict on generated.txt
    local output
    output=$(bash "$DISPATCH" apply 2>&1) || true

    # Should auto-resolve with --theirs and create the branch
    assert_contains "$output" "Auto-resolved conflict" "reports auto-resolution"
    assert_branch_exists "source/feature-1" "target created despite conflict"

    # Target should have the source version of the file
    local target_content
    target_content=$(git show source/feature-1:generated.txt)
    assert_eq "source-v2" "$target_content" "target has source version of conflicted file"

    # Semantic check recognizes auto-resolved commits as equivalent - shows in sync
    local status_output
    status_output=$(bash "$DISPATCH" status 2>&1 | sed $'s/\033\\[[0-9;]*m//g')
    assert_contains "$status_output" "in sync" "target in sync after auto-resolve (semantic match)"
    assert_not_contains "$status_output" "behind" "not behind after auto-resolve"
    assert_not_contains "$status_output" "DIVERGED" "no divergence after auto-resolve"

    teardown
}

# ---------- cherry-pick tests ----------

test_cherry_pick_source_to_target() {
    echo "=== test: cherry-pick --from source --to <id> ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    # Add new commit for target 4
    echo "fix" > fix.txt; git add fix.txt
    git commit -m "Fix endpoint$(printf '\n\nDispatch-Target-Id: 4')" -q

    local before
    before=$(git log --oneline master..source/feature-4 | wc -l | tr -d ' ')

    bash "$DISPATCH" cherry-pick --from source --to 4

    local after
    after=$(git log --oneline master..source/feature-4 | wc -l | tr -d ' ')

    assert_eq "$((before + 1))" "$after" "commit cherry-picked from source to target"

    teardown
}

test_cherry_pick_target_to_source() {
    echo "=== test: cherry-pick --from <id> --to source ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    # Add commit directly on target branch
    git checkout source/feature-3 -q
    echo "hotfix" > hotfix.txt; git add hotfix.txt
    git commit --no-verify -m "Hotfix on target" -q
    git checkout source/feature -q

    local before
    before=$(git log --oneline master..source/feature | wc -l | tr -d ' ')

    bash "$DISPATCH" cherry-pick --from 3 --to source

    local after
    after=$(git log --oneline master..source/feature | wc -l | tr -d ' ')

    assert_eq "$((before + 1))" "$after" "commit cherry-picked from target to source"

    teardown
}

test_cherry_pick_adds_trailer() {
    echo "=== test: cherry-pick --from <id> --to source adds Dispatch-Target-Id ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    # Commit on target without proper Dispatch-Target-Id
    git checkout source/feature-3 -q
    echo "fix" > fix.txt; git add fix.txt
    git commit --no-verify -m "Fix without trailer" -q
    git checkout source/feature -q

    bash "$DISPATCH" cherry-pick --from 3 --to source

    local source_trailer
    source_trailer=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" source/feature | tr -d '[:space:]')
    assert_eq "3" "$source_trailer" "Dispatch-Target-Id trailer added on cherry-pick to source"

    teardown
}

test_cherry_pick_dry_run() {
    echo "=== test: cherry-pick --dry-run ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    echo "fix" > fix.txt; git add fix.txt
    git commit -m "Fix$(printf '\n\nDispatch-Target-Id: 4')" -q

    local output
    output=$(bash "$DISPATCH" cherry-pick --from source --to 4 --dry-run)

    assert_contains "$output" "dry-run" "dry-run label shown"

    teardown
}

test_cherry_pick_target_to_source_noop_semantic_sync() {
    echo "=== test: cherry-pick --from <id> --to source skips no-op semantic commit ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    # Target-only commit (Dispatch-Target-Id 3): add "hotfix" line.
    git checkout source/feature-3 -q
    printf "a\nhotfix\n" > file.txt; git add file.txt
    git commit --no-verify -m "Target hotfix" -q

    # Source independently contains the same hotfix already, plus extra change in same commit.
    # Patch-id differs, but cherry-picking target commit to source is a semantic no-op.
    git checkout source/feature -q
    printf "a\nhotfix\n" > file.txt
    echo "extra" > extra.txt
    git add file.txt extra.txt
    git commit -m "Broader source change$(printf '\n\nDispatch-Target-Id: 4')" -q

    local before after cp_output status_output target3_line
    before=$(git rev-list --count master..source/feature)

    cp_output=$(bash "$DISPATCH" cherry-pick --from 3 --to source 2>&1 | sed $'s/\033\\[[0-9;]*m//g')
    after=$(git rev-list --count master..source/feature)

    assert_eq "$before" "$after" "no new source commit created for no-op semantic cherry-pick"
    assert_contains "$cp_output" "Source already has all commits from target 3" "reports semantic no-op target->source sync"

    status_output=$(bash "$DISPATCH" status 2>&1 | sed $'s/\033\\[[0-9;]*m//g')
    target3_line=$(echo "$status_output" | grep "source/feature-3" || true)
    assert_contains "$target3_line" "in sync" "target-3 treated as semantically in sync"
    assert_not_contains "$target3_line" "ahead" "target-3 no longer shown ahead on no-op semantic commit"

    teardown
}

# ---------- rebase tests ----------

test_rebase_base_to_source() {
    echo "=== test: rebase --from base --to source ==="
    setup
    create_source

    # Advance master
    git checkout master -q
    echo "new" > new.txt; git add new.txt
    git commit --no-verify -m "advance master" -q
    git checkout source/feature -q

    bash "$DISPATCH" rebase --from base --to source

    # Source should have linear history (no merges)
    local merge_count
    merge_count=$(git rev-list --merges master..source/feature | wc -l | tr -d ' ')
    assert_eq "0" "$merge_count" "linear history after rebase"

    # new.txt should be accessible
    if git show source/feature:new.txt >/dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC} base content available after rebase"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} base content not available"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_rebase_dry_run() {
    echo "=== test: rebase --dry-run ==="
    setup
    create_source

    git checkout master -q
    echo "new" > new.txt; git add new.txt
    git commit --no-verify -m "advance" -q
    git checkout source/feature -q

    local output
    output=$(bash "$DISPATCH" rebase --from base --to source --dry-run)

    assert_contains "$output" "dry-run" "dry-run label shown"

    teardown
}

# ---------- merge tests ----------

test_merge_base_to_source() {
    echo "=== test: merge --from base --to source ==="
    setup
    create_source

    # Advance master
    git checkout master -q
    echo "new" > new.txt; git add new.txt
    git commit --no-verify -m "advance master" -q
    git checkout source/feature -q

    bash "$DISPATCH" merge --from base --to source

    # Source should have merge commit
    local parent_count
    parent_count=$(git cat-file -p HEAD | grep -c '^parent ')
    assert_eq "2" "$parent_count" "source has merge commit"

    if [[ -f "new.txt" ]]; then
        echo -e "  ${GREEN}PASS${NC} base content merged into source"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} base content not merged"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_merge_dry_run() {
    echo "=== test: merge --dry-run ==="
    setup
    create_source

    git checkout master -q
    echo "new" > new.txt; git add new.txt
    git commit --no-verify -m "advance" -q
    git checkout source/feature -q

    local output
    output=$(bash "$DISPATCH" merge --from base --to source --dry-run)

    assert_contains "$output" "dry-run" "dry-run label shown"

    teardown
}

# ---------- push tests ----------

test_push_dry_run_all() {
    echo "=== test: push all --dry-run ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    local output
    output=$(bash "$DISPATCH" push all --dry-run)

    assert_contains "$output" "source/feature-3" "push shows target-3"
    assert_contains "$output" "source/feature-4" "push shows target-4"
    assert_contains "$output" "source/feature-5" "push shows target-5"

    teardown
}

test_push_dry_run_single() {
    echo "=== test: push <N> --dry-run ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    local output
    output=$(bash "$DISPATCH" push 4 --dry-run)

    assert_contains "$output" "source/feature-4" "push shows target-4"
    assert_not_contains "$output" "source/feature-3" "push excludes target-3"
    assert_not_contains "$output" "source/feature-5" "push excludes target-5"

    teardown
}

test_push_force_dry_run() {
    echo "=== test: push --force --dry-run ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    local output
    output=$(bash "$DISPATCH" push all --force --dry-run)

    assert_contains "$output" "--force-with-lease" "force uses --force-with-lease"

    teardown
}

test_push_source_dry_run() {
    echo "=== test: push source --dry-run ==="
    setup
    create_source

    local output
    output=$(bash "$DISPATCH" push source --dry-run)

    assert_contains "$output" "source/feature" "push shows source branch"

    teardown
}

test_push_no_argument_errors() {
    echo "=== test: push no argument errors ==="
    setup
    create_source

    local output
    output=$(bash "$DISPATCH" push 2>&1) || true

    assert_contains "$output" "Usage" "push with no args shows usage"

    teardown
}

# ---------- status tests ----------

test_status_shows_mode() {
    echo "=== test: status shows mode ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    local output
    output=$(bash "$DISPATCH" status 2>&1)

    assert_contains "$output" "independent" "status shows mode"
    assert_contains "$output" "master" "status shows base"
    assert_contains "$output" "source/feature" "status shows source"

    teardown
}

test_status_in_sync() {
    echo "=== test: status shows in sync after apply ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    local output
    output=$(bash "$DISPATCH" status 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    assert_contains "$output" "in sync" "status shows in sync"

    teardown
}

test_status_shows_pending() {
    echo "=== test: status shows pending commits ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    # Add new commit for target 4
    echo "fix" > fix.txt; git add fix.txt
    git commit -m "Fix$(printf '\n\nDispatch-Target-Id: 4')" -q

    local output
    output=$(bash "$DISPATCH" status 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    assert_contains "$output" "behind source" "status shows behind count"

    teardown
}

test_status_not_created() {
    echo "=== test: status shows not created targets ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "A$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    # Don't apply - targets don't exist yet
    local output
    output=$(bash "$DISPATCH" status 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    assert_contains "$output" "not created" "status shows not created"

    teardown
}

# ---------- reset tests ----------

test_reset_cleans_up() {
    echo "=== test: reset cleans everything ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    bash "$DISPATCH" reset --force

    # Branches should be deleted
    assert_branch_not_exists "source/feature-3" "target-3 deleted"
    assert_branch_not_exists "source/feature-4" "target-4 deleted"
    assert_branch_not_exists "source/feature-5" "target-5 deleted"

    # Config should be cleaned
    local base
    base=$(git config dispatch.base 2>/dev/null || true)
    assert_eq "" "$base" "dispatch.base removed"

    local mode
    mode=$(git config dispatch.mode 2>/dev/null || true)
    assert_eq "" "$mode" "dispatch.mode removed"

    teardown
}

# ---------- help test ----------

test_help() {
    echo "=== test: help ==="
    local output
    output=$(bash "$DISPATCH" help)
    assert_contains "$output" "SETUP" "help shows setup"
    assert_contains "$output" "COMMANDS" "help shows commands"
    assert_contains "$output" "TRAILERS" "help shows trailers"
}

# ---------- install test ----------

test_install_chmod() {
    echo "=== test: install.sh makes script executable ==="
    local install_dir
    install_dir=$(mktemp -d)
    cp "$SCRIPT_DIR/git-dispatch.sh" "$install_dir/"
    cp "$SCRIPT_DIR/install.sh" "$install_dir/"

    chmod -x "$install_dir/git-dispatch.sh"

    HOME="$install_dir" bash "$install_dir/install.sh" >/dev/null

    if [[ -x "$install_dir/git-dispatch.sh" ]]; then
        echo -e "  ${GREEN}PASS${NC} install.sh makes script executable"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} install.sh did not make script executable"
        FAIL=$((FAIL + 1))
    fi

    rm -rf "$install_dir"
}

# ---------- decimal target-id ordering ----------

test_apply_decimal_target_id() {
    echo "=== test: apply with decimal Dispatch-Target-Id ordering ==="
    setup

    git checkout -b source/feature master -q
    echo "b" > b.txt; git add b.txt
    git commit -m "Add B$(printf '\n\nDispatch-Target-Id: 2')" -q

    echo "a" > a.txt; git add a.txt
    git commit -m "Add A$(printf '\n\nDispatch-Target-Id: 1')" -q

    echo "mid" > mid.txt; git add mid.txt
    git commit -m "Add mid$(printf '\n\nDispatch-Target-Id: 1.5')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply

    assert_branch_exists "source/feature-1" "target-1 created"
    assert_branch_exists "source/feature-1.5" "target-1.5 created"
    assert_branch_exists "source/feature-2" "target-2 created"

    # Verify numeric ordering (1, 1.5, 2 regardless of commit order)
    local targets
    targets=$(git for-each-ref --format='%(refname:short)' refs/heads/ | grep '^source/feature-' | grep -v '^source/feature$' || true)
    assert_contains "$targets" "source/feature-1" "target-1 exists"
    assert_contains "$targets" "source/feature-1.5" "target-1.5 exists"
    assert_contains "$targets" "source/feature-2" "target-2 exists"

    teardown
}

# ---------- conflict handling tests ----------

test_cherry_pick_conflict_shows_details() {
    echo "=== test: cherry-pick conflict shows file details ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add file$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Create conflict: modify file.txt on target, then add conflicting source commit
    git checkout source/feature-1 -q
    echo "target-change" > file.txt; git add file.txt
    git commit --no-verify -m "Target modifies file" -q

    git checkout source/feature -q
    echo "source-change" > file.txt; git add file.txt
    git commit -m "Source modifies file$(printf '\n\nDispatch-Target-Id: 1')" -q

    local output
    output=$(bash "$DISPATCH" cherry-pick --from source --to 1 2>&1) || true

    assert_contains "$output" "Conflict on commit" "shows conflict position"
    assert_contains "$output" "Conflicted files" "shows conflicted files header"
    assert_contains "$output" "file.txt" "shows conflicted filename"
    assert_contains "$output" "Aborted" "shows abort message"
    assert_contains "$output" "--resolve" "suggests --resolve flag"

    teardown
}

test_cherry_pick_conflict_resolve_leaves_active() {
    echo "=== test: cherry-pick --resolve leaves conflict active ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add file$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "d" > d.txt; git add d.txt
    git commit -m "Add d$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "e" > e.txt; git add e.txt
    git commit -m "Add e$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Create conflict on file.txt
    git checkout source/feature-1 -q
    echo "target-change" > file.txt; git add file.txt
    git commit --no-verify -m "Target modifies file" -q

    git checkout source/feature -q
    echo "source-change" > file.txt; git add file.txt
    git commit -m "Source modifies file$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "f" > f.txt; git add f.txt
    git commit -m "Add f$(printf '\n\nDispatch-Target-Id: 1')" -q

    local output
    output=$(bash "$DISPATCH" cherry-pick --from source --to 1 --resolve 2>&1) || true

    assert_contains "$output" "Resolve conflicts" "shows resolve instructions"
    assert_contains "$output" "cherry-pick --continue" "shows continue command"
    assert_contains "$output" "Remaining commits" "shows remaining commits"

    # Verify worktree path is printed for conflict resolution
    if echo "$output" | grep -q "Worktree left at:"; then
        echo -e "  ${GREEN}PASS${NC} worktree path printed for resolution"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} worktree path not printed"
        FAIL=$((FAIL + 1))
    fi

    # Clean up any leftover worktrees
    git worktree prune 2>/dev/null || true

    teardown
}

test_cherry_pick_conflict_batch_reporting() {
    echo "=== test: cherry-pick conflict shows batch progress ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add a$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Create conflict on a.txt
    git checkout source/feature-1 -q
    echo "conflict" > a.txt; git add a.txt
    git commit --no-verify -m "Target modifies a" -q

    # Add 3 new source commits for target 1 - first will conflict
    git checkout source/feature -q
    echo "source-a" > a.txt; git add a.txt
    git commit -m "Source modifies a$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "Add b$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "c" > c.txt; git add c.txt
    git commit -m "Add c$(printf '\n\nDispatch-Target-Id: 1')" -q

    local output
    output=$(bash "$DISPATCH" cherry-pick --from source --to 1 --resolve 2>&1) || true

    assert_contains "$output" "Conflict on commit 1/3" "shows batch position"
    assert_contains "$output" "Remaining commits" "lists remaining commits"

    # Clean up
    git cherry-pick --abort 2>/dev/null || git reset --merge 2>/dev/null || true
    git checkout source/feature -q 2>/dev/null || true

    teardown
}

test_rebase_conflict_shows_details() {
    echo "=== test: rebase conflict shows details ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add file$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    # Advance master with conflicting content
    git checkout master -q
    echo "conflict" > file.txt; git add file.txt
    git commit --no-verify -m "Master changes file" -q

    git checkout source/feature -q

    local output
    output=$(bash "$DISPATCH" rebase --from base --to source 2>&1) || true

    assert_contains "$output" "Rebase conflict" "shows rebase conflict header"
    assert_contains "$output" "Conflicted files" "shows conflicted files"
    assert_contains "$output" "file.txt" "shows conflicted filename"
    assert_contains "$output" "Aborted" "shows abort message"

    teardown
}

test_rebase_conflict_resolve() {
    echo "=== test: rebase --resolve leaves conflict active ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add file$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    git checkout master -q
    echo "conflict" > file.txt; git add file.txt
    git commit --no-verify -m "Master changes file" -q

    git checkout source/feature -q

    local output
    output=$(bash "$DISPATCH" rebase --from base --to source --resolve 2>&1) || true

    assert_contains "$output" "Resolve conflicts" "shows resolve instructions"
    assert_contains "$output" "rebase --continue" "shows rebase continue command"
    assert_contains "$output" "Worktree left at:" "shows worktree path"

    # Clean up any leftover worktrees
    git worktree prune 2>/dev/null || true

    teardown
}

test_merge_conflict_shows_details() {
    echo "=== test: merge conflict shows details ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add file$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    git checkout master -q
    echo "conflict" > file.txt; git add file.txt
    git commit --no-verify -m "Master changes file" -q

    git checkout source/feature -q

    local output
    output=$(bash "$DISPATCH" merge --from base --to source 2>&1) || true

    assert_contains "$output" "Merge conflict" "shows merge conflict header"
    assert_contains "$output" "Conflicted files" "shows conflicted files"
    assert_contains "$output" "file.txt" "shows conflicted filename"

    teardown
}

test_merge_conflict_resolve() {
    echo "=== test: merge --resolve leaves conflict active ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add file$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    git checkout master -q
    echo "conflict" > file.txt; git add file.txt
    git commit --no-verify -m "Master changes file" -q

    git checkout source/feature -q

    local output
    output=$(bash "$DISPATCH" merge --from base --to source --resolve 2>&1) || true

    assert_contains "$output" "Resolve conflicts" "shows resolve instructions"
    assert_contains "$output" "commit" "shows commit command"
    assert_contains "$output" "Worktree left at:" "shows worktree path"

    # Clean up any leftover worktrees
    git worktree prune 2>/dev/null || true

    teardown
}

# ---------- divergence detection tests ----------

test_status_shows_diverged() {
    echo "=== test: status detects DIVERGED targets ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add file$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Create real divergence: different content on source and target
    git checkout source/feature-1 -q
    echo "target-version" > file.txt; git add file.txt
    git commit --no-verify -m "Target modification" -q

    git checkout source/feature -q
    echo "source-version" > file.txt; git add file.txt
    git commit -m "Source modification$(printf '\n\nDispatch-Target-Id: 1')" -q

    local output
    output=$(bash "$DISPATCH" status 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    assert_contains "$output" "DIVERGED" "status shows DIVERGED tag"
    assert_contains "$output" "git dispatch diff" "status shows diff hint"

    teardown
}

test_diff_shows_diverged_files() {
    echo "=== test: diff shows diverged files and resolution hints ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add file$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Create divergence
    git checkout source/feature-1 -q
    echo "target-version" > file.txt; git add file.txt
    git commit --no-verify -m "Target modification" -q

    git checkout source/feature -q
    echo "source-version" > file.txt; git add file.txt
    git commit -m "Source modification$(printf '\n\nDispatch-Target-Id: 1')" -q

    local output
    output=$(bash "$DISPATCH" diff --to 1 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    assert_contains "$output" "Files diverged" "diff shows diverged header"
    assert_contains "$output" "file.txt" "diff shows diverged filename"
    assert_contains "$output" "cherry-pick --from 1 --to source" "diff shows target-to-source resolution"
    assert_contains "$output" "cherry-pick --from source --to 1" "diff shows source-to-target resolution"
    assert_contains "$output" "git dispatch apply" "diff shows apply sync hint"

    teardown
}

test_diff_no_difference() {
    echo "=== test: diff reports no difference when in sync ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add file$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    local output
    output=$(bash "$DISPATCH" diff --to 1 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    assert_contains "$output" "No content difference" "diff reports no difference"

    teardown
}

test_status_semantic_source_to_target() {
    echo "=== test: status uses semantic check for source->target ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add file$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Amend the target commit so it has a different SHA but same content
    git checkout source/feature-1 -q
    git commit --amend --no-edit -q --allow-empty
    git checkout source/feature -q

    # git cherry sees different patch-ids, but content is identical
    local status_output
    status_output=$(bash "$DISPATCH" status 2>&1 | sed $'s/\033\\[[0-9;]*m//g')
    assert_contains "$status_output" "in sync" "semantic match detects equivalent content"
    assert_not_contains "$status_output" "behind" "no false behind after amend"

    teardown
}

# ---------- end-to-end lifecycle ----------

test_apply_reset_regenerates_target() {
    echo "=== test: apply --reset regenerates target branch ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" >/dev/null 2>&1

    echo "file1" > f1.txt; git add f1.txt
    git commit -m "Task 1$(printf '\n\nDispatch-Target-Id: 1')" -q

    echo "file2" > f2.txt; git add f2.txt
    git commit -m "Task 2$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" apply >/dev/null

    # Record original commit count on target 1
    local orig_count
    orig_count=$(git log --oneline master..source/feature-task-1 | wc -l | tr -d ' ')
    assert_eq "1" "$orig_count" "target-1 has 1 commit before reset"

    # Reset target 1 - should delete and recreate
    local reset_output
    reset_output=$(bash "$DISPATCH" apply --reset 1 2>&1)
    assert_contains "$reset_output" "Deleted source/feature-task-1" "reports branch deletion"
    assert_contains "$reset_output" "Created source/feature-task-1" "reports branch recreation"

    # Branch still exists with correct content
    assert_branch_exists "source/feature-task-1" "target-1 exists after reset"
    local new_count
    new_count=$(git log --oneline master..source/feature-task-1 | wc -l | tr -d ' ')
    assert_eq "1" "$new_count" "target-1 still has 1 commit after reset"

    # Target 2 was not affected
    local count2
    count2=$(git log --oneline master..source/feature-task-2 | wc -l | tr -d ' ')
    assert_eq "1" "$count2" "target-2 unaffected by reset of target-1"

    teardown
}

test_full_lifecycle() {
    echo "=== test: full lifecycle ==="
    setup

    # 1. Setup
    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" >/dev/null 2>&1

    # 2. Build
    echo "schema" > schema.sql; git add schema.sql
    git commit -m "Schema change$(printf '\n\nDispatch-Target-Id: 1')" -q

    echo "endpoint" > endpoint.ts; git add endpoint.ts
    git commit -m "Backend endpoint$(printf '\n\nDispatch-Target-Id: 2')" -q

    echo "component" > component.tsx; git add component.tsx
    git commit -m "Frontend component$(printf '\n\nDispatch-Target-Id: 3')" -q

    # 3. Apply
    bash "$DISPATCH" apply >/dev/null

    assert_branch_exists "source/feature-task-1" "task-1 created"
    assert_branch_exists "source/feature-task-2" "task-2 created"
    assert_branch_exists "source/feature-task-3" "task-3 created"

    # 4. Status shows in sync
    local status_output
    status_output=$(bash "$DISPATCH" status 2>&1 | sed $'s/\033\\[[0-9;]*m//g')
    assert_contains "$status_output" "in sync" "all targets in sync after apply"

    # 5. Add fix, re-apply
    echo "fix" > fix.ts; git add fix.ts
    git commit -m "Fix endpoint$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" apply >/dev/null

    local count2
    count2=$(git log --oneline master..source/feature-task-2 | wc -l | tr -d ' ')
    assert_eq "2" "$count2" "task-2 has 2 commits after fix"

    # 6. Reset
    bash "$DISPATCH" reset --force >/dev/null

    assert_branch_not_exists "source/feature-task-1" "task-1 deleted after reset"
    assert_branch_not_exists "source/feature-task-2" "task-2 deleted after reset"
    assert_branch_not_exists "source/feature-task-3" "task-3 deleted after reset"

    teardown
}

# ---------- refresh_base tests ----------

# Helper: create a bare "remote" repo and configure origin
setup_with_remote() {
    TMPDIR=$(mktemp -d)
    local bare_dir="$TMPDIR/bare.git"
    git init --bare --initial-branch=master -q "$bare_dir"

    cd "$TMPDIR"
    git clone -q "$bare_dir" repo
    cd repo
    git commit --allow-empty -m "init" -q
    git push -q origin master 2>/dev/null
}

teardown_with_remote() {
    cd /
    rm -rf "$TMPDIR"
}

test_refresh_base_fetches_remote() {
    echo "=== test: apply fetches origin/master before creating targets ==="
    setup_with_remote

    # Create source and init with origin/master base
    git checkout -b source/feature -q
    bash "$DISPATCH" init --base origin/master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    echo "a" > file.txt; git add file.txt
    git commit -m "Add feature$(printf '\n\nDispatch-Target-Id: 1')" -q

    # Simulate stale origin/master by pushing new commits from another clone
    local other_clone="$TMPDIR/other"
    git clone -q "$TMPDIR/bare.git" "$other_clone"
    cd "$other_clone"
    echo "upstream change" > upstream.txt; git add upstream.txt
    git commit -m "upstream commit" -q
    git push -q origin master 2>/dev/null
    cd "$TMPDIR/repo"

    # Record stale SHA
    local stale_sha
    stale_sha=$(git rev-parse origin/master)

    # Apply should fetch and use updated origin/master
    local output
    output=$(bash "$DISPATCH" apply 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    # Verify origin/master was updated
    local fresh_sha
    fresh_sha=$(git rev-parse origin/master)
    assert_eq "false" "$([ "$stale_sha" = "$fresh_sha" ] && echo true || echo false)" "origin/master updated by apply"

    # Verify the info message about base update
    assert_contains "$output" "Base origin/master updated" "apply informs user about base update"

    # Verify target branched from fresh base (contains upstream.txt)
    local has_upstream_file
    has_upstream_file=$(git ls-tree source/feature-1 --name-only | grep -c "upstream.txt" || true)
    assert_eq "1" "$has_upstream_file" "target includes upstream commit from fresh base"

    teardown_with_remote
}

test_refresh_base_noop_when_up_to_date() {
    echo "=== test: apply does not report update when base is current ==="
    setup_with_remote

    git checkout -b source/feature -q
    bash "$DISPATCH" init --base origin/master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    echo "a" > file.txt; git add file.txt
    git commit -m "Add feature$(printf '\n\nDispatch-Target-Id: 1')" -q

    # No new upstream commits - base is already current
    local output
    output=$(bash "$DISPATCH" apply 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    assert_not_contains "$output" "Base origin/master updated" "no update message when base is current"

    teardown_with_remote
}

test_refresh_base_local_branch_with_remote() {
    echo "=== test: apply updates local base branch with remote tracking ==="
    setup_with_remote

    # Set up local master tracking origin/master (already done by clone)
    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    echo "a" > file.txt; git add file.txt
    git commit -m "Add feature$(printf '\n\nDispatch-Target-Id: 1')" -q

    # Push upstream commit from another clone to advance origin/master
    local other_clone="$TMPDIR/other"
    git clone -q "$TMPDIR/bare.git" "$other_clone"
    cd "$other_clone"
    echo "upstream change" > upstream.txt; git add upstream.txt
    git commit -m "upstream commit" -q
    git push -q origin master 2>/dev/null
    cd "$TMPDIR/repo"

    # Apply should pull --rebase master and use updated base
    local output
    output=$(bash "$DISPATCH" apply 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    assert_contains "$output" "Base master updated" "apply informs about local base update"

    # Verify target branched from updated master (contains upstream.txt)
    local has_upstream_file
    has_upstream_file=$(git ls-tree source/feature-1 --name-only | grep -c "upstream.txt" || true)
    assert_eq "1" "$has_upstream_file" "target includes upstream commit via local base pull"

    teardown_with_remote
}

test_refresh_base_warns_on_fetch_failure() {
    echo "=== test: apply warns when fetch fails ==="
    setup

    git checkout -b source/feature master -q
    # Set base to a non-existent remote
    git config dispatch.base "nonexistent/master"
    git config dispatch.targetPattern "source/feature-{id}"
    git config dispatch.mode "independent"

    echo "a" > file.txt; git add file.txt
    git commit -m "Add feature$(printf '\n\nDispatch-Target-Id: 1')" -q

    # Apply should warn but not crash
    local output
    output=$(bash "$DISPATCH" apply 2>&1 | sed $'s/\033\\[[0-9;]*m//g') || true

    assert_contains "$output" "does not resolve" "warns about unresolvable base ref"

    teardown
}

test_rebase_refreshes_base() {
    echo "=== test: rebase fetches origin/master before rebasing ==="
    setup_with_remote

    git checkout -b source/feature -q
    bash "$DISPATCH" init --base origin/master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    echo "a" > file.txt; git add file.txt
    git commit -m "Add feature$(printf '\n\nDispatch-Target-Id: 1')" -q

    # Push upstream commit from another clone
    local other_clone="$TMPDIR/other"
    git clone -q "$TMPDIR/bare.git" "$other_clone"
    cd "$other_clone"
    echo "upstream" > upstream.txt; git add upstream.txt
    git commit -m "upstream commit" -q
    git push -q origin master 2>/dev/null
    cd "$TMPDIR/repo"

    local stale_sha
    stale_sha=$(git rev-parse origin/master)

    # Rebase should fetch first
    bash "$DISPATCH" rebase --from base --to source --force >/dev/null 2>&1

    local fresh_sha
    fresh_sha=$(git rev-parse origin/master)
    assert_eq "false" "$([ "$stale_sha" = "$fresh_sha" ] && echo true || echo false)" "origin/master updated by rebase"

    # Source should now contain the upstream commit
    local has_upstream_file
    has_upstream_file=$(git log --oneline source/feature | grep -c "upstream commit" || true)
    assert_eq "1" "$has_upstream_file" "source includes upstream commit after rebase"

    teardown_with_remote
}

test_apply_detects_stale_after_reassignment() {
    echo "=== test: apply detects stale target after tid reassignment ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 8')" -q
    echo "feature B" > b.txt; git add b.txt
    git commit -m "Feature B$(printf '\n\nDispatch-Target-Id: 8')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1
    assert_eq "true" "$(git rev-parse --verify refs/heads/target-8 &>/dev/null && echo true || echo false)" "target-8 exists after apply"

    # Rewrite source with different tid (simulates rebase + trailer change)
    git reset --hard master -q
    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 15')" -q
    echo "feature B" > b.txt; git add b.txt
    git commit -m "Feature B$(printf '\n\nDispatch-Target-Id: 15')" -q

    # Apply should detect stale and fail without --force
    local output exit_code=0
    output=$(bash "$DISPATCH" apply 2>&1) || exit_code=$?

    assert_contains "$output" "Stale targets detected" "shows stale warning"
    assert_contains "$output" "target-8" "mentions stale branch"
    assert_eq "1" "$exit_code" "exits with code 1 without --force"
    assert_eq "true" "$(git rev-parse --verify refs/heads/target-8 &>/dev/null && echo true || echo false)" "target-8 not deleted without --force"

    teardown
}

test_apply_force_rebuilds_stale() {
    echo "=== test: apply --force rebuilds stale targets ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 8')" -q
    echo "feature B" > b.txt; git add b.txt
    git commit -m "Feature B$(printf '\n\nDispatch-Target-Id: 8')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Rewrite source with different tid
    git reset --hard master -q
    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 15')" -q
    echo "feature B" > b.txt; git add b.txt
    git commit -m "Feature B$(printf '\n\nDispatch-Target-Id: 15')" -q

    local output
    output=$(bash "$DISPATCH" apply --force 2>&1)

    # target-8 should be deleted
    assert_eq "false" "$(git rev-parse --verify refs/heads/target-8 &>/dev/null && echo true || echo false)" "target-8 deleted"
    # target-15 should be created
    assert_eq "true" "$(git rev-parse --verify refs/heads/target-15 &>/dev/null && echo true || echo false)" "target-15 created"
    # target-15 should have the commits
    local count
    count=$(git log --oneline master..target-15 | wc -l | tr -d ' ')
    assert_eq "2" "$count" "target-15 has 2 commits"

    teardown
}

test_status_shows_stale() {
    echo "=== test: status shows stale indicator ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 8')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Rewrite source with different tid
    git reset --hard master -q
    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 15')" -q

    local output
    output=$(bash "$DISPATCH" status 2>&1)

    assert_contains "$output" "stale" "shows stale indicator"
    assert_contains "$output" "target-8" "mentions stale branch"
    assert_contains "$output" "apply --force" "suggests --force"

    teardown
}

test_apply_stale_warns_target_only_commits() {
    echo "=== test: apply warns about target-only commits on stale targets ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 8')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Add a target-only commit on target-8
    git checkout target-8 -q
    echo "target only" > t.txt; git add t.txt
    git commit -m "Target-only commit" -q
    git checkout source -q

    # Rewrite source with different tid
    git reset --hard master -q
    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 15')" -q

    local output exit_code=0
    output=$(bash "$DISPATCH" apply 2>&1) || exit_code=$?

    assert_contains "$output" "target-only" "warns about target-only commits"
    assert_eq "1" "$exit_code" "exits with code 1"

    teardown
}

test_apply_stale_dry_run() {
    echo "=== test: apply --dry-run shows stale without changes ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 8')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Rewrite source with different tid
    git reset --hard master -q
    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 15')" -q

    local output
    output=$(bash "$DISPATCH" apply --dry-run 2>&1)

    assert_contains "$output" "Stale targets detected" "shows stale warning"
    assert_contains "$output" "would rebuild" "shows would rebuild"
    assert_eq "true" "$(git rev-parse --verify refs/heads/target-8 &>/dev/null && echo true || echo false)" "target-8 not deleted in dry-run"

    teardown
}

# ---------- verify ----------

test_verify_no_deps() {
    echo "=== test: verify reports no deps when targets touch different files ==="
    setup

    git checkout -b source/feature master -q
    echo "schema" > schema.ts; git add schema.ts
    git commit -m "Add schema$(printf '\n\nDispatch-Target-Id: 3')" -q
    echo "endpoint" > endpoint.ts; git add endpoint.ts
    git commit -m "Add endpoint$(printf '\n\nDispatch-Target-Id: 4')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    local output
    output=$(bash "$DISPATCH" verify 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    assert_contains "$output" "file-independent" "reports all targets independent"

    teardown
}

test_verify_new_file_dep() {
    echo "=== test: verify detects new file dependency ==="
    setup

    git checkout -b source/feature master -q
    echo "export const auth = true" > auth.ts; git add auth.ts
    git commit -m "Add auth$(printf '\n\nDispatch-Target-Id: 3')" -q
    echo "import auth" > api.ts; git add api.ts
    echo "// updated" >> auth.ts; git add auth.ts
    git commit -m "Add API using auth$(printf '\n\nDispatch-Target-Id: 4')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    local output
    output=$(bash "$DISPATCH" verify 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    assert_contains "$output" "new file" "detects new file dependency"
    assert_contains "$output" "auth.ts" "names the dependent file"
    assert_contains "$output" "target 3" "names the introducing target"

    teardown
}

test_verify_shared_file_dep() {
    echo "=== test: verify detects shared file dependency ==="
    setup

    # Create a file on base
    echo "base content" > shared.ts; git add shared.ts
    git commit -m "Add shared file" -q

    git checkout -b source/feature master -q
    echo "change A" >> shared.ts; git add shared.ts
    git commit -m "Modify shared A$(printf '\n\nDispatch-Target-Id: 3')" -q
    echo "change B" >> shared.ts; git add shared.ts
    git commit -m "Modify shared B$(printf '\n\nDispatch-Target-Id: 4')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    local output
    output=$(bash "$DISPATCH" verify 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    assert_contains "$output" "shared file" "detects shared file dependency"
    assert_contains "$output" "shared.ts" "names the shared file"

    teardown
}

test_verify_stacked_mode_skips() {
    echo "=== test: verify skips in stacked mode ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add a$(printf '\n\nDispatch-Target-Id: 3')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" --mode stacked >/dev/null 2>&1

    local output
    output=$(bash "$DISPATCH" verify 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    assert_contains "$output" "inherit parent changes" "skips with stacked mode message"

    teardown
}

test_verify_before_apply() {
    echo "=== test: verify works before apply (no target branches needed) ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add a$(printf '\n\nDispatch-Target-Id: 3')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "Add b$(printf '\n\nDispatch-Target-Id: 4')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    # Do NOT run apply - verify should still work
    local output
    output=$(bash "$DISPATCH" verify 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    assert_contains "$output" "file-independent" "works without apply"

    teardown
}









# ---------- Dispatch-Target-Id: all ----------

test_target_id_all_hook_accepts() {
    echo "=== test: hook accepts Dispatch-Target-Id: all ==="
    setup

    git checkout -b source master -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "a" > a.txt; git add a.txt
    git commit -m "Shared change$(printf '\n\nDispatch-Target-Id: all')" -q

    # If we get here, the hook accepted it
    local tid
    tid=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" | tr -d '[:space:]')
    assert_eq "all" "$tid" "hook accepted Dispatch-Target-Id: all"

    teardown
}

test_target_id_all_included_in_all_targets() {
    echo "=== test: all commits are included in every target ==="
    setup

    git checkout -b source master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Shared change$(printf '\n\nDispatch-Target-Id: all')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "Add b$(printf '\n\nDispatch-Target-Id: 3')" -q

    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    bash "$DISPATCH" apply >/dev/null 2>&1

    assert_branch_exists "target-3" "target-3 created"

    # target-3 should have BOTH b.txt AND a.txt (all commits included in every target)
    local has_b has_a
    has_b=$(git show target-3:b.txt 2>/dev/null || echo "")
    has_a=$(git show target-3:a.txt 2>/dev/null || echo "MISSING")
    assert_eq "b" "$has_b" "target has b.txt"
    assert_eq "a" "$has_a" "target has a.txt (all-target commit included)"

    teardown
}

test_target_id_all_dry_run_display() {
    echo "=== test: dry-run shows included in all targets for all commits ==="
    setup

    git checkout -b source master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Shared change$(printf '\n\nDispatch-Target-Id: all')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "Add b$(printf '\n\nDispatch-Target-Id: 3')" -q

    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    local output
    output=$(bash "$DISPATCH" apply --dry-run 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    assert_contains "$output" "in all targets" "shows in all targets in dry-run"

    teardown
}

# ---------- Dispatch-Source-Keep ----------

test_source_keep_force_accepts_conflict() {
    echo "=== test: Source-Keep auto-resolves conflict with --theirs ==="
    setup

    echo "base-content" > generated.txt; git add generated.txt
    git commit --no-verify -m "Base generated file" -q

    git checkout -b source master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add a$(printf '\n\nDispatch-Target-Id: 3')" -q

    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null 2>&1

    # Create conflict: source modifies generated.txt with Source-Keep
    echo "source-version" > generated.txt; git add generated.txt
    git commit -m "Regen files$(printf '\n\nDispatch-Target-Id: 3\nDispatch-Source-Keep: true')" -q

    # Advance target's generated.txt so it conflicts
    git checkout target-3 -q
    echo "target-diverged" > generated.txt; git add generated.txt
    git commit --no-verify -m "Target diverges" -q
    git checkout source -q

    local output
    output=$(bash "$DISPATCH" apply 2>&1 | sed $'s/\033\\[[0-9;]*m//g') || true

    assert_contains "$output" "Force-accepted (Source-Keep)" "reports Source-Keep resolution"

    # Target should have source version
    local target_content
    target_content=$(git show target-3:generated.txt)
    assert_eq "source-version" "$target_content" "target has source version"

    teardown
}

test_source_keep_no_conflict_normal_pick() {
    echo "=== test: Source-Keep without conflict picks normally ==="
    setup

    git checkout -b source master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add a$(printf '\n\nDispatch-Target-Id: 3\nDispatch-Source-Keep: true')" -q

    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null 2>&1

    assert_branch_exists "target-3" "target-3 created"

    local has_a
    has_a=$(git show target-3:a.txt 2>/dev/null || echo "")
    assert_eq "a" "$has_a" "target has a.txt via normal cherry-pick"

    teardown
}

test_no_source_keep_conflict_still_fails() {
    echo "=== test: without Source-Keep, conflict still fails ==="
    setup

    echo "base-content" > generated.txt; git add generated.txt
    git commit --no-verify -m "Base generated file" -q

    git checkout -b source master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add a$(printf '\n\nDispatch-Target-Id: 3')" -q

    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null 2>&1

    # Create conflict WITHOUT Source-Keep trailer
    echo "source-version" > generated.txt; git add generated.txt
    git commit -m "Update generated$(printf '\n\nDispatch-Target-Id: 3')" -q

    # Advance target's generated.txt so it conflicts
    git checkout target-3 -q
    echo "target-diverged" > generated.txt; git add generated.txt
    git commit --no-verify -m "Target diverges" -q
    git checkout source -q

    local output
    output=$(bash "$DISPATCH" apply 2>&1 | sed $'s/\033\\[[0-9;]*m//g') || true

    assert_not_contains "$output" "Force-accepted" "no auto-resolve without Source-Keep"

    teardown
}

test_apply_from_target_branch() {
    echo "=== test: apply works from target branch via resolve_source ==="
    setup

    git checkout -b source master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add a$(printf '\n\nDispatch-Target-Id: 3')" -q

    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    bash "$DISPATCH" apply >/dev/null 2>&1
    assert_branch_exists "target-3" "target-3 created on first apply"

    # Add new commit on source
    echo "b" > b.txt; git add b.txt
    git commit -m "Add b$(printf '\n\nDispatch-Target-Id: 3')" -q

    # Switch to target branch and run apply from there
    git checkout target-3 -q

    local output
    output=$(bash "$DISPATCH" apply 2>&1 | sed $'s/\033\\[[0-9;]*m//g') || true

    # Target should have the new commit
    local target_has_b
    target_has_b=$(git show target-3:b.txt 2>/dev/null || echo "")
    assert_eq "b" "$target_has_b" "target updated when apply run from target branch"

    teardown
}

test_apply_skips_base_ancestor_commits() {
    echo "=== test: apply skips commits that are ancestors of base ==="
    setup

    # Create a commit on master that will also be reachable from source
    echo "shared" > shared.txt; git add shared.txt
    git commit --no-verify -m "Shared commit on master" -q

    git checkout -b source master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add a$(printf '\n\nDispatch-Target-Id: 3')" -q

    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    # Apply should succeed (base ancestor commits are skipped)
    local output
    output=$(bash "$DISPATCH" apply 2>&1 | sed $'s/\033\\[[0-9;]*m//g') || true

    assert_branch_exists "target-3" "target created despite base-ancestor commits in range"
    assert_not_contains "$output" "Error" "no error from base-ancestor commits"

    teardown
}


test_resolve_warns_about_dangling_stash() {
    echo "=== test: worktree cherry-pick does not disturb dirty working tree ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add file$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Create conflict
    git checkout source/feature-1 -q
    echo "target-change" > file.txt; git add file.txt
    git commit --no-verify -m "Target modifies file" -q

    git checkout source/feature -q
    # Create dirty working tree - should NOT be disturbed
    echo "dirty" > untracked.txt
    echo "source-change" > file.txt; git add file.txt
    git commit -m "Source modifies file$(printf '\n\nDispatch-Target-Id: 1')" -q

    local output
    output=$(bash "$DISPATCH" cherry-pick --from source --to 1 --resolve 2>&1) || true

    # Untracked file should still exist (no stashing happened)
    if [[ -f "untracked.txt" ]]; then
        echo -e "  ${GREEN}PASS${NC} untracked file not disturbed by worktree cherry-pick"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} untracked file was removed"
        FAIL=$((FAIL + 1))
    fi

    # Clean up any leftover worktrees
    git worktree prune 2>/dev/null || true

    teardown
}

test_cherry_pick_stash_before_checkout() {
    echo "=== test: cherry-pick stashes with --include-untracked before checkout ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add a$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Add new source commit to cherry-pick
    echo "b" > b.txt; git add b.txt
    git commit -m "Add b$(printf '\n\nDispatch-Target-Id: 1')" -q

    # Create untracked file that would block checkout
    echo "untracked" > untracked.txt

    local output
    output=$(bash "$DISPATCH" cherry-pick --from source --to 1 2>&1) || true

    # Should succeed (stash handled untracked file)
    assert_not_contains "$output" "error" "cherry-pick succeeds with untracked files"

    # Untracked file should still be present after stash pop
    if [[ -f "untracked.txt" ]]; then
        echo -e "  ${GREEN}PASS${NC} untracked file restored after cherry-pick"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} untracked file not restored after cherry-pick"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_merge_worktree_aware() {
    echo "=== test: merge handles worktree branches ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add a$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Add a commit to master (base) to have something to merge
    git checkout master -q
    echo "base-update" > base.txt; git add base.txt
    git commit --no-verify -m "Update base" -q
    git checkout source/feature -q

    local output
    output=$(bash "$DISPATCH" merge --from base --to 1 2>&1 | sed $'s/\033\\[[0-9;]*m//g') || true

    assert_contains "$output" "Merged" "merge into target succeeds"
    assert_not_contains "$output" "error" "no errors"

    teardown
}

test_apply_warns_base_drift() {
    echo "=== test: apply warns when source is behind base ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add a$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Add commits to base (master) so source falls behind
    git checkout master -q
    echo "new" > new.txt; git add new.txt
    git commit --no-verify -m "New base commit" -q
    git checkout source/feature -q

    # Add a new source commit to trigger the update path
    echo "b" > b.txt; git add b.txt
    git commit -m "Add b$(printf '\n\nDispatch-Target-Id: 1')" -q

    local output
    output=$(bash "$DISPATCH" apply 2>&1 | sed $'s/\033\\[[0-9;]*m//g') || true

    assert_contains "$output" "behind" "warns source is behind base"
    assert_contains "$output" "merge --from base" "suggests merge command"

    teardown
}

test_status_shows_untracked_commits() {
    echo "=== test: status shows untracked commits on target ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add a$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Add commit on target without proper Dispatch-Target-Id trailer
    # Must unset prepare-commit-msg to avoid auto-carry of Dispatch-Target-Id
    git checkout source/feature-1 -q
    echo "extra" > extra.txt; git add extra.txt
    GIT_AUTHOR_DATE="2020-01-01T00:00:00" git -c core.hooksPath=/dev/null commit -m "Extra commit without trailer" -q

    git checkout source/feature -q

    local output
    output=$(bash "$DISPATCH" status 2>&1 | sed $'s/\033\\[[0-9;]*m//g') || true

    assert_contains "$output" "untracked" "shows untracked commits in status"

    teardown
}

test_stash_pop_conflict_warns() {
    echo "=== test: staged changes survive worktree cherry-pick ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add file$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Modify file on source (staged but not committed)
    echo "staged-change" > file.txt; git add file.txt

    # Add new source commit
    echo "b" > b.txt; git add b.txt
    git commit -m "Add b$(printf '\n\nDispatch-Target-Id: 1')" -q

    # Cherry-pick via worktree should not touch staged changes
    local output
    output=$(bash "$DISPATCH" cherry-pick --from source --to 1 2>&1) || true

    # Should not crash
    assert_not_contains "$output" "fatal" "no fatal error from worktree cherry-pick"

    # Staged file.txt changes should still be present
    local staged_content
    staged_content=$(git show :file.txt 2>/dev/null || true)
    assert_eq "staged-change" "$staged_content" "staged changes survive cherry-pick operation"

    teardown
}

test_continue_cleans_completed_worktree() {
    echo "=== test: continue cleans up completed worktree ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add a$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Add a new commit and cherry-pick (non-conflicting)
    echo "b" > b.txt; git add b.txt
    git commit -m "Add b$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" cherry-pick --from source --to 1 >/dev/null 2>&1

    # No leftover worktrees should exist
    local output
    output=$(bash "$DISPATCH" continue 2>&1)
    assert_contains "$output" "No pending" "continue reports no pending operations"

    teardown
}

test_clean_lists_and_removes_worktrees() {
    echo "=== test: clean lists and force-removes worktrees ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add file$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Create conflict to leave worktree alive
    git checkout source/feature-1 -q
    echo "target-change" > file.txt; git add file.txt
    git commit --no-verify -m "Target modifies file" -q

    git checkout source/feature -q
    echo "source-change" > file.txt; git add file.txt
    git commit -m "Source modifies file$(printf '\n\nDispatch-Target-Id: 1')" -q

    # --resolve leaves worktree alive
    bash "$DISPATCH" cherry-pick --from source --to 1 --resolve 2>&1 || true

    # clean without --force lists them
    local list_output
    list_output=$(bash "$DISPATCH" clean 2>&1)
    assert_contains "$list_output" "git-dispatch-wt" "clean lists worktree"
    assert_contains "$list_output" "--force" "clean suggests --force"

    # clean --force removes them
    local clean_output
    clean_output=$(bash "$DISPATCH" clean --force 2>&1)
    assert_contains "$clean_output" "Removed" "clean --force removes worktree"

    # Verify it's gone
    local verify_output
    verify_output=$(bash "$DISPATCH" clean 2>&1)
    assert_contains "$verify_output" "No dispatch worktrees" "no worktrees after clean"

    teardown
}

test_continue_detects_pending_conflict() {
    echo "=== test: continue detects pending cherry-pick conflict ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add file$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Create conflict
    git checkout source/feature-1 -q
    echo "target-change" > file.txt; git add file.txt
    git commit --no-verify -m "Target modifies file" -q

    git checkout source/feature -q
    echo "source-change" > file.txt; git add file.txt
    git commit -m "Source modifies file$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" cherry-pick --from source --to 1 --resolve 2>&1 || true

    local output
    output=$(bash "$DISPATCH" continue 2>&1)
    assert_contains "$output" "Cherry-pick conflict pending" "continue detects pending cherry-pick"
    assert_contains "$output" "source/feature-1" "continue shows branch name"

    # Clean up
    bash "$DISPATCH" clean --force >/dev/null 2>&1

    teardown
}

# ---------- checkout tests ----------

test_checkout_creates_branch() {
    echo "=== test: checkout creates branch ==="
    setup
    create_source  # commits: tid=3, tid=4(x2), tid=5

    local output
    output=$(bash "$DISPATCH" checkout 4 2>&1)

    assert_branch_exists "dispatch-checkout/source/feature/4" "checkout branch created"

    # Should have tid=3 and tid=4 commits (3 total), not tid=5
    local count
    count=$(git log --oneline "master..dispatch-checkout/source/feature/4" | wc -l | tr -d ' ')
    assert_eq "3" "$count" "checkout has 3 commits (tid=3 + tid=4 x2)"

    assert_contains "$output" "dispatch-checkout/source/feature/4" "output shows branch name"

    teardown
}

test_checkout_includes_all_commits() {
    echo "=== test: checkout includes Dispatch-Target-Id: all ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "shared" > shared.txt; git add shared.txt
    git commit -m "shared config$(printf '\n\nDispatch-Target-Id: all')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "tid2$(printf '\n\nDispatch-Target-Id: 2')" -q
    echo "c" > c.txt; git add c.txt
    git commit -m "tid3$(printf '\n\nDispatch-Target-Id: 3')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    bash "$DISPATCH" checkout 2 >/dev/null 2>&1

    # Should have tid=1, tid=all, tid=2 (3 commits), not tid=3
    local count
    count=$(git log --oneline "master..dispatch-checkout/source/feature/2" | wc -l | tr -d ' ')
    assert_eq "3" "$count" "checkout has 3 commits (tid=1 + all + tid=2)"

    # shared.txt should exist (from tid=all commit)
    local shared_exists
    shared_exists=$(git show "dispatch-checkout/source/feature/2:shared.txt" 2>/dev/null || echo "MISSING")
    assert_eq "shared" "$shared_exists" "all commit content present"

    # c.txt should NOT exist (from tid=3)
    local c_exists
    c_exists=$(git show "dispatch-checkout/source/feature/2:c.txt" 2>/dev/null || echo "MISSING")
    assert_eq "MISSING" "$c_exists" "tid=3 content excluded"

    teardown
}

test_checkout_preserves_source_order() {
    echo "=== test: checkout preserves source commit order ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "A-tid2$(printf '\n\nDispatch-Target-Id: 2')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "B-tid1$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "c" > c.txt; git add c.txt
    git commit -m "C-tid2$(printf '\n\nDispatch-Target-Id: 2')" -q
    echo "d" > d.txt; git add d.txt
    git commit -m "D-tid1$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" checkout 2 >/dev/null 2>&1

    # All 4 commits should be present
    local count
    count=$(git log --oneline "master..dispatch-checkout/source/feature/2" | wc -l | tr -d ' ')
    assert_eq "4" "$count" "all 4 commits included"

    # Check order: first commit should be A (tid=2), not grouped
    local first_msg
    first_msg=$(git log --reverse --oneline "master..dispatch-checkout/source/feature/2" | head -1)
    assert_contains "$first_msg" "A-tid2" "first commit is A (source order preserved)"

    teardown
}

test_checkout_decimal_targets() {
    echo "=== test: checkout with decimal target ids ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "tid1.5$(printf '\n\nDispatch-Target-Id: 1.5')" -q
    echo "c" > c.txt; git add c.txt
    git commit -m "tid2$(printf '\n\nDispatch-Target-Id: 2')" -q
    echo "d" > d.txt; git add d.txt
    git commit -m "tid3$(printf '\n\nDispatch-Target-Id: 3')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" checkout 2 >/dev/null 2>&1

    local count
    count=$(git log --oneline "master..dispatch-checkout/source/feature/2" | wc -l | tr -d ' ')
    assert_eq "3" "$count" "includes tid=1, 1.5, 2 (excludes tid=3)"

    # b.txt from tid=1.5 should exist
    local b_exists
    b_exists=$(git show "dispatch-checkout/source/feature/2:b.txt" 2>/dev/null || echo "MISSING")
    assert_eq "b" "$b_exists" "decimal target 1.5 included"

    # d.txt from tid=3 should NOT exist
    local d_exists
    d_exists=$(git show "dispatch-checkout/source/feature/2:d.txt" 2>/dev/null || echo "MISSING")
    assert_eq "MISSING" "$d_exists" "tid=3 excluded"

    teardown
}

test_checkout_works_without_apply() {
    echo "=== test: checkout works without prior apply ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "tid2$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    # Do NOT apply

    bash "$DISPATCH" checkout 2 >/dev/null 2>&1

    assert_branch_exists "dispatch-checkout/source/feature/2" "checkout works without apply"

    local count
    count=$(git log --oneline "master..dispatch-checkout/source/feature/2" | wc -l | tr -d ' ')
    assert_eq "2" "$count" "both commits present"

    teardown
}

test_checkout_errors_if_exists() {
    echo "=== test: checkout errors if branch exists ==="
    setup
    create_source

    bash "$DISPATCH" checkout 4 >/dev/null 2>&1

    local output
    output=$(bash "$DISPATCH" checkout 4 2>&1) || true
    assert_contains "$output" "already exists" "errors when checkout branch exists"

    teardown
}

test_checkout_errors_if_not_initialized() {
    echo "=== test: checkout errors if not initialized ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit --no-verify -m "no init" -q

    local output
    output=$(bash "$DISPATCH" checkout 3 2>&1) || true
    assert_contains "$output" "Not initialized" "errors when not initialized"

    teardown
}

test_checkout_empty_range() {
    echo "=== test: checkout with no matching commits ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid5$(printf '\n\nDispatch-Target-Id: 5')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    local output
    output=$(bash "$DISPATCH" checkout 3 2>&1) || true
    assert_contains "$output" "No commits" "errors when no matching commits"

    teardown
}

test_checkout_large_N_includes_all() {
    echo "=== test: checkout with large N includes all commits ==="
    setup
    create_source  # commits: tid=3, tid=4(x2), tid=5

    bash "$DISPATCH" checkout 999 >/dev/null 2>&1

    local count
    count=$(git log --oneline "master..dispatch-checkout/source/feature/999" | wc -l | tr -d ' ')
    assert_eq "4" "$count" "all 4 commits included with N=999"

    teardown
}

# ---------- checkout source tests ----------

test_checkout_source_returns_to_source() {
    echo "=== test: checkout source returns to source ==="
    setup
    create_source

    bash "$DISPATCH" checkout 4 >/dev/null 2>&1

    # Switch to checkout branch
    git checkout "dispatch-checkout/source/feature/4" -q

    bash "$DISPATCH" checkout source >/dev/null 2>&1

    local cur
    cur=$(git symbolic-ref --short HEAD)
    assert_eq "source/feature" "$cur" "back on source branch"

    # Checkout branch should still exist
    assert_branch_exists "dispatch-checkout/source/feature/4" "checkout branch preserved"

    teardown
}

test_checkout_source_noop_on_source() {
    echo "=== test: checkout source no-op when already on source ==="
    setup
    create_source

    local output
    output=$(bash "$DISPATCH" checkout source 2>&1)
    assert_contains "$output" "Already on source" "informational message on source"

    teardown
}

# ---------- checkout clear tests ----------

test_checkout_clear_removes_branch() {
    echo "=== test: checkout clear removes branch ==="
    setup
    create_source

    bash "$DISPATCH" checkout 4 >/dev/null 2>&1

    bash "$DISPATCH" checkout clear >/dev/null 2>&1

    assert_branch_not_exists "dispatch-checkout/source/feature/4" "checkout branch deleted"

    local cur
    cur=$(git symbolic-ref --short HEAD)
    assert_eq "source/feature" "$cur" "still on source"

    teardown
}

test_checkout_clear_warns_unpicked_commits() {
    echo "=== test: checkout clear warns about unpicked commits ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" checkout 1 >/dev/null 2>&1

    # Make a new commit on checkout branch
    git checkout "dispatch-checkout/source/feature/1" -q
    echo "new" > new.txt; git add new.txt
    git commit -m "new commit$(printf '\n\nDispatch-Target-Id: 1')" -q
    git checkout source/feature -q

    local output
    output=$(bash "$DISPATCH" checkout clear 2>&1) || true
    assert_contains "$output" "unpicked" "warns about unpicked commits"

    # Branch should still exist
    assert_branch_exists "dispatch-checkout/source/feature/1" "branch preserved"

    teardown
}

test_checkout_clear_force_with_unpicked() {
    echo "=== test: checkout clear --force removes despite unpicked ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" checkout 1 >/dev/null 2>&1

    # Make a new commit on checkout branch
    git checkout "dispatch-checkout/source/feature/1" -q
    echo "new" > new.txt; git add new.txt
    git commit -m "new commit$(printf '\n\nDispatch-Target-Id: 1')" -q
    git checkout source/feature -q

    bash "$DISPATCH" checkout clear --force >/dev/null 2>&1

    assert_branch_not_exists "dispatch-checkout/source/feature/1" "branch deleted with --force"

    teardown
}

test_checkout_clear_no_checkout_exists() {
    echo "=== test: checkout clear when no checkout exists ==="
    setup
    create_source

    local output
    output=$(bash "$DISPATCH" checkout clear 2>&1)
    assert_contains "$output" "No checkout branch" "informational message"

    teardown
}

test_checkout_clear_from_checkout_branch() {
    echo "=== test: checkout clear from checkout branch ==="
    setup
    create_source

    bash "$DISPATCH" checkout 4 >/dev/null 2>&1

    # Switch to checkout branch
    git checkout "dispatch-checkout/source/feature/4" -q

    bash "$DISPATCH" checkout clear >/dev/null 2>&1

    local cur
    cur=$(git symbolic-ref --short HEAD)
    assert_eq "source/feature" "$cur" "switched to source"

    assert_branch_not_exists "dispatch-checkout/source/feature/4" "checkout branch deleted"

    teardown
}

# ---------- checkin tests ----------

test_checkin_picks_new_commits_to_source() {
    echo "=== test: checkin picks new commits to source ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "tid2$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" checkout 2 >/dev/null 2>&1

    # Make a new commit on checkout
    git checkout "dispatch-checkout/source/feature/2" -q
    echo "fix" > fix.txt; git add fix.txt
    git commit -m "bugfix$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" checkin >/dev/null 2>&1

    # Source should have the new commit
    local source_count
    source_count=$(git log --oneline "master..source/feature" | wc -l | tr -d ' ')
    assert_eq "3" "$source_count" "source has 3 commits (2 original + 1 checkin)"

    # Verify the new commit has correct trailer
    local last_tid
    last_tid=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" "source/feature" | tr -d '[:space:]')
    assert_eq "2" "$last_tid" "checkin commit has correct Dispatch-Target-Id"

    teardown
}

test_checkin_no_new_commits() {
    echo "=== test: checkin no-op with no new commits ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" checkout 1 >/dev/null 2>&1

    git checkout "dispatch-checkout/source/feature/1" -q

    local output
    output=$(bash "$DISPATCH" checkin 2>&1)
    assert_contains "$output" "No new commits" "reports no new commits"

    teardown
}

test_checkin_multiple_commits_different_targets() {
    echo "=== test: checkin with multiple commits ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "tid2$(printf '\n\nDispatch-Target-Id: 2')" -q
    echo "c" > c.txt; git add c.txt
    git commit -m "tid3$(printf '\n\nDispatch-Target-Id: 3')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" checkout 3 >/dev/null 2>&1

    git checkout "dispatch-checkout/source/feature/3" -q
    echo "fix2" > fix2.txt; git add fix2.txt
    git commit -m "fix for 2$(printf '\n\nDispatch-Target-Id: 2')" -q
    echo "fix3" > fix3.txt; git add fix3.txt
    git commit -m "fix for 3$(printf '\n\nDispatch-Target-Id: 3')" -q

    bash "$DISPATCH" checkin >/dev/null 2>&1

    local source_count
    source_count=$(git log --oneline "master..source/feature" | wc -l | tr -d ' ')
    assert_eq "5" "$source_count" "source has 5 commits (3 original + 2 checkin)"

    teardown
}

test_checkin_does_not_auto_apply() {
    echo "=== test: checkin does not auto-apply to targets ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null
    bash "$DISPATCH" checkout 1 >/dev/null 2>&1

    git checkout "dispatch-checkout/source/feature/1" -q
    echo "fix" > fix.txt; git add fix.txt
    git commit -m "bugfix$(printf '\n\nDispatch-Target-Id: 1')" -q

    local output
    output=$(bash "$DISPATCH" checkin 2>&1)

    # Target should NOT have the fix yet
    local target_count
    target_count=$(git log --oneline "master..source/feature-1" | wc -l | tr -d ' ')
    assert_eq "1" "$target_count" "target not auto-updated"

    assert_contains "$output" "apply" "output suggests running apply"

    teardown
}

test_checkin_errors_if_not_on_checkout() {
    echo "=== test: checkin errors if not on checkout ==="
    setup
    create_source

    local output
    output=$(bash "$DISPATCH" checkin 2>&1) || true
    assert_contains "$output" "Not on a checkout branch" "errors on source branch"

    teardown
}

test_checkin_skips_original_commits() {
    echo "=== test: checkin skips original commits ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "tid2$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    local before_count
    before_count=$(git log --oneline "master..source/feature" | wc -l | tr -d ' ')

    bash "$DISPATCH" checkout 2 >/dev/null 2>&1

    git checkout "dispatch-checkout/source/feature/2" -q
    echo "new" > new.txt; git add new.txt
    git commit -m "new work$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" checkin >/dev/null 2>&1

    local after_count
    after_count=$(git log --oneline "master..source/feature" | wc -l | tr -d ' ')
    assert_eq "3" "$after_count" "only 1 new commit added (originals skipped)"

    teardown
}

test_checkin_source_keep_auto_resolves_conflict() {
    echo "=== test: checkin Dispatch-Source-Keep auto-resolves conflict ==="
    setup

    git checkout -b source/feature master -q
    echo "original" > swagger.json; git add swagger.json
    git commit -m "add swagger$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" checkout 1 >/dev/null 2>&1

    # Modify swagger on source (creates conflict)
    echo "source-version" > swagger.json; git add swagger.json
    git commit -m "source swagger update$(printf '\n\nDispatch-Target-Id: 1')" -q

    # Modify swagger on checkout (different version)
    git checkout "dispatch-checkout/source/feature/1" -q
    echo "checkout-version" > swagger.json; git add swagger.json
    git commit -m "regen swagger$(printf '\n\nDispatch-Target-Id: 1\nDispatch-Source-Keep: true')" -q

    local output
    output=$(bash "$DISPATCH" checkin 2>&1)

    # Should auto-resolve - checkout version wins
    local swagger_content
    swagger_content=$(git show "source/feature:swagger.json")
    assert_eq "checkout-version" "$swagger_content" "checkout version accepted via Source-Keep"

    teardown
}

test_checkin_then_apply_lifecycle() {
    echo "=== test: checkin then apply lifecycle ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "tid2$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    bash "$DISPATCH" checkout 2 >/dev/null 2>&1

    git checkout "dispatch-checkout/source/feature/2" -q
    echo "fix" > fix.txt; git add fix.txt
    git commit -m "fix for 1$(printf '\n\nDispatch-Target-Id: 1')" -q

    # Checkin
    bash "$DISPATCH" checkin >/dev/null 2>&1

    # Switch to source and apply
    git checkout source/feature -q
    bash "$DISPATCH" apply >/dev/null 2>&1

    # Target-1 should have the fix
    local fix_content
    fix_content=$(git show "source/feature-1:fix.txt" 2>/dev/null || echo "MISSING")
    assert_eq "fix" "$fix_content" "target-1 has fix after apply"

    # Target-2 should NOT have the fix (it was tid=1)
    local fix_on_t2
    fix_on_t2=$(git show "source/feature-2:fix.txt" 2>/dev/null || echo "MISSING")
    assert_eq "MISSING" "$fix_on_t2" "target-2 does not have tid=1 fix"

    teardown
}

test_checkout_full_lifecycle() {
    echo "=== test: checkout full lifecycle ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "shared" > shared.txt; git add shared.txt
    git commit -m "shared$(printf '\n\nDispatch-Target-Id: all')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "tid2$(printf '\n\nDispatch-Target-Id: 2')" -q
    echo "c" > c.txt; git add c.txt
    git commit -m "tid3$(printf '\n\nDispatch-Target-Id: 3')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    # Checkout 2
    bash "$DISPATCH" checkout 2 >/dev/null 2>&1
    assert_branch_exists "dispatch-checkout/source/feature/2" "checkout created"

    # Verify content
    local shared
    shared=$(git show "dispatch-checkout/source/feature/2:shared.txt" 2>/dev/null || echo "MISSING")
    assert_eq "shared" "$shared" "all commit present"

    # Switch back to source
    git checkout "dispatch-checkout/source/feature/2" -q
    bash "$DISPATCH" checkout source >/dev/null 2>&1
    local cur
    cur=$(git symbolic-ref --short HEAD)
    assert_eq "source/feature" "$cur" "back on source"

    # Clear
    bash "$DISPATCH" checkout clear >/dev/null 2>&1
    assert_branch_not_exists "dispatch-checkout/source/feature/2" "checkout cleared"

    teardown
}

test_checkout_does_not_affect_targets() {
    echo "=== test: checkout does not affect targets ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "tid2$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    local target1_sha_before target2_sha_before
    target1_sha_before=$(git rev-parse source/feature-1)
    target2_sha_before=$(git rev-parse source/feature-2)

    bash "$DISPATCH" checkout 2 >/dev/null 2>&1

    # Targets unchanged
    local target1_sha_after target2_sha_after
    target1_sha_after=$(git rev-parse source/feature-1)
    target2_sha_after=$(git rev-parse source/feature-2)

    assert_eq "$target1_sha_before" "$target1_sha_after" "target-1 unchanged"
    assert_eq "$target2_sha_before" "$target2_sha_after" "target-2 unchanged"

    teardown
}

# ---------- run ----------

echo "git-dispatch test suite"
echo "======================="
echo ""

test_init_basic
test_init_requires_base
test_init_requires_target_pattern
test_init_stacked_mode
test_init_custom_pattern
test_init_reinit_warns
test_init_installs_hooks
test_init_hooks_only
test_hook_rejects_missing_trailer
test_hook_allows_valid_trailer
test_hook_rejects_non_numeric_target_id
test_hook_allows_decimal_target_id
test_hook_auto_carry_target_id
test_hook_auto_carry_no_override
test_worktree_shares_hooks_via_hookspath
test_apply_creates_targets
test_apply_dry_run
test_apply_incremental
test_apply_new_target_mid_stack
test_apply_idempotent
test_apply_stacked_mode
test_apply_conflict_aborts
test_apply_create_auto_resolves_with_theirs
test_cherry_pick_source_to_target
test_cherry_pick_target_to_source
test_cherry_pick_adds_trailer
test_cherry_pick_dry_run
test_cherry_pick_target_to_source_noop_semantic_sync
test_rebase_base_to_source
test_rebase_dry_run
test_merge_base_to_source
test_merge_dry_run
test_push_dry_run_all
test_push_dry_run_single
test_push_force_dry_run
test_push_source_dry_run
test_push_no_argument_errors
test_status_shows_mode
test_status_in_sync
test_status_shows_pending
test_status_not_created
test_reset_cleans_up
test_help
test_install_chmod
test_apply_decimal_target_id
test_cherry_pick_conflict_shows_details
test_cherry_pick_conflict_resolve_leaves_active
test_cherry_pick_conflict_batch_reporting
test_rebase_conflict_shows_details
test_rebase_conflict_resolve
test_merge_conflict_shows_details
test_merge_conflict_resolve
test_status_shows_diverged
test_diff_shows_diverged_files
test_diff_no_difference
test_status_semantic_source_to_target
test_apply_reset_regenerates_target
test_full_lifecycle
test_refresh_base_fetches_remote
test_refresh_base_noop_when_up_to_date
test_refresh_base_local_branch_with_remote
test_refresh_base_warns_on_fetch_failure
test_rebase_refreshes_base
test_apply_detects_stale_after_reassignment
test_apply_force_rebuilds_stale
test_status_shows_stale
test_apply_stale_warns_target_only_commits
test_apply_stale_dry_run
test_verify_no_deps
test_verify_new_file_dep
test_verify_shared_file_dep
test_verify_stacked_mode_skips
test_verify_before_apply
test_apply_from_target_branch
test_apply_skips_base_ancestor_commits
test_target_id_all_hook_accepts
test_target_id_all_included_in_all_targets
test_target_id_all_dry_run_display
test_source_keep_force_accepts_conflict
test_source_keep_no_conflict_normal_pick
test_no_source_keep_conflict_still_fails
test_resolve_warns_about_dangling_stash
test_cherry_pick_stash_before_checkout
test_merge_worktree_aware
test_apply_warns_base_drift
test_status_shows_untracked_commits
test_stash_pop_conflict_warns
test_continue_cleans_completed_worktree
test_clean_lists_and_removes_worktrees
test_continue_detects_pending_conflict
test_checkout_creates_branch
test_checkout_includes_all_commits
test_checkout_preserves_source_order
test_checkout_decimal_targets
test_checkout_works_without_apply
test_checkout_errors_if_exists
test_checkout_errors_if_not_initialized
test_checkout_empty_range
test_checkout_large_N_includes_all
test_checkout_source_returns_to_source
test_checkout_source_noop_on_source
test_checkout_clear_removes_branch
test_checkout_clear_warns_unpicked_commits
test_checkout_clear_force_with_unpicked
test_checkout_clear_no_checkout_exists
test_checkout_clear_from_checkout_branch
test_checkin_picks_new_commits_to_source
test_checkin_no_new_commits
test_checkin_multiple_commits_different_targets
test_checkin_does_not_auto_apply
test_checkin_errors_if_not_on_checkout
test_checkin_skips_original_commits
test_checkin_source_keep_auto_resolves_conflict
test_checkin_then_apply_lifecycle
test_checkout_full_lifecycle
test_checkout_does_not_affect_targets

echo ""
echo "======================="
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
