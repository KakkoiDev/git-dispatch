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

    assert_branch_exists "feat/task-3" "task-3 branch created"
    assert_branch_exists "feat/task-4" "task-4 branch created"
    assert_branch_exists "feat/task-5" "task-5 branch created"

    # task-3: 1 commit
    local count3
    count3=$(git log --oneline master..feat/task-3 | wc -l | tr -d ' ')
    assert_eq "1" "$count3" "task-3 has 1 commit"

    # task-4: 1 (task-3) + 2 own = 3
    local count4
    count4=$(git log --oneline master..feat/task-4 | wc -l | tr -d ' ')
    assert_eq "3" "$count4" "task-4 has 3 commits (stacked)"

    # task-5: 3 (task-3+4) + 1 own = 4
    local count5
    count5=$(git log --oneline master..feat/task-5 | wc -l | tr -d ' ')
    assert_eq "4" "$count5" "task-5 has 4 commits (stacked)"

    # Stack config
    local tasks_master
    tasks_master=$(git config --get-all branch.master.dispatchtasks 2>/dev/null || true)
    assert_eq "feat/task-3" "$tasks_master" "master has task-3 in stack"

    local tasks_3
    tasks_3=$(git config --get-all branch.feat/task-3.dispatchtasks 2>/dev/null || true)
    assert_eq "feat/task-4" "$tasks_3" "task-3 has task-4 in stack"

    local tasks_4
    tasks_4=$(git config --get-all branch.feat/task-4.dispatchtasks 2>/dev/null || true)
    assert_eq "feat/task-5" "$tasks_4" "task-4 has task-5 in stack"

    # Source association
    local src3
    src3=$(git config branch.feat/task-3.dispatchsource 2>/dev/null || true)
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
    assert_contains "$output" "feat/task-3" "task-3 in dry-run output"
    assert_contains "$output" "feat/task-4" "task-4 in dry-run output"

    # Branches should NOT exist
    if git rev-parse --verify "feat/task-3" >/dev/null 2>&1; then
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
    assert_contains "$tree" "feat/task-3" "tree shows task-3"
    assert_contains "$tree" "feat/task-4" "tree shows task-4"
    assert_contains "$tree" "feat/task-5" "tree shows task-5"
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
    before=$(git log --oneline master..feat/task-4 | wc -l | tr -d ' ')

    bash "$DISPATCH" sync source/feature feat/task-4

    local after
    after=$(git log --oneline master..feat/task-4 | wc -l | tr -d ' ')

    assert_eq "$((before + 1))" "$after" "new source commit cherry-picked into task"

    # Verify the file landed
    if git show feat/task-4:fix.txt >/dev/null 2>&1; then
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
    git checkout feat/task-3 -q
    echo "hotfix" > hotfix.txt; git add hotfix.txt
    git commit -m "Hotfix alignment$(printf '\n\nTask-Id: 3')" -q

    local before
    before=$(git log --oneline master..source/feature | wc -l | tr -d ' ')

    bash "$DISPATCH" sync source/feature feat/task-3

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
    git worktree add ../wt-task4 feat/task-4 -q

    # Add commit to source for task-4
    git checkout source/feature -q
    echo "wt-fix" > wt-fix.txt; git add wt-fix.txt
    git commit -m "Worktree fix$(printf '\n\nTask-Id: 4')" -q

    bash "$DISPATCH" sync source/feature feat/task-4

    # Verify via worktree
    if [[ -f "../wt-task4/wt-fix.txt" ]]; then
        echo -e "  ${GREEN}PASS${NC} worktree-aware sync landed file"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} worktree-aware sync did not land file"
        FAIL=$((FAIL + 1))
    fi

    git worktree remove ../wt-task4 --force 2>/dev/null || true
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
    before=$(git log --oneline master..feat/task-3 | wc -l | tr -d ' ')

    # Sync WITHOUT specifying source -- should auto-detect from current branch
    bash "$DISPATCH" sync

    local after
    after=$(git log --oneline master..feat/task-3 | wc -l | tr -d ' ')

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
    git checkout feat/task-4 -q

    local before
    before=$(git log --oneline master..feat/task-4 | wc -l | tr -d ' ')

    bash "$DISPATCH" sync

    local after
    after=$(git log --oneline master..feat/task-4 | wc -l | tr -d ' ')

    assert_eq "$((before + 1))" "$after" "auto-detect from task synced commit"

    teardown
}

test_sync_adds_trailer() {
    echo "=== test: sync task→source adds Task-Id trailer ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Commit on task branch WITHOUT Task-Id trailer
    git checkout feat/task-3 -q
    echo "no-trailer" > notrailer.txt; git add notrailer.txt
    git commit --no-verify -m "Fix without trailer" -q

    bash "$DISPATCH" sync source/feature feat/task-3

    # Check trailer was added on task branch commit (amended in-place)
    local task_trailer
    task_trailer=$(git log -1 --format="%(trailers:key=Task-Id,valueonly)" feat/task-3 | tr -d '[:space:]')
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
    git checkout feat/task-3 -q
    echo "task-fix" > task-fix.txt; git add task-fix.txt
    git commit -m "Task fix$(printf '\n\nTask-Id: 3')" -q

    local output
    output=$(bash "$DISPATCH" status source/feature)

    assert_contains "$output" "source/feature" "status shows source"
    assert_contains "$output" "feat/task-3" "status shows task-3"
    assert_contains "$output" "feat/task-4" "status shows task-4"
    assert_contains "$output" "feat/task-5" "status shows task-5"
    # task-4 should have 1 pending source -> task
    assert_contains "$output" "1 pending" "status shows pending count"
    # task-5 should show up to date
    assert_contains "$output" "up to date" "status shows up to date"

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
    assert_contains "$output" "feat/task-3" "auto-detect status shows tasks"

    teardown
}

