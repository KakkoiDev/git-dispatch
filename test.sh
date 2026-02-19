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

# Create a source branch with trailer-tagged commits
create_source() {
    git checkout -b source/feature master -q
    echo "a" > file.txt; git add file.txt
    git commit -m "Add enum$(printf '\n\nTask-Id: 3')" -q

    echo "b" > api.txt; git add api.txt
    git commit -m "Create GET endpoint$(printf '\n\nTask-Id: 4')" -q

    echo "c" > dto.txt; git add dto.txt
    git commit -m "Add DTOs$(printf '\n\nTask-Id: 4')" -q

    echo "d" > validate.txt; git add validate.txt
    git commit -m "Implement validation$(printf '\n\nTask-Id: 5')" -q
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
    tasks_master=$(git config --get-all branch.master.dispatchtasks 2>/dev/null || true)
    assert_eq "feat/3" "$tasks_master" "master has task-3 in stack"

    local tasks_3
    tasks_3=$(git config --get-all branch.feat/3.dispatchtasks 2>/dev/null || true)
    assert_eq "feat/4" "$tasks_3" "task-3 has task-4 in stack"

    local tasks_4
    tasks_4=$(git config --get-all branch.feat/4.dispatchtasks 2>/dev/null || true)
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
    git commit -m "Fix DTO validation$(printf '\n\nTask-Id: 4')" -q

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
    git commit -m "Hotfix alignment$(printf '\n\nTask-Id: 3')" -q

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
    git commit -m "Worktree fix$(printf '\n\nTask-Id: 4')" -q

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
        echo -e "  ${RED}FAIL${NC} hook should reject commit without Task-Id"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} hook rejects commit without Task-Id"
        PASS=$((PASS + 1))
    fi

    # Commit with trailer should succeed
    git commit -m "with trailer$(printf '\n\nTask-Id: 1')" -q
    if [[ $? -eq 0 ]]; then
        echo -e "  ${GREEN}PASS${NC} hook allows commit with Task-Id"
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

test_hook_auto_carry_task_id() {
    echo "=== test: hook auto-carries Task-Id from previous commit ==="
    setup

    bash "$DISPATCH" hook install

    # First commit with explicit Task-Id
    echo "a" > a.txt; git add a.txt
    git commit -m "first$(printf '\n\nTask-Id: 3')" -q

    # Second commit without trailer — should auto-carry Task-Id=3
    echo "b" > b.txt; git add b.txt
    git commit -m "second" -q

    local carried
    carried=$(git log -1 --format="%(trailers:key=Task-Id,valueonly)" | tr -d '[:space:]')
    assert_eq "$carried" "3" "Task-Id auto-carried from previous commit"

    teardown
}

test_hook_auto_carry_no_override() {
    echo "=== test: hook does not override explicit Task-Id ==="
    setup

    bash "$DISPATCH" hook install

    # First commit with Task-Id=3
    echo "a" > a.txt; git add a.txt
    git commit -m "first$(printf '\n\nTask-Id: 3')" -q

    # Second commit with explicit Task-Id=4 — should keep 4, not carry 3
    echo "b" > b.txt; git add b.txt
    git commit -m "second" --trailer "Task-Id=4" -q

    local task_id
    task_id=$(git log -1 --format="%(trailers:key=Task-Id,valueonly)" | tr -d '[:space:]')
    assert_eq "$task_id" "4" "explicit Task-Id not overridden by auto-carry"

    teardown
}

