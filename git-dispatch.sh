#!/bin/bash
set -euo pipefail

# git aliases with ! set GIT_DIR which overrides git -C; unset to fix worktree operations
unset GIT_DIR GIT_WORK_TREE

# git-dispatch: Split a source branch into stacked task branches and keep them in sync.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- helpers ----------

die() { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }
info() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }

current_branch() { git symbolic-ref --short HEAD 2>/dev/null; }

# Get tasks of a branch from git config (dispatch stack)
get_tasks() {
    local branch="$1"
    git config --get-all "branch.${branch}.dispatchtasks" 2>/dev/null || true
}

# Add a task branch to the dispatch stack
stack_add() {
    local task_name="$1" parent="$2"
    if get_tasks "$parent" | grep -Fxq "$task_name"; then
        return 0
    fi
    git config --add "branch.${parent}.dispatchtasks" "$task_name"
}

# Remove a task from the dispatch stack
stack_remove() {
    local task_name="$1" parent="$2"
    local tasks
    tasks=$(get_tasks "$parent" | grep -Fxv "$task_name" || true)
    git config --unset-all "branch.${parent}.dispatchtasks" 2>/dev/null || true
    if [[ -n "$tasks" ]]; then
        while IFS= read -r c; do
            git config --add "branch.${parent}.dispatchtasks" "$c"
        done <<< "$tasks"
    fi
}

