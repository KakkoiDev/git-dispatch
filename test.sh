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

# Create a source branch with trailer-tagged commits
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
}

# ---------- init tests ----------

test_init_basic() {
    echo "=== test: init basic ==="
    setup

    git checkout -b source/feature master -q

    bash "$DISPATCH" init --base master --prefix "task-" --mode independent

    local base mode prefix
    base=$(git config dispatch.base)
    mode=$(git config dispatch.mode)
    prefix=$(git config dispatch.prefix)

    assert_eq "master" "$base" "dispatch.base set"
    assert_eq "independent" "$mode" "dispatch.mode set"
    assert_eq "task-" "$prefix" "dispatch.prefix set"

    teardown
}

test_init_defaults() {
    echo "=== test: init defaults ==="
    setup

    git checkout -b source/feature master -q

    bash "$DISPATCH" init

    local base mode prefix
    base=$(git config dispatch.base)
    mode=$(git config dispatch.mode)
    prefix=$(git config dispatch.prefix)

    assert_eq "master" "$base" "default base is master"
    assert_eq "independent" "$mode" "default mode is independent"
    assert_eq "task-" "$prefix" "default prefix is task-"

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

test_init_custom_prefix() {
    echo "=== test: init custom prefix ==="
    setup

    git checkout -b source/feature master -q

    bash "$DISPATCH" init --prefix "phase-"

    local prefix
    prefix=$(git config dispatch.prefix)
    assert_eq "phase-" "$prefix" "custom prefix set"

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

    # post-merge should NOT be installed
    if [[ -f "$hook_dir/post-merge" ]]; then
        echo -e "  ${RED}FAIL${NC} post-merge hook should not be installed"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} post-merge hook correctly absent"
        PASS=$((PASS + 1))
    fi

    teardown
}

# ---------- tests ----------

test_split() {
    echo "=== test: split ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat

    assert_branch_exists "feat/3" "task-3 branch created"
    assert_branch_exists "feat/4" "task-4 branch created"
    assert_branch_exists "feat/5" "task-5 branch created"

    # task-3: 1 commit
    local count3
    count3=$(git log --oneline master..feat/3 | wc -l | tr -d ' ')
    assert_eq "1" "$count3" "task-3 has 1 commit"

    # task-4: 1 (task-3) + 2 own = 3
    local count4
    count4=$(git log --oneline master..feat/4 | wc -l | tr -d ' ')
    assert_eq "3" "$count4" "task-4 has 3 commits (stacked)"

    # task-5: 3 (task-3+4) + 1 own = 4
    local count5
    count5=$(git log --oneline master..feat/5 | wc -l | tr -d ' ')
    assert_eq "4" "$count5" "task-5 has 4 commits (stacked)"

    # Stack config
    local tasks_master
    tasks_master=$(git config --get-all branch.master.dispatchtargets 2>/dev/null || true)
    assert_eq "feat/3" "$tasks_master" "master has task-3 in stack"

    local tasks_3
    tasks_3=$(git config --get-all branch.feat/3.dispatchtargets 2>/dev/null || true)
    assert_eq "feat/4" "$tasks_3" "task-3 has task-4 in stack"

    local tasks_4
    tasks_4=$(git config --get-all branch.feat/4.dispatchtargets 2>/dev/null || true)
    assert_eq "feat/5" "$tasks_4" "task-4 has task-5 in stack"

    # Source association
    local src3
    src3=$(git config branch.feat/3.dispatchsource 2>/dev/null || true)
    assert_eq "source/feature" "$src3" "task-3 linked to source"

    teardown
}

test_split_dry_run() {
    echo "=== test: split --dry-run ==="
    setup
    create_source

    local output
    output=$(bash "$DISPATCH" split source/feature --base master --name feat --dry-run)

    assert_contains "$output" "[dry-run]" "dry-run output shown"
    assert_contains "$output" "feat/3" "task-3 in dry-run output"
    assert_contains "$output" "feat/4" "task-4 in dry-run output"

    # Branches should NOT exist
    if git rev-parse --verify "feat/3" >/dev/null 2>&1; then
        echo -e "  ${RED}FAIL${NC} dry-run should not create branches"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} dry-run did not create branches"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_tree() {
    echo "=== test: tree ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    local tree
    tree=$(bash "$DISPATCH" tree master)

    assert_contains "$tree" "master" "tree shows master"
    assert_contains "$tree" "feat/3" "tree shows task-3"
    assert_contains "$tree" "feat/4" "tree shows task-4"
    assert_contains "$tree" "feat/5" "tree shows task-5"
    assert_contains "$tree" "└──" "tree has branch characters"

    teardown
}

test_sync_source_to_task() {
    echo "=== test: sync source → task ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Add a new commit to source for task-4
    git checkout source/feature -q
    echo "fix" > fix.txt; git add fix.txt
    git commit -m "Fix DTO validation$(printf '\n\nTarget-Id: 4')" -q

    local before
    before=$(git log --oneline master..feat/4 | wc -l | tr -d ' ')

    bash "$DISPATCH" sync source/feature feat/4 || true

    local after
    after=$(git log --oneline master..feat/4 | wc -l | tr -d ' ')

    assert_eq "$((before + 1))" "$after" "new source commit cherry-picked into task"

    # Verify the file landed
    if git show feat/4:fix.txt >/dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC} fix.txt exists in task-4"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} fix.txt missing from task-4"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_sync_task_to_source() {
    echo "=== test: sync task → source ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Add a commit directly on task-3
    git checkout feat/3 -q
    echo "hotfix" > hotfix.txt; git add hotfix.txt
    git commit -m "Hotfix alignment$(printf '\n\nTarget-Id: 3')" -q

    local before
    before=$(git log --oneline master..source/feature | wc -l | tr -d ' ')

    bash "$DISPATCH" sync source/feature feat/3 || true

    local after
    after=$(git log --oneline master..source/feature | wc -l | tr -d ' ')

    assert_eq "$((before + 1))" "$after" "task commit cherry-picked into source"

    # Verify the file landed
    if git show source/feature:hotfix.txt >/dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC} hotfix.txt exists in source"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} hotfix.txt missing from source"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_sync_worktree() {
    echo "=== test: sync with worktree ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Create worktree for task-4
    git worktree add ../wt-task4 feat/4 -q

    # Add commit to source for task-4
    git checkout source/feature -q
    echo "wt-fix" > wt-fix.txt; git add wt-fix.txt
    git commit -m "Worktree fix$(printf '\n\nTarget-Id: 4')" -q

    bash "$DISPATCH" sync source/feature feat/4 || true

    # Verify via worktree
    if [[ -f "../wt-task4/wt-fix.txt" ]]; then
        echo -e "  ${GREEN}PASS${NC} worktree-aware sync landed file"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} worktree-aware sync did not land file"
        FAIL=$((FAIL + 1))
    fi

    git worktree remove ../wt-task4 --force 2>/dev/null || true
    rm -rf "$TMPDIR/../wt-task4" 2>/dev/null || true
    teardown
}

