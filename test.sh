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
    git commit -m "Add enum$(printf '\n\nTarget-Id: 3')" -q

    echo "b" > api.txt; git add api.txt
    git commit -m "Create GET endpoint$(printf '\n\nTarget-Id: 4')" -q

    echo "c" > dto.txt; git add dto.txt
    git commit -m "Add DTOs$(printf '\n\nTarget-Id: 4')" -q

    echo "d" > validate.txt; git add validate.txt
    git commit -m "Implement validation$(printf '\n\nTarget-Id: 5')" -q

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

test_init_defaults() {
    echo "=== test: init defaults ==="
    setup

    git checkout -b source/feature master -q

    bash "$DISPATCH" init

    local base mode target_pattern
    base=$(git config dispatch.base)
    mode=$(git config dispatch.mode)
    target_pattern=$(git config dispatch.targetPattern)

    assert_eq "master" "$base" "default base is master"
    assert_eq "independent" "$mode" "default mode is independent"
    assert_eq "source/feature-task-{id}" "$target_pattern" "default target pattern uses source branch"

    teardown
}

test_init_stacked_mode() {
    echo "=== test: init stacked mode ==="
    setup

    git checkout -b source/feature master -q

    bash "$DISPATCH" init --mode stacked

    local mode
    mode=$(git config dispatch.mode)
    assert_eq "stacked" "$mode" "mode set to stacked"

    teardown
}

test_init_custom_pattern() {
    echo "=== test: init custom target pattern ==="
    setup

    git checkout -b source/feature master -q

    bash "$DISPATCH" init --target-pattern "custom/path-{id}-done"

    local target_pattern
    target_pattern=$(git config dispatch.targetPattern)
    assert_eq "custom/path-{id}-done" "$target_pattern" "custom target pattern set"

    teardown
}

test_init_reinit_warns() {
    echo "=== test: init reinit warns ==="
    setup

    git checkout -b source/feature master -q

    bash "$DISPATCH" init --base master

    local output
    output=$(echo "n" | bash "$DISPATCH" init --base master 2>&1) || true

    assert_contains "$output" "already configured" "warns about existing config"

    teardown
}

