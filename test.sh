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

# Create a POC branch with trailer-tagged commits
create_poc() {
    git checkout -b poc/feature master -q
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
    create_poc

    bash "$DISPATCH" split poc/feature --base master --name feat

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
    local children_master
    children_master=$(git config --get-all branch.master.dispatchchildren 2>/dev/null || true)
    assert_eq "feat/task-3" "$children_master" "master has task-3 as child"

    local children_3
    children_3=$(git config --get-all branch.feat/task-3.dispatchchildren 2>/dev/null || true)
    assert_eq "feat/task-4" "$children_3" "task-3 has task-4 as child"

    local children_4
    children_4=$(git config --get-all branch.feat/task-4.dispatchchildren 2>/dev/null || true)
    assert_eq "feat/task-5" "$children_4" "task-4 has task-5 as child"

    # POC association
    local poc3
    poc3=$(git config branch.feat/task-3.dispatchpoc 2>/dev/null || true)
    assert_eq "poc/feature" "$poc3" "task-3 linked to POC"

    teardown
}

test_split_dry_run() {
    echo "=== test: split --dry-run ==="
    setup
    create_poc

    local output
    output=$(bash "$DISPATCH" split poc/feature --base master --name feat --dry-run)

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
    create_poc

    bash "$DISPATCH" split poc/feature --base master --name feat >/dev/null

    local tree
    tree=$(bash "$DISPATCH" tree master)

    assert_contains "$tree" "master" "tree shows master"
    assert_contains "$tree" "feat/task-3" "tree shows task-3"
    assert_contains "$tree" "feat/task-4" "tree shows task-4"
    assert_contains "$tree" "feat/task-5" "tree shows task-5"
    assert_contains "$tree" "└──" "tree has branch characters"

    teardown
}

test_sync_poc_to_child() {
    echo "=== test: sync POC → child ==="
    setup
    create_poc

    bash "$DISPATCH" split poc/feature --base master --name feat >/dev/null

    # Add a new commit to POC for task-4
    git checkout poc/feature -q
    echo "fix" > fix.txt; git add fix.txt
    git commit -m "Fix DTO validation$(printf '\n\nTask-Id: 4')" -q

    local before
    before=$(git log --oneline master..feat/task-4 | wc -l | tr -d ' ')

    bash "$DISPATCH" sync poc/feature feat/task-4

    local after
    after=$(git log --oneline master..feat/task-4 | wc -l | tr -d ' ')

    assert_eq "$((before + 1))" "$after" "new POC commit cherry-picked into child"

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

test_sync_child_to_poc() {
    echo "=== test: sync child → POC ==="
    setup
    create_poc

    bash "$DISPATCH" split poc/feature --base master --name feat >/dev/null

    # Add a commit directly on child task-3
    git checkout feat/task-3 -q
    echo "hotfix" > hotfix.txt; git add hotfix.txt
    git commit -m "Hotfix alignment$(printf '\n\nTask-Id: 3')" -q

    local before
    before=$(git log --oneline master..poc/feature | wc -l | tr -d ' ')

    bash "$DISPATCH" sync poc/feature feat/task-3

    local after
    after=$(git log --oneline master..poc/feature | wc -l | tr -d ' ')

    assert_eq "$((before + 1))" "$after" "child commit cherry-picked into POC"

    # Verify the file landed
    if git show poc/feature:hotfix.txt >/dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC} hotfix.txt exists in POC"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} hotfix.txt missing from POC"
        FAIL=$((FAIL + 1))
    fi

    teardown
}