test_hook() {
    echo "=== test: hook ==="
    setup

    bash "$DISPATCH" hook install

    # Commit without trailer should fail
    echo "x" > x.txt; git add x.txt
    if git commit -m "no trailer" 2>/dev/null; then
        echo -e "  ${RED}FAIL${NC} hook should reject commit without Target-Id"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} hook rejects commit without Target-Id"
        PASS=$((PASS + 1))
    fi

    # Commit with trailer should succeed
    git commit -m "with trailer$(printf '\n\nTarget-Id: 1')" -q
    if [[ $? -eq 0 ]]; then
        echo -e "  ${GREEN}PASS${NC} hook allows commit with Target-Id"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_hook_install_respects_hooks_path_relative() {
    echo "=== test: hook install respects core.hooksPath (relative) ==="
    setup

    git config core.hooksPath .husky

    bash "$DISPATCH" hook install

    local expected_dir
    expected_dir="$(git rev-parse --show-toplevel)/.husky"

    if [[ -f "$expected_dir/commit-msg" ]]; then
        echo -e "  ${GREEN}PASS${NC} hook installed to .husky/commit-msg"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} hook not found at $expected_dir/commit-msg"
        FAIL=$((FAIL + 1))
    fi

    # Should NOT be in .git/hooks
    local git_hooks
    git_hooks="$(git rev-parse --git-dir)/hooks"
    if [[ -f "$git_hooks/commit-msg" ]]; then
        echo -e "  ${RED}FAIL${NC} hook should not be in .git/hooks when core.hooksPath set"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} .git/hooks/commit-msg correctly absent"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_hook_install_respects_hooks_path_absolute() {
    echo "=== test: hook install respects core.hooksPath (absolute) ==="
    setup

    local abs_hook_dir
    abs_hook_dir="$TMPDIR/custom-hooks"
    git config core.hooksPath "$abs_hook_dir"

    bash "$DISPATCH" hook install

    if [[ -f "$abs_hook_dir/commit-msg" ]]; then
        echo -e "  ${GREEN}PASS${NC} hook installed to absolute custom path"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} hook not found at $abs_hook_dir/commit-msg"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_hook_install_default_without_hooks_path() {
    echo "=== test: hook install defaults to .git/hooks ==="
    setup

    # Ensure core.hooksPath is NOT set
    git config --unset core.hooksPath 2>/dev/null || true

    bash "$DISPATCH" hook install

    local git_hooks
    git_hooks="$(git rev-parse --git-dir)/hooks"

    if [[ -f "$git_hooks/commit-msg" ]]; then
        echo -e "  ${GREEN}PASS${NC} hook installed to .git/hooks (default)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} hook not found at $git_hooks/commit-msg"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_hook_auto_carry_target_id() {
    echo "=== test: hook auto-carries Target-Id from previous commit ==="
    setup

    bash "$DISPATCH" hook install

    # First commit with explicit Target-Id
    echo "a" > a.txt; git add a.txt
    git commit -m "first$(printf '\n\nTarget-Id: 3')" -q

    # Second commit without trailer - should auto-carry Target-Id=3
    echo "b" > b.txt; git add b.txt
    git commit -m "second" -q

    local carried
    carried=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" | tr -d '[:space:]')
    assert_eq "$carried" "3" "Target-Id auto-carried from previous commit"

    teardown
}

test_hook_auto_carry_no_override() {
    echo "=== test: hook does not override explicit Target-Id ==="
    setup

    bash "$DISPATCH" hook install

    # First commit with Target-Id=3
    echo "a" > a.txt; git add a.txt
    git commit -m "first$(printf '\n\nTarget-Id: 3')" -q

    # Second commit with explicit Target-Id=4 - should keep 4, not carry 3
    echo "b" > b.txt; git add b.txt
    git commit -m "second" --trailer "Target-Id=4" -q

    local target_id
    target_id=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" | tr -d '[:space:]')
    assert_eq "$target_id" "4" "explicit Target-Id not overridden by auto-carry"

    teardown
}

test_hook_rejects_non_numeric_target_id() {
    echo "=== test: hook rejects non-numeric Target-Id ==="
    setup

    bash "$DISPATCH" hook install

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

    bash "$DISPATCH" hook install

    echo "x" > x.txt; git add x.txt
    git commit -m "decimal id$(printf '\n\nTarget-Id: 1.5')" -q
    if [[ $? -eq 0 ]]; then
        echo -e "  ${GREEN}PASS${NC} hook allows decimal Target-Id"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} hook should allow decimal Target-Id"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_help() {
    echo "=== test: help ==="
    local output
    output=$(bash "$DISPATCH" help)
    assert_contains "$output" "WORKFLOW" "help shows workflow"
    assert_contains "$output" "COMMANDS" "help shows commands"
    assert_contains "$output" "TRAILERS" "help shows trailers"
}

test_sync_auto_detect_from_source() {
    echo "=== test: sync auto-detect from source branch ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Add a new commit to source for task-3
    git checkout source/feature -q
    echo "auto" > auto.txt; git add auto.txt
    git commit -m "Auto detect fix$(printf '\n\nTarget-Id: 3')" -q

    local before
    before=$(git log --oneline master..feat/3 | wc -l | tr -d ' ')

    # Sync WITHOUT specifying source -- should auto-detect from current branch
    bash "$DISPATCH" sync || true

    local after
    after=$(git log --oneline master..feat/3 | wc -l | tr -d ' ')

    assert_eq "$((before + 1))" "$after" "auto-detect from source synced commit"

    teardown
}

test_sync_auto_detect_from_task() {
    echo "=== test: sync auto-detect from task branch ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Add a commit to source for task-4
    git checkout source/feature -q
    echo "task-auto" > task-auto.txt; git add task-auto.txt
    git commit -m "Task auto fix$(printf '\n\nTarget-Id: 4')" -q

    # Switch to task branch, sync without args
    git checkout feat/4 -q

    local before
    before=$(git log --oneline master..feat/4 | wc -l | tr -d ' ')

    bash "$DISPATCH" sync || true

    local after
    after=$(git log --oneline master..feat/4 | wc -l | tr -d ' ')

    assert_eq "$((before + 1))" "$after" "auto-detect from task synced commit"

    teardown
}

test_sync_adds_trailer() {
    echo "=== test: sync task->source adds Target-Id trailer ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Commit on task branch WITHOUT Target-Id trailer
    git checkout feat/3 -q
    echo "no-trailer" > notrailer.txt; git add notrailer.txt
    git commit --no-verify -m "Fix without trailer" -q

    bash "$DISPATCH" sync source/feature feat/3 || true

    # Check trailer was added on task branch commit (amended in-place)
    local task_trailer
    task_trailer=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" feat/3 | tr -d '[:space:]')
    assert_eq "3" "$task_trailer" "Target-Id trailer added on task branch commit"

    # Check the cherry-picked commit on source also has Target-Id trailer
    local source_trailer
    source_trailer=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" source/feature | tr -d '[:space:]')
    assert_eq "3" "$source_trailer" "Target-Id trailer present on source after sync"

    teardown
}

test_status() {
    echo "=== test: status ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Add a commit to source for task-4
    git checkout source/feature -q
    echo "status-fix" > status-fix.txt; git add status-fix.txt
    git commit -m "Status fix$(printf '\n\nTarget-Id: 4')" -q

    # Add a commit directly on task-3
    git checkout feat/3 -q
    echo "task-fix" > task-fix.txt; git add task-fix.txt
    git commit -m "Task fix$(printf '\n\nTarget-Id: 3')" -q

    local output
    output=$(bash "$DISPATCH" status source/feature)

    assert_contains "$output" "source/feature" "status shows source"
    assert_contains "$output" "feat/3" "status shows task-3"
    assert_contains "$output" "feat/4" "status shows task-4"
    assert_contains "$output" "feat/5" "status shows task-5"
    # task-4 should have 1 pending source -> task
    assert_contains "$output" "1 pending" "status shows pending count"
    # task-5 should show in sync
    assert_contains "$output" "in sync" "status shows in sync"

    teardown
}

test_status_auto_detect() {
    echo "=== test: status auto-detect ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Run status from source branch without explicit arg
    git checkout source/feature -q
    local output
    output=$(bash "$DISPATCH" status)

    assert_contains "$output" "source/feature" "auto-detect status shows source"
    assert_contains "$output" "feat/3" "auto-detect status shows tasks"

    teardown
}

test_pr_dry_run() {
    echo "=== test: pr --dry-run ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" pr --dry-run source/feature)

    assert_contains "$output" "gh pr create --base master --head feat/3" "PR for task-3 with correct base"
    assert_contains "$output" "gh pr create --base feat/3 --head feat/4" "PR for task-4 with correct base"
    assert_contains "$output" "gh pr create --base feat/4 --head feat/5" "PR for task-5 with correct base"

    # Verify titles from first commit subjects
    assert_contains "$output" "Add enum" "PR title from first commit of task-3"
    assert_contains "$output" "Create GET endpoint" "PR title from first commit of task-4"
    assert_contains "$output" "Implement validation" "PR title from first commit of task-5"

    teardown
}