test_hook_auto_carry_task_order() {
    echo "=== test: hook auto-carries Task-Id and Task-Order ==="
    setup

    bash "$DISPATCH" hook install

    # First commit with Task-Id=3 and Task-Order=1
    echo "a" > a.txt; git add a.txt
    git commit -m "first$(printf '\n\nTask-Id: 3\nTask-Order: 1')" -q

    # Second commit without trailers — should auto-carry both
    echo "b" > b.txt; git add b.txt
    git commit -m "second" -q

    local carried_id carried_order
    carried_id=$(git log -1 --format="%(trailers:key=Task-Id,valueonly)" | tr -d '[:space:]')
    carried_order=$(git log -1 --format="%(trailers:key=Task-Order,valueonly)" | tr -d '[:space:]')
    assert_eq "$carried_id" "3" "Task-Id auto-carried"
    assert_eq "$carried_order" "1" "Task-Order auto-carried"

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
    git commit -m "Auto detect fix$(printf '\n\nTask-Id: 3')" -q

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
    git commit -m "Task auto fix$(printf '\n\nTask-Id: 4')" -q

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
    echo "=== test: sync task→source adds Task-Id trailer ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Commit on task branch WITHOUT Task-Id trailer
    git checkout feat/3 -q
    echo "no-trailer" > notrailer.txt; git add notrailer.txt
    git commit --no-verify -m "Fix without trailer" -q

    bash "$DISPATCH" sync source/feature feat/3 || true

    # Check trailer was added on task branch commit (amended in-place)
    local task_trailer
    task_trailer=$(git log -1 --format="%(trailers:key=Task-Id,valueonly)" feat/3 | tr -d '[:space:]')
    assert_eq "3" "$task_trailer" "Task-Id trailer added on task branch commit"

    # Check the cherry-picked commit on source also has Task-Id trailer
    local source_trailer
    source_trailer=$(git log -1 --format="%(trailers:key=Task-Id,valueonly)" source/feature | tr -d '[:space:]')
    assert_eq "3" "$source_trailer" "Task-Id trailer present on source after sync"

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
    git commit -m "Status fix$(printf '\n\nTask-Id: 4')" -q

    # Add a commit directly on task-3
    git checkout feat/3 -q
    echo "task-fix" > task-fix.txt; git add task-fix.txt
    git commit -m "Task fix$(printf '\n\nTask-Id: 3')" -q

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
    tasks_master=$(git config --get-all branch.master.dispatchtasks 2>/dev/null || true)
    assert_eq "" "$tasks_master" "master dispatchtasks removed"

    local tasks_3
    tasks_3=$(git config --get-all branch.feat/3.dispatchtasks 2>/dev/null || true)
    assert_eq "" "$tasks_3" "task-3 dispatchtasks removed"

    local tasks_4
    tasks_4=$(git config --get-all branch.feat/4.dispatchtasks 2>/dev/null || true)
    assert_eq "" "$tasks_4" "task-4 dispatchtasks removed"

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
    git commit -m "Conflict change$(printf '\n\nTask-Id: 3')" -q

    # Create conflicting commit on task-3 (different content in same file)
    git checkout feat/3 -q
    echo "different" > file.txt; git add file.txt
    git commit -m "Conflicting fix$(printf '\n\nTask-Id: 3')" -q

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
    echo "=== test: split when branch already exists ==="
    setup
    create_source

    # Pre-create a branch that split would create
    git branch feat/3 master

    local output
    if output=$(bash "$DISPATCH" split source/feature --base master --name feat 2>&1); then
        echo -e "  ${RED}FAIL${NC} split should fail when branch exists"
        FAIL=$((FAIL + 1))
    else
        assert_contains "$output" "already exists" "error mentions branch already exists"
    fi

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

test_split_non_numeric_task_id() {
    echo "=== test: non-numeric task ID accepted ==="
    setup

    git checkout -b source/alpha master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "Add alpha$(printf '\n\nTask-Id: task-6')" -q

    bash "$DISPATCH" split source/alpha --base master --name feat

    assert_branch_exists "feat/task-6" "non-numeric task-6 branch created"

    # Verify no double prefix (should NOT be feat/task-task-6)
    if git rev-parse --verify "feat/task-task-6" >/dev/null 2>&1; then
        echo -e "  ${RED}FAIL${NC} double prefix feat/task-task-6 should not exist"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} no double prefix"
        PASS=$((PASS + 1))
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

test_split_task_order() {
    echo "=== test: split with Task-Order ==="
    setup

    git checkout -b source/ordered master -q
    echo "b" > b.txt; git add b.txt
    git commit -m "Add B$(printf '\n\nTask-Id: task-B\nTask-Order: 2')" -q

    echo "a" > a.txt; git add a.txt
    git commit -m "Add A$(printf '\n\nTask-Id: task-A\nTask-Order: 1')" -q

    bash "$DISPATCH" split source/ordered --base master --name feat

    assert_branch_exists "feat/task-A" "task-A branch created"
    assert_branch_exists "feat/task-B" "task-B branch created"

    local tasks_master
    tasks_master=$(git config --get-all branch.master.dispatchtasks 2>/dev/null || true)
    assert_eq "feat/task-A" "$tasks_master" "master -> task-A (order 1 first)"

    local tasks_a
    tasks_a=$(git config --get-all branch.feat/task-A.dispatchtasks 2>/dev/null || true)
    assert_eq "feat/task-B" "$tasks_a" "task-A -> task-B (order 2 second)"

    teardown
}

test_split_task_order_partial() {
    echo "=== test: split with partial Task-Order ==="
    setup

    git checkout -b source/partial master -q
    echo "c" > c.txt; git add c.txt
    git commit -m "Add C$(printf '\n\nTask-Id: task-C\nTask-Order: 1')" -q

    echo "a" > a.txt; git add a.txt
    git commit -m "Add A$(printf '\n\nTask-Id: task-A')" -q

    echo "b" > b.txt; git add b.txt
    git commit -m "Add B$(printf '\n\nTask-Id: task-B')" -q

    bash "$DISPATCH" split source/partial --base master --name feat

    local tasks_master
    tasks_master=$(git config --get-all branch.master.dispatchtasks 2>/dev/null || true)
    assert_eq "feat/task-C" "$tasks_master" "master -> task-C (ordered first)"

    local tasks_c
    tasks_c=$(git config --get-all branch.feat/task-C.dispatchtasks 2>/dev/null || true)
    assert_eq "feat/task-A" "$tasks_c" "task-C -> task-A (unordered, commit order)"

    local tasks_a
    tasks_a=$(git config --get-all branch.feat/task-A.dispatchtasks 2>/dev/null || true)
    assert_eq "feat/task-B" "$tasks_a" "task-A -> task-B (unordered, commit order)"

    teardown
}

test_split_no_task_order_backward_compat() {
    echo "=== test: split without Task-Order (backward compat) ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat

    local tasks_master
    tasks_master=$(git config --get-all branch.master.dispatchtasks 2>/dev/null || true)
    assert_eq "feat/3" "$tasks_master" "master -> task-3 (commit order preserved)"

    local tasks_3
    tasks_3=$(git config --get-all branch.feat/3.dispatchtasks 2>/dev/null || true)
    assert_eq "feat/4" "$tasks_3" "task-3 -> task-4 (commit order preserved)"

    local tasks_4
    tasks_4=$(git config --get-all branch.feat/4.dispatchtasks 2>/dev/null || true)
    assert_eq "feat/5" "$tasks_4" "task-4 -> task-5 (commit order preserved)"

    teardown
}

test_status_stack_order() {
    echo "=== test: status shows branches in stack order ==="
    setup

    # Create source with task IDs that sort differently alphabetically vs numerically
    # Alpha order: 10, 20, 3 — Stack order: 3, 10, 20
    git checkout -b source/order master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "First$(printf '\n\nTask-Id: 3')" -q

    echo "b" > b.txt; git add b.txt
    git commit -m "Second$(printf '\n\nTask-Id: 10')" -q

    echo "c" > c.txt; git add c.txt
    git commit -m "Third$(printf '\n\nTask-Id: 20')" -q

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
    git commit -m "First$(printf '\n\nTask-Id: 3')" -q
    echo "b" > b.txt; git add b.txt
    git commit -m "Second$(printf '\n\nTask-Id: 4')" -q

    # Advance master again after source fork
    git checkout master -q
    echo "base3" > base3.txt; git add base3.txt
    git commit -m "Base advance 3" -q

    # Split — task branches are on current master, ahead of source fork point
    bash "$DISPATCH" split source/fresh --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" status source/fresh | sed $'s/\033\\[[0-9;]*m//g')

    # After a fresh split, all tasks should be in sync — no false pending
    assert_not_contains "$output" "pending" "no false pending after fresh split"
    assert_contains "$output" "in sync" "shows in sync after fresh split"

    teardown
}

test_sync_stack_order() {
    echo "=== test: sync processes branches in stack order ==="
    setup

    git checkout -b source/order master -q
    echo "a" > a.txt; git add a.txt
    git commit -m "First$(printf '\n\nTask-Id: 3')" -q

    echo "b" > b.txt; git add b.txt
    git commit -m "Second$(printf '\n\nTask-Id: 10')" -q

    echo "c" > c.txt; git add c.txt
    git commit -m "Third$(printf '\n\nTask-Id: 20')" -q

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
    git commit -m "First$(printf '\n\nTask-Id: 3')" -q

    echo "b" > b.txt; git add b.txt
    git commit -m "Second$(printf '\n\nTask-Id: 10')" -q

    echo "c" > c.txt; git add c.txt
    git commit -m "Third$(printf '\n\nTask-Id: 20')" -q

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

    # Verify HEAD~1 is the resolution commit with Task-Id
    local tid
    tid=$(git log -1 --skip=1 --format="%(trailers:key=Task-Id,valueonly)" | tr -d '[:space:]')
    assert_eq "3" "$tid" "Task-Id trailer on resolution commit"

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

    assert_contains "$output" "merge commit" "status shows merge warning"
    assert_contains "$output" "git dispatch resolve" "status suggests resolve command"

    teardown
}

test_hook_install_post_merge() {
    echo "=== test: hook install includes post-merge ==="
    setup

    bash "$DISPATCH" hook install

    local hook_dir
    hook_dir="$(git rev-parse --git-dir)/hooks"

    if [[ -f "$hook_dir/post-merge" ]]; then
        echo -e "  ${GREEN}PASS${NC} post-merge hook installed"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} post-merge hook not found"
        FAIL=$((FAIL + 1))
    fi

    if [[ -x "$hook_dir/post-merge" ]]; then
        echo -e "  ${GREEN}PASS${NC} post-merge hook is executable"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} post-merge hook not executable"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

# ---------- run ----------

echo "git-dispatch test suite"
echo "======================="
echo ""

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
test_hook_auto_carry_task_id
test_hook_auto_carry_no_override
test_hook_auto_carry_task_order
test_help
test_sync_cherry_pick_conflict
test_split_no_commits
test_split_already_exists
test_resolve_source_error_message
test_split_non_numeric_task_id
test_install_chmod
test_pr_single_branch
test_pr_custom_title_body
test_pr_branch_not_found
test_split_task_order
test_split_task_order_partial
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
test_hook_install_post_merge

echo ""
echo "======================="
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