# Recursive tree display
stack_show_all() {
    local branch="$1" prefix="${2:-}" child_prefix="${3:-}"
    echo "${prefix}${branch}"
    local tasks
    tasks=$(get_tasks "$branch")
    [[ -z "$tasks" ]] && return
    local -a arr
    while IFS= read -r line; do arr+=("$line"); done <<< "$tasks"
    local count=${#arr[@]}
    for ((i = 0; i < count; i++)); do
        if (( i + 1 == count )); then
            stack_show_all "${arr[$i]}" "${child_prefix}└── " "${child_prefix}    "
        else
            stack_show_all "${arr[$i]}" "${child_prefix}├── " "${child_prefix}│   "
        fi
    done
}

# Find worktree path for a branch (empty if none)
worktree_for_branch() {
    local branch="$1"
    git worktree list --porcelain | awk -v b="refs/heads/$branch" '
        /^worktree / { wt = substr($0, 10) }
        /^branch /   { if (substr($0, 8) == b) print wt }
    '
}

# Amend commits on a branch to add Task-Id trailer (rewrites history)
_amend_trailers_on_branch() {
    local branch="$1" task_id="$2"; shift 2
    local hashes=("$@")
    local wt
    wt=$(worktree_for_branch "$branch")
    local git_cmd=(git)
    local orig=""

    if [[ -n "$wt" ]]; then
        git_cmd=(git -C "$wt")
    else
        orig=$(current_branch)
        git checkout "$branch" --quiet
    fi

    for hash in "${hashes[@]}"; do
        local tid
        tid=$("${git_cmd[@]}" log -1 --format="%(trailers:key=Task-Id,valueonly)" "$hash" 2>/dev/null | tr -d '[:space:]')
        if [[ "$tid" != "$task_id" ]]; then
            # Rewrite this commit with the trailer using filter-branch on just this commit
            # Simpler: interactive rebase is not an option, so use commit --amend via rebase --exec
            # Even simpler: if it's the tip, just amend directly
            local tip
            tip=$("${git_cmd[@]}" rev-parse HEAD)
            if [[ "$hash" == "$tip" ]]; then
                "${git_cmd[@]}" commit --amend --no-edit --trailer "Task-Id=$task_id" --quiet
            else
                # For non-tip commits, use rebase with GIT_SEQUENCE_EDITOR
                local parent
                parent=$("${git_cmd[@]}" rev-parse "$hash^")
                GIT_SEQUENCE_EDITOR="sed -i.bak 's/^pick $( echo "$hash" | cut -c1-7)/edit ${hash:0:7}/'" \
                    "${git_cmd[@]}" rebase -i "$parent" --quiet 2>/dev/null || {
                    "${git_cmd[@]}" rebase --abort 2>/dev/null || true
                    die "Rebase failed while amending trailer on $hash in $branch. Resolve manually."
                }
                "${git_cmd[@]}" commit --amend --no-edit --trailer "Task-Id=$task_id" --quiet
                "${git_cmd[@]}" rebase --continue --quiet 2>/dev/null || {
                    "${git_cmd[@]}" rebase --abort 2>/dev/null || true
                    die "Rebase --continue failed on $branch. Resolve manually."
                }
            fi
        fi
    done

    if [[ -z "$wt" && -n "$orig" ]]; then
        git checkout "$orig" --quiet
    fi
}

# Cherry-pick into a branch, worktree-aware
cherry_pick_into() {
    local branch="$1"; shift
    local hashes=("$@")
    local wt
    wt=$(worktree_for_branch "$branch")
    local -a git_cmd=(git)
    [[ -n "$wt" ]] && git_cmd=(git -C "$wt")

    if [[ -z "$wt" ]]; then
        local orig
        orig=$(current_branch)
        git checkout "$branch" --quiet
    fi

    # Stash dirty working tree (staged + unstaged) so cherry-pick can proceed
    local stashed=false
    if ! "${git_cmd[@]}" diff --quiet 2>/dev/null || ! "${git_cmd[@]}" diff --cached --quiet 2>/dev/null; then
        "${git_cmd[@]}" stash push --quiet -m "git-dispatch: auto-stash before cherry-pick"
        stashed=true
    fi

    for hash in "${hashes[@]}"; do
        if ! "${git_cmd[@]}" cherry-pick -x "$hash"; then
            # Check if cherry-pick is actually in progress (vs aborted entirely)
            if "${git_cmd[@]}" rev-parse --verify CHERRY_PICK_HEAD &>/dev/null; then
                # Cherry-pick in progress but empty: patch already applied
                if "${git_cmd[@]}" diff --cached --quiet; then
                    warn "  Skipping empty cherry-pick: $("${git_cmd[@]}" log -1 --oneline "$hash")"
                    "${git_cmd[@]}" cherry-pick --skip
                    continue
                fi
            fi
            # Real failure: abort and die
            "${git_cmd[@]}" cherry-pick --abort 2>/dev/null || true
            $stashed && "${git_cmd[@]}" stash pop --quiet
            [[ -z "$wt" ]] && git checkout "$orig" --quiet
            local retry="git -C $wt cherry-pick -x ${hashes[*]}"
            [[ -z "$wt" ]] && retry="git checkout $branch && git cherry-pick -x ${hashes[*]}"
            die "Cherry-pick into $branch failed. Retry manually: $retry"
        fi
    done

    $stashed && "${git_cmd[@]}" stash pop --quiet
    [[ -z "$wt" ]] && git checkout "$orig" --quiet
}

# ---------- split ----------

cmd_split() {
    local source="" base="master" name="" dry_run=false continuing=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base)      base="$2"; shift 2 ;;
            --name)      name="$2"; shift 2 ;;
            --dry-run)   dry_run=true; shift ;;
            --continue)  continuing=true; shift ;;
            -*)          die "Unknown flag: $1" ;;
            *)           source="$1"; shift ;;
        esac
    done

    [[ -n "$source" ]]  || die "Usage: git dispatch split <source-branch> --name <prefix> [--base <base>]"

    git rev-parse --verify "$source" >/dev/null 2>&1  || die "Branch '$source' does not exist"

    # Check if already split
    local existing_tasks_str=""
    existing_tasks_str=$(find_dispatch_tasks "$source" | order_by_stack)

    if [[ -n "$existing_tasks_str" ]]; then
        # Re-split: recover base and prefix from metadata
        local recovered_base recovered_prefix
        recovered_base=$(recover_dispatch_base "$source")
        recovered_prefix=$(recover_dispatch_prefix "$source")

        # Guard: if user passed --base or --name, they must match
        if [[ "$base" != "master" && "$base" != "$recovered_base" ]]; then
            die "Base mismatch: existing stack uses '$recovered_base', you passed '$base'"
        fi
        if [[ -n "$name" && "$name" != "$recovered_prefix" ]]; then
            die "Prefix mismatch: existing stack uses '$recovered_prefix', you passed '$name'"
        fi

        base="$recovered_base"
        name="$recovered_prefix"
    else
        # First split — require --name
        [[ -n "$name" ]] || die "Missing --name flag (branch prefix)"
    fi

    git rev-parse --verify "$base" >/dev/null 2>&1 || die "Base '$base' does not exist"

    # Parse trailer-tagged commits into temp file: "hash task-id" per line
    local commit_file
    commit_file=$(mktemp)
    trap "rm -f '$commit_file'" RETURN

    while IFS= read -r _h; do
        _t=$(git log -1 --format="%(trailers:key=Task-Id,valueonly)" "$_h" | tr -d '[:space:]')
        _o=$(git log -1 --format="%(trailers:key=Task-Order,valueonly)" "$_h" | tr -d '[:space:]')
        echo "$_h $_t $_o"
    done < <(git log --reverse --format="%H" "$base..$source") > "$commit_file"

    [[ -s "$commit_file" ]] || die "No commits found between $base and $source"

    # Validate all commits have Task-Id
    while read -r hash task _order; do
        [[ -z "$task" ]] && die "Commit $hash has no Task-Id trailer"
    done < "$commit_file"

    # Ordered unique task ids (Task-Order aware: ordered tasks first, then unordered in commit order)
    local order_output
    if ! order_output=$(awk '
        !seen[$2]++ {
            task = $2; order = $3; tasks[++n] = task
            if (order != "") {
                if (order in order_used) {
                    print "Duplicate Task-Order " order " on tasks " order_used[order] " and " task
                    err = 1
                }
                order_used[order] = task; task_order[task] = order + 0
            }
        }
        END {
            if (err) exit 1
            for (i = 1; i <= n; i++) {
                t = tasks[i]
                if (t in task_order) { ordered[++oc] = t; ord_val[oc] = task_order[t] }
                else { unordered[++uc] = t }
            }
            for (i = 2; i <= oc; i++) {
                key = ordered[i]; kv = ord_val[i]; j = i - 1
                while (j > 0 && ord_val[j] > kv) {
                    ordered[j+1] = ordered[j]; ord_val[j+1] = ord_val[j]; j--
                }
                ordered[j+1] = key; ord_val[j+1] = kv
            }
            for (i = 1; i <= oc; i++) print ordered[i]
            for (i = 1; i <= uc; i++) print unordered[i]
        }
    ' "$commit_file"); then
        die "$order_output"
    fi

    local -a task_ids=()
    while IFS= read -r tid; do
        task_ids+=("$tid")
    done <<< "$order_output"

    # Warn about new tasks without Task-Order during re-split
    if [[ -n "$existing_tasks_str" ]]; then
        local -a existing_tids=()
        while IFS= read -r eb; do
            [[ -n "$eb" ]] && existing_tids+=("${eb##*/}")
        done <<< "$existing_tasks_str"

        for tid in "${task_ids[@]}"; do
            # Is this a new task?
            local is_new=true
            for et in "${existing_tids[@]}"; do
                [[ "$et" == "$tid" ]] && { is_new=false; break; }
            done
            $is_new || continue

            # Does it have Task-Order?
            local has_order
            has_order=$(awk -v t="$tid" '$2 == t && $3 != "" {found=1} END {print found+0}' "$commit_file")
            if [[ "$has_order" == "0" ]]; then
                warn "WARNING: New task '$tid' has no Task-Order and will be appended at end of stack."
                warn "  Add Task-Order to control position: git commit --amend --trailer \"Task-Order=N\""
            fi
        done
    fi

    echo -e "${CYAN}Source:${NC} $source"
    echo -e "${CYAN}Base:${NC}   $base"
    echo -e "${CYAN}Tasks:${NC}  ${task_ids[*]}"
    echo ""

    local prev_branch="$base"
    for tid in "${task_ids[@]}"; do
        local branch_name="${name}/${tid}"
        # Collect hashes for this task
        local -a hashes=()
        while IFS= read -r h; do
            hashes+=("$h")
        done < <(awk -v t="$tid" '$2 == t {print $1}' "$commit_file")

        if $dry_run; then
            echo -e "  ${YELLOW}[dry-run]${NC} $branch_name  (${#hashes[@]} commits from $prev_branch)"
        else
            git branch "$branch_name" "$prev_branch" 2>/dev/null || {
                info "  Skipping $branch_name (already exists)"
                prev_branch="$branch_name"
                continue
            }

            # Inline cherry-pick with conflict recovery
            local orig
            orig=$(current_branch)
            git checkout "$branch_name" --quiet

            local cherry_pick_failed=false
            for hash in "${hashes[@]}"; do
                if ! git cherry-pick -x "$hash" 2>/dev/null; then
                    if git rev-parse --verify CHERRY_PICK_HEAD &>/dev/null && git diff --cached --quiet; then
                        warn "  Skipping empty cherry-pick: $(git log -1 --oneline "$hash")"
                        git cherry-pick --skip
                        continue
                    fi
                    git cherry-pick --abort 2>/dev/null || true
                    cherry_pick_failed=true
                    break
                fi
            done

            git checkout "$orig" --quiet

            # Remove any stale references to this branch from other parents
            local stale_parent
            stale_parent=$(find_stack_parent "$branch_name")
            if [[ -n "$stale_parent" && "$stale_parent" != "$prev_branch" ]]; then
                stack_remove "$branch_name" "$stale_parent"
            fi

            # Find next existing branch in task_ids order (for splice)
            local next_existing=""
            local found_self=false
            for check_tid in "${task_ids[@]}"; do
                if $found_self; then
                    local check_branch="${name}/${check_tid}"
                    if git rev-parse --verify "$check_branch" &>/dev/null; then
                        next_existing="$check_branch"
                        break
                    fi
                fi
                [[ "$check_tid" == "$tid" ]] && found_self=true
            done

            # Splice into stack: prev → new → next_existing
            if [[ -n "$next_existing" ]]; then
                local next_parent
                next_parent=$(find_stack_parent "$next_existing")
                if [[ -n "$next_parent" ]]; then
                    stack_remove "$next_existing" "$next_parent"
                fi
                stack_add "$next_existing" "$branch_name"
            fi
            stack_add "$branch_name" "$prev_branch"
            git config "branch.${branch_name}.dispatchsource" "$source"

            if $cherry_pick_failed; then
                warn "  $branch_name created (cherry-pick conflicted — run sync to retry)"
            else
                info "  Created $branch_name (${#hashes[@]} commits)"
            fi
        fi
        prev_branch="$branch_name"
    done

    echo ""
    if ! $dry_run; then
        cmd_tree "$base"
    fi
}