test_pr_dry_run_push() {
    echo "=== test: pr --dry-run --push ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" pr --dry-run --push source/feature)

    assert_contains "$output" "git push -u origin feat/3" "push command for task-3"
    assert_contains "$output" "git push -u origin feat/4" "push command for task-4"
    assert_contains "$output" "git push -u origin feat/5" "push command for task-5"

    teardown
}

test_reset() {
    echo "=== test: reset ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    bash "$DISPATCH" reset --force source/feature

    # Verify config cleaned
    local src3
    src3=$(git config branch.feat/3.dispatchsource 2>/dev/null || true)
    assert_eq "" "$src3" "task-3 dispatchsource removed"

    local src4
    src4=$(git config branch.feat/4.dispatchsource 2>/dev/null || true)
    assert_eq "" "$src4" "task-4 dispatchsource removed"

    local tasks_master
    tasks_master=$(git config --get-all branch.master.dispatchtargets 2>/dev/null || true)
    assert_eq "" "$tasks_master" "master dispatchtargets removed"

    local tasks_3
    tasks_3=$(git config --get-all branch.feat/3.dispatchtargets 2>/dev/null || true)
    assert_eq "" "$tasks_3" "task-3 dispatchtargets removed"

    local tasks_4
    tasks_4=$(git config --get-all branch.feat/4.dispatchtargets 2>/dev/null || true)
    assert_eq "" "$tasks_4" "task-4 dispatchtargets removed"

    # Branches should still exist
    assert_branch_exists "feat/3" "task-3 still exists after reset"
    assert_branch_exists "feat/4" "task-4 still exists after reset"
    assert_branch_exists "feat/5" "task-5 still exists after reset"

    teardown
}

test_reset_branches() {
    echo "=== test: reset --branches ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    git checkout master -q
    bash "$DISPATCH" reset --force --branches source/feature

    # Branches should be deleted
    if git rev-parse --verify "feat/3" >/dev/null 2>&1; then
        echo -e "  ${RED}FAIL${NC} task-3 should be deleted"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} task-3 branch deleted"
        PASS=$((PASS + 1))
    fi

    if git rev-parse --verify "feat/4" >/dev/null 2>&1; then
        echo -e "  ${RED}FAIL${NC} task-4 should be deleted"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} task-4 branch deleted"
        PASS=$((PASS + 1))
    fi

    if git rev-parse --verify "feat/5" >/dev/null 2>&1; then
        echo -e "  ${RED}FAIL${NC} task-5 should be deleted"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} task-5 branch deleted"
        PASS=$((PASS + 1))
    fi

    # Config should also be clean
    local src3
    src3=$(git config branch.feat/3.dispatchsource 2>/dev/null || true)
    assert_eq "" "$src3" "config cleaned after reset --branches"

    teardown
}

test_sync_cherry_pick_conflict() {
    echo "=== test: sync cherry-pick conflict ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Create conflicting commit on source for task-3 (modifies file.txt which task-3 created)
    git checkout source/feature -q
    echo "conflict" > file.txt; git add file.txt
    git commit -m "Conflict change$(printf '\n\nTarget-Id: 3')" -q

    # Create conflicting commit on task-3 (different content in same file)
    git checkout feat/3 -q
    echo "different" > file.txt; git add file.txt
    git commit -m "Conflicting fix$(printf '\n\nTarget-Id: 3')" -q

    # Sync should fail with error message
    local output
    if output=$(bash "$DISPATCH" sync source/feature feat/3 2>&1); then
        echo -e "  ${RED}FAIL${NC} sync should fail on cherry-pick conflict"
        FAIL=$((FAIL + 1))
    else
        assert_contains "$output" "Cherry-pick into" "error mentions cherry-pick failure"
    fi

    # Branch should be clean (cherry-pick aborted)
    git checkout feat/3 -q 2>/dev/null || true
    local status
    status=$(git status --porcelain)
    assert_eq "" "$status" "branch left clean after failed cherry-pick"

    teardown
}

test_split_no_commits() {
    echo "=== test: split with no commits ==="
    setup

    # Create a branch with no commits beyond master
    git checkout -b source/empty master -q

    local output
    if output=$(bash "$DISPATCH" split source/empty --base master --name feat 2>&1); then
        echo -e "  ${RED}FAIL${NC} split should fail with no commits"
        FAIL=$((FAIL + 1))
    else
        assert_contains "$output" "No commits found" "error mentions no commits"
    fi

    teardown
}

test_split_already_exists() {
    echo "=== test: split skips existing branches ==="
    setup
    create_source

    # Pre-create a branch that split would create
    git branch feat/3 master

    local output
    output=$(bash "$DISPATCH" split source/feature --base master --name feat 2>&1)

    assert_contains "$output" "Skipping feat/3" "skips pre-existing branch"
    assert_branch_exists "feat/4" "task-4 still created"
    assert_branch_exists "feat/5" "task-5 still created"

    teardown
}

test_resolve_source_error_message() {
    echo "=== test: resolve_source error includes branch name ==="
    setup

    # Create a branch that's not a source or task
    git checkout -b random/branch master -q

    local output
    if output=$(bash "$DISPATCH" sync 2>&1); then
        echo -e "  ${RED}FAIL${NC} sync should fail on non-dispatch branch"
        FAIL=$((FAIL + 1))
    else
        assert_contains "$output" "random/branch" "error includes current branch name"
    fi

    teardown
}

test_install_chmod() {
    echo "=== test: install.sh makes script executable ==="
    local install_dir
    install_dir=$(mktemp -d)
    cp "$SCRIPT_DIR/git-dispatch.sh" "$install_dir/"
    cp "$SCRIPT_DIR/install.sh" "$install_dir/"

    # Remove execute permission
    chmod -x "$install_dir/git-dispatch.sh"

    # Run install with isolated HOME to avoid polluting global gitconfig
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

test_pr_single_branch() {
    echo "=== test: pr --branch targets single branch ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" pr --dry-run --branch feat/4 source/feature)

    assert_contains "$output" "gh pr create --base feat/3 --head feat/4" "PR for task-4 with correct base"

    # Should NOT contain task-3 or task-5 PR creation
    if [[ "$output" == *"--head feat/3"* ]]; then
        echo -e "  ${RED}FAIL${NC} should not create PR for task-3"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} no PR for task-3"
        PASS=$((PASS + 1))
    fi

    if [[ "$output" == *"--head feat/5"* ]]; then
        echo -e "  ${RED}FAIL${NC} should not create PR for task-5"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} no PR for task-5"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_pr_custom_title_body() {
    echo "=== test: pr --title and --body in dry-run ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" pr --dry-run --branch feat/3 --title "Custom PR Title" --body "Custom body text" source/feature)

    assert_contains "$output" "Custom PR Title" "custom title appears in dry-run"
    assert_contains "$output" "Custom body text" "custom body appears in dry-run"

    teardown
}

test_pr_branch_not_found() {
    echo "=== test: pr --branch nonexistent errors ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    local output
    if output=$(bash "$DISPATCH" pr --dry-run --branch nonexistent source/feature 2>&1); then
        echo -e "  ${RED}FAIL${NC} should fail for nonexistent branch"
        FAIL=$((FAIL + 1))
    else
        assert_contains "$output" "not found in dispatch stack" "error mentions branch not found"
    fi

    teardown
}

test_split_decimal_target_id() {
    echo "=== test: split with decimal Target-Id ==="
    setup

    git checkout -b source/ordered master -q
    echo "b" > b.txt; git add b.txt
    git commit -m "Add B$(printf '\n\nTarget-Id: 2')" -q

    echo "a" > a.txt; git add a.txt
    git commit -m "Add A$(printf '\n\nTarget-Id: 1')" -q

    bash "$DISPATCH" split source/ordered --base master --name feat

    assert_branch_exists "feat/1" "feat/1 branch created"
    assert_branch_exists "feat/2" "feat/2 branch created"

    local tasks_master
    tasks_master=$(git config --get-all branch.master.dispatchtargets 2>/dev/null || true)
    assert_eq "feat/1" "$tasks_master" "master -> feat/1 (numeric sort, 1 first)"

    local tasks_1
    tasks_1=$(git config --get-all branch.feat/1.dispatchtargets 2>/dev/null || true)
    assert_eq "feat/2" "$tasks_1" "feat/1 -> feat/2 (numeric sort, 2 second)"

    teardown
}

