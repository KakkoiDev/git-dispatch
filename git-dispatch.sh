#!/bin/bash
set -euo pipefail

# git-dispatch: Split a POC branch into stacked task branches and keep them in sync.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

STATE_FILE=".git/dispatch-state.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- helpers ----------

die() { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }
info() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }

current_branch() { git symbolic-ref --short HEAD 2>/dev/null; }

# Get children of a branch from git config (dispatch stack)
get_children() {
    local branch="$1"
    git config --get-all "branch.${branch}.dispatchchildren" 2>/dev/null || true
}

# Add a child branch to the dispatch stack
stack_add() {
    local child="$1" parent="$2"
    if get_children "$parent" | grep -q "^${child}$"; then
        return 0
    fi
    git config --add "branch.${parent}.dispatchchildren" "$child"
}

# Remove a child from the dispatch stack
stack_remove() {
    local child="$1" parent="$2"
    local children
    children=$(get_children "$parent" | grep -v "^${child}$" || true)
    git config --unset-all "branch.${parent}.dispatchchildren" 2>/dev/null || true
    if [[ -n "$children" ]]; then
        while IFS= read -r c; do
            git config --add "branch.${parent}.dispatchchildren" "$c"
        done <<< "$children"
    fi
}

# Recursive tree display
stack_show_all() {
    local branch="$1" prefix="${2:-}" child_prefix="${3:-}"
    echo "${prefix}${branch}"
    local children
    children=$(get_children "$branch")
    [[ -z "$children" ]] && return
    local -a arr
    while IFS= read -r line; do arr+=("$line"); done <<< "$children"
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
                    "${git_cmd[@]}" rebase -i "$parent" --quiet 2>/dev/null || true
                "${git_cmd[@]}" commit --amend --no-edit --trailer "Task-Id=$task_id" --quiet
                "${git_cmd[@]}" rebase --continue --quiet 2>/dev/null || true
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

    if [[ -n "$wt" ]]; then
        git -C "$wt" cherry-pick -x "${hashes[@]}"
    else
        local orig
        orig=$(current_branch)
        git checkout "$branch" --quiet
        git cherry-pick -x "${hashes[@]}"
        git checkout "$orig" --quiet
    fi
}

# Save state for conflict recovery
state_save() {
    local cmd="$1"; shift
    printf '{"command":"%s","args":%s}\n' "$cmd" "$(printf '%s\n' "$@" | jq -R . | jq -s .)" > "$STATE_FILE"
}

state_clear() { rm -f "$STATE_FILE"; }

state_load() {
    [[ -f "$STATE_FILE" ]] || die "No dispatch state found. Nothing to continue."
    cat "$STATE_FILE"
}

# ---------- split ----------

cmd_split() {
    local poc="" base="master" name="" dry_run=false continuing=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base)      base="$2"; shift 2 ;;
            --name)      name="$2"; shift 2 ;;
            --dry-run)   dry_run=true; shift ;;
            --continue)  continuing=true; shift ;;
            -*)          die "Unknown flag: $1" ;;
            *)           poc="$1"; shift ;;
        esac
    done

    [[ -n "$poc" ]]  || die "Usage: git dispatch split <poc-branch> --name <prefix> [--base <base>]"
    [[ -n "$name" ]] || die "Missing --name flag (branch prefix)"

    git rev-parse --verify "$poc" >/dev/null 2>&1  || die "Branch '$poc' does not exist"
    git rev-parse --verify "$base" >/dev/null 2>&1 || die "Base '$base' does not exist"

    # Parse trailer-tagged commits into temp file: "hash task-id" per line
    local commit_file
    commit_file=$(mktemp)
    trap "rm -f '$commit_file'" RETURN

    git log --reverse --format="%H %(trailers:key=Task-Id,valueonly)" "$base..$poc" \
        | grep -v '^$' > "$commit_file"

    [[ -s "$commit_file" ]] || die "No commits found between $base and $poc"

    # Validate all commits have Task-Id
    while IFS= read -r line; do
        local hash="${line%% *}"
        local task="${line#* }"
        task="${task## }"
        [[ -z "$task" || "$task" == "$hash" ]] && die "Commit $hash has no Task-Id trailer"
    done < "$commit_file"

    # Ordered unique task ids (first appearance order)
    local -a task_ids=()
    while IFS= read -r tid; do
        task_ids+=("$tid")
    done < <(awk '{print $2}' "$commit_file" | awk '!seen[$0]++')

    echo -e "${CYAN}POC:${NC}  $poc"
    echo -e "${CYAN}Base:${NC} $base"
    echo -e "${CYAN}Tasks:${NC} ${task_ids[*]}"
    echo ""

    local prev_branch="$base"
    for tid in "${task_ids[@]}"; do
        local branch_name="${name}/task-${tid}"
        # Collect hashes for this task
        local -a hashes=()
        while IFS= read -r h; do
            hashes+=("$h")
        done < <(awk -v t="$tid" '$2 == t {print $1}' "$commit_file")

        if $dry_run; then
            echo -e "  ${YELLOW}[dry-run]${NC} $branch_name  (${#hashes[@]} commits from $prev_branch)"
        else
            git branch "$branch_name" "$prev_branch" 2>/dev/null || die "Branch '$branch_name' already exists"
            cherry_pick_into "$branch_name" "${hashes[@]}"
            stack_add "$branch_name" "$prev_branch"
            git config "branch.${branch_name}.dispatchpoc" "$poc"
            info "  Created $branch_name (${#hashes[@]} commits)"
        fi
        prev_branch="$branch_name"
    done

    echo ""
    if ! $dry_run; then
        cmd_tree "$base"
    fi
}

