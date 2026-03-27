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

    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    local base target_pattern
    base=$(git config branch.$(git symbolic-ref --short HEAD).dispatchbase)
    target_pattern=$(git config branch.$(git symbolic-ref --short HEAD).dispatchtargetPattern)

    assert_eq "master" "$base" "dispatch.base set"
    assert_eq "source/feature-task-{id}" "$target_pattern" "dispatch.targetPattern set"

    teardown
}

test_init_requires_base() {
    echo "=== test: init requires --base (non-interactive uses default) ==="
    setup

    git checkout -b source/feature master -q

    # Non-interactive: --base defaults to origin/master, which doesn't exist
    local output
    output=$(bash "$DISPATCH" init --target-pattern "source/feature-task-{id}" 2>&1) || true
    assert_contains "$output" "does not exist" "init rejects missing base ref"

    teardown
}

test_init_requires_target_pattern() {
    echo "=== test: init requires --target-pattern (non-interactive) ==="
    setup

    git checkout -b source/feature master -q

    # Non-interactive: --target-pattern has no default, fails
    local output
    output=$(bash "$DISPATCH" init --base master 2>&1) || true
    assert_contains "$output" "Missing input in non-interactive mode" "init requires target-pattern in non-interactive mode"

    teardown
}

test_init_custom_pattern() {
    echo "=== test: init custom target pattern ==="
    setup

    git checkout -b source/feature master -q

    bash "$DISPATCH" init --base master --target-pattern "custom/path-{id}-done"

    local target_pattern
    target_pattern=$(git config branch.$(git symbolic-ref --short HEAD).dispatchtargetPattern)
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
    base=$(git config branch.$(git symbolic-ref --short HEAD).dispatchbase 2>/dev/null || echo "")
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

test_hook_rejects_duplicate_target_id() {
    echo "=== test: hook rejects duplicate Dispatch-Target-Id ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" >/dev/null 2>&1

    echo "x" > x.txt; git add x.txt
    # Craft a commit message with two Dispatch-Target-Id trailers
    if git commit -m "dual target$(printf '\n\nDispatch-Target-Id: 3\nDispatch-Target-Id: all')" 2>/dev/null; then
        echo -e "  ${RED}FAIL${NC} hook should reject duplicate Dispatch-Target-Id"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} hook rejects duplicate Dispatch-Target-Id"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_hook_rejects_duplicate_source_keep() {
    echo "=== test: hook rejects duplicate Dispatch-Source-Keep ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" >/dev/null 2>&1

    echo "x" > x.txt; git add x.txt
    # Craft a commit message with two Dispatch-Source-Keep trailers
    if git commit -m "dual keep$(printf '\n\nDispatch-Target-Id: 3\nDispatch-Source-Keep: true\nDispatch-Source-Keep: false')" 2>/dev/null; then
        echo -e "  ${RED}FAIL${NC} hook should reject duplicate Dispatch-Source-Keep"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} hook rejects duplicate Dispatch-Source-Keep"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_hook_ignores_legacy_target_id() {
    echo "=== test: hook ignores legacy Target-Id trailer ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" >/dev/null 2>&1

    echo "x" > x.txt; git add x.txt
    # Legacy Target-Id alongside valid Dispatch-Target-Id should be accepted (Target-Id is dead)
    git commit -m "legacy mix$(printf '\n\nTarget-Id: 9\nDispatch-Target-Id: 3')" -q
    if [[ $? -eq 0 ]]; then
        echo -e "  ${GREEN}PASS${NC} hook ignores legacy Target-Id"
        PASS=$((PASS + 1))
    fi

    # Verify only Dispatch-Target-Id is read
    local target_id
    target_id=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" | tr -d '[:space:]')
    assert_eq "3" "$target_id" "only Dispatch-Target-Id is used (not legacy Target-Id)"

    teardown
}