test_split_no_task_order_backward_compat() {
    echo "=== test: split without Task-Order (backward compat) ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat

    local tasks_master
    tasks_master=$(git config --get-all branch.master.dispatchtargets 2>/dev/null || true)
    assert_eq "feat/3" "$tasks_master" "master -> task-3 (commit order preserved)"

    local tasks_3
    tasks_3=$(git config --get-all branch.feat/3.dispatchtargets 2>/dev/null || true)
    assert_eq "feat/4" "$tasks_3" "task-3 -> task-4 (commit order preserved)"

    local tasks_4
    tasks_4=$(git config --get-all branch.feat/4.dispatchtargets 2>/dev/null || true)
    assert_eq "feat/5" "$tasks_4" "task-4 -> task-5 (commit order preserved)"

    teardown
}

test_status_stack_order() {
    echo "=== test: status shows branches in stack order ==="
    setup

    # Create source with target IDs that sort differently alphabetically vs numerically
    # Alpha order: 10, 20, 3 - Stack order: 3, 10, 20
    git checkout -b source/order master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "First$(printf '\n\nTarget-Id: 3')" -q

    echo "b" > b.txt; git add b.txt
    git commit -m "Second$(printf '\n\nTarget-Id: 10')" -q

    echo "c" > c.txt; git add c.txt
    git commit -m "Third$(printf '\n\nTarget-Id: 20')" -q

    bash "$DISPATCH" split source/order --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" status source/order | sed $'s/\033\\[[0-9;]*m//g')

    # Extract branch names in order of appearance
    local order
    order=$(echo "$output" | grep 'feat/' | awk '{print $1}' | tr '\n' ' ')

    assert_eq "feat/3 feat/10 feat/20 " "$order" "status lists branches in stack order, not alphabetical"

    teardown
}

test_status_no_false_pending() {
    echo "=== test: status shows in sync after fresh split (no false pending from base) ==="
    setup

    # Advance master so base diverges from source fork point
    echo "base1" > base1.txt; git add base1.txt
    git commit -m "Base advance 1" -q
    echo "base2" > base2.txt; git add base2.txt
    git commit -m "Base advance 2" -q

    git checkout -b source/fresh master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "First$(printf '\n\nTarget-Id: 3')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "Second$(printf '\n\nTarget-Id: 4')" -q

    # Advance master again after source fork
    git checkout master -q
    echo "base3" > base3.txt; git add base3.txt
    git commit -m "Base advance 3" -q

    # Split - task branches are on current master, ahead of source fork point
    bash "$DISPATCH" split source/fresh --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" status source/fresh | sed $'s/\033\\[[0-9;]*m//g')

    # After a fresh split, all tasks should be in sync - no false pending
    assert_not_contains "$output" "pending" "no false pending after fresh split"
    assert_contains "$output" "in sync" "shows in sync after fresh split"

    teardown
}

test_sync_stack_order() {
    echo "=== test: sync processes branches in stack order ==="
    setup

    git checkout -b source/order master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "First$(printf '\n\nTarget-Id: 3')" -q

    echo "b" > b.txt; git add b.txt
    git commit -m "Second$(printf '\n\nTarget-Id: 10')" -q

    echo "c" > c.txt; git add c.txt
    git commit -m "Third$(printf '\n\nTarget-Id: 20')" -q

    bash "$DISPATCH" split source/order --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" sync source/order 2>&1)

    # Extract "Syncing: <branch>" lines in order
    local order
    order=$(echo "$output" | grep 'Syncing:' | awk '{print $2}' | tr '\n' ' ')

    assert_eq "feat/3 feat/10 feat/20 " "$order" "sync processes branches in stack order"

    teardown
}

test_pr_stack_order() {
    echo "=== test: pr creates PRs in stack order ==="
    setup

    git checkout -b source/order master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "First$(printf '\n\nTarget-Id: 3')" -q

    echo "b" > b.txt; git add b.txt
    git commit -m "Second$(printf '\n\nTarget-Id: 10')" -q

    echo "c" > c.txt; git add c.txt
    git commit -m "Third$(printf '\n\nTarget-Id: 20')" -q

    bash "$DISPATCH" split source/order --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" pr --dry-run source/order)

    # Extract --head values in order
    local order
    order=$(echo "$output" | grep '\-\-head' | sed 's/.*--head //' | awk '{print $1}' | tr -d '"' | tr '\n' ' ')

    assert_eq "feat/3 feat/10 feat/20 " "$order" "pr creates PRs in stack order"

    teardown
}

test_push_dry_run() {
    echo "=== test: push --dry-run ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" push --dry-run source/feature)

    assert_contains "$output" "git push -u origin feat/3" "push dry-run shows task-3"
    assert_contains "$output" "git push -u origin feat/4" "push dry-run shows task-4"
    assert_contains "$output" "git push -u origin feat/5" "push dry-run shows task-5"

    teardown
}

test_push_force_dry_run() {
    echo "=== test: push --force --dry-run ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" push --force --dry-run source/feature)

    assert_contains "$output" "--force-with-lease" "force flag uses --force-with-lease"
    assert_contains "$output" "git push -u origin --force-with-lease feat/3" "force push dry-run shows task-3"

    teardown
}

test_push_branch_filter() {
    echo "=== test: push --dry-run --branch targets single branch ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" push --dry-run --branch feat/4 source/feature)

    assert_contains "$output" "git push -u origin feat/4" "push shows target branch"
    assert_not_contains "$output" "feat/3" "push excludes task-3"
    assert_not_contains "$output" "feat/5" "push excludes task-5"

    teardown
}

test_resolve_basic() {
    echo "=== test: resolve creates resolution commit + re-merge ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Create add/add conflict on file.txt (feat/3 has it, add different version to master)
    git checkout master -q
    echo "master-version" > file.txt; git add file.txt
    git commit -m "Master adds file.txt" -q

    # Merge and resolve conflict
    git checkout feat/3 -q
    git merge master -q 2>/dev/null || {
        echo "resolved-content" > file.txt
        git add file.txt
        git commit --no-edit -q
    }

    # Verify HEAD is merge before resolve
    local parent_count
    parent_count=$(git cat-file -p HEAD | grep -c '^parent ')
    assert_eq "2" "$parent_count" "HEAD is merge before resolve"

    bash "$DISPATCH" resolve

    # Verify HEAD is merge commit (re-merge)
    parent_count=$(git cat-file -p HEAD | grep -c '^parent ')
    assert_eq "2" "$parent_count" "HEAD is merge after resolve (re-merge)"

    # Verify HEAD~1 is the resolution commit with Target-Id
    local tid
    tid=$(git log -1 --skip=1 --format="%(trailers:key=Target-Id,valueonly)" | tr -d '[:space:]')
    assert_eq "3" "$tid" "Target-Id trailer on resolution commit"

    # Verify resolution commit is regular (1 parent)
    local res_parents
    res_parents=$(git cat-file -p HEAD~1 | grep -c '^parent ')
    assert_eq "1" "$res_parents" "resolution commit is regular commit"

    teardown
}

test_resolve_preserves_content() {
    echo "=== test: resolve preserves conflict resolution content ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    git checkout master -q
    echo "master-version" > file.txt; git add file.txt
    git commit -m "Master adds file.txt" -q

    git checkout feat/3 -q
    git merge master -q 2>/dev/null || {
        echo "carefully-resolved" > file.txt
        git add file.txt
        git commit --no-edit -q
    }

    bash "$DISPATCH" resolve

    local content
    content=$(cat file.txt)
    assert_eq "carefully-resolved" "$content" "resolution content preserved in working tree"

    # Verify via git show on HEAD (re-merge)
    local git_content
    git_content=$(git show HEAD:file.txt)
    assert_eq "carefully-resolved" "$git_content" "resolution content preserved in merge commit"

    # Verify HEAD is a merge commit
    local parent_count
    parent_count=$(git cat-file -p HEAD | grep -c '^parent ')
    assert_eq "2" "$parent_count" "HEAD is merge after resolve"

    teardown
}