# ---------- sync ----------

# Resolve source branch from current context
# Priority: explicit arg > current branch is source > current branch is task (read dispatchsource)
resolve_source() {
    local explicit="$1"
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
        return
    fi

    local cur
    cur=$(current_branch)

    # Is current branch a source for any task?
    local is_source
    is_source=$(git for-each-ref --format='%(refname:short)' refs/heads/ | while read -r b; do
        local csource
        csource=$(git config "branch.${b}.dispatchsource" 2>/dev/null || true)
        if [[ "$csource" == "$cur" ]]; then echo "$cur"; break; fi
    done)
    if [[ -n "$is_source" ]]; then
        echo "$is_source"
        return
    fi

    # Is current branch a task? Read its dispatchsource
    local csource
    csource=$(git config "branch.${cur}.dispatchsource" 2>/dev/null || true)
    if [[ -n "$csource" ]]; then
        echo "$csource"
        return
    fi

    die "Cannot detect source branch (current: '${cur}'). Run from a source or task branch, or pass it explicitly."
}

# Find all dispatch tasks for a given source
find_dispatch_tasks() {
    local source="$1"
    local -a found=()

    while IFS= read -r ref; do
        local bname="${ref#refs/heads/}"
        local csource
        csource=$(git config "branch.${bname}.dispatchsource" 2>/dev/null || true)
        [[ "$csource" == "$source" ]] && found+=("$bname")
    done < <(git for-each-ref --format='%(refname)' refs/heads/)

    [[ ${#found[@]} -gt 0 ]] && printf '%s\n' "${found[@]}" || true
}

# Order tasks by walking the dispatch stack hierarchy.
# Reads task names from stdin, writes them in stack order to stdout.
order_by_stack() {
    local -a tasks=()
    while IFS= read -r t; do [[ -n "$t" ]] && tasks+=("$t"); done

    [[ ${#tasks[@]} -gt 0 ]] || return 0

    # Find base branch (parent of first task that isn't itself a dispatch task)
    local base=""
    for task in "${tasks[@]}"; do
        local parent
        parent=$(find_stack_parent "$task")
        local parent_is_task=false
        for c in "${tasks[@]}"; do
            [[ "$c" == "$parent" ]] && { parent_is_task=true; break; }
        done
        if ! $parent_is_task; then
            base="$parent"
            break
        fi
    done

    if [[ -z "$base" ]]; then
        printf '%s\n' "${tasks[@]}"
        return
    fi

    # Walk from base through dispatch tasks in stack order
    local current="$base"
    while true; do
        local next=""
        for c in "${tasks[@]}"; do
            if get_tasks "$current" | grep -Fxq "$c"; then
                next="$c"
                break
            fi
        done
        [[ -n "$next" ]] || break
        echo "$next"
        current="$next"
    done
}

# Find the parent branch in the dispatch stack for a given branch
find_stack_parent() {
    local branch="$1"
    git for-each-ref --format='%(refname:short)' refs/heads/ | while read -r b; do
        if get_tasks "$b" | grep -Fxq "$branch"; then
            echo "$b"
            break
        fi
    done
}

# Recover base branch from dispatch metadata
recover_dispatch_base() {
    local source="$1"
    local tasks
    tasks=$(find_dispatch_tasks "$source" | order_by_stack)
    [[ -n "$tasks" ]] || return 1
    local first_task
    first_task=$(echo "$tasks" | head -1)
    find_stack_parent "$first_task"
}

# Recover branch prefix from dispatch metadata
recover_dispatch_prefix() {
    local source="$1"
    local first_task
    first_task=$(find_dispatch_tasks "$source" | order_by_stack | head -1)
    [[ -n "$first_task" ]] || return 1
    echo "${first_task%/*}"
}

cmd_sync() {
    local source_arg="" task="" continuing=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --continue) continuing=true; shift ;;
            -*)         die "Unknown flag: $1" ;;
            *)
                if [[ -z "$source_arg" ]]; then source_arg="$1"
                elif [[ -z "$task" ]]; then task="$1"
                fi
                shift ;;
        esac
    done

    local source
    source=$(resolve_source "$source_arg")

    # Resolve task branches to sync (in stack order)
    local -a targets=()
    if [[ -n "$task" ]]; then
        targets=("$task")
    else
        while IFS= read -r c; do
            [[ -n "$c" ]] && targets+=("$c")
        done < <(find_dispatch_tasks "$source" | order_by_stack)
    fi

    [[ ${#targets[@]} -gt 0 ]] || die "No dispatch tasks found for $source"

    echo -e "${CYAN}Source:${NC} $source"
    echo ""

    for task_branch in "${targets[@]}"; do
        echo -e "${CYAN}Syncing:${NC} $task_branch"

        # Extract task-id from branch name (last path segment)
        local task_id="${task_branch##*/}"
        [[ -n "$task_id" ]] || die "Empty task ID in branch '${task_branch}'"

        # Source → task: commits in source for this task not yet in task branch
        local -a source_to_task=()
        local cherry_out
        cherry_out=$(git cherry -v "$task_branch" "$source" 2>&1) || die "git cherry failed: $cherry_out"
        while IFS= read -r line; do
            [[ "$line" == +* ]] || continue
            local hash
            hash=$(echo "$line" | awk '{print $2}')
            # Check if this commit has matching Task-Id
            local tid
            tid=$(git log -1 --format="%(trailers:key=Task-Id,valueonly)" "$hash" | tr -d '[:space:]')
            [[ "$tid" == "$task_id" ]] && source_to_task+=("$hash")
        done <<< "$cherry_out"

        if [[ ${#source_to_task[@]} -gt 0 ]]; then
            info "  Source → task: ${#source_to_task[@]} commit(s)"
            cherry_pick_into "$task_branch" "${source_to_task[@]}"
        else
            echo "  Source → task: up to date"
        fi

        # Task → source: commits in task branch not yet in source
        # Use stack parent as limit so we only count this task's commits
        local parent
        parent=$(find_stack_parent "$task_branch")
        local -a task_to_source=()
        local needs_trailer=false
        cherry_out=$(git cherry -v "$source" "$task_branch" ${parent:+"$parent"} 2>&1) || die "git cherry failed: $cherry_out"
        while IFS= read -r line; do
            [[ "$line" == +* ]] || continue
            local hash
            hash=$(echo "$line" | awk '{print $2}')
            local tid
            tid=$(git log -1 --format="%(trailers:key=Task-Id,valueonly)" "$hash" | tr -d '[:space:]')
            if [[ "$tid" != "$task_id" ]]; then
                needs_trailer=true
            fi
            task_to_source+=("$hash")
        done <<< "$cherry_out"

        if [[ ${#task_to_source[@]} -gt 0 ]]; then
            # Amend commits on task branch to add Task-Id before cherry-picking
            if $needs_trailer; then
                info "  Fixing Task-Id on task commits..."
                _amend_trailers_on_branch "$task_branch" "$task_id" "${task_to_source[@]}"
                # Re-read hashes after rewrite
                task_to_source=()
                cherry_out=$(git cherry -v "$source" "$task_branch" ${parent:+"$parent"} 2>&1) || die "git cherry failed: $cherry_out"
                while IFS= read -r line; do
                    [[ "$line" == +* ]] || continue
                    local hash
                    hash=$(echo "$line" | awk '{print $2}')
                    task_to_source+=("$hash")
                done <<< "$cherry_out"
            fi
            info "  Task → source: ${#task_to_source[@]} commit(s)"
            cherry_pick_into "$source" "${task_to_source[@]}"
        else
            echo "  Task → source: up to date"
        fi

        echo ""
    done
}

# ---------- status ----------

cmd_status() {
    local source_arg=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -*) die "Unknown flag: $1" ;;
            *)  source_arg="$1"; shift ;;
        esac
    done

    local source
    source=$(resolve_source "$source_arg")

    local -a targets=()
    while IFS= read -r c; do
        [[ -n "$c" ]] && targets+=("$c")
    done < <(find_dispatch_tasks "$source" | order_by_stack)

    [[ ${#targets[@]} -gt 0 ]] || die "No dispatch tasks found for $source"

    echo -e "${CYAN}Source:${NC} $source"
    echo ""

    for task_branch in "${targets[@]}"; do
        local task_id="${task_branch##*/}"
        [[ -n "$task_id" ]] || die "Empty task ID in branch '${task_branch}'"

        # Source -> task: commits in source for this task not yet in task branch
        local source_to_task=0
        local cherry_out
        cherry_out=$(git cherry -v "$task_branch" "$source" 2>&1) || die "git cherry failed: $cherry_out"
        while IFS= read -r line; do
            [[ "$line" == +* ]] || continue
            local hash
            hash=$(echo "$line" | awk '{print $2}')
            local tid
            tid=$(git log -1 --format="%(trailers:key=Task-Id,valueonly)" "$hash" | tr -d '[:space:]')
            [[ "$tid" == "$task_id" ]] && source_to_task=$((source_to_task + 1))
        done <<< "$cherry_out"

        # Task -> source: commits in task branch not yet in source
        # Use stack parent as limit so we only count this task's commits,
        # not ancestor commits from base/master
        local task_to_source=0
        local parent
        parent=$(find_stack_parent "$task_branch")
        cherry_out=$(git cherry -v "$source" "$task_branch" ${parent:+"$parent"} 2>&1) || die "git cherry failed: $cherry_out"
        while IFS= read -r line; do
            [[ "$line" == +* ]] || continue
            task_to_source=$((task_to_source + 1))
        done <<< "$cherry_out"

        echo -e "  ${YELLOW}$task_branch${NC}"
        if [[ $source_to_task -eq 0 && $task_to_source -eq 0 ]]; then
            echo -e "    ${GREEN}in sync${NC}"
        else
            if [[ $source_to_task -gt 0 ]]; then
                echo -e "    Source -> task: ${YELLOW}${source_to_task} pending${NC}"
            fi
            if [[ $task_to_source -gt 0 ]]; then
                echo -e "    Task -> source: ${YELLOW}${task_to_source} pending${NC}"
            fi
        fi

        # Check for unresolved merge commits on task branch
        # Skip merge commits produced by "git dispatch resolve" (their first
        # parent is the resolution commit with "resolve merge conflicts" message)
        local merge_commits unresolved_count=0
        merge_commits=$(git rev-list --merges "${parent}..${task_branch}" 2>/dev/null)
        while IFS= read -r mc; do
            [[ -z "$mc" ]] && continue
            local first_parent_msg
            first_parent_msg=$(git log -1 --format="%s" "${mc}^1" 2>/dev/null)
            if [[ "$first_parent_msg" == *"resolve merge conflicts with base"* ]]; then
                continue
            fi
            unresolved_count=$((unresolved_count + 1))
        done <<< "$merge_commits"
        if [[ $unresolved_count -gt 0 ]]; then
            echo -e "    ${RED}WARNING: ${unresolved_count} merge commit(s) — run: git dispatch resolve${NC}"
        fi

        echo ""
    done
}

# ---------- resolve ----------

cmd_resolve() {
    local branch
    branch=$(current_branch)

    # Verify this is a dispatch task branch
    local source
    source=$(git config "branch.${branch}.dispatchsource" 2>/dev/null || true)
    [[ -n "$source" ]] || die "Not a dispatch task branch: $branch"

    # Extract task_id from branch name (last segment)
    local task_id="${branch##*/}"
    [[ -n "$task_id" ]] || die "Cannot extract task ID from branch '$branch'"

    # Verify HEAD is a merge commit (2+ parents)
    local parent_count
    parent_count=$(git cat-file -p HEAD | grep -c '^parent ')
    [[ $parent_count -ge 2 ]] || die "HEAD is not a merge commit"

    # Verify merge not pushed
    if git rev-parse --verify "origin/$branch" &>/dev/null; then
        if git merge-base --is-ancestor HEAD "origin/$branch" 2>/dev/null; then
            die "Merge already pushed to origin/$branch. Cannot resolve."
        fi
    fi

    # Save refs
    local first_parent second_parent merge_head
    first_parent=$(git rev-parse HEAD^1)
    second_parent=$(git rev-parse HEAD^2)
    merge_head=$(git rev-parse HEAD)

    # Find task-owned files: all files touched between stack parent and first_parent
    local stack_parent
    stack_parent=$(find_stack_parent "$branch")
    [[ -n "$stack_parent" ]] || die "Cannot find stack parent for $branch"

    local task_files
    task_files=$(git log --format="" --name-only "${stack_parent}..${first_parent}" | sort -u | sed '/^$/d')

    if [[ -z "$task_files" ]]; then
        info "Clean merge, no resolution needed"
        return
    fi

    # Find task files changed by the merge resolution
    local changed_files=""
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if ! git diff --quiet "$first_parent" "$merge_head" -- "$f" 2>/dev/null; then
            changed_files+="$f"$'\n'
        fi
    done <<< "$task_files"
    changed_files=$(echo "$changed_files" | sed '/^$/d')

    if [[ -z "$changed_files" ]]; then
        info "Clean merge, no resolution needed"
        return
    fi

    # Create resolution commit + clean re-merge
    # 1. Reset to pre-merge state
    git reset --hard "$first_parent" -q

    # 2. Apply changed task files as resolution commit
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local dir
        dir=$(dirname "$f")
        [[ "$dir" == "." ]] || mkdir -p "$dir"
        if git cat-file -e "${merge_head}:${f}" 2>/dev/null; then
            git show "${merge_head}:${f}" > "$f"
            git add "$f"
        else
            git rm -f "$f" 2>/dev/null || true
        fi
    done <<< "$changed_files"

    git commit --no-verify -m "fix: resolve merge conflicts with base" --trailer "Task-Id=$task_id" -q

    # 3. Re-merge with -X ours (no conflicts since resolution already applied)
    git merge -X ours "$second_parent" --no-verify --no-edit -q

    info "Resolved: resolution commit + clean re-merge (Task-Id=$task_id)"
}

# ---------- restack ----------

cmd_restack() {
    local source_arg="" dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            -*)        die "Unknown flag: $1" ;;
            *)         source_arg="$1"; shift ;;
        esac
    done

    local source
    source=$(resolve_source "$source_arg")

    local base
    base=$(recover_dispatch_base "$source")
    [[ -n "$base" ]] || die "Cannot determine base branch for $source"

    # Determine base ref (prefer origin, fallback to local)
    local base_ref
    if ! $dry_run && git remote get-url origin &>/dev/null; then
        git fetch origin "$base" --quiet 2>/dev/null || true
    fi
    if git rev-parse --verify "origin/$base" &>/dev/null; then
        base_ref="origin/$base"
    else
        base_ref="$base"
    fi

    # Get ordered task branches
    local -a ordered=()
    while IFS= read -r c; do
        [[ -n "$c" ]] && ordered+=("$c")
    done < <(find_dispatch_tasks "$source" | order_by_stack)

    [[ ${#ordered[@]} -gt 0 ]] || die "No dispatch tasks found for $source"

    # Save old tip refs before any rebasing (needed for correct --onto parent)
    local -a old_tips=()
    for b in "${ordered[@]}"; do
        old_tips+=("$(git rev-parse "$b")")
    done

    # Save current checkout to restore later
    local orig
    orig=$(current_branch)

    echo -e "${CYAN}Source:${NC}  $source"
    echo -e "${CYAN}Base:${NC}    $base (rebasing onto $base_ref)"
    echo ""

    local merged=0 rebased=0 conflict="" rebase_onto="$base_ref"

    for i in "${!ordered[@]}"; do
        local task_branch="${ordered[$i]}"

        # Check if fully merged into base
        if git merge-base --is-ancestor "${old_tips[$i]}" "$base_ref" 2>/dev/null; then
            if $dry_run; then
                echo -e "  ${GREEN}[merged]${NC} $task_branch"
            else
                info "  [merged] $task_branch"
            fi
            merged=$((merged + 1))
            continue
        fi

        # Find parent in stack
        local parent
        parent=$(find_stack_parent "$task_branch")
        [[ -n "$parent" ]] || { warn "  Cannot find parent for $task_branch, skipping"; continue; }

        # Resolve parent's OLD ref (before we may have rebased it)
        local parent_ref="$parent"
        for j in "${!ordered[@]}"; do
            if [[ "${ordered[$j]}" == "$parent" ]]; then
                parent_ref="${old_tips[$j]}"
                break
            fi
        done

        if $dry_run; then
            echo -e "  ${YELLOW}[rebase]${NC} $task_branch onto $(git rev-parse --short "$rebase_onto" 2>/dev/null || echo "$rebase_onto")"
            rebase_onto="$task_branch"
            rebased=$((rebased + 1))
            continue
        fi

        # Worktree-aware rebase
        local wt
        wt=$(worktree_for_branch "$task_branch")

        if [[ -n "$wt" ]]; then
            if ! git -C "$wt" rebase --onto "$rebase_onto" "$parent_ref" 2>/dev/null; then
                git -C "$wt" rebase --abort 2>/dev/null || true
                conflict="$task_branch"
                warn "  [conflict] $task_branch — aborted"
                break
            fi
        else
            if ! git rebase --onto "$rebase_onto" "$parent_ref" "$task_branch" 2>/dev/null; then
                git rebase --abort 2>/dev/null || true
                conflict="$task_branch"
                warn "  [conflict] $task_branch — aborted"
                break
            fi
        fi

        info "  [rebased] $task_branch"
        rebase_onto="$task_branch"
        rebased=$((rebased + 1))
    done

    # Restore original checkout
    if ! $dry_run && [[ -n "$orig" ]]; then
        git checkout "$orig" --quiet 2>/dev/null || true
    fi

    echo ""
    if $dry_run; then
        echo -e "${CYAN}Summary (dry-run):${NC} $merged merged, $rebased to rebase"
    else
        echo -e "${CYAN}Summary:${NC} $merged merged, $rebased rebased"
    fi

    if [[ $merged -gt 0 && $rebased -eq 0 && -z "$conflict" ]]; then
        echo "All branches merged. Run: git dispatch reset --force"
    fi

    if [[ -n "$conflict" ]]; then
        warn "Stopped at $conflict due to conflict."
        warn "Resolve manually, then re-run: git dispatch restack"
        return 1
    fi

    if [[ $rebased -gt 0 ]] && ! $dry_run; then
        echo "Next: git dispatch push --force"
    fi
}

# ---------- push ----------

cmd_push() {
    local source_arg="" dry_run=false branch_filter="" force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --branch)  branch_filter="$2"; shift 2 ;;
            --force)   force=true; shift ;;
            -*)        die "Unknown flag: $1" ;;
            *)         source_arg="$1"; shift ;;
        esac
    done

    local source
    source=$(resolve_source "$source_arg")

    local -a ordered=()
    while IFS= read -r c; do
        [[ -n "$c" ]] && ordered+=("$c")
    done < <(find_dispatch_tasks "$source" | order_by_stack)

    [[ ${#ordered[@]} -gt 0 ]] || die "No dispatch tasks found for $source"

    if [[ -n "$branch_filter" ]]; then
        local found=false
        for c in "${ordered[@]}"; do
            [[ "$c" == "$branch_filter" ]] && { found=true; break; }
        done
        $found || die "Branch '$branch_filter' not found in dispatch stack"
        ordered=("$branch_filter")
    fi

    local -a push_args=(-u origin)
    $force && push_args+=(--force-with-lease)

    echo -e "${CYAN}Source:${NC} $source"
    echo ""

    for task_branch in "${ordered[@]}"; do
        # Skip if local matches remote (nothing to push)
        local local_head remote_head
        local_head=$(git rev-parse "$task_branch" 2>/dev/null || true)
        remote_head=$(git rev-parse "origin/$task_branch" 2>/dev/null || true)
        if [[ -n "$remote_head" && "$local_head" == "$remote_head" ]] && ! $force; then
            echo "  $task_branch: up to date"
            continue
        fi

        if $dry_run; then
            echo -e "  ${YELLOW}[dry-run]${NC} git push ${push_args[*]} $task_branch"
        else
            git push "${push_args[@]}" "$task_branch" 2>/dev/null && \
                info "  Pushed $task_branch" || \
                warn "  Push failed for $task_branch"
        fi
    done
}

# ---------- pr ----------

cmd_pr() {
    local source_arg="" push=false dry_run=false
    local branch_filter="" custom_title="" custom_body=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --push)    push=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            --branch)  branch_filter="$2"; shift 2 ;;
            --title)   custom_title="$2"; shift 2 ;;
            --body)    custom_body="$2"; shift 2 ;;
            -*)        die "Unknown flag: $1" ;;
            *)         source_arg="$1"; shift ;;
        esac
    done

    local source
    source=$(resolve_source "$source_arg")

    local -a ordered=()
    while IFS= read -r c; do
        [[ -n "$c" ]] && ordered+=("$c")
    done < <(find_dispatch_tasks "$source" | order_by_stack)

    [[ ${#ordered[@]} -gt 0 ]] || die "No dispatch tasks found for $source"

    if ! $dry_run && ! command -v gh &>/dev/null; then
        die "gh CLI is required. Install: https://cli.github.com"
    fi

    # Filter to single branch if --branch is set
    if [[ -n "$branch_filter" ]]; then
        local found=false
        for c in "${ordered[@]}"; do
            if [[ "$c" == "$branch_filter" ]]; then
                found=true
                break
            fi
        done
        $found || die "Branch '$branch_filter' not found in dispatch stack"
        ordered=("$branch_filter")
    fi

    echo -e "${CYAN}Source:${NC} $source"
    echo ""

    for task_branch in "${ordered[@]}"; do
        local parent
        parent=$(find_stack_parent "$task_branch")

        # PR title: custom or first commit subject
        local title
        if [[ -n "$custom_title" ]]; then
            title="$custom_title"
        else
            title=$(git log --reverse --format="%s" "${parent}..${task_branch}" | head -1)
        fi

        # PR body: custom or empty
        local body=""
        if [[ -n "$custom_body" ]]; then
            body="$custom_body"
        fi

        if $push; then
            if $dry_run; then
                echo -e "  ${YELLOW}[dry-run]${NC} git push -u origin $task_branch"
            else
                git push -u origin "$task_branch" 2>/dev/null || warn "  Push failed for $task_branch"
            fi
        fi

        if $dry_run; then
            echo -e "  ${YELLOW}[dry-run]${NC} gh pr create --base $parent --head $task_branch --title \"$title\" --body \"$body\""
        else
            local url
            url=$(gh pr create --base "$parent" --head "$task_branch" --title "$title" --body "$body" 2>&1) || {
                warn "  PR creation failed for $task_branch: $url"
                continue
            }
            info "  Created PR: $url"
        fi
    done
}

# ---------- reset ----------

cmd_reset() {
    local source_arg="" delete_branches=false force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --branches) delete_branches=true; shift ;;
            --force)    force=true; shift ;;
            -*)         die "Unknown flag: $1" ;;
            *)          source_arg="$1"; shift ;;
        esac
    done

    local source
    source=$(resolve_source "$source_arg")

    local -a tasks=()
    while IFS= read -r c; do
        [[ -n "$c" ]] && tasks+=("$c")
    done < <(find_dispatch_tasks "$source")

    [[ ${#tasks[@]} -gt 0 ]] || die "No dispatch tasks found for $source"

    echo -e "${CYAN}Source:${NC} $source"
    echo "Tasks: ${tasks[*]}"
    if $delete_branches; then
        warn "Will also delete task branches"
    fi

    if ! $force; then
        echo ""
        read -p "Reset dispatch metadata? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi

    # Collect parent-task pairs before modifying config
    local -a parents=()
    for task in "${tasks[@]}"; do
        parents+=("$(find_stack_parent "$task")")
    done

    for i in "${!tasks[@]}"; do
        local task="${tasks[$i]}"
        local parent="${parents[$i]}"

        # Remove dispatchsource from task
        git config --unset "branch.${task}.dispatchsource" 2>/dev/null || true

        # Remove task from parent's dispatchtasks
        if [[ -n "$parent" ]]; then
            stack_remove "$task" "$parent"
        fi

        # Remove any dispatchtasks on this task itself
        git config --unset-all "branch.${task}.dispatchtasks" 2>/dev/null || true

        if $delete_branches; then
            local cur
            cur=$(current_branch)
            if [[ "$cur" == "$task" ]]; then
                warn "  Skipping delete of $task (currently checked out)"
            else
                git branch -D "$task" 2>/dev/null || warn "  Could not delete $task"
                info "  Deleted $task"
            fi
        else
            info "  Cleaned $task"
        fi
    done

    echo ""
    info "Reset complete."
}

# ---------- tree ----------

cmd_tree() {
    local branch="${1:-}"
    if [[ -z "$branch" ]]; then
        # Auto-detect: find root by walking dispatchsource or use current branch
        branch=$(current_branch)
        local source_ref
        source_ref=$(git config "branch.${branch}.dispatchsource" 2>/dev/null || true)
        if [[ -n "$source_ref" ]]; then
            # Walk up to find the base
            local parent
            parent=$(git for-each-ref --format='%(refname:short)' refs/heads/ | while read -r b; do
                if get_tasks "$b" | grep -Fxq "$branch"; then echo "$b"; break; fi
            done)
            # Find root of the stack
            while [[ -n "$parent" ]]; do
                local gp
                gp=$(git for-each-ref --format='%(refname:short)' refs/heads/ | while read -r b; do
                    if get_tasks "$b" | grep -Fxq "$parent"; then echo "$b"; break; fi
                done)
                [[ -z "$gp" ]] && break
                parent="$gp"
            done
            [[ -n "$parent" ]] && branch="$parent"
        fi
    fi
    stack_show_all "$branch"
}

# ---------- hook install ----------

cmd_hook_install() {
    local hook_dir
    hook_dir=$(git config core.hooksPath 2>/dev/null || echo "")
    if [[ -z "$hook_dir" ]]; then
        hook_dir="$(git rev-parse --git-dir)/hooks"
    elif [[ "$hook_dir" != /* ]]; then
        # Resolve relative paths (e.g. ".husky") against repo root
        hook_dir="$(git rev-parse --show-toplevel)/$hook_dir"
    fi
    mkdir -p "$hook_dir"
    cp "$SCRIPT_DIR/hooks/prepare-commit-msg" "$hook_dir/prepare-commit-msg"
    chmod +x "$hook_dir/prepare-commit-msg"
    cp "$SCRIPT_DIR/hooks/commit-msg" "$hook_dir/commit-msg"
    chmod +x "$hook_dir/commit-msg"
    info "Installed prepare-commit-msg hook to $hook_dir/prepare-commit-msg"
    cp "$SCRIPT_DIR/hooks/post-merge" "$hook_dir/post-merge"
    chmod +x "$hook_dir/post-merge"
    info "Installed commit-msg hook to $hook_dir/commit-msg"
    info "Installed post-merge hook to $hook_dir/post-merge"
}

# ---------- help ----------

cmd_help() {
    cat <<'HELP'
git-dispatch: Split a source branch into stacked task branches and keep them in sync.

WORKFLOW
  1. Code on a source branch, tagging each commit with a Task-Id trailer:
       git commit -m "Add feature X" --trailer "Task-Id=3"

  2. Split into stacked branches:
       git dispatch split source/feature --base master --name feat/feature

  3. Continue working on source or task branches, then sync:
       git dispatch sync                                      # auto-detect source, sync all
       git dispatch sync source/feature                       # explicit source, sync all
       git dispatch sync source/feature feat/feature/3       # sync one task

  4. View the stack:
       git dispatch tree

COMMANDS
  split <source> --name <prefix> [--base <base>] [--dry-run]
      Parse Task-Id trailers from <source>, group commits by task, create stacked
      branches named <prefix>/<task-id>. Each branch stacks on the previous.

  sync [source] [task-branch]
      Bidirectional sync using git cherry (patch-id comparison).
      Source->task: new commits for the task appear in the task branch.
      Task->source: direct fixes on task appear back in the source (Task-Id added).
      If <source> is omitted, auto-detects from current branch context.

  status [source]
      Show pending sync counts per task branch without applying changes.
      Quick check before running sync.

  push [source] [--branch <name>] [--force] [--dry-run]
      Push task branches to origin. Walks the dispatch stack in order.
      --branch targets a single branch instead of all tasks.
      --force uses --force-with-lease (safe after sync rewrites history).
      --dry-run shows what would be pushed without doing it.

  pr [source] [--branch <name>] [--title <title>] [--body <body>] [--push] [--dry-run]
      Create stacked PRs with correct --base flags via gh CLI.
      Walks the dispatch stack in order. --push pushes branches first.
      --branch targets a single branch instead of all tasks.
      --title and --body override the auto-generated PR title and empty body.
      --dry-run shows what would be created without doing it.

  resolve
      Convert a merge commit (HEAD) on a task branch into a regular commit
      with Task-Id trailer. Use after merging master to resolve conflicts.

  restack [source] [--dry-run]
      Rebase stack onto updated base after merge. Walks the stack in order;
      merged branches are skipped, remaining branches are rebased onto the
      updated base. Stops on conflict. Use after a PR is merged to master.
      --dry-run shows what would happen without modifying branches.

  reset [source] [--branches] [--force]
      Clean up dispatch metadata from git config.
      --branches also deletes the task branches.
      --force skips confirmation prompt.

  tree [branch]
      Show the dispatch stack hierarchy.

  hook install
      Install hooks: prepare-commit-msg (auto-carries Task-Id from previous
      commit) and commit-msg (rejects commits without Task-Id).

  help
      Show this message.

TRAILERS
  Task-Id (required):
    git commit -m "message" --trailer "Task-Id=3"

  Task-Order (optional): Controls stack position during split. Tasks with
  Task-Order sort first (ascending), unordered tasks follow in commit order.
    git commit -m "fix" --trailer "Task-Id=3" --trailer "Task-Order=1"

  The hooks (install with `git dispatch hook install`) auto-carry Task-Id from
  the previous commit and reject commits without a Task-Id trailer.
HELP
}

# ---------- main ----------

main() {
    [[ $# -gt 0 ]] || { cmd_help; exit 0; }

    local cmd="$1"; shift
    case "$cmd" in
        split)        cmd_split "$@" ;;
        sync)         cmd_sync "$@" ;;
        status)       cmd_status "$@" ;;
        push)         cmd_push "$@" ;;
        pr)           cmd_pr "$@" ;;
        reset)        cmd_reset "$@" ;;
        resolve)      cmd_resolve "$@" ;;
        restack)      cmd_restack "$@" ;;
        tree)         cmd_tree "$@" ;;
        hook)
            [[ "${1:-}" == "install" ]] || die "Usage: git dispatch hook install"
            shift; cmd_hook_install "$@" ;;
        help|--help|-h) cmd_help ;;
        *)            die "Unknown command: $cmd. Run 'git dispatch help' for usage." ;;
    esac
}

main "$@"