# ---------- sync ----------

# Resolve POC branch from current context
# Priority: explicit arg > current branch is POC > current branch is child (read dispatchpoc)
resolve_poc() {
    local explicit="$1"
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
        return
    fi

    local cur
    cur=$(current_branch)

    # Is current branch a POC for any child?
    local is_poc
    is_poc=$(git for-each-ref --format='%(refname:short)' refs/heads/ | while read -r b; do
        local cpoc
        cpoc=$(git config "branch.${b}.dispatchpoc" 2>/dev/null || true)
        if [[ "$cpoc" == "$cur" ]]; then echo "$cur"; break; fi
    done)
    if [[ -n "$is_poc" ]]; then
        echo "$is_poc"
        return
    fi

    # Is current branch a child? Read its dispatchpoc
    local cpoc
    cpoc=$(git config "branch.${cur}.dispatchpoc" 2>/dev/null || true)
    if [[ -n "$cpoc" ]]; then
        echo "$cpoc"
        return
    fi

    die "Cannot detect POC branch. Run from a POC or child branch, or pass it explicitly."
}

# Find all dispatch children for a given POC
find_dispatch_children() {
    local poc="$1"
    local -a found=()

    while IFS= read -r ref; do
        local bname="${ref#refs/heads/}"
        local cpoc
        cpoc=$(git config "branch.${bname}.dispatchpoc" 2>/dev/null || true)
        [[ "$cpoc" == "$poc" ]] && found+=("$bname")
    done < <(git for-each-ref --format='%(refname)' refs/heads/)

    printf '%s\n' "${found[@]}"
}