test_resolve_no_task_changes() {
    echo "=== test: resolve keeps clean merge as-is (no task file changes) ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Advance master with unrelated file
    git checkout master -q
    echo "unrelated" > unrelated.txt; git add unrelated.txt
    git commit -m "Unrelated change" -q

    # Clean merge into feat/3
    git checkout feat/3 -q
    git merge master --no-edit -q

    local merge_head
    merge_head=$(git rev-parse HEAD)

    bash "$DISPATCH" resolve

    # HEAD should be unchanged (clean merge left as-is)
    local post_resolve_head
    post_resolve_head=$(git rev-parse HEAD)
    assert_eq "$merge_head" "$post_resolve_head" "HEAD unchanged (clean merge kept)"

    # Verify still a merge commit
    local parent_count
    parent_count=$(git cat-file -p HEAD | grep -c '^parent ')
    assert_eq "2" "$parent_count" "merge commit still present"

    teardown
}

test_resolve_not_merge() {
    echo "=== test: resolve errors on non-merge HEAD ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    git checkout feat/3 -q

    local output
    if output=$(bash "$DISPATCH" resolve 2>&1); then
        echo -e "  ${RED}FAIL${NC} resolve should fail on non-merge HEAD"
        FAIL=$((FAIL + 1))
    else
        assert_contains "$output" "not a merge commit" "error mentions not a merge commit"
    fi

    teardown
}

test_resolve_not_task_branch() {
    echo "=== test: resolve errors on non-dispatch branch ==="
    setup

    git checkout -b random/branch master -q
    echo "x" > x.txt; git add x.txt
    git commit -m "stuff" -q

    local output
    if output=$(bash "$DISPATCH" resolve 2>&1); then
        echo -e "  ${RED}FAIL${NC} resolve should fail on non-dispatch branch"
        FAIL=$((FAIL + 1))
    else
        assert_contains "$output" "Not a dispatch task branch" "error mentions not a dispatch branch"
    fi

    teardown
}

test_status_merge_warning() {
    echo "=== test: status shows merge warning ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Create merge on feat/3
    git checkout master -q
    echo "unrelated" > unrelated.txt; git add unrelated.txt
    git commit -m "Unrelated" -q

    git checkout feat/3 -q
    git merge master --no-edit -q

    local output
    output=$(bash "$DISPATCH" status source/feature 2>&1)

    assert_contains "$output" "merge commit" "status shows merge info"
    assert_contains "$output" "no action needed" "clean merge shows no action needed"

    teardown
}

test_resplit_recovers_metadata() {
    echo "=== test: re-split recovers --base and --name from metadata ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Re-split without --base or --name
    local output
    output=$(bash "$DISPATCH" split source/feature 2>&1)

    assert_contains "$output" "Skipping feat/3" "re-split skips existing task-3"
    assert_contains "$output" "Skipping feat/4" "re-split skips existing task-4"
    assert_contains "$output" "Skipping feat/5" "re-split skips existing task-5"
    local clean_output
    clean_output=$(echo "$output" | sed $'s/\033\\[[0-9;]*m//g')
    assert_contains "$clean_output" "Base:   master" "recovered base from metadata"

    teardown
}

test_resplit_guards_wrong_prefix() {
    echo "=== test: re-split rejects mismatched --name ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    local output
    if output=$(bash "$DISPATCH" split source/feature --name wrong/prefix 2>&1); then
        echo -e "  ${RED}FAIL${NC} re-split should reject wrong prefix"
        FAIL=$((FAIL + 1))
    else
        assert_contains "$output" "Prefix mismatch" "error mentions prefix mismatch"
    fi

    teardown
}

test_resplit_guards_wrong_base() {
    echo "=== test: re-split rejects mismatched --base ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Create a decoy base
    git branch wrong-base master

    local output
    if output=$(bash "$DISPATCH" split source/feature --base wrong-base 2>&1); then
        echo -e "  ${RED}FAIL${NC} re-split should reject wrong base"
        FAIL=$((FAIL + 1))
    else
        assert_contains "$output" "Base mismatch" "error mentions base mismatch"
    fi

    teardown
}

test_resplit_idempotent() {
    echo "=== test: re-split is idempotent ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Record state before
    local tree_before
    tree_before=$(bash "$DISPATCH" tree master)
    local tip3_before tip4_before tip5_before
    tip3_before=$(git rev-parse feat/3)
    tip4_before=$(git rev-parse feat/4)
    tip5_before=$(git rev-parse feat/5)

    # Re-split
    bash "$DISPATCH" split source/feature >/dev/null

    # State should be identical
    local tree_after
    tree_after=$(bash "$DISPATCH" tree master)
    assert_eq "$tree_before" "$tree_after" "tree unchanged after idempotent re-split"

    local tip3_after tip4_after tip5_after
    tip3_after=$(git rev-parse feat/3)
    tip4_after=$(git rev-parse feat/4)
    tip5_after=$(git rev-parse feat/5)
    assert_eq "$tip3_before" "$tip3_after" "task-3 tip unchanged"
    assert_eq "$tip4_before" "$tip4_after" "task-4 tip unchanged"
    assert_eq "$tip5_before" "$tip5_after" "task-5 tip unchanged"

    teardown
}

test_resplit_new_task_mid_stack() {
    echo "=== test: re-split inserts new task mid-stack ==="
    setup

    git checkout -b source/midstack master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add A$(printf '\n\nTarget-Id: 1')" -q

    echo "c" > c.txt; git add c.txt
    git commit -m "Add C$(printf '\n\nTarget-Id: 3')" -q

    # First split: 1 -> 3
    bash "$DISPATCH" split source/midstack --base master --name feat >/dev/null

    local tree_before
    tree_before=$(bash "$DISPATCH" tree master)
    assert_contains "$tree_before" "feat/1" "feat/1 in initial tree"
    assert_contains "$tree_before" "feat/3" "feat/3 in initial tree"

    # Add Target-Id: 2 (should go between 1 and 3 by numeric sort)
    git checkout source/midstack -q
    echo "b" > b.txt; git add b.txt
    git commit -m "Add B$(printf '\n\nTarget-Id: 2')" -q

    # Re-split
    bash "$DISPATCH" split source/midstack >/dev/null

    # Verify stack order: master -> 1 -> 2 -> 3
    local tasks_master
    tasks_master=$(git config --get-all branch.master.dispatchtargets 2>/dev/null || true)
    assert_eq "feat/1" "$tasks_master" "master -> feat/1"

    local tasks_1
    tasks_1=$(git config --get-all branch.feat/1.dispatchtargets 2>/dev/null || true)
    assert_eq "feat/2" "$tasks_1" "feat/1 -> feat/2 (mid-stack insert)"

    local tasks_2
    tasks_2=$(git config --get-all branch.feat/2.dispatchtargets 2>/dev/null || true)
    assert_eq "feat/3" "$tasks_2" "feat/2 -> feat/3 (re-linked)"

    # Verify feat/2 has the commit
    if git show feat/2:b.txt >/dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC} b.txt exists in feat/2"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} b.txt missing from feat/2"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_resplit_new_task_at_end() {
    echo "=== test: re-split appends new task at end of stack ==="
    setup

    git checkout -b source/append master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add A$(printf '\n\nTarget-Id: 1')" -q

    echo "b" > b.txt; git add b.txt
    git commit -m "Add B$(printf '\n\nTarget-Id: 2')" -q

    bash "$DISPATCH" split source/append --base master --name feat >/dev/null

    # Add task at end
    git checkout source/append -q
    echo "c" > c.txt; git add c.txt
    git commit -m "Add C$(printf '\n\nTarget-Id: 3')" -q

    bash "$DISPATCH" split source/append >/dev/null

    local tasks_2
    tasks_2=$(git config --get-all branch.feat/2.dispatchtargets 2>/dev/null || true)
    assert_eq "feat/3" "$tasks_2" "feat/2 -> feat/3 (appended at end)"

    assert_branch_exists "feat/3" "feat/3 branch created"

    teardown
}