test_sync_worktree() {
    echo "=== test: sync with worktree ==="
    setup
    create_poc

    bash "$DISPATCH" split poc/feature --base master --name feat >/dev/null

    # Create worktree for task-4
    git worktree add ../wt-task4 feat/task-4 -q

    # Add commit to POC for task-4
    git checkout poc/feature -q
    echo "wt-fix" > wt-fix.txt; git add wt-fix.txt
    git commit -m "Worktree fix$(printf '\n\nTask-Id: 4')" -q

    bash "$DISPATCH" sync poc/feature feat/task-4

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

test_help() {
    echo "=== test: help ==="
    local output
    output=$(bash "$DISPATCH" help)
    assert_contains "$output" "WORKFLOW" "help shows workflow"
    assert_contains "$output" "COMMANDS" "help shows commands"
    assert_contains "$output" "TRAILERS" "help shows trailers"
}

test_sync_auto_detect_from_poc() {
    echo "=== test: sync auto-detect from POC branch ==="
    setup
    create_poc

    bash "$DISPATCH" split poc/feature --base master --name feat >/dev/null

    # Add a new commit to POC for task-3
    git checkout poc/feature -q
    echo "auto" > auto.txt; git add auto.txt
    git commit -m "Auto detect fix$(printf '\n\nTask-Id: 3')" -q

    local before
    before=$(git log --oneline master..feat/task-3 | wc -l | tr -d ' ')

    # Sync WITHOUT specifying POC -- should auto-detect from current branch
    bash "$DISPATCH" sync

    local after
    after=$(git log --oneline master..feat/task-3 | wc -l | tr -d ' ')

    assert_eq "$((before + 1))" "$after" "auto-detect from POC synced commit"

    teardown
}

test_sync_auto_detect_from_child() {
    echo "=== test: sync auto-detect from child branch ==="
    setup
    create_poc

    bash "$DISPATCH" split poc/feature --base master --name feat >/dev/null

    # Add a commit to POC for task-4
    git checkout poc/feature -q
    echo "child-auto" > child-auto.txt; git add child-auto.txt
    git commit -m "Child auto fix$(printf '\n\nTask-Id: 4')" -q

    # Switch to child branch, sync without args
    git checkout feat/task-4 -q

    local before
    before=$(git log --oneline master..feat/task-4 | wc -l | tr -d ' ')

    bash "$DISPATCH" sync

    local after
    after=$(git log --oneline master..feat/task-4 | wc -l | tr -d ' ')

    assert_eq "$((before + 1))" "$after" "auto-detect from child synced commit"

    teardown
}

test_sync_adds_trailer() {
    echo "=== test: sync child→POC adds Task-Id trailer ==="
    setup
    create_poc

    bash "$DISPATCH" split poc/feature --base master --name feat >/dev/null

    # Commit on child WITHOUT Task-Id trailer
    git checkout feat/task-3 -q
    echo "no-trailer" > notrailer.txt; git add notrailer.txt
    git commit --no-verify -m "Fix without trailer" -q

    bash "$DISPATCH" sync poc/feature feat/task-3

    # Check trailer was added on child branch commit (amended in-place)
    local child_trailer
    child_trailer=$(git log -1 --format="%(trailers:key=Task-Id,valueonly)" feat/task-3 | tr -d '[:space:]')
    assert_eq "3" "$child_trailer" "Task-Id trailer added on child branch commit"

    # Check the cherry-picked commit on POC also has Task-Id trailer
    local poc_trailer
    poc_trailer=$(git log -1 --format="%(trailers:key=Task-Id,valueonly)" poc/feature | tr -d '[:space:]')
    assert_eq "3" "$poc_trailer" "Task-Id trailer present on POC after sync"

    teardown
}

test_status() {
    echo "=== test: status ==="
    setup
    create_poc

    bash "$DISPATCH" split poc/feature --base master --name feat >/dev/null

    # Add a commit to POC for task-4
    git checkout poc/feature -q
    echo "status-fix" > status-fix.txt; git add status-fix.txt
    git commit -m "Status fix$(printf '\n\nTask-Id: 4')" -q

    # Add a commit directly on child task-3
    git checkout feat/task-3 -q
    echo "child-fix" > child-fix.txt; git add child-fix.txt
    git commit -m "Child fix$(printf '\n\nTask-Id: 3')" -q

    local output
    output=$(bash "$DISPATCH" status poc/feature)

    assert_contains "$output" "poc/feature" "status shows POC"
    assert_contains "$output" "feat/task-3" "status shows task-3"
    assert_contains "$output" "feat/task-4" "status shows task-4"
    assert_contains "$output" "feat/task-5" "status shows task-5"
    # task-4 should have 1 pending POC -> child
    assert_contains "$output" "1 pending" "status shows pending count"
    # task-5 should show up to date
    assert_contains "$output" "up to date" "status shows up to date"

    teardown
}

test_status_auto_detect() {
    echo "=== test: status auto-detect ==="
    setup
    create_poc

    bash "$DISPATCH" split poc/feature --base master --name feat >/dev/null

    # Run status from POC branch without explicit arg
    git checkout poc/feature -q
    local output
    output=$(bash "$DISPATCH" status)

    assert_contains "$output" "poc/feature" "auto-detect status shows POC"
    assert_contains "$output" "feat/task-3" "auto-detect status shows children"

    teardown
}

test_pr_dry_run() {
    echo "=== test: pr --dry-run ==="
    setup
    create_poc

    bash "$DISPATCH" split poc/feature --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" pr --dry-run poc/feature)

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
    create_poc

    bash "$DISPATCH" split poc/feature --base master --name feat >/dev/null

    local output
    output=$(bash "$DISPATCH" pr --dry-run --push poc/feature)

    assert_contains "$output" "git push -u origin feat/task-3" "push command for task-3"
    assert_contains "$output" "git push -u origin feat/task-4" "push command for task-4"
    assert_contains "$output" "git push -u origin feat/task-5" "push command for task-5"

    teardown
}

test_reset() {
    echo "=== test: reset ==="
    setup
    create_poc

    bash "$DISPATCH" split poc/feature --base master --name feat >/dev/null

    bash "$DISPATCH" reset --force poc/feature

    # Verify config cleaned
    local poc3
    poc3=$(git config branch.feat/task-3.dispatchpoc 2>/dev/null || true)
    assert_eq "" "$poc3" "task-3 dispatchpoc removed"

    local poc4
    poc4=$(git config branch.feat/task-4.dispatchpoc 2>/dev/null || true)
    assert_eq "" "$poc4" "task-4 dispatchpoc removed"

    local children_master
    children_master=$(git config --get-all branch.master.dispatchchildren 2>/dev/null || true)
    assert_eq "" "$children_master" "master dispatchchildren removed"

    local children_3
    children_3=$(git config --get-all branch.feat/task-3.dispatchchildren 2>/dev/null || true)
    assert_eq "" "$children_3" "task-3 dispatchchildren removed"

    local children_4
    children_4=$(git config --get-all branch.feat/task-4.dispatchchildren 2>/dev/null || true)
    assert_eq "" "$children_4" "task-4 dispatchchildren removed"

    # Branches should still exist
    assert_branch_exists "feat/task-3" "task-3 still exists after reset"
    assert_branch_exists "feat/task-4" "task-4 still exists after reset"
    assert_branch_exists "feat/task-5" "task-5 still exists after reset"

    teardown
}

test_reset_branches() {
    echo "=== test: reset --branches ==="
    setup
    create_poc

    bash "$DISPATCH" split poc/feature --base master --name feat >/dev/null

    git checkout master -q
    bash "$DISPATCH" reset --force --branches poc/feature

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
    local poc3
    poc3=$(git config branch.feat/task-3.dispatchpoc 2>/dev/null || true)
    assert_eq "" "$poc3" "config cleaned after reset --branches"

    teardown
}

# ---------- run ----------

echo "git-dispatch test suite"
echo "======================="
echo ""

test_split
test_split_dry_run
test_tree
test_sync_poc_to_child
test_sync_child_to_poc
test_sync_worktree
test_sync_auto_detect_from_poc
test_sync_auto_detect_from_child
test_sync_adds_trailer
test_status
test_status_auto_detect
test_pr_dry_run
test_pr_dry_run_push
test_reset
test_reset_branches
test_hook
test_help

echo ""
echo "======================="
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