test_pr_dry_run() {
    echo "=== test: pr --dry-run ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" pr --dry-run source/feature)

    assert_contains "$output" "gh pr create --base master --head feat/task-3" "PR for task-3 with correct base"
    assert_contains "$output" "gh pr create --base feat/task-3 --head feat/task-4" "PR for task-4 with correct base"
    assert_contains "$output" "gh pr create --base feat/task-4 --head feat/task-5" "PR for task-5 with correct base"

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

    assert_contains "$output" "git push -u origin feat/task-3" "push command for task-3"
    assert_contains "$output" "git push -u origin feat/task-4" "push command for task-4"
    assert_contains "$output" "git push -u origin feat/task-5" "push command for task-5"

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
    src3=$(git config branch.feat/task-3.dispatchsource 2>/dev/null || true)
    assert_eq "" "$src3" "task-3 dispatchsource removed"

    local src4
    src4=$(git config branch.feat/task-4.dispatchsource 2>/dev/null || true)
    assert_eq "" "$src4" "task-4 dispatchsource removed"

    local tasks_master
    tasks_master=$(git config --get-all branch.master.dispatchtasks 2>/dev/null || true)
    assert_eq "" "$tasks_master" "master dispatchtasks removed"

    local tasks_3
    tasks_3=$(git config --get-all branch.feat/task-3.dispatchtasks 2>/dev/null || true)
    assert_eq "" "$tasks_3" "task-3 dispatchtasks removed"

    local tasks_4
    tasks_4=$(git config --get-all branch.feat/task-4.dispatchtasks 2>/dev/null || true)
    assert_eq "" "$tasks_4" "task-4 dispatchtasks removed"

    # Branches should still exist
    assert_branch_exists "feat/task-3" "task-3 still exists after reset"
    assert_branch_exists "feat/task-4" "task-4 still exists after reset"
    assert_branch_exists "feat/task-5" "task-5 still exists after reset"

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
    if git rev-parse --verify "feat/task-3" >/dev/null 2>&1; then
        echo -e "  ${RED}FAIL${NC} task-3 should be deleted"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} task-3 branch deleted"
        PASS=$((PASS + 1))
    fi

    if git rev-parse --verify "feat/task-4" >/dev/null 2>&1; then
        echo -e "  ${RED}FAIL${NC} task-4 should be deleted"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} task-4 branch deleted"
        PASS=$((PASS + 1))
    fi

    if git rev-parse --verify "feat/task-5" >/dev/null 2>&1; then
        echo -e "  ${RED}FAIL${NC} task-5 should be deleted"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} task-5 branch deleted"
        PASS=$((PASS + 1))
    fi

    # Config should also be clean
    local src3
    src3=$(git config branch.feat/task-3.dispatchsource 2>/dev/null || true)
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
    git checkout feat/task-3 -q
    echo "different" > file.txt; git add file.txt
    git commit -m "Conflicting fix$(printf '\n\nTask-Id: 3')" -q

    # Sync should fail with error message
    local output
    if output=$(bash "$DISPATCH" sync source/feature feat/task-3 2>&1); then
        echo -e "  ${RED}FAIL${NC} sync should fail on cherry-pick conflict"
        FAIL=$((FAIL + 1))
    else
        assert_contains "$output" "Cherry-pick into" "error mentions cherry-pick failure"
    fi

    # Branch should be clean (cherry-pick aborted)
    git checkout feat/task-3 -q 2>/dev/null || true
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
    git branch feat/task-3 master

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
    echo "=== test: non-numeric task ID rejected ==="
    setup
    create_source

    bash "$DISPATCH" split source/feature --base master --name feat >/dev/null

    # Manually create a dispatch task with non-numeric task ID
    git branch feat/task-abc master
    git config "branch.feat/task-abc.dispatchsource" "source/feature"

    local output
    if output=$(bash "$DISPATCH" sync source/feature feat/task-abc 2>&1); then
        echo -e "  ${RED}FAIL${NC} sync should reject non-numeric task ID"
        FAIL=$((FAIL + 1))
    else
        assert_contains "$output" "Invalid task ID" "error mentions invalid task ID"
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
    output=$(bash "$DISPATCH" pr --dry-run --branch feat/task-4 source/feature)

    assert_contains "$output" "gh pr create --base feat/task-3 --head feat/task-4" "PR for task-4 with correct base"

    # Should NOT contain task-3 or task-5 PR creation
    if [[ "$output" == *"--head feat/task-3"* ]]; then
        echo -e "  ${RED}FAIL${NC} should not create PR for task-3"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}PASS${NC} no PR for task-3"
        PASS=$((PASS + 1))
    fi

    if [[ "$output" == *"--head feat/task-5"* ]]; then
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
    output=$(bash "$DISPATCH" pr --dry-run --branch feat/task-3 --title "Custom PR Title" --body "Custom body text" source/feature)

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

echo ""
echo "======================="
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