test_split_cherry_pick_conflict_graceful() {
    echo "=== test: split handles cherry-pick conflict gracefully ==="
    setup

    git checkout -b source/conflict master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add file$(printf '\n\nTarget-Id: 1')" -q

    echo "b" > file.txt; git add file.txt
    git commit -m "Modify file$(printf '\n\nTarget-Id: 2')" -q

    bash "$DISPATCH" split source/conflict --base master --name feat >/dev/null

    # Merge master into feat/1 to create resolve scenario
    git checkout master -q
    echo "master-change" > file.txt; git add file.txt
    git commit -m "Master changes file" -q

    git checkout feat/1 -q
    git merge master -q 2>/dev/null || {
        echo "resolved" > file.txt
        git add file.txt
        git commit --no-edit -q
    }
    bash "$DISPATCH" resolve

    # Delete feat/2 to force re-creation
    git checkout master -q
    git branch -D feat/2
    git config --remove-section branch.feat/2 2>/dev/null || true
    git config --unset "branch.feat/1.dispatchtargets" 2>/dev/null || true

    # Re-split should handle conflict gracefully
    local output
    output=$(bash "$DISPATCH" split source/conflict 2>&1)

    assert_contains "$output" "cherry-pick conflicted" "warns about cherry-pick conflict"
    assert_branch_exists "feat/2" "feat/2 branch still created (metadata)"

    # Branch should have dispatchsource set
    local src
    src=$(git config branch.feat/2.dispatchsource 2>/dev/null || true)
    assert_eq "source/conflict" "$src" "feat/2 linked to source despite conflict"

    teardown
}

test_resplit_after_reset_pr_feedback() {
    echo "=== test: re-split after reset picks up fix commit (PR feedback) ==="
    setup

    git checkout -b source/prfix master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add A$(printf '\n\nTarget-Id: 1')" -q

    echo "b" > b.txt; git add b.txt
    git commit -m "Add B$(printf '\n\nTarget-Id: 2')" -q

    # Initial split
    bash "$DISPATCH" split source/prfix --base master --name feat >/dev/null

    assert_branch_exists "feat/1" "feat/1 created"
    assert_branch_exists "feat/2" "feat/2 created"

    # Reset all dispatch metadata + branches (simulates cleanup)
    bash "$DISPATCH" reset source/prfix --branches --force >/dev/null 2>&1

    # Verify branches are gone
    assert_branch_not_exists "feat/1" "feat/1 removed after reset"
    assert_branch_not_exists "feat/2" "feat/2 removed after reset"

    # Reviewer left a comment on feat/1 -- add fix commit on source
    git checkout source/prfix -q
    echo "a-fix" >> a.txt; git add a.txt
    git commit -m "fix: address PR comment on A$(printf '\n\nTarget-Id: 1')" -q

    # Re-split recreates all branches including the fix
    bash "$DISPATCH" split source/prfix --base master --name feat >/dev/null

    assert_branch_exists "feat/1" "feat/1 recreated after re-split"
    assert_branch_exists "feat/2" "feat/2 recreated after re-split"

    # feat/1 should have 2 commits (original + fix)
    local count_1
    count_1=$(git log --oneline master..feat/1 | wc -l | tr -d ' ')
    assert_eq "2" "$count_1" "feat/1 has 2 commits (original + fix)"

    # Verify fix landed
    local content
    content=$(git show feat/1:a.txt)
    assert_contains "$content" "a-fix" "fix content present in feat/1"

    teardown
}

test_restack_basic() {
    echo "=== test: restack basic ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Record old tips
    local old_4 old_5
    old_4=$(git rev-parse feat/4)
    old_5=$(git rev-parse feat/5)

    # Simulate feat/3 merged to master + another PR merged (master advances)
    git checkout master -q
    git merge feat/3 --ff-only -q
    echo "other-pr" > other.txt; git add other.txt
    git commit -m "Other PR merged to master" -q

    bash "$DISPATCH" restack source/feature

    # feat/4 should have been rebased (different hash since master advanced)
    local new_4
    new_4=$(git rev-parse feat/4)
    if [[ "$old_4" != "$new_4" ]]; then
        echo -e "  ${GREEN}PASS${NC} feat/4 rebased (new hash)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} feat/4 should have new hash after rebase"
        FAIL=$((FAIL + 1))
    fi

    # feat/4 should have only its own 2 commits on top of master
    local count4
    count4=$(git log --oneline master..feat/4 | wc -l | tr -d ' ')
    assert_eq "2" "$count4" "feat/4 has 2 own commits on master"

    # feat/5 should have 3 commits on master (2 from feat/4 + 1 own)
    local count5
    count5=$(git log --oneline master..feat/5 | wc -l | tr -d ' ')
    assert_eq "3" "$count5" "feat/5 has 3 commits on master"

    # Verify file content preserved
    if git show feat/4:api.txt >/dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC} feat/4 has api.txt"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} feat/4 missing api.txt"
        FAIL=$((FAIL + 1))
    fi

    if git show feat/5:validate.txt >/dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC} feat/5 has validate.txt"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} feat/5 missing validate.txt"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_restack_dry_run() {
    echo "=== test: restack --dry-run ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Merge feat/3 to master + advance
    git checkout master -q
    git merge feat/3 --ff-only -q
    echo "other-pr" > other.txt; git add other.txt
    git commit -m "Other PR merged" -q

    local old_4
    old_4=$(git rev-parse feat/4)

    local output
    output=$(bash "$DISPATCH" restack --dry-run source/feature)

    assert_contains "$output" "[merged]" "dry-run shows merged branch"
    assert_contains "$output" "[rebase]" "dry-run shows rebase plan"
    assert_contains "$output" "dry-run" "dry-run label in summary"

    # Branches should NOT have changed
    local new_4
    new_4=$(git rev-parse feat/4)
    assert_eq "$old_4" "$new_4" "dry-run did not modify branches"

    teardown
}

test_restack_all_merged() {
    echo "=== test: restack all merged ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Fast-forward master through all branches
    git checkout master -q
    git merge feat/5 --ff-only -q

    local output
    output=$(bash "$DISPATCH" restack source/feature)

    assert_contains "$output" "[merged]" "reports merged branches"
    assert_contains "$output" "All branches merged" "suggests reset"

    teardown
}

test_restack_auto_detect() {
    echo "=== test: restack auto-detect ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    git checkout master -q
    git merge feat/3 --ff-only -q
    echo "other-pr" > other.txt; git add other.txt
    git commit -m "Other PR merged" -q

    local old_4
    old_4=$(git rev-parse feat/4)

    # Run from source branch without explicit arg
    git checkout source/feature -q
    bash "$DISPATCH" restack

    local new_4
    new_4=$(git rev-parse feat/4)
    if [[ "$old_4" != "$new_4" ]]; then
        echo -e "  ${GREEN}PASS${NC} auto-detect restacked from source branch"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} auto-detect should have restacked"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_restack_conflict_stops() {
    echo "=== test: restack conflict stops ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Merge feat/3 to master, then add conflicting change
    git checkout master -q
    git merge feat/3 --ff-only -q
    echo "conflicting-content" > api.txt; git add api.txt
    git commit -m "Master conflicts with feat/4" -q

    local output
    if output=$(bash "$DISPATCH" restack source/feature 2>&1); then
        echo -e "  ${RED}FAIL${NC} restack should fail on conflict"
        FAIL=$((FAIL + 1))
    else
        assert_contains "$output" "[conflict]" "reports conflict"
        assert_contains "$output" "feat/4" "identifies conflicting branch"
    fi

    # feat/5 should be untouched (stopped before reaching it)
    # After ff-merge of feat/3 + conflict commit, master..feat/5 = 3 (feat/4's 2 + feat/5's 1)
    local old_5_check
    old_5_check=$(git log --oneline master..feat/5 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "3" "$old_5_check" "feat/5 untouched after conflict stop"

    teardown
}

