#!/bin/bash
set -euo pipefail

# git aliases with ! set GIT_DIR which overrides git -C; unset to fix worktree operations
unset GIT_DIR GIT_WORK_TREE

# git-dispatch: Create target branches from a source branch and keep them in sync.

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

# Get targets of a branch from git config
get_targets() {
    local branch="$1"
    git config --get-all "branch.${branch}.dispatchtargets" 2>/dev/null || true
}

# Add a target branch to the dispatch stack
stack_add() {
    local target_name="$1" parent="$2"
    if get_targets "$parent" | grep -Fxq "$target_name"; then
        return 0
    fi
    git config --add "branch.${parent}.dispatchtargets" "$target_name"
}

# Remove a target from the dispatch stack
stack_remove() {
    local target_name="$1" parent="$2"
    local targets
    targets=$(get_targets "$parent" | grep -Fxv "$target_name" || true)
    git config --unset-all "branch.${parent}.dispatchtargets" 2>/dev/null || true
    if [[ -n "$targets" ]]; then
        while IFS= read -r c; do
            git config --add "branch.${parent}.dispatchtargets" "$c"
        done <<< "$targets"
    fi
}

# Find worktree path for a branch (empty if none)
worktree_for_branch() {
    local branch="$1"
    git worktree list --porcelain | awk -v b="refs/heads/$branch" '
        /^worktree / { wt = substr($0, 10) }
        /^branch /   { if (substr($0, 8) == b) print wt }
    '
}

# Read dispatch config shorthand
_get_config() {
    local key="$1"
    git config "dispatch.${key}" 2>/dev/null || true
}

# Require dispatch init has been run
_require_init() {
    local base
    base=$(_get_config base)
    [[ -n "$base" ]] || die "Not initialized. Run: git dispatch init"
}