test_apply_rejects_duplicate_target_id() {
    echo "=== test: apply rejects commits with duplicate Dispatch-Target-Id ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" >/dev/null 2>&1

    # Bypass the hook by committing directly with git (no hooks)
    echo "a" > a.txt; git add a.txt
    git commit --no-verify -m "dual trailer$(printf '\n\nDispatch-Target-Id: 3\nDispatch-Target-Id: all')" -q

    local output
    output=$(bash "$DISPATCH" apply --yes 2>&1 || true)
    assert_contains "$output" "Dispatch-Target-Id trailers" "apply rejects duplicate Dispatch-Target-Id"

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

test_apply_new_target_mid_range() {
    echo "=== test: apply creates new target mid-range ==="
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

    assert_branch_exists "source/feature-2" "target-2 created (mid-range)"

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

# ---------- rebase tests ----------

# ---------- merge tests ----------

test_sync_merges_and_applies() {
    echo "=== test: sync merges base into source then apply works ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    # Advance master
    git checkout master -q
    echo "new" > new.txt; git add new.txt
    git commit --no-verify -m "advance master" -q
    git checkout source/feature -q

    bash "$DISPATCH" sync >/dev/null 2>&1

    # Source should have merge commit (base merged in)
    local has_new
    has_new=$(git show source/feature:new.txt 2>/dev/null || echo "MISSING")
    assert_eq "new" "$has_new" "base content merged into source"

    teardown
}

test_sync_up_to_date() {
    echo "=== test: sync when already up to date ==="
    setup
    create_source

    local output
    output=$(bash "$DISPATCH" sync 2>&1)

    assert_contains "$output" "up to date" "reports already up to date"

    teardown
}

test_sync_dry_run() {
    echo "=== test: sync --dry-run ==="
    setup
    create_source

    git checkout master -q
    echo "new" > new.txt; git add new.txt
    git commit --no-verify -m "advance" -q
    git checkout source/feature -q

    local output
    output=$(bash "$DISPATCH" sync --dry-run 2>&1)

    assert_contains "$output" "dry-run" "dry-run shows merge plan"
    assert_contains "$output" "merge" "shows merge action"

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

test_status_shows_info() {
    echo "=== test: status shows base and source ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    local output
    output=$(bash "$DISPATCH" status 2>&1)

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
    base=$(git config branch.$(git symbolic-ref --short HEAD).dispatchbase 2>/dev/null || true)
    assert_eq "" "$base" "dispatch.base removed"

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

test_sync_conflict_shows_details() {
    echo "=== test: sync conflict shows details ==="
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
    output=$(bash "$DISPATCH" sync 2>&1) || true

    assert_contains "$output" "Merge conflict" "shows merge conflict header"
    assert_contains "$output" "file.txt" "shows conflicted filename"

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
    assert_contains "$output" "Diverged targets have file content that differs from source" "status shows diverged hint"

    teardown
}

test_status_no_false_diverged_base_drift() {
    echo "=== test: no false DIVERGED when source is behind base ==="
    setup

    # Create a 20-line file (enough separation for clean region-based merge)
    for i in $(seq -w 1 20); do echo "line$i" >> shared.txt; done
    git add shared.txt
    git commit -m "Initial shared file" -q

    # Advance master at line15 (far from source changes at line05)
    sed -i.bak 's/line15/line15-master/' shared.txt && rm shared.txt.bak
    git add shared.txt
    git commit -m "Master change at line15" -q

    # Source branch from old master (before the advance), creating base drift
    git checkout -b source/feature HEAD~1 -q

    # Two DTI=1 commits both modifying line05 (triggers re-cherry-pick conflict in status)
    sed -i.bak 's/line05/line05-v1/' shared.txt && rm shared.txt.bak
    git add shared.txt
    git commit -m "Feature change v1$(printf '\n\nDispatch-Target-Id: 1')" -q

    sed -i.bak 's/line05-v1/line05-v2/' shared.txt && rm shared.txt.bak
    git add shared.txt
    git commit -m "Feature change v2$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1

    # Apply: cherry-picks onto current master (clean merge, different regions)
    bash "$DISPATCH" apply >/dev/null 2>&1

    # Verify target has merged content (both feature and master changes)
    local target_content
    target_content=$(git show source/feature-1:shared.txt)
    assert_contains "$target_content" "line05-v2" "target has feature change"
    assert_contains "$target_content" "line15-master" "target has master change (base drift)"

    # Status should NOT show DIVERGED - the diff is from base drift, not real divergence
    local status_output
    status_output=$(bash "$DISPATCH" status 2>&1 | sed $'s/\033\\[[0-9;]*m//g')
    assert_not_contains "$status_output" "DIVERGED" "no false diverged after base drift"

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
    echo "=== test: apply reset regenerates target branch ==="
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
    reset_output=$(bash "$DISPATCH" apply reset 1 2>&1)
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

test_apply_single_target() {
    echo "=== test: apply <N> applies to single target ==="
    setup
    create_source  # commits: tid=3, tid=4(x2), tid=5

    bash "$DISPATCH" apply 4 >/dev/null 2>&1

    # Only target-4 should exist
    assert_branch_exists "source/feature-4" "target-4 created"
    assert_branch_not_exists "source/feature-3" "target-3 not created"
    assert_branch_not_exists "source/feature-5" "target-5 not created"

    teardown
}

test_apply_reset_subcommand() {
    echo "=== test: apply reset <N> regenerates target ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Count commits on target-4 before reset
    local before
    before=$(git log --oneline master..source/feature-4 | wc -l | tr -d ' ')
    assert_eq "2" "$before" "target-4 has 2 commits before reset"

    # Reset and regenerate
    bash "$DISPATCH" apply reset 4 >/dev/null 2>&1

    assert_branch_exists "source/feature-4" "target-4 recreated"

    local after
    after=$(git log --oneline master..source/feature-4 | wc -l | tr -d ' ')
    assert_eq "2" "$after" "target-4 has 2 commits after reset"

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
    git config branch.$(git symbolic-ref --short HEAD).dispatchbase "nonexistent/master"
    git config branch.$(git symbolic-ref --short HEAD).dispatchtargetPattern "source/feature-{id}"

    echo "a" > file.txt; git add file.txt
    git commit -m "Add feature$(printf '\n\nDispatch-Target-Id: 1')" -q

    # Apply should warn but not crash
    local output
    output=$(bash "$DISPATCH" apply 2>&1 | sed $'s/\033\\[[0-9;]*m//g') || true

    assert_contains "$output" "does not resolve" "warns about unresolvable base ref"

    teardown
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

test_apply_force_resets_partial_reassignment() {
    echo "=== test: apply --force resets target with partially reassigned commits ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "feature B" > b.txt; git add b.txt
    git commit -m "Feature B$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Verify target-1 has 2 commits
    local count
    count=$(git log --oneline master..target-1 | wc -l | tr -d ' ')
    assert_eq "2" "$count" "target-1 has 2 commits before reassignment"

    # Reassign Feature B from tid 1 to tid 2 (rewrite source)
    git reset --hard master -q
    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "feature B" > b.txt; git add b.txt
    git commit -m "Feature B$(printf '\n\nDispatch-Target-Id: 2')" -q

    # apply --force should reset target-1 and create target-2
    local output
    output=$(bash "$DISPATCH" apply --force 2>&1)

    assert_contains "$output" "reassigned" "reports reassigned commits"
    assert_contains "$output" "Reset target-1" "resets target-1"

    # target-1 should now have only 1 commit (Feature A)
    count=$(git log --oneline master..target-1 | wc -l | tr -d ' ')
    assert_eq "1" "$count" "target-1 rebuilt with 1 commit"

    # target-2 should be created with Feature B
    assert_branch_exists "target-2" "target-2 created"
    count=$(git log --oneline master..target-2 | wc -l | tr -d ' ')
    assert_eq "1" "$count" "target-2 has 1 commit"

    teardown
}

test_apply_no_force_ignores_partial_reassignment() {
    echo "=== test: apply without --force does not reset partial reassignment ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "feature B" > b.txt; git add b.txt
    git commit -m "Feature B$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Reassign Feature B from tid 1 to tid 2
    git reset --hard master -q
    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "feature B" > b.txt; git add b.txt
    git commit -m "Feature B$(printf '\n\nDispatch-Target-Id: 2')" -q

    # apply without --force should still work (incremental), target-1 keeps old commits
    local output
    output=$(bash "$DISPATCH" apply 2>&1)

    # target-1 still has 2 commits (old cherry-pick not removed)
    local count
    count=$(git log --oneline master..target-1 | wc -l | tr -d ' ')
    assert_eq "2" "$count" "target-1 unchanged without --force"

    # target-2 created
    assert_branch_exists "target-2" "target-2 created"

    teardown
}

test_apply_dry_run_shows_partial_reassignment() {
    echo "=== test: apply --dry-run reports partial reassignment ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "feature B" > b.txt; git add b.txt
    git commit -m "Feature B$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Reassign Feature B from tid 1 to tid 2
    git reset --hard master -q
    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "feature B" > b.txt; git add b.txt
    git commit -m "Feature B$(printf '\n\nDispatch-Target-Id: 2')" -q

    local output
    output=$(bash "$DISPATCH" apply --dry-run 2>&1)

    assert_contains "$output" "reassigned" "shows reassigned warning"
    assert_contains "$output" "would reset" "shows would reset"

    # Branches untouched
    local count
    count=$(git log --oneline master..target-1 | wc -l | tr -d ' ')
    assert_eq "2" "$count" "target-1 not modified in dry-run"

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

test_target_id_all_not_stale() {
    echo "=== test: all commits do not cause false stale detection ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "shared" > shared.txt; git add shared.txt
    git commit -m "shared config$(printf '\n\nDispatch-Target-Id: all')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "tid2$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null 2>&1

    local output
    output=$(bash "$DISPATCH" status 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    # Should NOT show stale or "all" as a target
    assert_not_contains "$output" "stale" "no stale warning with all commits"
    assert_not_contains "$output" "task-all" "no task-all target shown"
    assert_not_contains "$output" "not created" "no uncreated all target"

    teardown
}

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
    output=$(bash "$DISPATCH" apply --resolve 2>&1) || true

    # Untracked file should still exist (no stashing happened)
    if [[ -f "untracked.txt" ]]; then
        echo -e "  ${GREEN}PASS${NC} untracked file not disturbed by worktree apply"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} untracked file was removed"
        FAIL=$((FAIL + 1))
    fi

    # Clean up any leftover worktrees
    git worktree prune 2>/dev/null || true

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
    assert_contains "$output" "git dispatch sync" "suggests sync command"

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
    echo "=== test: staged changes survive worktree apply ==="
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

    # Apply via worktree should not touch staged changes
    local output
    output=$(bash "$DISPATCH" apply 2>&1) || true

    # Should not crash
    assert_not_contains "$output" "fatal" "no fatal error from worktree apply"

    # Staged file.txt changes should still be present
    local staged_content
    staged_content=$(git show :file.txt 2>/dev/null || true)
    assert_eq "staged-change" "$staged_content" "staged changes survive apply operation"

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

    # Add a new commit and apply (non-conflicting)
    echo "b" > b.txt; git add b.txt
    git commit -m "Add b$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # No leftover worktrees should exist
    local output
    output=$(bash "$DISPATCH" continue 2>&1)
    assert_contains "$output" "No pending" "continue reports no pending operations"

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

    bash "$DISPATCH" apply --resolve 2>&1 || true

    local output
    output=$(bash "$DISPATCH" continue 2>&1)
    assert_contains "$output" "Cherry-pick conflict pending" "continue detects pending cherry-pick"
    assert_contains "$output" "source/feature-1" "continue shows branch name"

    # Clean up
    git worktree prune 2>/dev/null; git worktree list --porcelain | awk '/^worktree / {p=substr($0,10)} /git-dispatch-wt/ {system("git worktree remove --force " p)}' 2>/dev/null || true

    teardown
}

# ---------- checkout tests ----------

test_checkout_creates_branch() {
    echo "=== test: checkout creates branch ==="
    setup
    create_source  # commits: tid=3, tid=4(x2), tid=5

    bash "$DISPATCH" apply >/dev/null 2>&1

    local output
    output=$(bash "$DISPATCH" checkout 4 2>&1)

    assert_branch_exists "dispatch-checkout/source/feature/4" "checkout branch created"

    # Should have content from tid=3 and tid=4, not tid=5
    local file_exists validate_exists
    file_exists=$(git show "dispatch-checkout/source/feature/4:file.txt" 2>/dev/null || echo "MISSING")
    validate_exists=$(git show "dispatch-checkout/source/feature/4:validate.txt" 2>/dev/null || echo "MISSING")
    assert_eq "a" "$file_exists" "tid=3 content present"
    assert_eq "MISSING" "$validate_exists" "tid=5 content excluded"

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
    bash "$DISPATCH" apply >/dev/null 2>&1

    bash "$DISPATCH" checkout 2 >/dev/null 2>&1

    # shared.txt should exist (from tid=all, applied to both targets)
    local shared_exists
    shared_exists=$(git show "dispatch-checkout/source/feature/2:shared.txt" 2>/dev/null || echo "MISSING")
    assert_eq "shared" "$shared_exists" "all commit content present"

    # c.txt should NOT exist (from tid=3)
    local c_exists
    c_exists=$(git show "dispatch-checkout/source/feature/2:c.txt" 2>/dev/null || echo "MISSING")
    assert_eq "MISSING" "$c_exists" "tid=3 content excluded"

    teardown
}

test_checkout_merges_targets_in_order() {
    echo "=== test: checkout merges targets in numeric order ==="
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
    bash "$DISPATCH" apply >/dev/null 2>&1
    bash "$DISPATCH" checkout 2 >/dev/null 2>&1

    # All content should be present (merged from target-1 and target-2)
    local a_exists b_exists c_exists d_exists
    a_exists=$(git show "dispatch-checkout/source/feature/2:a.txt" 2>/dev/null || echo "MISSING")
    b_exists=$(git show "dispatch-checkout/source/feature/2:b.txt" 2>/dev/null || echo "MISSING")
    c_exists=$(git show "dispatch-checkout/source/feature/2:c.txt" 2>/dev/null || echo "MISSING")
    d_exists=$(git show "dispatch-checkout/source/feature/2:d.txt" 2>/dev/null || echo "MISSING")
    assert_eq "a" "$a_exists" "a.txt from tid=2 present"
    assert_eq "b" "$b_exists" "b.txt from tid=1 present"
    assert_eq "c" "$c_exists" "c.txt from tid=2 present"
    assert_eq "d" "$d_exists" "d.txt from tid=1 present"

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
    bash "$DISPATCH" apply >/dev/null 2>&1
    bash "$DISPATCH" checkout 2 >/dev/null 2>&1

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

test_checkout_requires_apply() {
    echo "=== test: checkout requires apply first ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "tid2$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    # Do NOT apply

    local output
    output=$(bash "$DISPATCH" checkout 2 2>&1) || true

    assert_contains "$output" "not created" "checkout errors without apply"

    teardown
}

test_checkout_errors_if_exists() {
    echo "=== test: checkout errors if branch exists ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null 2>&1
    bash "$DISPATCH" checkout 4 >/dev/null 2>&1

    local output
    output=$(bash "$DISPATCH" checkout 4 2>&1) || true
    assert_contains "$output" "Already on a checkout branch" "errors when checkout branch exists"

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
    bash "$DISPATCH" apply >/dev/null 2>&1
    output=$(bash "$DISPATCH" checkout 3 2>&1) || true
    assert_contains "$output" "No commits" "errors when no matching commits"

    teardown
}

test_checkout_large_N_includes_all() {
    echo "=== test: checkout with large N includes all content ==="
    setup
    create_source  # commits: tid=3, tid=4(x2), tid=5

    bash "$DISPATCH" apply >/dev/null 2>&1
    bash "$DISPATCH" checkout 999 >/dev/null 2>&1

    # All content from all targets should be present
    local file_exists api_exists dto_exists validate_exists
    file_exists=$(git show "dispatch-checkout/source/feature/999:file.txt" 2>/dev/null || echo "MISSING")
    validate_exists=$(git show "dispatch-checkout/source/feature/999:validate.txt" 2>/dev/null || echo "MISSING")
    assert_eq "a" "$file_exists" "tid=3 content present with N=999"
    assert_eq "d" "$validate_exists" "tid=5 content present with N=999"

    teardown
}

# ---------- checkout source tests ----------

test_checkout_source_returns_to_source() {
    echo "=== test: checkout source returns to source ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null 2>&1
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

    bash "$DISPATCH" apply >/dev/null 2>&1
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
    bash "$DISPATCH" apply >/dev/null 2>&1
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
    bash "$DISPATCH" apply >/dev/null 2>&1
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

test_checkout_clear_removes_all_branches() {
    echo "=== test: checkout clear removes all checkout branches at once ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "tid2$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null 2>&1

    # Create two checkout branches (must return to source between them)
    bash "$DISPATCH" checkout 1 >/dev/null 2>&1
    bash "$DISPATCH" checkout source >/dev/null 2>&1
    bash "$DISPATCH" checkout 2 >/dev/null 2>&1
    bash "$DISPATCH" checkout source >/dev/null 2>&1

    assert_branch_exists "dispatch-checkout/source/feature/1" "checkout 1 exists"
    assert_branch_exists "dispatch-checkout/source/feature/2" "checkout 2 exists"

    # Single clear should remove both
    local output
    output=$(bash "$DISPATCH" checkout clear 2>&1)
    assert_not_contains "$output" "No checkout branch" "found branches to clear"
    assert_contains "$output" "dispatch-checkout/source/feature/1" "reports clearing checkout 1"
    assert_contains "$output" "dispatch-checkout/source/feature/2" "reports clearing checkout 2"

    assert_branch_not_exists "dispatch-checkout/source/feature/1" "checkout 1 deleted"
    assert_branch_not_exists "dispatch-checkout/source/feature/2" "checkout 2 deleted"

    teardown
}

test_checkout_clear_all_with_one_unpicked() {
    echo "=== test: checkout clear clears safe branches, warns about unpicked ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "tid2$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null 2>&1

    bash "$DISPATCH" checkout 1 >/dev/null 2>&1
    bash "$DISPATCH" checkout source >/dev/null 2>&1
    bash "$DISPATCH" checkout 2 >/dev/null 2>&1
    bash "$DISPATCH" checkout source >/dev/null 2>&1

    # Add unpicked commit to checkout 1
    git checkout "dispatch-checkout/source/feature/1" -q
    echo "new" > new.txt; git add new.txt
    git commit -m "new commit$(printf '\n\nDispatch-Target-Id: 1')" -q
    git checkout source/feature -q

    local output
    output=$(bash "$DISPATCH" checkout clear 2>&1) || true

    # Checkout 1 should be preserved (unpicked), checkout 2 should be cleared
    assert_contains "$output" "unpicked" "warns about unpicked on checkout 1"
    assert_contains "$output" "Cleared: dispatch-checkout/source/feature/2" "clears checkout 2"
    assert_branch_exists "dispatch-checkout/source/feature/1" "checkout 1 preserved"
    assert_branch_not_exists "dispatch-checkout/source/feature/2" "checkout 2 deleted"

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

    bash "$DISPATCH" apply >/dev/null 2>&1
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
    bash "$DISPATCH" apply >/dev/null 2>&1
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
    bash "$DISPATCH" apply >/dev/null 2>&1
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
    bash "$DISPATCH" apply >/dev/null 2>&1
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

test_checkin_from_source_with_n() {
    echo "=== test: checkin <N> works from source branch ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null 2>&1
    bash "$DISPATCH" checkout 1 >/dev/null 2>&1

    # Make a new commit on checkout
    git checkout "dispatch-checkout/source/feature/1" -q
    echo "fix" > fix.txt; git add fix.txt
    git commit -m "bugfix$(printf '\n\nDispatch-Target-Id: 1')" -q

    # Go back to source
    git checkout source/feature -q

    # Checkin from source with <N>
    bash "$DISPATCH" checkin 1 >/dev/null 2>&1

    local source_count
    source_count=$(git log --oneline "master..source/feature" | wc -l | tr -d ' ')
    assert_eq "2" "$source_count" "checkin <N> from source picked commit"

    teardown
}

test_checkin_dry_run() {
    echo "=== test: checkin --dry-run shows plan ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null 2>&1
    bash "$DISPATCH" checkout 1 >/dev/null 2>&1

    git checkout "dispatch-checkout/source/feature/1" -q
    echo "fix" > fix.txt; git add fix.txt
    git commit -m "bugfix$(printf '\n\nDispatch-Target-Id: 1')" -q
    git checkout source/feature -q

    local output
    output=$(bash "$DISPATCH" checkin 1 --dry-run 2>&1)

    assert_contains "$output" "dry-run" "shows dry-run label"
    assert_contains "$output" "bugfix" "shows commit"

    # Source should NOT have the commit (dry-run)
    local source_count
    source_count=$(git log --oneline "master..source/feature" | wc -l | tr -d ' ')
    assert_eq "1" "$source_count" "dry-run did not modify source"

    teardown
}

test_checkout_dry_run() {
    echo "=== test: checkout --dry-run shows plan ==="
    setup
    create_source

    local output
    bash "$DISPATCH" apply >/dev/null 2>&1
    output=$(bash "$DISPATCH" checkout 4 --dry-run 2>&1)

    assert_contains "$output" "dry-run" "shows dry-run label"
    assert_contains "$output" "merge" "shows merge plan"

    # Branch should NOT exist
    assert_branch_not_exists "dispatch-checkout/source/feature/4" "dry-run did not create branch"

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

    bash "$DISPATCH" apply >/dev/null 2>&1
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
    bash "$DISPATCH" apply >/dev/null 2>&1
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

test_checkin_only_picks_new_commits() {
    echo "=== test: checkin only picks commits authored after checkout ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "feature a$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "feature b$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Checkout: merges target-1 (which has 2 cherry-picked commits)
    bash "$DISPATCH" checkout 1 >/dev/null 2>&1
    git checkout "dispatch-checkout/source/feature/1" -q

    # Add ONE new commit on the checkout branch
    echo "fix" > fix.txt; git add fix.txt
    git commit -m "hotfix$(printf '\n\nDispatch-Target-Id: 1')" -q

    # Checkin should pick ONLY the 1 new commit, not the 2 original target commits
    local output
    output=$(bash "$DISPATCH" checkin 2>&1)

    assert_contains "$output" "1 commit" "checkin picks only new commit"
    assert_not_contains "$output" "Conflict" "no conflicts from replayed originals"

    # Verify the fix is on source
    local fix_content
    fix_content=$(git show "source/feature:fix.txt" 2>/dev/null || echo "MISSING")
    assert_eq "fix" "$fix_content" "fix cherry-picked to source"

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
    bash "$DISPATCH" apply >/dev/null 2>&1
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

test_continue_resumes_remaining_queue() {
    echo "=== test: continue resumes remaining merges after conflict ==="
    setup

    git checkout -b source/feature master -q

    # Target 1 creates shared.txt
    echo "a" > a.txt; git add a.txt
    echo "version-1" > shared.txt; git add shared.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q

    # Target 2 also creates shared.txt (different content) + its own file
    # This will conflict during checkout merge since both add shared.txt
    echo "b" > b.txt; git add b.txt
    git commit -m "tid2-b$(printf '\n\nDispatch-Target-Id: 2')" -q

    # Target 3 is clean
    echo "c" > c.txt; git add c.txt
    git commit -m "tid3$(printf '\n\nDispatch-Target-Id: 3')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null 2>&1

    # Manually create a conflict: modify shared.txt on target-2 branch
    local wt_t2
    wt_t2=$(mktemp -d)
    git worktree add -q "$wt_t2" "source/feature-2"
    echo "target2-version" > "$wt_t2/shared.txt"
    git -C "$wt_t2" add shared.txt
    git -C "$wt_t2" -c core.hooksPath= commit -m "target-2 modifies shared.txt" -q
    git worktree remove --force "$wt_t2"
    git worktree prune

    # Checkout 3 with --resolve: merge target-1 (has shared.txt=version-1),
    # then target-2 (has shared.txt=target2-version) - CONFLICT
    local output
    output=$(bash "$DISPATCH" checkout 3 --resolve 2>&1) || true

    # Find the worktree
    local wt
    wt=$(git worktree list --porcelain | awk '/^worktree / {path=substr($0, 10)} /^branch / {if (path ~ /git-dispatch-wt\./) print path}' | head -1)

    if [[ -n "$wt" ]]; then
        # Merge queue should exist with remaining targets
        assert_eq "true" "$(test -f "$wt/.dispatch-merge-queue" && echo true || echo false)" "merge queue file created"

        # Resolve the merge conflict
        echo "resolved" > "$wt/shared.txt"
        git -C "$wt" add shared.txt 2>/dev/null
        git -C "$wt" -c core.hooksPath= commit --no-edit -q 2>/dev/null

        # Continue should resume remaining merges
        local cont_output
        cont_output=$(bash "$DISPATCH" continue 2>&1)
        assert_contains "$cont_output" "merged" "continue resumes remaining merges"

        # c.txt should exist (from target-3, merged after conflict resolution)
        local c_exists
        c_exists=$(git show "dispatch-checkout/source/feature/3:c.txt" 2>/dev/null || echo "MISSING")
        assert_eq "c" "$c_exists" "target-3 content present after continue"
    else
        echo -e "  ${RED}FAIL${NC} no worktree found for conflict resolution"
        FAIL=$((FAIL + 1))
    fi

    # Cleanup
    git worktree prune 2>/dev/null; git worktree list --porcelain | awk '/^worktree / {p=substr($0,10)} /git-dispatch-wt/ {system("git worktree remove --force " p)}' 2>/dev/null || true

    teardown
}

test_continue_resumes_apply_queue() {
    echo "=== test: continue resumes apply queue after conflict ==="
    setup

    git checkout -b source/feature master -q

    echo "a" > a.txt; git add a.txt
    git commit -m "tid1$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null 2>&1

    # Create conflict: target modifies file, source adds new commit modifying same file
    git checkout source/feature-1 -q
    echo "target-change" > a.txt; git add a.txt
    git commit --no-verify -m "target modifies a" -q
    git checkout source/feature -q

    echo "source-change" > a.txt; git add a.txt
    git commit -m "source modifies a$(printf '\n\nDispatch-Target-Id: 1')" -q

    # Add another commit AFTER the conflicting one
    echo "d" > d.txt; git add d.txt
    git commit -m "another commit$(printf '\n\nDispatch-Target-Id: 1')" -q

    # Apply with --resolve
    bash "$DISPATCH" apply --resolve 2>&1 || true

    # Find worktree
    local wt
    wt=$(git worktree list --porcelain | awk '/^worktree / {path=substr($0, 10)} /^branch / {if (path ~ /git-dispatch-wt\./) print path}' | head -1)

    if [[ -n "$wt" ]]; then
        # Resolve conflict
        git -C "$wt" checkout --theirs a.txt 2>/dev/null
        git -C "$wt" add a.txt 2>/dev/null
        git -C "$wt" cherry-pick --continue --no-edit 2>/dev/null

        # Continue should pick remaining
        local cont_output
        cont_output=$(bash "$DISPATCH" continue 2>&1)

        # d.txt should exist on target (from the queued commit)
        local d_exists
        d_exists=$(git show "source/feature-1:d.txt" 2>/dev/null || echo "MISSING")
        assert_eq "d" "$d_exists" "queued apply commit landed after continue"
    else
        echo -e "  ${RED}FAIL${NC} no worktree found for conflict resolution"
        FAIL=$((FAIL + 1))
    fi

    git worktree prune 2>/dev/null; git worktree list --porcelain | awk '/^worktree / {p=substr($0,10)} /git-dispatch-wt/ {system("git worktree remove --force " p)}' 2>/dev/null || true

    teardown
}

# ---------- --yes and interactive tests ----------

test_init_yes_skips_overwrite_prompt() {
    echo "=== test: init --yes skips overwrite prompt ==="
    setup

    git checkout -b source/feature master -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    # Re-init with --yes should not prompt
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" --yes

    local base
    base=$(git config branch.source/feature.dispatchbase)
    assert_eq "master" "$base" "config updated with --yes"

    teardown
}

test_short_flags_rejected() {
    echo "=== test: -y short flag rejected (long flags only) ==="
    setup

    git checkout -b source/feature master -q

    # -y should be rejected as unknown flag
    local output
    output=$(bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" -y 2>&1) || true
    assert_contains "$output" "Unknown flag" "-y rejected on init"

    teardown
}

test_reset_yes_skips_prompt() {
    echo "=== test: reset --yes skips prompt ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    # Reset with --yes should not prompt (piped stdin)
    bash "$DISPATCH" reset --yes

    local base
    base=$(git config branch.source/feature.dispatchbase 2>/dev/null || true)
    assert_eq "" "$base" "config cleared with --yes"

    teardown
}

test_apply_reset_yes_skips_prompt() {
    echo "=== test: apply reset --yes skips prompt ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    echo "a" > a.txt
    git add a.txt
    git commit -m "add a" --trailer "Dispatch-Target-Id=1" -q

    bash "$DISPATCH" apply

    # Add target-only commit
    local wt_path
    wt_path=$(mktemp -d)
    git worktree add -q "$wt_path" "source/feature-task-1"
    git -C "$wt_path" commit --allow-empty -m "target-only" -q
    git worktree remove --force "$wt_path"
    git worktree prune

    # apply reset with --yes should not prompt about target-only commits
    bash "$DISPATCH" apply reset 1 --yes

    teardown
}

test_force_only_for_safety_overrides() {
    echo "=== test: --force only for safety overrides, --yes for prompts ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    echo "a" > a.txt; git add a.txt
    git commit -m "add a" --trailer "Dispatch-Target-Id=1" -q
    bash "$DISPATCH" apply

    # --yes skips apply reset all confirmation (piped stdin = non-interactive)
    local output
    output=$(bash "$DISPATCH" apply reset all --yes 2>&1)
    assert_contains "$output" "Deleted source/feature-task-1" "apply reset all --yes works"
    assert_contains "$output" "Created source/feature-task-1" "apply reset all --yes recreates"

    # --force on apply is for stale rebuild, not confirmation skip
    bash "$DISPATCH" apply  # recreate target

    # --force is a deprecated alias for --yes, so it still works
    output=$(bash "$DISPATCH" apply reset all --force 2>&1) || true

    teardown
}

test_reset_y_instead_of_force() {
    echo "=== test: reset uses --yes for confirmation ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    # --yes skips the prompt
    bash "$DISPATCH" reset --yes

    local base
    base=$(git config branch.source/feature.dispatchbase 2>/dev/null || true)
    assert_eq "" "$base" "reset --yes clears config"

    # Re-init, test that --force still works as deprecated alias
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"
    bash "$DISPATCH" reset --force

    base=$(git config branch.source/feature.dispatchbase 2>/dev/null || true)
    assert_eq "" "$base" "reset --force (deprecated) still works"

    teardown
}

test_apply_force_only_for_stale() {
    echo "=== test: apply --force is only for stale target rebuild ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "a" > a.txt; git add a.txt
    git commit -m "A$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Reassign tid to make target-1 stale
    git reset --hard master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "A$(printf '\n\nDispatch-Target-Id: 2')" -q

    # Without --force: stale detected but not rebuilt
    local output
    output=$(bash "$DISPATCH" apply 2>&1) || true
    assert_contains "$output" "Stale targets" "stale detected without force"

    # With --force: stale targets rebuilt
    output=$(bash "$DISPATCH" apply --force 2>&1)
    assert_contains "$output" "Deleted stale" "stale rebuilt with force"

    teardown
}

test_init_interactive_missing_target_pattern() {
    echo "=== test: init fails non-interactive without target-pattern ==="
    setup

    git checkout -b source/feature master -q

    local output
    output=$(bash "$DISPATCH" init --base master 2>&1) || true
    assert_contains "$output" "Missing input" "non-interactive init requires --target-pattern"

    teardown
}

test_worktree_config_isolation() {
    echo "=== test: worktree config does not collide ==="
    setup

    git checkout -b source/feature-a master -q
    bash "$DISPATCH" init --base master --target-pattern "feature-a/task-{id}"

    local base_a
    base_a=$(git config branch.source/feature-a.dispatchbase)
    assert_eq "master" "$base_a" "feature-a config set"

    git checkout -b source/feature-b master -q
    bash "$DISPATCH" init --base master --target-pattern "feature-b/task-{id}"

    local base_b
    base_b=$(git config branch.source/feature-b.dispatchbase)
    assert_eq "master" "$base_b" "feature-b config set"

    # feature-a config should still be intact
    local base_a_after
    base_a_after=$(git config branch.source/feature-a.dispatchbase)
    assert_eq "master" "$base_a_after" "feature-a config not collided"

    local pattern_a
    pattern_a=$(git config branch.source/feature-a.dispatchtargetPattern)
    assert_eq "feature-a/task-{id}" "$pattern_a" "feature-a pattern preserved"

    local pattern_b
    pattern_b=$(git config branch.source/feature-b.dispatchtargetPattern)
    assert_eq "feature-b/task-{id}" "$pattern_b" "feature-b pattern set"

    teardown
}

test_reset_preserves_other_session_hooks() {
    echo "=== test: reset preserves hooks when other sessions exist ==="
    setup

    git checkout -b source/feature-a master -q
    bash "$DISPATCH" init --base master --target-pattern "feature-a/task-{id}"

    git checkout -b source/feature-b master -q
    bash "$DISPATCH" init --base master --target-pattern "feature-b/task-{id}"

    # Reset feature-b
    bash "$DISPATCH" reset --yes

    # Hooks should still exist (feature-a still active)
    local hook_dir
    hook_dir="$(git rev-parse --git-dir)/hooks"
    if [[ -f "$hook_dir/commit-msg" ]]; then
        echo -e "  ${GREEN}PASS${NC} hooks preserved after partial reset"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} hooks deleted despite other active session"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_reset_removes_hooks_when_last_session() {
    echo "=== test: reset removes hooks when last session ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    # Reset the only session
    bash "$DISPATCH" reset --yes

    # Hooks should be deleted
    local hook_dir
    hook_dir="$(git rev-parse --git-dir)/hooks"
    if [[ ! -f "$hook_dir/commit-msg" ]]; then
        echo -e "  ${GREEN}PASS${NC} hooks removed after last session reset"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} hooks not removed after last session reset"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_no_legacy_fallback() {
    echo "=== test: no legacy global config fallback ==="
    setup

    git checkout -b source/feature master -q

    # Set legacy global config (should be ignored)
    git config dispatch.base "stale-base"
    git config dispatch.targetPattern "stale/pattern-{id}"

    # _get_config should NOT return legacy values
    local output
    output=$(bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" 2>&1)
    # No "already configured" warning since legacy config is ignored
    assert_not_contains "$output" "already configured" "legacy global config ignored"

    teardown
}

# ---------- merge-base-into-targets tests ----------

test_sync_merges_into_existing_targets() {
    echo "=== test: sync merges base into existing targets ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    echo "a" > a.txt
    git add a.txt
    git commit -m "add a" --trailer "Dispatch-Target-Id=1" -q

    echo "b" > b.txt
    git add b.txt
    git commit -m "add b" --trailer "Dispatch-Target-Id=2" -q

    bash "$DISPATCH" apply

    # Advance master with a non-conflicting change (disable hooks for non-dispatch commit)
    git checkout master -q
    echo "master-change" > master.txt
    git add master.txt
    git -c core.hooksPath= commit -m "master: add master.txt" -q

    git checkout source/feature -q

    # Apply with --base should merge master into source AND targets
    bash "$DISPATCH" sync

    # Verify targets have master's change (via merge, not recreate)
    local t1_master t2_master
    t1_master=$(git show "source/feature-task-1:master.txt" 2>/dev/null || echo "MISSING")
    t2_master=$(git show "source/feature-task-2:master.txt" 2>/dev/null || echo "MISSING")

    assert_eq "master-change" "$t1_master" "target-1 has master change via merge"
    assert_eq "master-change" "$t2_master" "target-2 has master change via merge"

    # Verify targets still have their original content
    local t1_a t2_b
    t1_a=$(git show "source/feature-task-1:a.txt" 2>/dev/null || echo "MISSING")
    t2_b=$(git show "source/feature-task-2:b.txt" 2>/dev/null || echo "MISSING")

    assert_eq "a" "$t1_a" "target-1 still has a.txt"
    assert_eq "b" "$t2_b" "target-2 still has b.txt"

    teardown
}

test_sync_no_force_push_needed() {
    echo "=== test: sync produces fast-forward-compatible targets ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    echo "a" > a.txt
    git add a.txt
    git commit -m "add a" --trailer "Dispatch-Target-Id=1" -q

    bash "$DISPATCH" apply

    # Record target SHA before
    local sha_before
    sha_before=$(git rev-parse "source/feature-task-1")

    # Advance master
    git checkout master -q
    echo "master-file" > m.txt
    git add m.txt
    git -c core.hooksPath= commit -m "master: add m.txt" -q

    git checkout source/feature -q
    bash "$DISPATCH" sync

    # Target should be a descendant of the old SHA (no force push needed)
    if git merge-base --is-ancestor "$sha_before" "source/feature-task-1"; then
        echo -e "  ${GREEN}PASS${NC} target is fast-forward from previous SHA"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} target not fast-forward (would need force push)"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_sync_target_merge_dry_run() {
    echo "=== test: sync --dry-run shows merge plan ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    echo "a" > a.txt
    git add a.txt
    git commit -m "add a" --trailer "Dispatch-Target-Id=1" -q

    bash "$DISPATCH" apply

    # Advance master
    git checkout master -q
    echo "m" > m.txt
    git add m.txt
    git -c core.hooksPath= commit -m "master change" -q

    git checkout source/feature -q

    local output
    output=$(bash "$DISPATCH" sync --dry-run 2>&1)

    assert_contains "$output" "merge" "dry-run shows merge plan for targets"

    teardown
}

test_sync_skips_up_to_date_targets() {
    echo "=== test: sync skips targets already up to date ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    echo "a" > a.txt
    git add a.txt
    git commit -m "add a" --trailer "Dispatch-Target-Id=1" -q

    bash "$DISPATCH" apply

    # Apply --base with no base changes (source already up to date)
    local output
    output=$(bash "$DISPATCH" sync 2>&1)

    assert_contains "$output" "Already in sync" "no merge when base unchanged"

    teardown
}

test_sync_conflict_on_target_merge() {
    echo "=== test: sync conflict on target merge ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    echo "source-a" > a.txt
    git add a.txt
    git commit -m "add a" --trailer "Dispatch-Target-Id=1" -q

    # Create a second file so source merge doesn't conflict on a.txt
    echo "b" > b.txt; git add b.txt
    git commit -m "add b" --trailer "Dispatch-Target-Id=1" -q

    bash "$DISPATCH" apply

    # Directly modify target's a.txt (simulating a checkin that diverged)
    local wt_path
    wt_path=$(mktemp -d)
    git worktree add -q "$wt_path" "source/feature-task-1"
    echo "target-modified-a" > "$wt_path/a.txt"
    git -C "$wt_path" add a.txt
    git -C "$wt_path" commit --no-verify -m "target-only change" -q
    git worktree remove --force "$wt_path"
    git worktree prune

    # Master also changes a.txt
    git checkout master -q
    echo "master-a" > a.txt; git add a.txt
    git -c core.hooksPath= commit -m "master: change a.txt" -q
    git checkout source/feature -q

    # Sync: source merge is clean (source doesn't conflict with master on a.txt)
    # but target merge conflicts (target has "target-modified-a", master has "master-a")
    local output
    output=$(bash "$DISPATCH" sync 2>&1) || true

    assert_contains "$output" "Merge conflict" "detects conflict merging base into target"

    teardown
}

test_sync_does_not_create_new_targets() {
    echo "=== test: sync does not create new targets ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    echo "a" > a.txt
    git add a.txt
    git commit -m "add a" --trailer "Dispatch-Target-Id=1" -q

    bash "$DISPATCH" apply

    # Add new target on source (not yet applied)
    echo "c" > c.txt
    git add c.txt
    git commit -m "add c" --trailer "Dispatch-Target-Id=2" -q

    # Advance master
    git checkout master -q
    echo "m" > m.txt; git add m.txt
    git -c core.hooksPath= commit -m "master change" -q
    git checkout source/feature -q

    bash "$DISPATCH" sync

    # Sync should NOT create target-2 (only apply creates targets)
    assert_branch_not_exists "source/feature-task-2" "sync does not create new targets"
    # But target-1 should have the master merge
    local t1_m
    t1_m=$(git show "source/feature-task-1:m.txt" 2>/dev/null || echo "MISSING")
    assert_eq "m" "$t1_m" "existing target-1 has master content via merge"

    teardown
}

# ---------- apply reset scoping / abort / --continue tests ----------

test_apply_reset_does_not_cascade() {
    echo "=== test: apply reset N does not cascade to other targets ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    echo "a" > a.txt
    git add a.txt
    git commit -m "add a" --trailer "Dispatch-Target-Id=1" -q

    echo "b" > b.txt
    git add b.txt
    git commit -m "add b" --trailer "Dispatch-Target-Id=2" -q

    bash "$DISPATCH" apply

    local sha2_before
    sha2_before=$(git rev-parse "source/feature-task-2")

    # Reset only target 1 - target 2 should be untouched
    bash "$DISPATCH" apply reset 1 --yes

    local sha2_after
    sha2_after=$(git rev-parse "source/feature-task-2")

    assert_eq "$sha2_before" "$sha2_after" "target-2 SHA unchanged after reset 1"

    teardown
}

test_apply_reset_all() {
    echo "=== test: apply reset all regenerates all targets ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    echo "a" > a.txt
    git add a.txt
    git commit -m "add a" --trailer "Dispatch-Target-Id=1" -q

    echo "b" > b.txt
    git add b.txt
    git commit -m "add b" --trailer "Dispatch-Target-Id=2" -q

    bash "$DISPATCH" apply

    # Record SHAs before reset
    local sha1_before sha2_before
    sha1_before=$(git rev-parse "source/feature-task-1")
    sha2_before=$(git rev-parse "source/feature-task-2")

    # reset all regenerates (deletes + recreates in same apply run)
    local output
    output=$(bash "$DISPATCH" apply reset all --yes 2>&1)

    assert_contains "$output" "Deleted source/feature-task-1" "target-1 was deleted"
    assert_contains "$output" "Deleted source/feature-task-2" "target-2 was deleted"
    assert_contains "$output" "Created source/feature-task-1" "target-1 was recreated"
    assert_contains "$output" "Created source/feature-task-2" "target-2 was recreated"

    # SHAs should differ (regenerated)
    local sha1_after sha2_after
    sha1_after=$(git rev-parse "source/feature-task-1")
    sha2_after=$(git rev-parse "source/feature-task-2")

    if [[ "$sha1_before" != "$sha1_after" ]]; then
        echo -e "  ${GREEN}PASS${NC} target-1 SHA changed after reset all"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} target-1 SHA unchanged after reset all"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_apply_reset_all_includes_orphaned() {
    echo "=== test: apply reset all includes orphaned branches ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    echo "a" > a.txt
    git add a.txt
    git commit -m "add a" --trailer "Dispatch-Target-Id=1" -q

    bash "$DISPATCH" apply

    # Orphan the target by removing dispatchsource config
    git config --unset "branch.source/feature-task-1.dispatchsource"

    # apply reset all should find orphaned branch via pattern matching and recreate it
    local output
    output=$(bash "$DISPATCH" apply reset all --yes 2>&1)

    assert_contains "$output" "Deleted source/feature-task-1" "orphaned target found and deleted by reset all"

    teardown
}

test_abort_cleans_cherry_pick_worktree() {
    echo "=== test: abort cleans up cherry-pick conflict ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    echo "a" > a.txt
    git add a.txt
    git commit -m "add a" --trailer "Dispatch-Target-Id=1" -q

    bash "$DISPATCH" apply

    # Create conflict: modify a.txt on target directly
    local wt_path
    wt_path=$(mktemp -d)
    git worktree add -q "$wt_path" "source/feature-task-1"
    echo "target-change" > "$wt_path/a.txt"
    git -C "$wt_path" add a.txt
    git -C "$wt_path" -c core.hooksPath= commit -m "target modifies a" -q
    git worktree remove --force "$wt_path"
    git worktree prune

    # Modify same file on source
    echo "source-change" > a.txt
    git add a.txt
    git commit -m "source modifies a" --trailer "Dispatch-Target-Id=1" -q

    # Apply with --resolve to leave conflict active
    bash "$DISPATCH" apply --resolve 2>/dev/null || true

    # Abort should clean everything up
    local output
    output=$(bash "$DISPATCH" abort 2>&1)

    assert_contains "$output" "Abort complete" "abort completes"

    # No dispatch worktrees should remain
    local remaining
    remaining=$(git worktree list --porcelain | grep -c "git-dispatch-wt" || true)
    assert_eq "0" "$remaining" "no dispatch worktrees remain after abort"

    teardown
}

test_abort_nothing_to_abort() {
    echo "=== test: abort with nothing pending ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    local output
    output=$(bash "$DISPATCH" abort 2>&1)

    assert_contains "$output" "Nothing to abort" "nothing to abort when clean"

    teardown
}

test_continue_alias_for_resolve() {
    echo "=== test: --continue alias for --resolve ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}"

    echo "a" > a.txt
    git add a.txt
    git commit -m "add a" --trailer "Dispatch-Target-Id=1" -q

    # --continue should be accepted as a flag (same as --resolve)
    local output
    output=$(bash "$DISPATCH" apply --dry-run --continue 2>&1)

    # Should not error with "Unknown flag: --continue"
    assert_not_contains "$output" "Unknown flag" "--continue accepted as flag"

    teardown
}

test_apply_base_flag_removed() {
    echo "=== test: apply --base gives helpful error ==="
    setup
    create_source

    local output
    output=$(bash "$DISPATCH" apply --base 2>&1) || true
    assert_contains "$output" "git dispatch sync" "apply --base suggests sync"

    teardown
}

test_sync_blocked_during_checkout() {
    echo "=== test: sync blocked during active checkout ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null 2>&1
    bash "$DISPATCH" checkout 4 >/dev/null 2>&1
    bash "$DISPATCH" checkout source >/dev/null 2>&1

    local output
    output=$(bash "$DISPATCH" sync 2>&1) || true
    assert_contains "$output" "Cannot sync while checkout is active" "sync blocked during checkout"

    teardown
}

test_sync_warns_source_behind_in_apply() {
    echo "=== test: apply warns when source is behind base ==="
    setup

    git checkout -b source/feature master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add a$(printf '\n\nDispatch-Target-Id: 1')" -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    # Advance master
    git checkout master -q
    echo "new" > new.txt; git add new.txt
    git commit --no-verify -m "New base commit" -q
    git checkout source/feature -q

    local output
    output=$(bash "$DISPATCH" apply --dry-run 2>&1 | sed $'s/\033\\[[0-9;]*m//g')
    assert_contains "$output" "behind" "warns source is behind"
    assert_contains "$output" "git dispatch sync" "suggests sync command"

    teardown
}

test_spinner_no_output_in_pipe() {
    echo "=== test: spinner suppressed in non-interactive mode ==="
    setup
    create_source

    # When stdout/stderr are piped, spinner text should not appear
    local apply_output
    apply_output=$(bash "$DISPATCH" apply 2>&1)
    assert_not_contains "$apply_output" "Refreshing base" "no spinner text in piped apply"

    local status_output
    status_output=$(bash "$DISPATCH" status 2>&1)
    assert_not_contains "$status_output" "Analyzing" "no spinner text in piped status"

    teardown
}

test_status_no_false_diverged_source_keep() {
    echo "=== test: Source-Keep commits do not trigger false DIVERGED ==="
    setup

    echo "base-gen" > generated.txt; git add generated.txt
    git commit --no-verify -m "Base generated file" -q

    git checkout -b source master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add a$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null 2>&1

    # Source adds a Source-Keep commit (generated file regen)
    echo "source-gen-v2" > generated.txt; git add generated.txt
    git commit -m "Regen files$(printf '\n\nDispatch-Target-Id: 1\nDispatch-Source-Keep: true')" -q

    # Apply the Source-Keep commit to target
    bash "$DISPATCH" apply >/dev/null 2>&1

    # Manually diverge the generated file on target (simulates regen on different base)
    git checkout target-1 -q
    echo "target-gen-v2" > generated.txt; git add generated.txt
    git commit --no-verify -m "Target regen diverges" -q
    git checkout source -q

    # Status should NOT show DIVERGED - only Source-Keep files differ
    local status_output
    status_output=$(bash "$DISPATCH" status 2>&1 | sed $'s/\033\\[[0-9;]*m//g')
    assert_not_contains "$status_output" "DIVERGED" "no false diverged from Source-Keep drift"

    teardown
}

test_status_diverged_non_source_keep_still_detected() {
    echo "=== test: real divergence still detected alongside Source-Keep ==="
    setup

    echo "base-gen" > generated.txt; git add generated.txt
    git commit --no-verify -m "Base generated file" -q

    git checkout -b source master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add a$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null 2>&1

    # Source adds a Source-Keep commit
    echo "source-gen-v2" > generated.txt; git add generated.txt
    git commit -m "Regen files$(printf '\n\nDispatch-Target-Id: 1\nDispatch-Source-Keep: true')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Diverge target with BOTH generated AND real files
    git checkout target-1 -q
    echo "target-gen-v2" > generated.txt; git add generated.txt
    echo "rogue-change" > a.txt; git add a.txt
    git commit --no-verify -m "Target diverges for real" -q
    git checkout source -q

    # Status SHOULD show DIVERGED - real file (a.txt) differs
    local status_output
    status_output=$(bash "$DISPATCH" status 2>&1 | sed $'s/\033\\[[0-9;]*m//g')
    assert_contains "$status_output" "DIVERGED" "real divergence still detected"

    teardown
}

# ---------- retarget tests ----------

test_retarget_basic() {
    echo "=== test: retarget moves commits between targets ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 8')" -q
    echo "feature B" > b.txt; git add b.txt
    git commit -m "Feature B$(printf '\n\nDispatch-Target-Id: 9')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Verify target-8 has Feature A
    local count
    count=$(git log --oneline master..target-8 | wc -l | tr -d ' ')
    assert_eq "1" "$count" "target-8 has 1 commit before retarget"

    # Retarget from 8 to 9
    local output
    output=$(bash "$DISPATCH" retarget 8 9 2>&1)

    assert_contains "$output" "Retarget 1 commit(s)" "reports commit count"
    assert_contains "$output" "Feature A" "reports commit subject"
    assert_contains "$output" "now empty" "reports old target empty"

    # Source should have revert + re-apply commits
    local source_count
    source_count=$(git log --oneline master..source | wc -l | tr -d ' ')
    assert_eq "4" "$source_count" "source has 4 commits (2 original + 1 revert + 1 re-apply)"

    # Net diff on source should be zero (revert + re-apply cancel out)
    local diff_to_original
    diff_to_original=$(git diff source~2 source 2>/dev/null)
    assert_eq "" "$diff_to_original" "retarget is net-zero diff on source"

    # After apply, target-9 should have Feature B + re-applied Feature A
    bash "$DISPATCH" apply --force >/dev/null 2>&1
    count=$(git log --oneline master..target-9 | wc -l | tr -d ' ')
    assert_eq "2" "$count" "target-9 has 2 commits after apply (Feature B + re-applied Feature A)"

    # target-8 should have original + revert (net empty diff)
    local t8_count
    t8_count=$(git log --oneline master..target-8 | wc -l | tr -d ' ')
    assert_eq "2" "$t8_count" "target-8 has 2 commits (original + revert, net zero)"
    local t8_diff
    t8_diff=$(git diff master target-8 2>/dev/null)
    assert_eq "" "$t8_diff" "target-8 has no net diff from master"

    teardown
}

test_retarget_dry_run() {
    echo "=== test: retarget --dry-run makes no changes ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "feature A" > a.txt; git add a.txt
    git commit -m "Feature A$(printf '\n\nDispatch-Target-Id: 8')" -q

    local before_sha
    before_sha=$(git rev-parse HEAD)

    local output
    output=$(bash "$DISPATCH" retarget 8 15 --dry-run 2>&1)

    assert_contains "$output" "Feature A" "shows commit in dry run"
    assert_contains "$output" "Dry run" "says dry run"
    assert_eq "$before_sha" "$(git rev-parse HEAD)" "no commits created"

    teardown
}

test_retarget_multiple_commits() {
    echo "=== test: retarget handles multiple commits ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "a" > a.txt; git add a.txt
    git commit -m "First$(printf '\n\nDispatch-Target-Id: 5')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "Second$(printf '\n\nDispatch-Target-Id: 5')" -q
    echo "c" > c.txt; git add c.txt
    git commit -m "Third$(printf '\n\nDispatch-Target-Id: 5')" -q

    local output
    output=$(bash "$DISPATCH" retarget 5 10 2>&1)

    assert_contains "$output" "Retarget 3 commit(s)" "reports 3 commits"
    assert_contains "$output" "3 revert(s) and 3 re-apply" "created correct commit count"

    # Source should have 3 original + 3 reverts + 3 re-applies = 9 commits
    local count
    count=$(git log --oneline master..source | wc -l | tr -d ' ')
    assert_eq "9" "$count" "source has 9 commits"

    teardown
}

test_retarget_no_commits_errors() {
    echo "=== test: retarget errors when no commits with from-id ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "a" > a.txt; git add a.txt
    git commit -m "A$(printf '\n\nDispatch-Target-Id: 1')" -q

    local output exit_code=0
    output=$(bash "$DISPATCH" retarget 99 1 2>&1) || exit_code=$?

    assert_eq "1" "$exit_code" "exits with error"
    assert_contains "$output" "No commits found" "reports no commits"

    teardown
}

test_retarget_all_disallowed() {
    echo "=== test: retarget from 'all' is disallowed ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "a" > a.txt; git add a.txt
    git commit -m "A$(printf '\n\nDispatch-Target-Id: all')" -q

    local output exit_code=0
    output=$(bash "$DISPATCH" retarget all 1 2>&1) || exit_code=$?

    assert_eq "1" "$exit_code" "exits with error"
    assert_contains "$output" "Cannot retarget from" "rejects retarget from all"

    teardown
}

test_retarget_same_id_errors() {
    echo "=== test: retarget same from and to errors ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "a" > a.txt; git add a.txt
    git commit -m "A$(printf '\n\nDispatch-Target-Id: 1')" -q

    local output exit_code=0
    output=$(bash "$DISPATCH" retarget 1 1 2>&1) || exit_code=$?

    assert_eq "1" "$exit_code" "exits with error"
    assert_contains "$output" "same" "reports same id error"

    teardown
}

test_retarget_to_all_allowed() {
    echo "=== test: retarget to 'all' is allowed ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "a" > a.txt; git add a.txt
    git commit -m "Shared change$(printf '\n\nDispatch-Target-Id: 3')" -q

    local output
    output=$(bash "$DISPATCH" retarget 3 all 2>&1)

    assert_contains "$output" "Retarget 1 commit(s)" "retarget to all works"
    assert_contains "$output" "1 revert(s) and 1 re-apply" "creates commits"

    # Verify the re-apply commit has Dispatch-Target-Id: all
    local last_trailer
    last_trailer=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" | tr -d '[:space:]')
    assert_eq "all" "$last_trailer" "re-apply has target-id all"

    teardown
}

test_retarget_with_apply_flag() {
    echo "=== test: retarget --apply runs apply automatically ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "a" > a.txt; git add a.txt
    git commit -m "Feature$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "Other$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    local output
    output=$(bash "$DISPATCH" retarget 1 2 --apply 2>&1)

    assert_contains "$output" "Running: git dispatch apply" "runs apply"

    teardown
}

# ---------- run ----------

echo "git-dispatch test suite"
echo "======================="
echo ""

test_init_basic
test_init_requires_base
test_init_requires_target_pattern
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
test_hook_rejects_duplicate_target_id
test_hook_rejects_duplicate_source_keep
test_hook_ignores_legacy_target_id
test_apply_rejects_duplicate_target_id
test_worktree_shares_hooks_via_hookspath
test_apply_creates_targets
test_apply_dry_run
test_apply_incremental
test_apply_new_target_mid_range
test_apply_idempotent
test_apply_conflict_aborts
test_apply_create_auto_resolves_with_theirs
test_sync_merges_and_applies
test_sync_up_to_date
test_sync_dry_run
test_push_dry_run_all
test_push_dry_run_single
test_push_force_dry_run
test_push_source_dry_run
test_push_no_argument_errors
test_status_shows_info
test_status_in_sync
test_status_shows_pending
test_status_not_created
test_reset_cleans_up
test_help
test_install_chmod
test_apply_decimal_target_id
test_sync_conflict_shows_details
test_status_shows_diverged
test_status_no_false_diverged_base_drift
test_status_semantic_source_to_target
test_apply_reset_regenerates_target
test_apply_single_target
test_apply_reset_subcommand
test_full_lifecycle
test_refresh_base_fetches_remote
test_refresh_base_noop_when_up_to_date
test_refresh_base_local_branch_with_remote
test_refresh_base_warns_on_fetch_failure
test_apply_detects_stale_after_reassignment
test_apply_force_rebuilds_stale
test_status_shows_stale
test_apply_stale_warns_target_only_commits
test_apply_stale_dry_run
test_apply_force_resets_partial_reassignment
test_apply_no_force_ignores_partial_reassignment
test_apply_dry_run_shows_partial_reassignment
test_apply_from_target_branch
test_apply_skips_base_ancestor_commits
test_target_id_all_hook_accepts
test_target_id_all_included_in_all_targets
test_target_id_all_dry_run_display
test_target_id_all_not_stale
test_source_keep_force_accepts_conflict
test_source_keep_no_conflict_normal_pick
test_no_source_keep_conflict_still_fails
test_resolve_warns_about_dangling_stash
test_apply_warns_base_drift
test_status_shows_untracked_commits
test_stash_pop_conflict_warns
test_continue_cleans_completed_worktree
test_continue_detects_pending_conflict
test_checkout_creates_branch
test_checkout_includes_all_commits
test_checkout_merges_targets_in_order
test_checkout_decimal_targets
test_checkout_requires_apply
test_checkout_errors_if_exists
test_checkout_errors_if_not_initialized
test_checkout_empty_range
test_checkout_large_N_includes_all
test_checkout_source_returns_to_source
test_checkout_source_noop_on_source
test_checkout_clear_removes_branch
test_checkout_clear_warns_unpicked_commits
test_checkout_clear_force_with_unpicked
test_checkout_clear_removes_all_branches
test_checkout_clear_all_with_one_unpicked
test_checkout_clear_no_checkout_exists
test_checkout_clear_from_checkout_branch
test_checkin_picks_new_commits_to_source
test_checkin_no_new_commits
test_checkin_multiple_commits_different_targets
test_checkin_does_not_auto_apply
test_checkin_errors_if_not_on_checkout
test_checkin_from_source_with_n
test_checkin_dry_run
test_checkout_dry_run
test_checkin_skips_original_commits
test_checkin_source_keep_auto_resolves_conflict
test_checkin_then_apply_lifecycle
test_checkin_only_picks_new_commits
test_checkout_full_lifecycle
test_checkout_does_not_affect_targets
test_continue_resumes_remaining_queue
test_continue_resumes_apply_queue
test_init_yes_skips_overwrite_prompt
test_short_flags_rejected
test_reset_yes_skips_prompt
test_apply_reset_yes_skips_prompt
test_force_only_for_safety_overrides
test_reset_y_instead_of_force
test_apply_force_only_for_stale
test_init_interactive_missing_target_pattern
test_worktree_config_isolation
test_reset_preserves_other_session_hooks
test_reset_removes_hooks_when_last_session
test_no_legacy_fallback
test_sync_merges_into_existing_targets
test_sync_no_force_push_needed
test_sync_target_merge_dry_run
test_sync_skips_up_to_date_targets
test_sync_conflict_on_target_merge
test_sync_does_not_create_new_targets
test_apply_reset_does_not_cascade
test_apply_reset_all
test_apply_reset_all_includes_orphaned
test_abort_cleans_cherry_pick_worktree
test_abort_nothing_to_abort
test_continue_alias_for_resolve
test_apply_base_flag_removed
test_sync_blocked_during_checkout
test_sync_warns_source_behind_in_apply
test_spinner_no_output_in_pipe
test_status_no_false_diverged_source_keep
test_status_diverged_non_source_keep_still_detected
test_retarget_basic
test_retarget_dry_run
test_retarget_multiple_commits
test_retarget_no_commits_errors
test_retarget_all_disallowed
test_retarget_same_id_errors
test_retarget_to_all_allowed
test_retarget_with_apply_flag

# ---------- merged target detection ----------

test_merged_target_skipped_in_apply() {
    echo "=== test: apply skips merged targets ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "feature" > a.txt; git add a.txt
    git commit -m "Feature$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Simulate squash-merge into master
    git checkout master -q
    git merge --squash target-1 -q 2>/dev/null
    git commit --no-verify -m "merge target 1" -q
    git checkout source -q

    local output
    output=$(bash "$DISPATCH" apply 2>&1)
    assert_contains "$output" "merged" "apply reports merged target"

    teardown
}

test_merged_target_skipped_in_sync() {
    echo "=== test: sync skips merged targets ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "feature" > a.txt; git add a.txt
    git commit -m "Feature$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Simulate squash-merge into master
    git checkout master -q
    git merge --squash target-1 -q 2>/dev/null
    git commit --no-verify -m "merge target 1" -q

    # Add another commit to master so sync has work to do
    echo "base change" > base.txt; git add base.txt
    git commit --no-verify -m "base update" -q
    git checkout source -q

    local output
    output=$(bash "$DISPATCH" sync 2>&1)
    assert_contains "$output" "merged" "sync reports merged target skipped"

    teardown
}

test_apply_all_includes_merged() {
    echo "=== test: apply --all includes merged targets ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "feature" > a.txt; git add a.txt
    git commit -m "Feature$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Simulate squash-merge
    git checkout master -q
    git merge --squash target-1 -q 2>/dev/null
    git commit --no-verify -m "merge target 1" -q
    git checkout source -q

    # Add new commit to same target
    echo "feature v2" > a.txt; git add a.txt
    git commit -m "Feature v2$(printf '\n\nDispatch-Target-Id: 1')" -q

    local output
    output=$(bash "$DISPATCH" apply --all 2>&1)
    assert_not_contains "$output" "merged" "apply --all does not skip merged"

    teardown
}

test_sync_all_includes_merged() {
    echo "=== test: sync --all includes merged targets ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "feature" > a.txt; git add a.txt
    git commit -m "Feature$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Simulate squash-merge + extra base commit
    git checkout master -q
    git merge --squash target-1 -q 2>/dev/null
    git commit --no-verify -m "merge target 1" -q
    echo "base" > base.txt; git add base.txt
    git commit --no-verify -m "base update" -q
    git checkout source -q

    local output
    output=$(bash "$DISPATCH" sync --all 2>&1)
    assert_not_contains "$output" "skipped. Use --all" "sync --all does not skip merged"

    teardown
}

test_status_shows_merged() {
    echo "=== test: status shows merged indicator ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "feature" > a.txt; git add a.txt
    git commit -m "Feature$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Simulate squash-merge
    git checkout master -q
    git merge --squash target-1 -q 2>/dev/null
    git commit --no-verify -m "merge target 1" -q
    git checkout source -q

    local output
    output=$(bash "$DISPATCH" status 2>&1)
    assert_contains "$output" "merged" "status shows merged target"

    teardown
}

test_merged_target_resumes_after_revert() {
    echo "=== test: unmerged target resumes after revert on base ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "feature" > a.txt; git add a.txt
    git commit -m "Feature$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Simulate squash-merge
    git checkout master -q
    git merge --squash target-1 -q 2>/dev/null
    git commit --no-verify -m "merge target 1" -q

    # Revert it (disable hooks for master commit)
    git -c core.hooksPath=/tmp revert --no-edit HEAD
    git checkout source -q

    # Target is no longer merged - apply should not skip it
    local output
    output=$(bash "$DISPATCH" apply 2>&1)
    assert_not_contains "$output" "merged" "reverted target not reported as merged"

    teardown
}

# ---------- delete command ----------

test_delete_single_target() {
    echo "=== test: delete removes a single target ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "a" > a.txt; git add a.txt
    git commit -m "A$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "B$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    local output
    output=$(bash "$DISPATCH" delete 1 --yes 2>&1)
    assert_contains "$output" "Deleted target-1" "reports deletion"

    # Branch should be gone
    local exists
    exists=$(git rev-parse --verify refs/heads/target-1 2>&1 || true)
    assert_contains "$exists" "fatal" "target-1 branch deleted"

    # target-2 should still exist
    git rev-parse --verify refs/heads/target-2 >/dev/null 2>&1
    assert_eq "0" "$?" "target-2 still exists"

    teardown
}

test_delete_all_targets() {
    echo "=== test: delete all removes all targets ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "a" > a.txt; git add a.txt
    git commit -m "A$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "B$(printf '\n\nDispatch-Target-Id: 2')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    local output
    output=$(bash "$DISPATCH" delete all --yes 2>&1)
    assert_contains "$output" "2 target(s) deleted" "reports all deleted"

    # Both should be gone
    local e1 e2
    e1=$(git rev-parse --verify refs/heads/target-1 2>&1 || true)
    e2=$(git rev-parse --verify refs/heads/target-2 2>&1 || true)
    assert_contains "$e1" "fatal" "target-1 deleted"
    assert_contains "$e2" "fatal" "target-2 deleted"

    # Config should still be intact (unlike reset)
    local base
    base=$(git config branch.source.dispatchbase 2>/dev/null || echo "")
    assert_eq "master" "$base" "dispatch config preserved after delete"

    teardown
}

test_delete_dry_run() {
    echo "=== test: delete --dry-run makes no changes ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "a" > a.txt; git add a.txt
    git commit -m "A$(printf '\n\nDispatch-Target-Id: 1')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    local output
    output=$(bash "$DISPATCH" delete 1 --dry-run 2>&1)
    assert_contains "$output" "dry-run" "shows dry-run"

    # Branch should still exist
    git rev-parse --verify refs/heads/target-1 >/dev/null 2>&1
    assert_eq "0" "$?" "target-1 still exists after dry-run"

    teardown
}

test_delete_prune_orphaned() {
    echo "=== test: delete --prune removes orphaned targets ==="
    setup

    git checkout -b source -q
    bash "$DISPATCH" init --base master --target-pattern "target-{id}" >/dev/null 2>&1

    echo "a" > a.txt; git add a.txt
    git commit -m "A$(printf '\n\nDispatch-Target-Id: 1')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "B$(printf '\n\nDispatch-Target-Id: 2')" -q
    echo "c" > c.txt; git add c.txt
    git commit -m "C$(printf '\n\nDispatch-Target-Id: 3')" -q

    bash "$DISPATCH" apply >/dev/null 2>&1

    # Rebase to remove tid 3 (simulate dropping the commit via interactive rebase)
    # Instead: create a new source without tid 3
    git branch -D target-3 -q 2>/dev/null || true
    # Manually create orphan: target-3 exists but tid 3 gone from source
    # Use apply reset to rebuild, then remove the tid 3 commit
    # Simpler: just apply, then amend the last commit to change its tid
    git config --unset branch.target-3.dispatchsource 2>/dev/null || true

    # Re-create target-3 manually as a dispatch target
    git branch target-3 master -q
    git config "branch.target-3.dispatchsource" "source"

    # Now remove the tid-3 commit from source via rebase (drop last commit, add it back as tid 2)
    local last_hash
    last_hash=$(git log -1 --format="%H" source)
    git reset --hard HEAD~1 -q
    echo "c" > c.txt; git add c.txt
    git commit -m "C moved$(printf '\n\nDispatch-Target-Id: 2')" -q

    # target-3 exists but tid 3 no longer in source
    local output
    output=$(bash "$DISPATCH" delete --prune --yes 2>&1)
    assert_contains "$output" "Deleted target-3" "prune deletes orphaned target-3"

    # target-1 and target-2 should still exist
    git rev-parse --verify refs/heads/target-1 >/dev/null 2>&1
    assert_eq "0" "$?" "target-1 preserved by prune"
    git rev-parse --verify refs/heads/target-2 >/dev/null 2>&1
    assert_eq "0" "$?" "target-2 preserved by prune"

    teardown
}

test_merged_target_skipped_in_apply
test_merged_target_skipped_in_sync
test_apply_all_includes_merged
test_sync_all_includes_merged
test_status_shows_merged
test_merged_target_resumes_after_revert
test_delete_single_target
test_delete_all_targets
test_delete_dry_run
test_delete_prune_orphaned

echo ""
echo "======================="
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