test_restack_worktree() {
    echo "=== test: restack with worktree ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Create worktree for feat/4
    git worktree add ../wt-restack feat/4 -q

    # Merge feat/3 to master + advance
    git checkout master -q
    git merge feat/3 --ff-only -q
    echo "other-pr" > other.txt; git add other.txt
    git commit -m "Other PR merged" -q

    local old_4
    old_4=$(git rev-parse feat/4)

    bash "$DISPATCH" restack source/feature

    # feat/4 should be rebased even though it's in a worktree
    local new_4
    new_4=$(git rev-parse feat/4)
    if [[ "$old_4" != "$new_4" ]]; then
        echo -e "  ${GREEN}PASS${NC} worktree branch rebased"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} worktree branch should have been rebased"
        FAIL=$((FAIL + 1))
    fi

    # Verify file exists in worktree
    if [[ -f "../wt-restack/api.txt" ]]; then
        echo -e "  ${GREEN}PASS${NC} worktree has rebased content"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} worktree missing rebased content"
        FAIL=$((FAIL + 1))
    fi

    git worktree remove ../wt-restack --force 2>/dev/null || true
    rm -rf "$TMPDIR/../wt-restack" 2>/dev/null || true
    teardown
}

test_restack_middle_merged() {
    echo "=== test: restack with middle branches merged ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Merge feat/3 AND feat/4 to master + advance
    git checkout master -q
    git merge feat/4 --ff-only -q
    echo "other-pr" > other.txt; git add other.txt
    git commit -m "Other PR merged" -q

    local old_5
    old_5=$(git rev-parse feat/5)

    bash "$DISPATCH" restack source/feature

    # feat/5 should be rebased directly onto master
    local new_5
    new_5=$(git rev-parse feat/5)
    if [[ "$old_5" != "$new_5" ]]; then
        echo -e "  ${GREEN}PASS${NC} feat/5 rebased (new hash)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} feat/5 should have new hash after rebase"
        FAIL=$((FAIL + 1))
    fi

    # feat/5 should have only its 1 own commit on top of master
    local count5
    count5=$(git log --oneline master..feat/5 | wc -l | tr -d ' ')
    assert_eq "1" "$count5" "feat/5 has 1 own commit directly on master"

    # Verify content preserved
    if git show feat/5:validate.txt >/dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC} feat/5 has validate.txt"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} feat/5 missing validate.txt"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_sync_cherry_pick_untracked_with_merge() {
    echo "=== test: sync cherry-picks untracked commits when merge detected ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Advance master
    git checkout master -q
    echo "new" > new.txt; git add new.txt
    git commit -m "advance master" -q

    # Merge master into task branch
    git checkout feat/3 -q
    git merge master --no-edit -q

    # Make untracked commit (no Target-Id trailer)
    echo "fix" > fix.txt; git add fix.txt
    git commit --no-verify -m "hotfix on task branch" -q

    # Sync
    bash "$DISPATCH" sync source/feature feat/3

    # Verify: source has "hotfix" commit with Target-Id: 3
    local source_msg
    source_msg=$(git log -1 --format="%s" source/feature)
    assert_eq "hotfix on task branch" "$source_msg" "commit message on source"

    local source_trailer
    source_trailer=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" source/feature | tr -d '[:space:]')
    assert_eq "3" "$source_trailer" "Target-Id trailer added on source"

    teardown
}

test_sync_cherry_pick_untracked_preserves_message() {
    echo "=== test: sync cherry-pick preserves original commit message ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Advance master and merge into task branch
    git checkout master -q
    echo "advance" > adv.txt; git add adv.txt
    git commit -m "advance" -q

    git checkout feat/3 -q
    git merge master --no-edit -q

    # Make commit with multi-line message
    echo "data" > data.txt; git add data.txt
    git commit --no-verify -m "$(printf 'Multi-line fix\n\nThis is the body of the commit.')" -q

    bash "$DISPATCH" sync source/feature feat/3

    local source_subject
    source_subject=$(git log -1 --format="%s" source/feature)
    assert_eq "Multi-line fix" "$source_subject" "subject line preserved"

    local source_body
    source_body=$(git log -1 --format="%b" source/feature)
    assert_contains "$source_body" "This is the body of the commit." "body preserved"

    teardown
}

test_sync_rebase_path_without_merge() {
    echo "=== test: sync uses rebase path when no merge commits ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Add untracked commit (no merge from base)
    git checkout feat/3 -q
    echo "plain" > plain.txt; git add plain.txt
    git commit --no-verify -m "plain fix" -q

    bash "$DISPATCH" sync source/feature feat/3

    # Task branch commit should have been amended with Target-Id (rebase path)
    local task_trailer
    task_trailer=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" feat/3 | tr -d '[:space:]')
    assert_eq "3" "$task_trailer" "Target-Id added on task branch via rebase"

    # Source should also have the commit
    local source_msg
    source_msg=$(git log -1 --format="%s" source/feature)
    assert_eq "plain fix" "$source_msg" "commit synced to source"

    teardown
}

test_status_shows_untracked_commits() {
    echo "=== test: status reports untracked commits ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Add untracked commit on feat/3 (no Target-Id)
    git checkout feat/3 -q
    echo "notrailer" > notrailer.txt; git add notrailer.txt
    git commit --no-verify -m "untracked commit" -q

    local output
    output=$(bash "$DISPATCH" status source/feature 2>&1)

    assert_contains "$output" "1 untracked commit" "status shows untracked count"
    assert_contains "$output" "git dispatch sync" "status suggests sync"

    # feat/4 and feat/5 should still show in sync
    # (use clean output to match)
    local clean_output
    clean_output=$(echo "$output" | sed $'s/\033\\[[0-9;]*m//g')
    # feat/5 should show in sync
    assert_contains "$clean_output" "in sync" "other branches still in sync"

    teardown
}

test_sync_cherry_pick_untracked_conflict() {
    echo "=== test: sync cherry-pick conflict with merge commits ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Advance master and merge into task branch
    git checkout master -q
    echo "advance" > adv.txt; git add adv.txt
    git commit -m "advance" -q

    git checkout feat/3 -q
    git merge master --no-edit -q

    # Create conflicting changes
    echo "task-version" > file.txt; git add file.txt
    git commit --no-verify -m "conflict on task" -q

    # Create conflicting commit on source
    git checkout source/feature -q
    echo "source-version" > file.txt; git add file.txt
    git commit -m "conflict on source$(printf '\n\nTarget-Id: 3')" -q

    # Sync should fail gracefully
    local output
    if output=$(bash "$DISPATCH" sync source/feature feat/3 2>&1); then
        echo -e "  ${RED}FAIL${NC} sync should fail on cherry-pick conflict"
        FAIL=$((FAIL + 1))
    else
        assert_contains "$output" "Cherry-pick into" "error mentions cherry-pick failure"
    fi

    # Branch should be clean
    git checkout source/feature -q 2>/dev/null || true
    local status
    status=$(git status --porcelain)
    assert_eq "" "$status" "branch left clean after failed cherry-pick"

    teardown
}

test_push_short_branch_name() {
    echo "=== test: push --branch accepts short name ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" push --dry-run --branch 4 source/feature)

    assert_contains "$output" "git push -u origin feat/4" "short name '4' matches feat/4"
    assert_not_contains "$output" "feat/3" "push excludes task-3"
    assert_not_contains "$output" "feat/5" "push excludes task-5"

    teardown
}

test_pr_short_branch_name() {
    echo "=== test: pr --branch accepts short name ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" pr --dry-run --branch 4 source/feature)

    assert_contains "$output" "gh pr create --base feat/3 --head feat/4" "short name '4' matches feat/4"

    # Should NOT contain other branches
    if [[ "$output" == *"--head feat/3"* ]]; then
        echo -e "  ${RED}FAIL${NC} should not create PR for task-3"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} no PR for task-3"
        PASS=$((PASS + 1))
    fi

    if [[ "$output" == *"--head feat/5"* ]]; then
        echo -e "  ${RED}FAIL${NC} should not create PR for task-5"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} no PR for task-5"
        PASS=$((PASS + 1))
    fi

    teardown
}