cmd_sync() {
    local poc_arg="" child="" continuing=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --continue) continuing=true; shift ;;
            -*)         die "Unknown flag: $1" ;;
            *)
                if [[ -z "$poc_arg" ]]; then poc_arg="$1"
                elif [[ -z "$child" ]]; then child="$1"
                fi
                shift ;;
        esac
    done

    local poc
    poc=$(resolve_poc "$poc_arg")

    # Resolve child branches to sync
    local -a targets=()
    if [[ -n "$child" ]]; then
        targets=("$child")
    else
        while IFS= read -r c; do
            [[ -n "$c" ]] && targets+=("$c")
        done < <(find_dispatch_children "$poc")
    fi

    [[ ${#targets[@]} -gt 0 ]] || die "No dispatch children found for $poc"

    echo -e "${CYAN}POC:${NC} $poc"
    echo ""

    for child_branch in "${targets[@]}"; do
        echo -e "${CYAN}Syncing:${NC} $child_branch"

        # Extract task-id from branch name (last segment after task-)
        local task_id="${child_branch##*/task-}"

        # POC → child: commits in POC for this task not yet in child
        local -a poc_to_child=()
        while IFS= read -r line; do
            [[ "$line" == +* ]] || continue
            local hash="${line:2:40}"
            # Check if this commit has matching Task-Id
            local tid
            tid=$(git log -1 --format="%(trailers:key=Task-Id,valueonly)" "$hash" | tr -d '[:space:]')
            [[ "$tid" == "$task_id" ]] && poc_to_child+=("$hash")
        done < <(git cherry -v "$child_branch" "$poc" 2>/dev/null || true)

        if [[ ${#poc_to_child[@]} -gt 0 ]]; then
            info "  POC → child: ${#poc_to_child[@]} commit(s)"
            cherry_pick_into "$child_branch" "${poc_to_child[@]}"
        else
            echo "  POC → child: up to date"
        fi

        # Child → POC: commits in child not yet in POC
        # First, amend any child commits missing Task-Id on the child branch itself
        local -a child_to_poc=()
        local needs_trailer=false
        while IFS= read -r line; do
            [[ "$line" == +* ]] || continue
            local hash="${line:2:40}"
            local tid
            tid=$(git log -1 --format="%(trailers:key=Task-Id,valueonly)" "$hash" | tr -d '[:space:]')
            if [[ "$tid" != "$task_id" ]]; then
                needs_trailer=true
            fi
            child_to_poc+=("$hash")
        done < <(git cherry -v "$poc" "$child_branch" 2>/dev/null || true)

        if [[ ${#child_to_poc[@]} -gt 0 ]]; then
            # Amend commits on child branch to add Task-Id before cherry-picking
            if $needs_trailer; then
                info "  Fixing Task-Id on child commits..."
                _amend_trailers_on_branch "$child_branch" "$task_id" "${child_to_poc[@]}"
                # Re-read hashes after rewrite
                child_to_poc=()
                while IFS= read -r line; do
                    [[ "$line" == +* ]] || continue
                    local hash="${line:2:40}"
                    child_to_poc+=("$hash")
                done < <(git cherry -v "$poc" "$child_branch" 2>/dev/null || true)
            fi
            info "  Child → POC: ${#child_to_poc[@]} commit(s)"
            cherry_pick_into "$poc" "${child_to_poc[@]}"
        else
            echo "  Child → POC: up to date"
        fi

        echo ""
    done
}

# ---------- tree ----------

cmd_tree() {
    local branch="${1:-}"
    if [[ -z "$branch" ]]; then
        # Auto-detect: find root by walking dispatchpoc or use current branch
        branch=$(current_branch)
        local poc
        poc=$(git config "branch.${branch}.dispatchpoc" 2>/dev/null || true)
        if [[ -n "$poc" ]]; then
            # Walk up to find the base
            local parent
            parent=$(git for-each-ref --format='%(refname:short)' refs/heads/ | while read -r b; do
                if get_children "$b" | grep -q "^${branch}$"; then echo "$b"; break; fi
            done)
            # Find root of the stack
            while [[ -n "$parent" ]]; do
                local gp
                gp=$(git for-each-ref --format='%(refname:short)' refs/heads/ | while read -r b; do
                    if get_children "$b" | grep -q "^${parent}$"; then echo "$b"; break; fi
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
    hook_dir="$(git rev-parse --git-dir)/hooks"
    mkdir -p "$hook_dir"
    cp "$SCRIPT_DIR/hooks/commit-msg" "$hook_dir/commit-msg"
    chmod +x "$hook_dir/commit-msg"
    info "Installed commit-msg hook to $hook_dir/commit-msg"
}

# ---------- help ----------

cmd_help() {
    cat <<'HELP'
git-dispatch: Split a POC branch into stacked task branches and keep them in sync.

WORKFLOW
  1. Code on a POC branch, tagging each commit with a Task-Id trailer:
       git commit -m "Add feature X" --trailer "Task-Id=3"

  2. Split into stacked branches:
       git dispatch split cyril/poc/feature --base master --name cyril/feat/feature

  3. Continue working on POC or child branches, then sync:
       git dispatch sync                                      # auto-detect POC, sync all
       git dispatch sync cyril/poc/feature                    # explicit POC, sync all
       git dispatch sync cyril/poc/feature child/task-3       # sync one child

  4. View the stack:
       git dispatch tree

COMMANDS
  split <poc> --name <prefix> [--base <base>] [--dry-run]
      Parse Task-Id trailers from <poc>, group commits by task, create stacked
      branches named <prefix>/task-N. Each branch stacks on the previous.

  sync [poc] [child-branch]
      Bidirectional sync using git cherry (patch-id comparison).
      POC→child: new commits for the task appear in the child branch.
      Child→POC: direct fixes on child appear back in the POC (Task-Id added).
      If <poc> is omitted, auto-detects from current branch context.

  tree [branch]
      Show the dispatch stack hierarchy.

  hook install
      Install commit-msg hook that enforces Task-Id trailer presence.

  help
      Show this message.

TRAILERS
  Commits use native git trailers for task linking:
    git commit -m "message" --trailer "Task-Id=3"

  The hook (install with `git dispatch hook install`) rejects commits without
  a Task-Id trailer.
HELP
}

# ---------- main ----------

main() {
    [[ $# -gt 0 ]] || { cmd_help; exit 0; }

    local cmd="$1"; shift
    case "$cmd" in
        split)        cmd_split "$@" ;;
        sync)         cmd_sync "$@" ;;
        tree)         cmd_tree "$@" ;;
        hook)
            [[ "${1:-}" == "install" ]] || die "Usage: git dispatch hook install"
            shift; cmd_hook_install "$@" ;;
        help|--help|-h) cmd_help ;;
        *)            die "Unknown command: $cmd. Run 'git dispatch help' for usage." ;;
    esac
}

main "$@"