# Install hooks (prepare-commit-msg + commit-msg only)
_install_hooks() {
    local hook_dir
    hook_dir=$(git config core.hooksPath 2>/dev/null || echo "")
    if [[ -z "$hook_dir" ]]; then
        hook_dir="$(git rev-parse --git-dir)/hooks"
    elif [[ "$hook_dir" != /* ]]; then
        hook_dir="$(git rev-parse --show-toplevel)/$hook_dir"
    fi
    mkdir -p "$hook_dir"
    cp "$SCRIPT_DIR/hooks/prepare-commit-msg" "$hook_dir/prepare-commit-msg"
    chmod +x "$hook_dir/prepare-commit-msg"
    cp "$SCRIPT_DIR/hooks/commit-msg" "$hook_dir/commit-msg"
    chmod +x "$hook_dir/commit-msg"
    info "Installed hooks to $hook_dir"
}

# Check if a branch's content has been merged (e.g. squash-merged) into base
_is_content_merged() {
    local branch_tip="$1" base_ref="$2"
    local mb
    mb=$(git merge-base "$base_ref" "$branch_tip" 2>/dev/null) || return 1
    local changed_files
    changed_files=$(git diff --name-only "$mb" "$branch_tip" 2>/dev/null)
    [[ -z "$changed_files" ]] && return 0
    git diff --quiet "$base_ref" "$branch_tip" -- $changed_files 2>/dev/null
}

# Return 0 if a commit's resulting file content is already present on a branch.
# This treats "same final content, different history/patch-id" as semantically synced.
_commit_effect_in_branch() {
    local commit="$1" branch="$2"
    local file

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        local commit_obj="" branch_obj=""
        commit_obj=$(git rev-parse "${commit}:${file}" 2>/dev/null || true)
        branch_obj=$(git rev-parse "${branch}:${file}" 2>/dev/null || true)
        if [[ "$commit_obj" != "$branch_obj" ]]; then
            return 1
        fi
    done < <(git diff-tree --no-commit-id --name-only -r "$commit")

    return 0
}

# Return 0 if cherry-picking commit onto branch would result in no staged changes.
_would_cherry_pick_be_empty_on_branch() {
    local commit="$1" branch="$2"
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/git-dispatch-empty-check.XXXXXX")

    if ! git worktree add --detach -q "$tmpdir" "$branch" >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        return 1
    fi

    local -a g=(git -C "$tmpdir")
    local is_empty=1

    if "${g[@]}" cherry-pick --no-commit "$commit" >/dev/null 2>&1; then
        if "${g[@]}" diff --cached --quiet; then
            is_empty=0
        fi
        "${g[@]}" reset --hard --quiet >/dev/null 2>&1 || true
    else
        if "${g[@]}" rev-parse --verify CHERRY_PICK_HEAD &>/dev/null && "${g[@]}" diff --cached --quiet; then
            is_empty=0
        fi
        "${g[@]}" cherry-pick --abort >/dev/null 2>&1 || "${g[@]}" reset --hard --quiet >/dev/null 2>&1 || true
    fi

    git worktree remove --force "$tmpdir" >/dev/null 2>&1 || rm -rf "$tmpdir"
    return $is_empty
}

# Return 0 if commit should be treated as already integrated in branch.
_commit_semantically_in_branch() {
    local commit="$1" branch="$2"
    _commit_effect_in_branch "$commit" "$branch" && return 0
    _would_cherry_pick_be_empty_on_branch "$commit" "$branch" && return 0
    return 1
}

# Get files touched by commits with a specific Target-Id on a branch.
_target_id_files() {
    local base="$1" branch="$2" tid="$3"
    while IFS= read -r hash; do
        local ctid
        ctid=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" "$hash" | tr -d '[:space:]')
        [[ "$ctid" == "$tid" ]] && git diff-tree --no-commit-id --name-only -r "$hash" 2>/dev/null
    done < <(git log --format="%H" "$base..$branch")
}

# Check if source and target have diverged content (not just different SHAs).
# Only checks files from commits with the matching Target-Id (avoids false
# positives from generated files or other tasks' changes in independent mode).
# Returns 0 if content actually differs, 1 if same content (different commits only).
_target_content_diverged() {
    local source="$1" target_branch="$2" base="$3" tid="$4"
    local target_files
    target_files=$(_target_id_files "$base" "$target_branch" "$tid" | sort -u)
    [[ -n "$target_files" ]] || return 1
    # shellcheck disable=SC2086
    git diff --quiet "$source" "$target_branch" -- $target_files 2>/dev/null && return 1
    return 0
}

# Best-effort PR detection. Outputs "branch pr_number" lines. Returns 1 if gh unavailable.
_get_open_prs() {
    local source="$1"
    if ! command -v gh &>/dev/null; then
        return 1
    fi
    if ! gh auth status &>/dev/null 2>&1; then
        return 1
    fi
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        local pr_num
        pr_num=$(gh pr list --head "$target" --state open --json number --jq '.[0].number' 2>/dev/null)
        [[ -n "$pr_num" ]] && echo "$target $pr_num"
    done < <(find_dispatch_targets "$source")
}

# Show conflicted files and diff for any conflict (cherry-pick, merge, rebase)
_show_conflict_diff() {
    local wt_path="$1"
    local -a gcmd=(git)
    [[ -n "$wt_path" ]] && gcmd=(git -C "$wt_path")

    local conflicted
    conflicted=$("${gcmd[@]}" diff --name-only --diff-filter=U 2>/dev/null)
    if [[ -n "$conflicted" ]]; then
        warn "Conflicted files:"
        echo "$conflicted" | while IFS= read -r f; do echo "  $f"; done
        echo ""
        "${gcmd[@]}" diff 2>/dev/null || true
    fi
}

# Display conflict details for a failed cherry-pick
_show_conflict_details() {
    local wt_path="$1" failing_hash="$2" applied="$3" total="$4"

    echo ""
    warn "Conflict on commit $((applied + 1))/$total: $(git log -1 --oneline "$failing_hash")"
    _show_conflict_diff "$wt_path"
}

# Handle cherry-pick conflict: show details, abort or leave for resolution
_handle_cherry_pick_conflict() {
    local wt_path="$1" failing_hash="$2" applied="$3" total="$4" resolve="$5" branch="$6"
    shift 6
    local remaining_hashes=("$@")
    local -a gcmd=(git)
    [[ -n "$wt_path" ]] && gcmd=(git -C "$wt_path")

    _show_conflict_details "$wt_path" "$failing_hash" "$applied" "$total"

    if [[ "$resolve" == "true" ]]; then
        echo ""
        warn "Resolve conflicts, then run: git cherry-pick --continue"
        if [[ ${#remaining_hashes[@]} -gt 0 ]]; then
            warn "Remaining commits to cherry-pick after resolution:"
            for rh in "${remaining_hashes[@]}"; do
                echo "  $(git log -1 --oneline "$rh")"
            done
        fi
    else
        "${gcmd[@]}" cherry-pick --abort 2>/dev/null || "${gcmd[@]}" reset --merge 2>/dev/null || true
        echo ""
        warn "Aborted. Re-run with --resolve to keep conflict active for manual resolution."
    fi
}

# Cherry-pick into a branch, adding Target-Id to commits that lack them
_cherry_pick_with_trailers() {
    local resolve="$1" branch="$2" target_id="$3"; shift 3
    local hashes=("$@")
    local wt
    wt=$(worktree_for_branch "$branch")
    local -a git_cmd=(git)
    [[ -n "$wt" ]] && git_cmd=(git -C "$wt")

    local stashed=false
    DISPATCH_LAST_PICKED=0
    DISPATCH_LAST_SKIPPED=0

    if [[ -z "$wt" ]]; then
        local orig
        orig=$(current_branch)
        # Stash everything (including untracked) before checkout to avoid conflicts
        if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
            warn "Uncommitted changes detected. Stash first with: git stash -u"
            git stash push --include-untracked --quiet -m "git-dispatch: auto-stash before cherry-pick"
            stashed=true
        fi
        if ! git checkout "$branch" --quiet 2>/dev/null; then
            if $stashed; then git stash pop --quiet; fi
            die "Cannot checkout $branch. Check for stale worktrees or conflicting files."
        fi
    else
        if ! "${git_cmd[@]}" diff --quiet 2>/dev/null || ! "${git_cmd[@]}" diff --cached --quiet 2>/dev/null; then
            "${git_cmd[@]}" stash push --quiet -m "git-dispatch: auto-stash before cherry-pick"
            stashed=true
        fi
    fi

    for (( _idx=0; _idx < ${#hashes[@]}; _idx++ )); do
        local hash="${hashes[$_idx]}"
        local tid
        tid=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" "$hash" | tr -d '[:space:]')
        if [[ "$tid" == "$target_id" ]]; then
            if ! "${git_cmd[@]}" cherry-pick -x "$hash"; then
                if "${git_cmd[@]}" rev-parse --verify CHERRY_PICK_HEAD &>/dev/null; then
                    if "${git_cmd[@]}" diff --cached --quiet; then
                        warn "  Skipping empty cherry-pick: $("${git_cmd[@]}" log -1 --oneline "$hash")"
                        "${git_cmd[@]}" cherry-pick --skip
                        DISPATCH_LAST_SKIPPED=$((DISPATCH_LAST_SKIPPED + 1))
                        continue
                    fi
                fi
                _handle_cherry_pick_conflict "${wt:-}" "$hash" "$_idx" "${#hashes[@]}" "$resolve" "$branch" "${hashes[@]:$((_idx+1))}"
                if [[ "$resolve" != "true" ]]; then
                    if $stashed; then "${git_cmd[@]}" stash pop --quiet; fi
                    if [[ -z "$wt" ]]; then git checkout "$orig" --quiet; fi
                fi
                exit 1
            fi
            DISPATCH_LAST_PICKED=$((DISPATCH_LAST_PICKED + 1))
        else
            if ! "${git_cmd[@]}" cherry-pick --no-commit "$hash"; then
                if "${git_cmd[@]}" rev-parse --verify CHERRY_PICK_HEAD &>/dev/null; then
                    if "${git_cmd[@]}" diff --cached --quiet; then
                        warn "  Skipping empty cherry-pick: $("${git_cmd[@]}" log -1 --oneline "$hash")"
                        "${git_cmd[@]}" cherry-pick --skip 2>/dev/null || "${git_cmd[@]}" reset HEAD --quiet
                        continue
                    fi
                fi
                _handle_cherry_pick_conflict "${wt:-}" "$hash" "$_idx" "${#hashes[@]}" "$resolve" "$branch" "${hashes[@]:$((_idx+1))}"
                if [[ "$resolve" != "true" ]]; then
                    if $stashed; then "${git_cmd[@]}" stash pop --quiet; fi
                    if [[ -z "$wt" ]]; then git checkout "$orig" --quiet; fi
                fi
                exit 1
            fi
            # Some no-op picks can succeed with --no-commit but stage nothing.
            # Treat them as empty cherry-picks instead of failing on commit.
            if "${git_cmd[@]}" diff --cached --quiet; then
                warn "  Skipping empty cherry-pick: $("${git_cmd[@]}" log -1 --oneline "$hash")"
                if "${git_cmd[@]}" rev-parse --verify CHERRY_PICK_HEAD &>/dev/null; then
                    "${git_cmd[@]}" cherry-pick --skip 2>/dev/null || "${git_cmd[@]}" reset HEAD --quiet
                fi
                DISPATCH_LAST_SKIPPED=$((DISPATCH_LAST_SKIPPED + 1))
                continue
            fi
            local msg
            msg=$(git log -1 --format="%B" "$hash")
            if ! "${git_cmd[@]}" commit -m "$msg" --trailer "Target-Id=$target_id" --quiet; then
                if "${git_cmd[@]}" diff --cached --quiet; then
                    warn "  Skipping empty cherry-pick: $("${git_cmd[@]}" log -1 --oneline "$hash")"
                    if "${git_cmd[@]}" rev-parse --verify CHERRY_PICK_HEAD &>/dev/null; then
                        "${git_cmd[@]}" cherry-pick --skip 2>/dev/null || "${git_cmd[@]}" reset HEAD --quiet
                    fi
                    DISPATCH_LAST_SKIPPED=$((DISPATCH_LAST_SKIPPED + 1))
                    continue
                fi
                "${git_cmd[@]}" cherry-pick --abort 2>/dev/null || true
                if $stashed; then "${git_cmd[@]}" stash pop --quiet; fi
                if [[ -z "$wt" ]]; then git checkout "$orig" --quiet; fi
                die "Cherry-pick into $branch failed on $hash while creating commit. Resolve manually."
            fi
            DISPATCH_LAST_PICKED=$((DISPATCH_LAST_PICKED + 1))
        fi
    done

    if $stashed; then "${git_cmd[@]}" stash pop --quiet; fi
    if [[ -z "$wt" ]]; then git checkout "$orig" --quiet; fi
}

# Cherry-pick into a branch, worktree-aware
cherry_pick_into() {
    local resolve="$1" branch="$2"; shift 2
    local hashes=("$@")
    local wt
    wt=$(worktree_for_branch "$branch")
    local -a git_cmd=(git)
    [[ -n "$wt" ]] && git_cmd=(git -C "$wt")

    if [[ -z "$wt" ]]; then
        local orig
        orig=$(current_branch)
        local checkout_err
        if ! checkout_err=$(git checkout "$branch" --quiet 2>&1); then
            die "Cannot checkout $branch: $checkout_err"
        fi
    fi

    local stashed=false
    if ! "${git_cmd[@]}" diff --quiet 2>/dev/null || ! "${git_cmd[@]}" diff --cached --quiet 2>/dev/null; then
        "${git_cmd[@]}" stash push --quiet -m "git-dispatch: auto-stash before cherry-pick"
        stashed=true
    fi

    for (( _idx=0; _idx < ${#hashes[@]}; _idx++ )); do
        local hash="${hashes[$_idx]}"
        if ! "${git_cmd[@]}" cherry-pick -x "$hash"; then
            if "${git_cmd[@]}" rev-parse --verify CHERRY_PICK_HEAD &>/dev/null; then
                if "${git_cmd[@]}" diff --cached --quiet; then
                    warn "  Skipping empty cherry-pick: $("${git_cmd[@]}" log -1 --oneline "$hash")"
                    "${git_cmd[@]}" cherry-pick --skip
                    continue
                fi
            fi
            _handle_cherry_pick_conflict "${wt:-}" "$hash" "$_idx" "${#hashes[@]}" "$resolve" "$branch" "${hashes[@]:$((_idx+1))}"
            if [[ "$resolve" != "true" ]]; then
                if $stashed; then "${git_cmd[@]}" stash pop --quiet; fi
                if [[ -z "$wt" ]]; then git checkout "$orig" --quiet; fi
            fi
            exit 1
        fi
    done

    if $stashed; then "${git_cmd[@]}" stash pop --quiet; fi
    if [[ -z "$wt" ]]; then git checkout "$orig" --quiet; fi
}

# Resolve source branch: current branch or from dispatchsource
resolve_source() {
    local explicit="$1"
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
        return
    fi
    local cur
    cur=$(current_branch)
    # Is current branch a source for any target?
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
    # Is current branch a target? Read its dispatchsource
    local csource
    csource=$(git config "branch.${cur}.dispatchsource" 2>/dev/null || true)
    if [[ -n "$csource" ]]; then
        echo "$csource"
        return
    fi
    # Is dispatch initialized? Current branch is the source (no targets exist yet)
    local dispatch_base
    dispatch_base=$(_get_config base)
    if [[ -n "$dispatch_base" && "$cur" != "$dispatch_base" ]]; then
        echo "$cur"
        return
    fi
    die "Cannot detect source branch. Run from a source or target branch."
}

# Find all dispatch targets for a given source
find_dispatch_targets() {
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

# Order targets by walking the dispatch stack hierarchy
order_by_stack() {
    local -a targets=()
    while IFS= read -r t; do [[ -n "$t" ]] && targets+=("$t"); done
    [[ ${#targets[@]} -gt 0 ]] || return 0

    # Find roots: targets whose parent is not itself a target
    local -a roots=()
    local base=""
    for target in "${targets[@]}"; do
        local parent
        parent=$(find_stack_parent "$target")
        local parent_is_target=false
        for c in "${targets[@]}"; do
            [[ "$c" == "$parent" ]] && { parent_is_target=true; break; }
        done
        if ! $parent_is_target; then
            base="$parent"
            roots+=("$target")
        fi
    done

    if [[ -z "$base" ]]; then
        printf '%s\n' "${targets[@]}"
        return
    fi

    # BFS walk: print roots, then their children, etc.
    local -a queue=("${roots[@]}")
    local -a visited=()
    while [[ ${#queue[@]} -gt 0 ]]; do
        local current="${queue[0]}"
        queue=("${queue[@]:1}")
        echo "$current"
        visited+=("$current")
        for c in "${targets[@]}"; do
            # Skip already visited
            local seen=false
            for v in "${visited[@]}"; do [[ "$v" == "$c" ]] && { seen=true; break; }; done
            $seen && continue
            if get_targets "$current" | grep -Fxq "$c"; then
                queue+=("$c")
            fi
        done
    done
}

# Find the parent branch in the dispatch stack for a given branch
find_stack_parent() {
    local branch="$1"
    git for-each-ref --format='%(refname:short)' refs/heads/ | while read -r b; do
        if get_targets "$b" | grep -Fxq "$branch"; then
            echo "$b"
            break
        fi
    done
}

# Derive target branch name from configured pattern and target id
_target_branch_name() {
    local tid="$1"
    local pattern
    pattern=$(_get_config targetPattern)
    [[ -n "$pattern" ]] || die "Missing dispatch.targetPattern. Re-run: git dispatch init"
    [[ "$pattern" == *"{id}"* ]] || die "Invalid dispatch.targetPattern (missing {id})"
    echo "${pattern//\{id\}/$tid}"
}

# ---------- init ----------

cmd_init() {
    local base="" target_pattern="" mode="independent"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base)   base="$2"; shift 2 ;;
            --target-pattern) target_pattern="$2"; shift 2 ;;
            --mode)   mode="$2"; shift 2 ;;
            --force)  shift ;;
            -*)       die "Unknown flag: $1" ;;
            *)        die "Unexpected argument: $1" ;;
        esac
    done

    [[ "$mode" == "independent" || "$mode" == "stacked" ]] || \
        die "Invalid mode '$mode'. Use: independent or stacked"

    local source
    source=$(current_branch)
    [[ -n "$source" ]] || die "Not on a branch (detached HEAD)"

    if [[ -z "$base" || -z "$target_pattern" ]]; then
        die "Missing required flags: --base and --target-pattern. Example: --base origin/master --target-pattern \"user/feat/task-{id}\""
    fi
    [[ "$target_pattern" == *"{id}"* ]] || die "Invalid --target-pattern. Must include {id}"

    git rev-parse --verify "$base" &>/dev/null || die "Base branch '$base' does not exist"
    [[ "$source" != "$base" ]] || die "Cannot init on the base branch itself"

    local existing_base
    existing_base=$(_get_config base)
    if [[ -n "$existing_base" ]]; then
        local existing_mode existing_pattern
        existing_mode=$(_get_config mode)
        existing_pattern=$(_get_config targetPattern)
        local target_count
        target_count=$(find_dispatch_targets "$source" | wc -l | tr -d ' ')

        warn "Warning: dispatch already configured on this branch:"
        warn "  mode:   ${existing_mode:-independent}"
        warn "  base:   $existing_base"
        warn "  target-pattern: ${existing_pattern:-<unset>}"
        [[ "$target_count" -gt 0 ]] && warn "  targets: $target_count branches exist"
        echo ""
        warn "Overwriting config will orphan existing target branches."

        if [[ -t 0 ]]; then
            read -p "Proceed? [y/N] " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
        fi
    fi

    git config dispatch.base "$base"
    git config dispatch.targetPattern "$target_pattern"
    git config dispatch.mode "$mode"

    _install_hooks

    echo ""
    info "Initialized dispatch on '$source'"
    echo -e "  ${CYAN}mode:${NC}   $mode"
    echo -e "  ${CYAN}base:${NC}   $base"
    echo -e "  ${CYAN}target-pattern:${NC} $target_pattern"
}

# ---------- apply ----------

cmd_apply() {
    _require_init

    local dry_run=false resolve=false force=false reset_target=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)  dry_run=true; shift ;;
            --resolve)  resolve=true; shift ;;
            --force)    force=true; shift ;;
            --reset)    reset_target="$2"; shift 2 ;;
            -*)         die "Unknown flag: $1" ;;
            *)          die "Unexpected argument: $1" ;;
        esac
    done

    local base mode source
    base=$(_get_config base)
    mode=$(_get_config mode)
    source=$(current_branch)
    [[ -n "$source" ]] || die "Not on a branch"

    # Parse trailer-tagged commits into temp file: "hash target-id" per line
    local commit_file
    commit_file=$(mktemp)
    trap "rm -f '$commit_file'" RETURN

    while IFS= read -r _h; do
        # Skip merge commits (they have no Target-Id and that's expected)
        local _pc
        _pc=$(git rev-list --parents -n1 "$_h" | wc -w)
        (( _pc > 2 )) && continue
        local _t
        _t=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" "$_h" | tr -d '[:space:]')
        echo "$_h $_t"
    done < <(git log --reverse --format="%H" "$base..$source") > "$commit_file"

    [[ -s "$commit_file" ]] || die "No commits found between $base and $source"

    # Validate all commits have numeric Target-Id
    while read -r hash tid; do
        [[ -z "$tid" ]] && die "Commit $(echo "$hash" | cut -c1-8) has no Target-Id trailer"
        if ! echo "$tid" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
            die "Commit $(echo "$hash" | cut -c1-8) has non-numeric Target-Id '$tid'"
        fi
    done < "$commit_file"

    # Ordered unique target ids (numeric sort)
    local -a target_ids=()
    while IFS= read -r tid; do
        target_ids+=("$tid")
    done < <(awk '!seen[$2]++ {print $2}' "$commit_file" | sort -t. -k1,1n -k2,2n)

    if $dry_run; then
        echo -e "${CYAN}mode:${NC} $mode (targets branch from ${mode/independent/base}${mode/stacked/previous target})"
        echo ""
    fi

    local prev_branch="$base"
    local created=0 updated=0 skipped=0 failed=0

    # Stash once before the loop to avoid per-target stash/pop churn
    local apply_stashed=false
    if ! $dry_run; then
        if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
            git stash push --include-untracked --quiet -m "git-dispatch: auto-stash before apply"
            apply_stashed=true
        fi
    fi

    # --reset <id>: delete the target branch so apply recreates it fresh
    if [[ -n "$reset_target" ]]; then
        local reset_branch
        reset_branch=$(_target_branch_name "$reset_target")
        if git rev-parse --verify "refs/heads/$reset_branch" &>/dev/null; then
            # Remove worktree if branch is checked out in one
            local wt_path
            wt_path=$(git worktree list --porcelain 2>/dev/null | awk -v b="$reset_branch" '
                /^worktree / { path=$2 }
                /^branch refs\/heads\// { if ($2 == "refs/heads/" b) print path }
            ')
            if [[ -n "$wt_path" ]]; then
                git worktree remove --force "$wt_path" 2>/dev/null || true
                git worktree prune 2>/dev/null || true
                info "Removed worktree $wt_path"
            fi
            local delete_err
            if delete_err=$(git branch -D "$reset_branch" 2>&1); then
                info "Deleted $reset_branch (will regenerate)"
            else
                if $apply_stashed; then git stash pop --quiet 2>/dev/null || true; fi
                die "Could not delete $reset_branch: $delete_err"
            fi
        else
            if $apply_stashed; then git stash pop --quiet 2>/dev/null || true; fi
            die "Branch $reset_branch does not exist"
        fi
    fi

    for tid in "${target_ids[@]}"; do
        local branch_name
        branch_name=$(_target_branch_name "$tid")

        # Collect hashes for this target
        local -a hashes=()
        while IFS= read -r h; do
            hashes+=("$h")
        done < <(awk -v t="$tid" '$2 == t {print $1}' "$commit_file")

        # Determine parent branch for this target
        local parent_branch="$base"
        if [[ "$mode" == "stacked" && "$prev_branch" != "$base" ]]; then
            parent_branch="$prev_branch"
        fi

        if $dry_run; then
            if git rev-parse --verify "refs/heads/$branch_name" &>/dev/null; then
                # Check for new commits
                local new_count=0
                local cherry_out
                cherry_out=$(git cherry -v "$branch_name" "$source" 2>/dev/null) || true
                while IFS= read -r line; do
                    [[ "$line" == +* ]] || continue
                    local hash
                    hash=$(echo "$line" | awk '{print $2}')
                    local ctid
                    ctid=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" "$hash" | tr -d '[:space:]')
                    [[ "$ctid" == "$tid" ]] && new_count=$((new_count + 1))
                done <<< "$cherry_out"
                if [[ $new_count -gt 0 ]]; then
                    echo -e "  ${YELLOW}cherry-pick${NC} $new_count commit(s) to target $tid  $branch_name"
                else
                    echo -e "  ${GREEN}skip${NC} target $tid  $branch_name  in sync"
                fi
            else
                echo -e "  ${YELLOW}create${NC} target $tid  $branch_name  (${#hashes[@]} commits from $parent_branch)"
            fi
            prev_branch="$branch_name"
            continue
        fi

        if git rev-parse --verify "refs/heads/$branch_name" &>/dev/null; then
            # Target exists locally - cherry-pick new commits
            local -a new_hashes=()
            local cherry_out
            cherry_out=$(git cherry -v "$branch_name" "$source" 2>/dev/null) || true
            while IFS= read -r line; do
                [[ "$line" == +* ]] || continue
                local hash
                hash=$(echo "$line" | awk '{print $2}')
                local ctid
                ctid=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" "$hash" | tr -d '[:space:]')
                [[ "$ctid" == "$tid" ]] && new_hashes+=("$hash")
            done <<< "$cherry_out"

            if [[ ${#new_hashes[@]} -gt 0 ]]; then
                cherry_pick_into "$resolve" "$branch_name" "${new_hashes[@]}"
                info "  Updated $branch_name (${#new_hashes[@]} new commits)"
                updated=$((updated + 1))
            else
                echo "  $branch_name: in sync"
                skipped=$((skipped + 1))
            fi
        else
            # Create new target branch (--no-track avoids inheriting upstream from base)
            git branch --no-track "$branch_name" "$parent_branch" 2>/dev/null || \
                die "Could not create branch $branch_name"

            local orig
            orig=$(current_branch)

            local checkout_err
            if ! checkout_err=$(git checkout "$branch_name" --quiet 2>&1); then
                git branch -D "$branch_name" 2>/dev/null || true
                warn "  Failed to checkout $branch_name:"
                warn "  $checkout_err"
                warn "  Skipping this target. Fix the issue and re-run apply."
                failed=$((failed + 1))
                prev_branch="$branch_name"
                continue
            fi

            local cherry_pick_failed=false
            for hash in "${hashes[@]}"; do
                local cp_err
                if ! cp_err=$(git cherry-pick -x "$hash" 2>&1); then
                    if git rev-parse --verify CHERRY_PICK_HEAD &>/dev/null && git diff --cached --quiet; then
                        warn "  Skipping empty cherry-pick: $(git log -1 --oneline "$hash")"
                        git cherry-pick --skip
                        continue
                    fi
                    # Retry with --theirs to auto-resolve conflicts (safe on fresh targets)
                    git cherry-pick --abort 2>/dev/null || true
                    if git cherry-pick -x --strategy-option theirs "$hash" 2>/dev/null; then
                        warn "  Auto-resolved conflict (--theirs): $(git log -1 --oneline "$hash")"
                        continue
                    fi
                    # --theirs also failed
                    warn "  Cherry-pick failed on $(git log -1 --oneline "$hash")"
                    [[ -n "$cp_err" ]] && warn "  $cp_err"
                    git cherry-pick --abort 2>/dev/null || true
                    cherry_pick_failed=true
                    break
                fi
            done

            local checkout_err
            if ! checkout_err=$(git checkout "$orig" --quiet 2>&1); then
                warn "Could not return to $orig: $checkout_err"
            fi

            # Set up stack metadata
            stack_add "$branch_name" "$parent_branch"
            git config "branch.${branch_name}.dispatchsource" "$source"

            if $cherry_pick_failed; then
                warn "  $branch_name created (cherry-pick conflicted)"
            else
                info "  Created $branch_name (${#hashes[@]} commits)"
            fi
            created=$((created + 1))
        fi
        prev_branch="$branch_name"
    done

    if $apply_stashed; then
        if ! git stash pop --quiet 2>/dev/null; then
            warn "Auto-stash pop had conflicts. Run: git stash pop"
        fi
    fi

    echo ""
    if $dry_run; then
        echo -e "${CYAN}Summary (dry-run):${NC} ${#target_ids[@]} targets"
    else
        local summary="$created created, $updated updated, $skipped in sync"
        [[ $failed -gt 0 ]] && summary="$summary, ${RED}$failed failed${NC}"
        echo -e "${CYAN}Summary:${NC} $summary"
    fi
}

# ---------- cherry-pick ----------

cmd_cherry_pick() {
    _require_init

    local from="" to="" dry_run=false resolve=false force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)     from="$2"; shift 2 ;;
            --to)       to="$2"; shift 2 ;;
            --dry-run)  dry_run=true; shift ;;
            --resolve)  resolve=true; shift ;;
            --force)    force=true; shift ;;
            -*)         die "Unknown flag: $1" ;;
            *)          die "Unexpected argument: $1" ;;
        esac
    done

    [[ -n "$from" ]] || die "Missing --from"
    [[ -n "$to" ]] || die "Missing --to"

    local base source
    base=$(_get_config base)
    source=$(resolve_source "")

    # --from source --to all -> delegate to apply
    if [[ "$from" == "source" && "$to" == "all" ]]; then
        cmd_apply ${dry_run:+--dry-run} ${resolve:+--resolve} ${force:+--force}
        return
    fi

    if [[ "$from" == "source" ]]; then
        # Cherry-pick from source to target <id>
        local target_branch
        target_branch=$(_target_branch_name "$to")
        git rev-parse --verify "refs/heads/$target_branch" &>/dev/null || \
            die "Target branch '$target_branch' does not exist locally. Run: git dispatch apply"

        local -a new_hashes=()
        local cherry_out
        cherry_out=$(git cherry -v "$target_branch" "$source" 2>/dev/null) || \
            die "git cherry failed"
        while IFS= read -r line; do
            [[ "$line" == +* ]] || continue
            local hash
            hash=$(echo "$line" | awk '{print $2}')
            local tid
            tid=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" "$hash" | tr -d '[:space:]')
            [[ "$tid" == "$to" ]] && new_hashes+=("$hash")
        done <<< "$cherry_out"

        if [[ ${#new_hashes[@]} -eq 0 ]]; then
            info "Target $to already in sync"
            return
        fi

        if $dry_run; then
            echo -e "${YELLOW}[dry-run]${NC} cherry-pick ${#new_hashes[@]} commit(s) from source to $target_branch"
            return
        fi

        cherry_pick_into "$resolve" "$target_branch" "${new_hashes[@]}"
        info "Cherry-picked ${#new_hashes[@]} commit(s) to $target_branch"

    else
        # Cherry-pick from target <id> to source
        [[ "$to" == "source" ]] || die "Invalid --to '$to'. Use: source or a Target-Id"

        local target_branch
        target_branch=$(_target_branch_name "$from")
        git rev-parse --verify "refs/heads/$target_branch" &>/dev/null || \
            die "Target branch '$target_branch' does not exist locally. Run: git dispatch apply"

        local parent
        parent=$(find_stack_parent "$target_branch")

        local -a new_hashes=()
        local cherry_out
        cherry_out=$(git cherry -v "$source" "$target_branch" ${parent:+"$parent"} 2>/dev/null) || \
            die "git cherry failed"
        while IFS= read -r line; do
            [[ "$line" == +* ]] || continue
            local hash
            hash=$(echo "$line" | awk '{print $2}')
            # Skip commits from base
            if git merge-base --is-ancestor "$hash" "$base" 2>/dev/null; then
                continue
            fi
            # Skip commits already integrated in source, even with different history.
            if _commit_semantically_in_branch "$hash" "$source"; then
                continue
            fi
            new_hashes+=("$hash")
        done <<< "$cherry_out"

        if [[ ${#new_hashes[@]} -eq 0 ]]; then
            info "Source already has all commits from target $from"
            return
        fi

        if $dry_run; then
            echo -e "${YELLOW}[dry-run]${NC} cherry-pick ${#new_hashes[@]} commit(s) from $target_branch to source"
            return
        fi

        # Cherry-pick with trailer addition
        _cherry_pick_with_trailers "$resolve" "$source" "$from" "${new_hashes[@]}"
        if [[ ${DISPATCH_LAST_PICKED:-0} -eq 0 ]]; then
            info "No new commits applied from $target_branch to source (${DISPATCH_LAST_SKIPPED:-0} empty/no-op)"
        else
            info "Cherry-picked ${DISPATCH_LAST_PICKED} commit(s) from $target_branch to source (${DISPATCH_LAST_SKIPPED:-0} skipped)"
        fi
    fi
}

# ---------- rebase ----------

cmd_rebase() {
    _require_init

    local from="" to="" dry_run=false resolve=false force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)     from="$2"; shift 2 ;;
            --to)       to="$2"; shift 2 ;;
            --dry-run)  dry_run=true; shift ;;
            --resolve)  resolve=true; shift ;;
            --force)    force=true; shift ;;
            -*)         die "Unknown flag: $1" ;;
            *)          die "Unexpected argument: $1" ;;
        esac
    done

    [[ -n "$from" ]] || die "Missing --from"
    [[ -n "$to" ]] || die "Missing --to"
    [[ "$from" == "base" && "$to" == "source" ]] || \
        die "Only --from base --to source is supported"

    local base source
    base=$(_get_config base)
    source=$(resolve_source "")

    # Check for open PRs on downstream targets
    if ! $force; then
        local pr_info
        if pr_info=$(_get_open_prs "$source" 2>/dev/null) && [[ -n "$pr_info" ]]; then
            local pr_branches
            pr_branches=$(echo "$pr_info" | awk '{print $1 " (PR #" $2 ")"}')
            warn "Rebase rewrites history on source."
            warn "Targets with open PRs:"
            echo "$pr_branches" | while IFS= read -r line; do warn "  $line"; done
            die "Downstream force-push required. Use --force to override."
        fi
    fi

    if $dry_run; then
        local count
        count=$(git rev-list --count "$base..$source" 2>/dev/null || echo 0)
        echo -e "${YELLOW}[dry-run]${NC} rebase $source ($count commits) onto $base"
        return
    fi

    local orig
    orig=$(current_branch)
    local checkout_err
    if ! checkout_err=$(git checkout "$source" --quiet 2>&1); then
        die "Cannot checkout $source: $checkout_err"
    fi

    if ! git rebase "$base"; then
        echo ""
        warn "Rebase conflict on $source onto $base"
        _show_conflict_diff ""
        if $resolve; then
            echo ""
            warn "Resolve conflicts, then run: git rebase --continue"
            exit 1
        fi
        git rebase --abort 2>/dev/null || true
        [[ "$orig" != "$source" ]] && git checkout "$orig" --quiet 2>/dev/null || true
        echo ""
        warn "Aborted. Re-run with --resolve to keep conflict active for manual resolution."
        exit 1
    fi

    [[ "$orig" != "$source" ]] && git checkout "$orig" --quiet 2>/dev/null || true
    info "Rebased $source onto $base"
}

# ---------- merge ----------

cmd_merge() {
    _require_init

    local from="" to="" dry_run=false resolve=false force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)     from="$2"; shift 2 ;;
            --to)       to="$2"; shift 2 ;;
            --dry-run)  dry_run=true; shift ;;
            --resolve)  resolve=true; shift ;;
            --force)    force=true; shift ;;
            -*)         die "Unknown flag: $1" ;;
            *)          die "Unexpected argument: $1" ;;
        esac
    done

    [[ -n "$from" ]] || die "Missing --from"
    [[ -n "$to" ]] || die "Missing --to"
    [[ "$from" == "base" ]] || die "Only --from base is supported"

    local base source
    base=$(_get_config base)
    source=$(resolve_source "")

    # Build list of branches to merge into
    local -a branches=()
    if [[ "$to" == "source" ]]; then
        branches=("$source")
    elif [[ "$to" == "all" ]]; then
        branches=("$source")
        while IFS= read -r c; do
            [[ -n "$c" ]] && branches+=("$c")
        done < <(find_dispatch_targets "$source" | order_by_stack)
        [[ ${#branches[@]} -gt 1 ]] || die "No targets found"
    else
        # Numeric target id
        local target_branch
        target_branch=$(_target_branch_name "$to")
        git rev-parse --verify "refs/heads/$target_branch" &>/dev/null || \
            die "Target branch '$target_branch' does not exist locally. Run: git dispatch apply"
        branches=("$target_branch")
    fi

    if $dry_run; then
        for branch in "${branches[@]}"; do
            local count
            count=$(git rev-list --count "$branch..$base" 2>/dev/null || echo 0)
            if [[ "$count" -eq 0 ]]; then
                echo -e "  ${GREEN}$branch${NC}: up to date"
            else
                echo -e "  ${YELLOW}[dry-run]${NC} merge $base ($count commits) into $branch"
            fi
        done
        return
    fi

    local orig
    orig=$(current_branch)
    local merged=0 uptodate=0 failed=0

    for branch in "${branches[@]}"; do
        local count
        count=$(git rev-list --count "$branch..$base" 2>/dev/null || echo 0)
        if [[ "$count" -eq 0 ]]; then
            info "  $branch: up to date"
            uptodate=$((uptodate + 1))
            continue
        fi

        local checkout_err
        if ! checkout_err=$(git checkout "$branch" --quiet 2>&1); then
            warn "  Cannot checkout $branch: $checkout_err"
            failed=$((failed + 1))
            continue
        fi

        if ! git merge "$base" --no-edit; then
            echo ""
            warn "Merge conflict on $branch from $base"
            _show_conflict_diff ""
            if $resolve; then
                echo ""
                warn "Resolve conflicts, then run: git commit"
                exit 1
            fi
            git merge --abort 2>/dev/null || true
            warn "  $branch: merge conflict (skipped)"
            failed=$((failed + 1))
            continue
        fi

        info "  Merged $base into $branch"
        merged=$((merged + 1))
    done

    git checkout "$orig" --quiet 2>/dev/null || true
    echo ""
    info "Summary: $merged merged, $uptodate up to date${failed:+, $failed failed}"
}

# ---------- push ----------

cmd_push() {
    _require_init

    local from="" dry_run=false force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)     from="$2"; shift 2 ;;
            --dry-run)  dry_run=true; shift ;;
            --force)    force=true; shift ;;
            -*)         die "Unknown flag: $1" ;;
            *)          die "Unexpected argument: $1" ;;
        esac
    done

    [[ -n "$from" ]] || die "Missing --from"

    local base source
    base=$(_get_config base)
    source=$(resolve_source "")

    local -a branches=()

    if [[ "$from" == "all" ]]; then
        while IFS= read -r c; do
            [[ -n "$c" ]] && branches+=("$c")
        done < <(find_dispatch_targets "$source" | order_by_stack)
        [[ ${#branches[@]} -gt 0 ]] || die "No targets found"
    elif [[ "$from" == "source" ]]; then
        branches=("$source")
    else
        # Numeric target id
        local target_branch
        target_branch=$(_target_branch_name "$from")
        git rev-parse --verify "refs/heads/$target_branch" &>/dev/null || \
            die "Target branch '$target_branch' does not exist locally. Run: git dispatch apply"
        branches=("$target_branch")
    fi

    local -a push_args=(-u origin)
    $force && push_args+=(--force-with-lease)

    for branch in "${branches[@]}"; do
        if $dry_run; then
            echo -e "  ${YELLOW}[dry-run]${NC} git push ${push_args[*]} $branch"
        else
            local push_out
            if push_out=$(git push "${push_args[@]}" "$branch" 2>&1); then
                info "  Pushed $branch"
            else
                local reason
                reason=$(printf '%s\n' "$push_out" | sed '/^[[:space:]]*$/d' | tail -n 1)
                [[ -z "$reason" ]] && reason="unknown error"
                warn "  Push failed for $branch: $reason"
            fi
        fi
    done
}

# ---------- status ----------

cmd_status() {
    _require_init

    local base target_pattern mode source
    base=$(_get_config base)
    target_pattern=$(_get_config targetPattern)
    mode=$(_get_config mode)
    source=$(resolve_source "")

    echo -e "${CYAN}mode:${NC}   $mode"
    echo -e "${CYAN}base:${NC}   $base"
    echo -e "${CYAN}source:${NC} $source"
    echo -e "${CYAN}target-pattern:${NC} ${target_pattern:-\"\"}"
    echo ""

    local -a ordered=()
    while IFS= read -r c; do
        [[ -n "$c" ]] && ordered+=("$c")
    done < <(find_dispatch_targets "$source" | order_by_stack)

    # Also find Target-Ids in source that don't have branches yet
    local -a source_tids=()
    while IFS= read -r _h; do
        local _t
        _t=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" "$_h" | tr -d '[:space:]')
        [[ -n "$_t" ]] && source_tids+=("$_t")
    done < <(git log --format="%H" "$base..$source")
    # Unique sorted
    local -a unique_tids=()
    while IFS= read -r t; do
        unique_tids+=("$t")
    done < <(printf '%s\n' "${source_tids[@]}" | sort -t. -k1,1n -k2,2n -u)

    # Cache PR info
    local pr_cache=""
    pr_cache=$(_get_open_prs "$source" 2>/dev/null) || true

    # Pre-compute column widths
    local max_tid=0 max_branch=0
    for tid in "${unique_tids[@]}"; do
        (( ${#tid} > max_tid )) && max_tid=${#tid}
        local bn
        bn=$(_target_branch_name "$tid")
        (( ${#bn} > max_branch )) && max_branch=${#bn}
    done

    for tid in "${unique_tids[@]}"; do
        local branch_name
        branch_name=$(_target_branch_name "$tid")

        local pr_suffix=""
        if [[ -n "$pr_cache" ]]; then
            local pr_num
            pr_num=$(echo "$pr_cache" | awk -v b="$branch_name" '$1 == b {print $2}')
            [[ -n "$pr_num" ]] && pr_suffix=" [PR #${pr_num}]"
        fi

        if ! git rev-parse --verify "refs/heads/$branch_name" &>/dev/null; then
            printf "  ${YELLOW}%-${max_tid}s${NC}  %-${max_branch}s  not created\n" "$tid" "$branch_name"
            continue
        fi

        # Count pending source -> target
        # Two-phase: cheap history check, then semantic filtering for candidates
        local source_to_target=0
        local cherry_out
        local -a source_to_target_candidates=()
        cherry_out=$(git cherry -v "$branch_name" "$source" 2>/dev/null) || true
        while IFS= read -r line; do
            [[ "$line" == +* ]] || continue
            local hash
            hash=$(echo "$line" | awk '{print $2}')
            local ctid
            ctid=$(git log -1 --format="%(trailers:key=Target-Id,valueonly)" "$hash" | tr -d '[:space:]')
            [[ "$ctid" == "$tid" ]] && source_to_target_candidates+=("$hash")
        done <<< "$cherry_out"

        if [[ ${#source_to_target_candidates[@]} -gt 0 ]]; then
            # Fast path: check if file content matches for all files touched by candidate commits
            local candidate_files=""
            for hash in "${source_to_target_candidates[@]}"; do
                candidate_files+=$'\n'"$(git diff-tree --no-commit-id --name-only -r "$hash" 2>/dev/null)"
            done
            candidate_files=$(echo "$candidate_files" | sort -u | sed '/^$/d')

            if [[ -n "$candidate_files" ]] && git diff --quiet "$source" "$branch_name" -- $candidate_files 2>/dev/null; then
                source_to_target=0
            else
                for hash in "${source_to_target_candidates[@]}"; do
                    if _commit_semantically_in_branch "$hash" "$branch_name"; then
                        continue
                    fi
                    source_to_target=$((source_to_target + 1))
                done
            fi
        fi

        # Count pending target -> source
        # Two-phase:
        # 1) cheap history-based candidate detection
        # 2) semantic no-op filtering only for branches with candidates
        local target_to_source=0
        local parent
        local -a target_to_source_candidates=()
        parent=$(find_stack_parent "$branch_name")
        cherry_out=$(git cherry -v "$source" "$branch_name" ${parent:+"$parent"} 2>/dev/null) || true
        while IFS= read -r line; do
            [[ "$line" == +* ]] || continue
            local hash
            hash=$(echo "$line" | awk '{print $2}')
            if git merge-base --is-ancestor "$hash" "$base" 2>/dev/null; then
                continue
            fi
            target_to_source_candidates+=("$hash")
        done <<< "$cherry_out"

        # Only run semantic checks for branches that are history-ahead.
        if [[ ${#target_to_source_candidates[@]} -gt 0 ]]; then
            # Fast path: check if file content matches for all candidate files
            local t2s_files=""
            for hash in "${target_to_source_candidates[@]}"; do
                t2s_files+=$'\n'"$(git diff-tree --no-commit-id --name-only -r "$hash" 2>/dev/null)"
            done
            t2s_files=$(echo "$t2s_files" | sort -u | sed '/^$/d')

            # shellcheck disable=SC2086
            if [[ -n "$t2s_files" ]] && git diff --quiet "$source" "$branch_name" -- $t2s_files 2>/dev/null; then
                target_to_source=0
            else
                for hash in "${target_to_source_candidates[@]}"; do
                    if _commit_semantically_in_branch "$hash" "$source"; then
                        continue
                    fi
                    target_to_source=$((target_to_source + 1))
                done
            fi
        fi

        if [[ $source_to_target -eq 0 && $target_to_source -eq 0 ]]; then
            printf "  ${GREEN}%-${max_tid}s${NC}  %-${max_branch}s  in sync${pr_suffix}\n" "$tid" "$branch_name"
        else
            local status_parts=""
            [[ $source_to_target -gt 0 ]] && status_parts="${source_to_target} behind source"
            [[ $target_to_source -gt 0 ]] && status_parts="${status_parts:+$status_parts, }${target_to_source} ahead"

            local diverge_tag=""
            if [[ $source_to_target -gt 0 && $target_to_source -gt 0 ]]; then
                if _target_content_diverged "$source" "$branch_name" "$base" "$tid"; then
                    diverge_tag=" ${RED}(DIVERGED)${NC}"
                    has_diverged=true
                else
                    diverge_tag=" (cosmetic)"
                    has_cosmetic=true
                fi
            fi

            printf "  ${YELLOW}%-${max_tid}s${NC}  %-${max_branch}s  $status_parts${diverge_tag}${pr_suffix}\n" "$tid" "$branch_name"
        fi
    done

    if [[ "${has_diverged:-}" == "true" ]]; then
        echo ""
        warn "Diverged targets have different file content than source."
        warn "Run: git dispatch diff --target <id>  to inspect."
    fi
    if [[ "${has_cosmetic:-}" == "true" ]]; then
        echo ""
        echo "  \"cosmetic\" = same file content, different commit SHAs (normal after"
        echo "  conflict resolution). Safe to ignore, or fix by regenerating the target:"
        echo "  git dispatch apply --reset <id>"
    fi
}

# ---------- diff ----------

cmd_diff() {
    _require_init

    local target=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target) target="$2"; shift 2 ;;
            -*)       die "Unknown flag: $1" ;;
            *)        die "Unexpected argument: $1" ;;
        esac
    done

    [[ -n "$target" ]] || die "Missing --target <id>"

    local base source target_branch
    base=$(_get_config base)
    source=$(resolve_source "")
    target_branch=$(_target_branch_name "$target")

    git rev-parse --verify "refs/heads/$target_branch" &>/dev/null || \
        die "Target branch '$target_branch' does not exist locally."

    local target_files
    target_files=$(_target_id_files "$base" "$target_branch" "$target" | sort -u)

    if [[ -z "$target_files" ]]; then
        info "No files changed by target $target on $target_branch"
        return
    fi

    # shellcheck disable=SC2086
    local diff_files
    diff_files=$(git diff --name-only "$source" "$target_branch" -- $target_files 2>/dev/null)

    if [[ -z "$diff_files" ]]; then
        info "No content difference between $source and $target_branch"
    else
        warn "Files diverged between $source and $target_branch:"
        echo "$diff_files" | while IFS= read -r f; do echo "  $f"; done
        echo ""
        # shellcheck disable=SC2086
        git diff "$source" "$target_branch" -- $target_files 2>/dev/null
        echo ""
        echo -e "${CYAN}To resolve:${NC}"
        echo "  git dispatch cherry-pick --from $target --to source --resolve   # bring target changes to source"
        echo "  git dispatch cherry-pick --from source --to $target              # push source version to target"
        echo -e "${CYAN}Then sync:${NC}"
        echo "  git dispatch apply"
    fi
}

# ---------- reset ----------

cmd_reset() {
    _require_init

    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            -*)      die "Unknown flag: $1" ;;
            *)       die "Unexpected argument: $1" ;;
        esac
    done

    local source
    source=$(resolve_source "")

    local -a targets=()
    while IFS= read -r c; do
        [[ -n "$c" ]] && targets+=("$c")
    done < <(find_dispatch_targets "$source")

    echo -e "${CYAN}This will delete:${NC}"
    echo "  - dispatch config on source branch"
    if [[ ${#targets[@]} -gt 0 ]]; then
        echo "  - target branches: ${targets[*]}"
    fi
    echo "  - hooks from .git/hooks"

    if ! $force; then
        echo ""
        read -p "Proceed? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi

    local cur
    cur=$(current_branch)

    # Delete target branches and metadata
    for target in "${targets[@]}"; do
        local parent
        parent=$(find_stack_parent "$target")

        git config --unset "branch.${target}.dispatchsource" 2>/dev/null || true
        [[ -n "$parent" ]] && stack_remove "$target" "$parent"
        git config --unset-all "branch.${target}.dispatchtargets" 2>/dev/null || true

        if [[ "$cur" == "$target" ]]; then
            warn "  Skipping delete of $target (currently checked out)"
        else
            git branch -D "$target" 2>/dev/null || true
            info "  Deleted $target"
        fi
    done

    # Delete dispatch config
    git config --unset dispatch.base 2>/dev/null || true
    git config --unset dispatch.targetPattern 2>/dev/null || true
    git config --unset dispatch.prefix 2>/dev/null || true
    git config --unset dispatch.mode 2>/dev/null || true

    echo ""
    info "Reset complete."
}

# ---------- help ----------

cmd_help() {
    cat <<'HELP'
git-dispatch: Create target branches from a source branch and keep them in sync.

SETUP
  git dispatch init --base <branch> --target-pattern <pattern> [--mode <independent|stacked>]

  Initialize dispatch on the current branch. Stores config, installs hooks.
  Defaults: --mode independent.
  Required: --base (recommended: "origin/master").
  Required: --target-pattern (must include "{id}"), e.g. "user/feat/task-{id}".

WORKFLOW
  1. Tag every commit with a Target-Id trailer:
       git commit -m "Add feature" --trailer "Target-Id=1"

  2. Create target branches:
       git dispatch apply

  3. Propagate changes:
       git dispatch apply                              # source to all targets
       git dispatch cherry-pick --from source --to 2   # source to one target
       git dispatch cherry-pick --from 2 --to source   # target back to source

  4. Update with base changes:
       git dispatch merge --from base --to source      # source only, safe
       git dispatch merge --from base --to all         # source + all targets
       git dispatch merge --from base --to 8           # one target
       git dispatch rebase --from base --to source     # rewrites history

COMMANDS
  init      Configure dispatch on current source branch
  apply     Make all targets match source (create/update). --reset <id> to regenerate.
  cherry-pick  Move commits between source and target (--from/--to)
  rebase    Rebase source onto base (--from base --to source)
  merge     Merge base into branches (--from base --to <source|id|all>)
  push      Push branches (--from <id|all|source>)
  status    Show mode, base, source, and all targets with sync state
  reset     Delete all dispatch metadata and target branches

FLAGS (on propagation commands)
  --dry-run   Show plan, make no changes
  --resolve   Enter conflict resolution mode
  --force     Override safety checks

TRAILERS
  Target-Id (required): numeric integer or decimal (1, 2, 1.5)
    git commit -m "message" --trailer "Target-Id=1"

  Hook auto-carries Target-Id from previous commit when absent.
HELP
}

# ---------- main ----------

main() {
    [[ $# -gt 0 ]] || { cmd_help; exit 0; }

    local cmd="$1"; shift
    case "$cmd" in
        init)         cmd_init "$@" ;;
        apply)        cmd_apply "$@" ;;
        cherry-pick)  cmd_cherry_pick "$@" ;;
        rebase)       cmd_rebase "$@" ;;
        merge)        cmd_merge "$@" ;;
        push)         cmd_push "$@" ;;
        status)       cmd_status "$@" ;;
        diff)         cmd_diff "$@" ;;
        reset)        cmd_reset "$@" ;;
        help|--help|-h) cmd_help ;;
        *)            die "Unknown command: $cmd" ;;
    esac
}

main "$@"