test_restack_squash_merge() {
    echo "=== test: restack detects squash-merged parent ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Simulate squash-merge of feat/3 into master
    git checkout master -q
    git merge --squash feat/3 -q
    git commit -m "squash-merge feat/3" -q

    local old_4
    old_4=$(git rev-parse feat/4)

    bash "$DISPATCH" restack source/feature

    # feat/3 should be detected as merged (content-based)
    # feat/4 should be rebased onto master
    local new_4
    new_4=$(git rev-parse feat/4)
    if [[ "$old_4" != "$new_4" ]]; then
        echo -e "  ${GREEN}PASS${NC} feat/4 rebased after squash-merge detection"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} feat/4 should have new hash after rebase"
        FAIL=$((FAIL + 1))
    fi

    # feat/4 should have only its own 2 commits on top of master
    local count4
    count4=$(git log --oneline master..feat/4 | wc -l | tr -d ' ')
    assert_eq "2" "$count4" "feat/4 has 2 own commits on master"

    # feat/5 should have 3 commits on master (2 from feat/4 + 1 own)
    local count5
    count5=$(git log --oneline master..feat/5 | wc -l | tr -d ' ')
    assert_eq "3" "$count5" "feat/5 has 3 commits on master"

    teardown
}

test_restack_squash_merge_reparents() {
    echo "=== test: restack reparents children after squash-merge ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Verify initial stack: master -> feat/3 -> feat/4 -> feat/5
    local tasks_master_before
    tasks_master_before=$(git config --get-all branch.master.dispatchtargets 2>/dev/null || true)
    assert_eq "feat/3" "$tasks_master_before" "initial: master -> feat/3"

    # Squash-merge feat/3 into master
    git checkout master -q
    git merge --squash feat/3 -q
    git commit -m "squash-merge feat/3" -q

    bash "$DISPATCH" restack source/feature

    # After restack: feat/3 removed from stack, feat/4 reparented to master
    local tasks_master_after
    tasks_master_after=$(git config --get-all branch.master.dispatchtargets 2>/dev/null || true)
    assert_eq "feat/4" "$tasks_master_after" "after restack: master -> feat/4 (reparented)"

    # feat/3 should have no children
    local tasks_3_after
    tasks_3_after=$(git config --get-all branch.feat/3.dispatchtargets 2>/dev/null || true)
    assert_eq "" "$tasks_3_after" "feat/3 has no children after reparenting"

    teardown
}

# ---------- PR-aware tests ----------

test_update_base_merge() {
    echo "=== test: update-base --merge ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Advance master
    git checkout master -q
    echo "new-base" > new-base.txt; git add new-base.txt
    git commit -m "advance master" -q

    bash "$DISPATCH" update-base --merge source/feature

    # Source should have merge commit
    git checkout source/feature -q
    local parent_count
    parent_count=$(git cat-file -p HEAD | grep -c '^parent ')
    assert_eq "2" "$parent_count" "source has merge commit after update-base --merge"

    # new-base.txt should be present
    if [[ -f "new-base.txt" ]]; then
        echo -e "  ${GREEN}PASS${NC} base content merged into source"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} base content not merged"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_update_base_rebase() {
    echo "=== test: update-base --rebase ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Advance master
    git checkout master -q
    echo "new-base" > new-base.txt; git add new-base.txt
    git commit -m "advance master" -q

    bash "$DISPATCH" update-base --rebase source/feature

    # Source should have linear history (no merge commits)
    git checkout source/feature -q
    local merge_count
    merge_count=$(git rev-list --merges master..source/feature | wc -l | tr -d ' ')
    assert_eq "0" "$merge_count" "linear history after update-base --rebase"

    # new-base.txt should be present (rebased on top of master)
    if git show source/feature:new-base.txt >/dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC} base content available after rebase"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} base content not available after rebase"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_update_base_auto_detect() {
    echo "=== test: update-base auto-detects source ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Advance master
    git checkout master -q
    echo "new-base" > new-base.txt; git add new-base.txt
    git commit -m "advance master" -q

    # Run from source branch without explicit source arg
    git checkout source/feature -q
    bash "$DISPATCH" update-base --rebase

    local merge_count
    merge_count=$(git rev-list --merges master..source/feature | wc -l | tr -d ' ')
    assert_eq "0" "$merge_count" "auto-detect source rebased correctly"

    teardown
}

test_pr_status_no_gh() {
    echo "=== test: pr-status warns when gh unavailable ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Run pr-status with gh hidden from PATH
    local output
    output=$(PATH=/usr/bin:/bin bash "$DISPATCH" pr-status source/feature 2>&1) || true

    assert_contains "$output" "gh CLI not found" "warns about missing gh"

    teardown
}

test_update_base_default_no_gh() {
    echo "=== test: update-base defaults to rebase when gh unavailable ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Advance master
    git checkout master -q
    echo "new-base" > new-base.txt; git add new-base.txt
    git commit -m "advance master" -q

    # Run without --merge/--rebase, with gh hidden (no PR detection)
    local output
    output=$(PATH=/usr/bin:/bin bash "$DISPATCH" update-base source/feature 2>&1)

    assert_contains "$output" "rebase" "defaults to rebase without gh"

    # Verify linear history
    local merge_count
    merge_count=$(git rev-list --merges master..source/feature | wc -l | tr -d ' ')
    assert_eq "0" "$merge_count" "linear history (rebase default without gh)"

    teardown
}

test_status_no_pr_noise() {
    echo "=== test: status runs clean without gh ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Run status with gh hidden from PATH
    local output
    output=$(PATH=/usr/bin:/bin bash "$DISPATCH" status source/feature 2>&1)

    assert_not_contains "$output" "gh CLI" "no gh warning in status output"
    assert_contains "$output" "feat/3" "status still shows branches"
    assert_contains "$output" "in sync" "status still shows sync state"

    teardown
}

# ---------- run ----------

echo "git-dispatch test suite"
echo "======================="
echo ""

test_init_basic
test_init_defaults
test_init_stacked_mode
test_init_custom_prefix
test_init_reinit_warns
test_init_installs_hooks
test_split
test_split_dry_run
test_tree
test_sync_source_to_task
test_sync_task_to_source
test_sync_worktree
test_sync_auto_detect_from_source
test_sync_auto_detect_from_task
test_sync_adds_trailer
test_status
test_status_auto_detect
test_pr_dry_run
test_pr_dry_run_push
test_reset
test_reset_branches
test_hook
test_hook_install_respects_hooks_path_relative
test_hook_install_respects_hooks_path_absolute
test_hook_install_default_without_hooks_path
test_hook_auto_carry_target_id
test_hook_auto_carry_no_override
test_hook_rejects_non_numeric_target_id
test_hook_allows_decimal_target_id
test_help
test_sync_cherry_pick_conflict
test_split_no_commits
test_split_already_exists
test_resolve_source_error_message
test_install_chmod
test_pr_single_branch
test_pr_custom_title_body
test_pr_branch_not_found
test_split_decimal_target_id
test_split_no_task_order_backward_compat
test_status_stack_order
test_status_no_false_pending
test_sync_stack_order
test_pr_stack_order
test_push_dry_run
test_push_branch_filter
test_push_force_dry_run
test_resolve_basic
test_resolve_preserves_content
test_resolve_no_task_changes
test_resolve_not_merge
test_resolve_not_task_branch
test_status_merge_warning
test_resplit_recovers_metadata
test_resplit_guards_wrong_prefix
test_resplit_guards_wrong_base
test_resplit_idempotent
test_resplit_new_task_mid_stack
test_resplit_new_task_at_end
test_split_cherry_pick_conflict_graceful
test_resplit_after_reset_pr_feedback
test_restack_basic
test_restack_dry_run
test_restack_all_merged
test_restack_auto_detect
test_restack_conflict_stops
test_restack_worktree
test_restack_middle_merged
test_sync_cherry_pick_untracked_with_merge
test_sync_cherry_pick_untracked_preserves_message
test_sync_rebase_path_without_merge
test_status_shows_untracked_commits
test_sync_cherry_pick_untracked_conflict
test_push_short_branch_name
test_pr_short_branch_name
test_restack_squash_merge
test_restack_squash_merge_reparents
test_update_base_merge
test_update_base_rebase
test_update_base_auto_detect
test_pr_status_no_gh
test_update_base_default_no_gh
test_status_no_pr_noise

echo ""
echo "======================="
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