test_init_installs_hooks() {
    echo "=== test: init installs hooks ==="
    setup

    git checkout -b source/feature master -q

    bash "$DISPATCH" init

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

# ---------- hook tests ----------

test_hook_rejects_missing_trailer() {
    echo "=== test: hook rejects commit without Target-Id ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init >/dev/null 2>&1

    echo "x" > x.txt; git add x.txt
    if git commit -m "no trailer" 2>/dev/null; then
        echo -e "  ${RED}FAIL${NC} hook should reject commit without Target-Id"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} hook rejects commit without Target-Id"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_hook_allows_valid_trailer() {
    echo "=== test: hook allows commit with Target-Id ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init >/dev/null 2>&1

    echo "x" > x.txt; git add x.txt
    git commit -m "with trailer$(printf '\n\nTarget-Id: 1')" -q
    if [[ $? -eq 0 ]]; then
        echo -e "  ${GREEN}PASS${NC} hook allows commit with Target-Id"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_hook_rejects_non_numeric_target_id() {
    echo "=== test: hook rejects non-numeric Target-Id ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init >/dev/null 2>&1

    echo "x" > x.txt; git add x.txt
    if git commit -m "bad id$(printf '\n\nTarget-Id: task-3')" 2>/dev/null; then
        echo -e "  ${RED}FAIL${NC} hook should reject non-numeric Target-Id"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} hook rejects non-numeric Target-Id"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_hook_allows_decimal_target_id() {
    echo "=== test: hook allows decimal Target-Id ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init >/dev/null 2>&1

    echo "x" > x.txt; git add x.txt
    git commit -m "decimal$(printf '\n\nTarget-Id: 1.5')" -q
    if [[ $? -eq 0 ]]; then
        echo -e "  ${GREEN}PASS${NC} hook allows decimal Target-Id"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_hook_auto_carry_target_id() {
    echo "=== test: hook auto-carries Target-Id from previous commit ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init >/dev/null 2>&1

    echo "a" > a.txt; git add a.txt
    git commit -m "first$(printf '\n\nTarget-Id: 3')" -q

    echo "b" > b.txt; git add b.txt
    git commit -m "second" -q

    local carried
    carried=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" | tr -d '[:space:]')
    assert_eq "3" "$carried" "Target-Id auto-carried from previous commit"

    teardown
}

test_hook_auto_carry_no_override() {
    echo "=== test: hook does not override explicit Target-Id ==="
    setup

    git checkout -b source/feature master -q
    bash "$DISPATCH" init >/dev/null 2>&1

    echo "a" > a.txt; git add a.txt
    git commit -m "first$(printf '\n\nTarget-Id: 3')" -q

    echo "b" > b.txt; git add b.txt
    git commit -m "second" --trailer "Target-Id=4" -q

    local target_id
    target_id=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" | tr -d '[:space:]')
    assert_eq "4" "$target_id" "explicit Target-Id not overridden by auto-carry"

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
    git commit -m "Fix DTO validation$(printf '\n\nTarget-Id: 4')" -q

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
    git commit -m "Add A$(printf '\n\nTarget-Id: 1')" -q

    echo "c" > c.txt; git add c.txt
    git commit -m "Add C$(printf '\n\nTarget-Id: 3')" -q

    bash "$DISPATCH" init --base master --target-pattern "source/feature-{id}" >/dev/null 2>&1
    bash "$DISPATCH" apply >/dev/null

    assert_branch_exists "source/feature-1" "target-1 created"
    assert_branch_exists "source/feature-3" "target-3 created"

    # Add target 2 (mid-stack insert via numeric sort)
    echo "b" > b.txt; git add b.txt
    git commit -m "Add B$(printf '\n\nTarget-Id: 2')" -q

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
    git commit -m "Add enum$(printf '\n\nTarget-Id: 1')" -q

    echo "b" > api.txt; git add api.txt
    git commit -m "Create endpoint$(printf '\n\nTarget-Id: 2')" -q

    echo "c" > validate.txt; git add validate.txt
    git commit -m "Add validation$(printf '\n\nTarget-Id: 3')" -q

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
    git commit -m "Add file$(printf '\n\nTarget-Id: 1')" -q

    echo "b" > file.txt; git add file.txt
    git commit -m "Modify file$(printf '\n\nTarget-Id: 2')" -q

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

# ---------- cherry-pick tests ----------

test_cherry_pick_source_to_target() {
    echo "=== test: cherry-pick --from source --to <id> ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    # Add new commit for target 4
    echo "fix" > fix.txt; git add fix.txt
    git commit -m "Fix endpoint$(printf '\n\nTarget-Id: 4')" -q

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
    echo "=== test: cherry-pick --from <id> --to source adds Target-Id ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    # Commit on target without proper Target-Id
    git checkout source/feature-3 -q
    echo "fix" > fix.txt; git add fix.txt
    git commit --no-verify -m "Fix without trailer" -q
    git checkout source/feature -q

    bash "$DISPATCH" cherry-pick --from 3 --to source

    local source_trailer
    source_trailer=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" source/feature | tr -d '[:space:]')
    assert_eq "3" "$source_trailer" "Target-Id trailer added on cherry-pick to source"

    teardown
}

test_cherry_pick_dry_run() {
    echo "=== test: cherry-pick --dry-run ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    echo "fix" > fix.txt; git add fix.txt
    git commit -m "Fix$(printf '\n\nTarget-Id: 4')" -q

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

    # Target-only commit (Target-Id 3): add "hotfix" line.
    git checkout source/feature-3 -q
    printf "a\nhotfix\n" > file.txt; git add file.txt
    git commit --no-verify -m "Target hotfix" -q

    # Source independently contains the same hotfix already, plus extra change in same commit.
    # Patch-id differs, but cherry-picking target commit to source is a semantic no-op.
    git checkout source/feature -q
    printf "a\nhotfix\n" > file.txt
    echo "extra" > extra.txt
    git add file.txt extra.txt
    git commit -m "Broader source change$(printf '\n\nTarget-Id: 4')" -q

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
    echo "=== test: push --from all --dry-run ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    local output
    output=$(bash "$DISPATCH" push --from all --dry-run)

    assert_contains "$output" "source/feature-3" "push shows target-3"
    assert_contains "$output" "source/feature-4" "push shows target-4"
    assert_contains "$output" "source/feature-5" "push shows target-5"

    teardown
}

test_push_dry_run_single() {
    echo "=== test: push --from <id> --dry-run ==="
    setup
    create_source

    bash "$DISPATCH" apply >/dev/null

    local output
    output=$(bash "$DISPATCH" push --from 4 --dry-run)

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
    output=$(bash "$DISPATCH" push --from all --force --dry-run)

    assert_contains "$output" "--force-with-lease" "force uses --force-with-lease"

    teardown
}

test_push_source_dry_run() {
    echo "=== test: push --from source --dry-run ==="
    setup
    create_source

    local output
    output=$(bash "$DISPATCH" push --from source --dry-run)

    assert_contains "$output" "source/feature" "push shows source branch"

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
    git commit -m "Fix$(printf '\n\nTarget-Id: 4')" -q

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
    git commit -m "A$(printf '\n\nTarget-Id: 1')" -q

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
    echo "=== test: apply with decimal Target-Id ordering ==="
    setup

    git checkout -b source/feature master -q
    echo "b" > b.txt; git add b.txt
    git commit -m "Add B$(printf '\n\nTarget-Id: 2')" -q

    echo "a" > a.txt; git add a.txt
    git commit -m "Add A$(printf '\n\nTarget-Id: 1')" -q

    echo "mid" > mid.txt; git add mid.txt
    git commit -m "Add mid$(printf '\n\nTarget-Id: 1.5')" -q

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

# ---------- end-to-end lifecycle ----------

test_full_lifecycle() {
    echo "=== test: full lifecycle ==="
    setup

    # 1. Setup
    git checkout -b source/feature master -q
    bash "$DISPATCH" init --base master --target-pattern "source/feature-task-{id}" >/dev/null 2>&1

    # 2. Build
    echo "schema" > schema.sql; git add schema.sql
    git commit -m "Schema change$(printf '\n\nTarget-Id: 1')" -q

    echo "endpoint" > endpoint.ts; git add endpoint.ts
    git commit -m "Backend endpoint$(printf '\n\nTarget-Id: 2')" -q

    echo "component" > component.tsx; git add component.tsx
    git commit -m "Frontend component$(printf '\n\nTarget-Id: 3')" -q

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
    git commit -m "Fix endpoint$(printf '\n\nTarget-Id: 2')" -q

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

# ---------- run ----------

echo "git-dispatch test suite"
echo "======================="
echo ""

test_init_basic
test_init_defaults
test_init_stacked_mode
test_init_custom_pattern
test_init_reinit_warns
test_init_installs_hooks
test_hook_rejects_missing_trailer
test_hook_allows_valid_trailer
test_hook_rejects_non_numeric_target_id
test_hook_allows_decimal_target_id
test_hook_auto_carry_target_id
test_hook_auto_carry_no_override
test_apply_creates_targets
test_apply_dry_run
test_apply_incremental
test_apply_new_target_mid_stack
test_apply_idempotent
test_apply_stacked_mode
test_apply_conflict_aborts
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
test_status_shows_mode
test_status_in_sync
test_status_shows_pending
test_status_not_created
test_reset_cleans_up
test_help
test_install_chmod
test_apply_decimal_target_id
test_full_lifecycle

echo ""
echo "======================="
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
