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

# Find worktree path for a branch (empty if none)
worktree_for_branch() {
    local branch="$1"
    git worktree list --porcelain | awk -v b="refs/heads/$branch" '
        /^worktree / { wt = substr($0, 10) }
        /^branch /   { if (substr($0, 8) == b) print wt }
    '
}

_DISPATCH_WT_PATH=""
_DISPATCH_WT_CREATED=false
_DISPATCH_WT_STASHED=false

_enter_branch() {
    local branch="$1"
    _DISPATCH_WT_PATH=$(worktree_for_branch "$branch")
    _DISPATCH_WT_CREATED=false
    _DISPATCH_WT_STASHED=false
    if [[ -z "$_DISPATCH_WT_PATH" ]]; then
        _DISPATCH_WT_PATH=$(mktemp -d "${TMPDIR:-/tmp}/git-dispatch-wt.XXXXXX")
        git worktree add -q "$_DISPATCH_WT_PATH" "$branch" 2>/dev/null || {
            rm -rf "$_DISPATCH_WT_PATH"; _DISPATCH_WT_PATH=""; return 1
        }
        _DISPATCH_WT_CREATED=true
    else
        # Existing worktree: stash dirty state so operations run cleanly
        if ! git -C "$_DISPATCH_WT_PATH" diff --quiet 2>/dev/null || \
           ! git -C "$_DISPATCH_WT_PATH" diff --cached --quiet 2>/dev/null; then
            git -C "$_DISPATCH_WT_PATH" stash push --quiet -m "git-dispatch: auto-stash in worktree" 2>/dev/null || true
            _DISPATCH_WT_STASHED=true
        fi
    fi
}

_leave_branch() {
    if $_DISPATCH_WT_STASHED && [[ -n "$_DISPATCH_WT_PATH" ]]; then
        git -C "$_DISPATCH_WT_PATH" stash pop --quiet 2>/dev/null || true
    fi
    if $_DISPATCH_WT_CREATED && [[ -n "$_DISPATCH_WT_PATH" ]]; then
        git worktree remove --force "$_DISPATCH_WT_PATH" 2>/dev/null || rm -rf "$_DISPATCH_WT_PATH"
    fi
    _DISPATCH_WT_PATH=""
    _DISPATCH_WT_CREATED=false
    _DISPATCH_WT_STASHED=false
}

# Handle conflict exit: leave worktree alive for --resolve or clean up
_conflict_leave() {
    local resolve="$1"
    if [[ "$resolve" == "true" ]]; then
        echo ""
        warn "Worktree left at: $_DISPATCH_WT_PATH"
        _DISPATCH_WT_CREATED=false
        _DISPATCH_WT_STASHED=false
    else
        _leave_branch
    fi
}

# Skip an empty cherry-pick and increment the skipped counter
_skip_empty_pick() {
    local hash="$1"; shift
    local -a gcmd=("$@")
    warn "  Skipping empty cherry-pick: $(git log -1 --oneline "$hash")"
    if "${gcmd[@]}" rev-parse --verify CHERRY_PICK_HEAD &>/dev/null; then
        "${gcmd[@]}" cherry-pick --skip 2>/dev/null || "${gcmd[@]}" reset HEAD --quiet
    fi
    DISPATCH_LAST_SKIPPED=$((DISPATCH_LAST_SKIPPED + 1))
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

# Lockfile for preventing concurrent dispatch operations
DISPATCH_LOCKFILE=""

_acquire_lock() {
    # Reentrant: skip if we already hold the lock (e.g. cherry-pick delegates to apply)
    if [[ -n "${DISPATCH_LOCKFILE:-}" && -f "$DISPATCH_LOCKFILE" ]]; then
        local existing_pid
        existing_pid=$(cat "$DISPATCH_LOCKFILE" 2>/dev/null || true)
        [[ "$existing_pid" == "$$" ]] && return 0
    fi
    local git_dir
    git_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
    DISPATCH_LOCKFILE="$git_dir/dispatch.lock"
    if [[ -f "$DISPATCH_LOCKFILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$DISPATCH_LOCKFILE" 2>/dev/null || true)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            die "Another dispatch operation is running (PID $lock_pid). Remove if stale: $DISPATCH_LOCKFILE"
        fi
        rm -f "$DISPATCH_LOCKFILE"
    fi
    echo $$ > "$DISPATCH_LOCKFILE"
    trap '_leave_branch; _release_lock' EXIT
}

_release_lock() {
    [[ -n "${DISPATCH_LOCKFILE:-}" ]] && rm -f "$DISPATCH_LOCKFILE"
}


# Refresh the base ref to ensure targets branch from up-to-date base.
# Handles both remote tracking refs (origin/master) and local branches (master).
# Informs user when base was updated and warns on failure.
_refresh_base() {
    local base="$1"
    local old_sha new_sha err_output

    old_sha=$(git rev-parse "$base" 2>/dev/null) || {
        warn "Base ref '$base' does not resolve - cannot refresh"
        return 1
    }

    if [[ "$base" == */* ]]; then
        # Remote tracking ref (e.g. origin/master) - fetch from remote
        local remote="${base%%/*}"
        local ref="${base#*/}"
        if ! err_output=$(git fetch "$remote" "$ref" 2>&1); then
            warn "Failed to fetch $base:"
            warn "  $err_output"
            warn "Targets will branch from local (possibly stale) ref"
            return 1
        fi
    else
        # Local branch (e.g. master) - fast-forward via fetch, no checkout needed
        local upstream_remote upstream_ref
        upstream_remote=$(git config "branch.${base}.remote" 2>/dev/null || true)
        if [[ -z "$upstream_remote" ]]; then
            # No remote tracking - local-only branch, nothing to refresh
            return 0
        fi
        upstream_ref=$(git config "branch.${base}.merge" 2>/dev/null || true)
        upstream_ref="${upstream_ref#refs/heads/}"
        [[ -z "$upstream_ref" ]] && upstream_ref="$base"
        # Try fast-forward update without checkout
        if ! err_output=$(git fetch "$upstream_remote" "$upstream_ref:$base" 2>&1); then
            # Fetch-to-ref failed (diverged) - rebase in temp worktree
            _enter_branch "$base" || {
                warn "Could not access $base to update - targets may branch from stale ref"
                return 1
            }
            if ! err_output=$(git -C "$_DISPATCH_WT_PATH" pull --rebase 2>&1); then
                warn "Failed to update $base:"
                warn "  $err_output"
                warn "Targets may branch from stale ref"
                git -C "$_DISPATCH_WT_PATH" rebase --abort 2>/dev/null || true
                _leave_branch
                return 1
            fi
            _leave_branch
        fi
    fi

    new_sha=$(git rev-parse "$base" 2>/dev/null) || return 0
    if [[ "$old_sha" != "$new_sha" ]]; then
        local count
        count=$(git rev-list --count "$old_sha..$new_sha" 2>/dev/null || echo "?")
        info "Base $base updated ($count new commits)"
    fi
    return 0
}

# Install hooks to the main repo .git/hooks and set core.hooksPath
# so all worktrees share the same hooks.
_install_hooks() {
    local common_dir
    common_dir="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)/hooks"
    mkdir -p "$common_dir"
    cp "$SCRIPT_DIR/hooks/prepare-commit-msg" "$common_dir/prepare-commit-msg"
    chmod +x "$common_dir/prepare-commit-msg"
    cp "$SCRIPT_DIR/hooks/commit-msg" "$common_dir/commit-msg"
    chmod +x "$common_dir/commit-msg"
    # core.hooksPath ensures worktrees use the main repo's hooks
    git config core.hooksPath "$common_dir"
    info "Installed hooks to $common_dir"
}

# Check if a branch's content has been merged (e.g. squash-merged) into base
_is_content_merged() {
    local branch_tip="$1" base_ref="$2"
    local mb
    mb=$(git merge-base "$base_ref" "$branch_tip" 2>/dev/null) || return 1
    local -a changed_files_arr=()
    while IFS= read -r -d '' f; do
        changed_files_arr+=("$f")
    done < <(git diff --name-only -z "$mb" "$branch_tip" 2>/dev/null)
    [[ ${#changed_files_arr[@]} -eq 0 ]] && return 0
    git diff --quiet "$base_ref" "$branch_tip" -- "${changed_files_arr[@]}" 2>/dev/null
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

    # Trap ensures cleanup on normal return and on ERR (set -e)
    # Value of tmpdir is captured at definition time (double-quoted string)
    trap "git worktree remove --force '$tmpdir' >/dev/null 2>&1 || rm -rf '$tmpdir'" RETURN

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

    return $is_empty
}

# Return 0 if commit should be treated as already integrated in branch.
_commit_semantically_in_branch() {
    local commit="$1" branch="$2"
    _commit_effect_in_branch "$commit" "$branch" && return 0
    _would_cherry_pick_be_empty_on_branch "$commit" "$branch" && return 0
    return 1
}

# Get files touched by commits with a specific Dispatch-Target-Id on a branch.
_target_id_files() {
    local base="$1" branch="$2" tid="$3"
    while IFS= read -r hash; do
        local ctid
        ctid=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" "$hash" | tr -d '[:space:]')
        [[ "$ctid" == "$tid" ]] && git diff-tree --no-commit-id --name-only -r "$hash" 2>/dev/null
    done < <(git log --format="%H" "$base..$branch")
}

# Check if source and target have diverged content (not just different SHAs).
# Only checks files from commits with the matching Dispatch-Target-Id (avoids false
# positives from generated files or other tasks' changes in independent mode).
# Returns 0 if content actually differs, 1 if same content (different commits only).
_target_content_diverged() {
    local source="$1" target_branch="$2" base="$3" tid="$4"
    local -a target_files_arr=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && target_files_arr+=("$f")
    done < <(_target_id_files "$base" "$target_branch" "$tid" | sort -u)
    [[ ${#target_files_arr[@]} -eq 0 ]] && return 1
    git diff --quiet "$source" "$target_branch" -- "${target_files_arr[@]}" 2>/dev/null && return 1
    return 0
}

# Extract Dispatch-Target-Id from a branch name by reversing the target-pattern.
_extract_tid_from_branch() {
    local branch="$1"
    local pattern
    pattern=$(_get_config targetPattern)
    local prefix="${pattern%%\{id\}*}"
    local suffix="${pattern#*\{id\}}"
    # Use literal string removal to avoid glob interpretation of [ ] * ? in pattern
    local tid
    if [[ "$branch" == "${prefix}"*"${suffix}" ]]; then
        tid="${branch#"$prefix"}"
        [[ -n "$suffix" ]] && tid="${tid%"$suffix"}"
    else
        return 1
    fi
    echo "$tid" | grep -Eq '^[1-9][0-9]*(\.[0-9]+)?$' && echo "$tid"
}

# Build a patch-id map from source commits (batched - single pipe instead of N+1 processes).
# Input: commit_file with "hash tid" per line.
# Output: map_file with "patch-id hash tid" per line.
_build_source_patch_id_map() {
    local map_file="$1" commit_file="$2"
    > "$map_file"
    # Batch: stream all commits through one git patch-id invocation
    local pid_output
    pid_output=$(while read -r hash tid; do
        [[ -n "$hash" ]] && git show "$hash" 2>/dev/null
    done < "$commit_file" | git patch-id --stable 2>/dev/null)
    [[ -z "$pid_output" ]] && return 0
    while read -r pid hash; do
        [[ -n "$pid" ]] || continue
        local tid
        tid=$(awk -v h="$hash" '$1 == h {print $2; exit}' "$commit_file")
        [[ -n "$tid" ]] && echo "$pid $hash $tid"
    done <<< "$pid_output" > "$map_file"
}

# Find stale commits on a target branch (batched patch-id computation).
# Outputs "target_hash source_tid" for each stale commit.
_find_stale_commits() {
    local branch="$1" tid="$2" base="$3" map_file="$4"
    local -a target_hashes=()
    while read -r hash; do
        [[ -n "$hash" ]] && target_hashes+=("$hash")
    done < <(git log --format="%H" "$base..$branch" 2>/dev/null)
    [[ ${#target_hashes[@]} -eq 0 ]] && return 0
    # Batch: compute all patch-ids in one pass
    local pid_output
    pid_output=$(for hash in "${target_hashes[@]}"; do
        git show "$hash" 2>/dev/null
    done | git patch-id --stable 2>/dev/null)
    [[ -z "$pid_output" ]] && return 0
    while read -r pid hash; do
        [[ -n "$pid" ]] || continue
        local match_tid
        match_tid=$(awk -v p="$pid" '$1 == p {print $3; exit}' "$map_file")
        [[ -n "$match_tid" && "$match_tid" != "$tid" ]] && echo "$hash $match_tid"
    done <<< "$pid_output"
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
        warn "Resolve conflicts, then run: ${gcmd[*]} cherry-pick --continue"
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


# Unified cherry-pick into a branch via temp worktree (no main-worktree checkout).
# Usage: _cherry_pick_commits resolve branch [--add-trailer tid] [--theirs-fallback] hash...
# Sets DISPATCH_LAST_PICKED / DISPATCH_LAST_SKIPPED globals.
_cherry_pick_commits() {
    local resolve="$1" branch="$2"; shift 2
    local add_trailer="" theirs_fallback=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --add-trailer) add_trailer="$2"; shift 2 ;;
            --theirs-fallback) theirs_fallback=true; shift ;;
            *) break ;;
        esac
    done
    local hashes=("$@")

    DISPATCH_LAST_PICKED=0
    DISPATCH_LAST_SKIPPED=0

    _enter_branch "$branch" || die "Cannot access branch $branch (worktree conflict?)"
    local -a gcmd=(git -C "$_DISPATCH_WT_PATH")

    for (( _idx=0; _idx < ${#hashes[@]}; _idx++ )); do
        local hash="${hashes[$_idx]}"

        # Decide: plain cherry-pick or trailer-rewrite cherry-pick
        local needs_trailer=false
        if [[ -n "$add_trailer" ]]; then
            local tid
            tid=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" "$hash" | tr -d '[:space:]')
            [[ "$tid" != "$add_trailer" ]] && needs_trailer=true
        fi

        if $needs_trailer; then
            # cherry-pick --no-commit, then commit with trailer rewrite
            if ! "${gcmd[@]}" cherry-pick --no-commit "$hash" 2>/dev/null; then
                if "${gcmd[@]}" rev-parse --verify CHERRY_PICK_HEAD &>/dev/null && "${gcmd[@]}" diff --cached --quiet; then
                    _skip_empty_pick "$hash" "${gcmd[@]}"; continue
                fi
                # Auto-resolve with --theirs when Dispatch-Source-Keep trailer is present
                local _source_keep
                _source_keep=$(git log -1 --format="%(trailers:key=Dispatch-Source-Keep,valueonly)" "$hash" | tr -d '[:space:]')
                if [[ -n "$_source_keep" ]]; then
                    "${gcmd[@]}" cherry-pick --abort 2>/dev/null || true
                    if "${gcmd[@]}" cherry-pick --no-commit --strategy-option theirs "$hash" 2>/dev/null; then
                        warn "  Force-accepted (Source-Keep): $(git log -1 --oneline "$hash")"
                        # Fall through to commit with trailer rewrite below
                    else
                        _handle_cherry_pick_conflict "$_DISPATCH_WT_PATH" "$hash" "$_idx" "${#hashes[@]}" "$resolve" "$branch" "${hashes[@]:$((_idx+1))}"
                        _conflict_leave "$resolve"; return 1
                    fi
                else
                    _handle_cherry_pick_conflict "$_DISPATCH_WT_PATH" "$hash" "$_idx" "${#hashes[@]}" "$resolve" "$branch" "${hashes[@]:$((_idx+1))}"
                    _conflict_leave "$resolve"; return 1
                fi
            fi
            # Empty no-commit pick: skip
            if "${gcmd[@]}" diff --cached --quiet; then
                _skip_empty_pick "$hash" "${gcmd[@]}"; continue
            fi
            local msg
            msg=$(git log -1 --format="%B" "$hash")
            if ! "${gcmd[@]}" commit -m "$msg" --trailer "Dispatch-Target-Id=$add_trailer" --quiet; then
                if "${gcmd[@]}" diff --cached --quiet; then
                    _skip_empty_pick "$hash" "${gcmd[@]}"; continue
                fi
                "${gcmd[@]}" cherry-pick --abort 2>/dev/null || true
                _leave_branch
                die "Cherry-pick into $branch failed on $hash while creating commit. Resolve manually."
            fi
            DISPATCH_LAST_PICKED=$((DISPATCH_LAST_PICKED + 1))
        else
            # Standard cherry-pick -x
            if ! "${gcmd[@]}" cherry-pick -x "$hash" 2>/dev/null; then
                if "${gcmd[@]}" rev-parse --verify CHERRY_PICK_HEAD &>/dev/null && "${gcmd[@]}" diff --cached --quiet; then
                    _skip_empty_pick "$hash" "${gcmd[@]}"; continue
                fi
                # Auto-resolve with --theirs when Dispatch-Source-Keep trailer is present
                local _source_keep2
                _source_keep2=$(git log -1 --format="%(trailers:key=Dispatch-Source-Keep,valueonly)" "$hash" | tr -d '[:space:]')
                if [[ -n "$_source_keep2" ]]; then
                    "${gcmd[@]}" cherry-pick --abort 2>/dev/null || true
                    if "${gcmd[@]}" cherry-pick -x --strategy-option theirs "$hash" 2>/dev/null; then
                        warn "  Force-accepted (Source-Keep): $(git log -1 --oneline "$hash")"
                        DISPATCH_LAST_PICKED=$((DISPATCH_LAST_PICKED + 1))
                        continue
                    fi
                fi
                # --theirs-fallback: retry with --theirs for fresh target creation
                if $theirs_fallback; then
                    "${gcmd[@]}" cherry-pick --abort 2>/dev/null || true
                    if "${gcmd[@]}" cherry-pick -x --strategy-option theirs "$hash" 2>/dev/null; then
                        warn "  Auto-resolved conflict (--theirs): $(git log -1 --oneline "$hash")"
                        DISPATCH_LAST_PICKED=$((DISPATCH_LAST_PICKED + 1))
                        continue
                    fi
                fi
                _handle_cherry_pick_conflict "$_DISPATCH_WT_PATH" "$hash" "$_idx" "${#hashes[@]}" "$resolve" "$branch" "${hashes[@]:$((_idx+1))}"
                _conflict_leave "$resolve"; return 1
            fi
            DISPATCH_LAST_PICKED=$((DISPATCH_LAST_PICKED + 1))
        fi
    done

    _leave_branch
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
    if [[ -z "$cur" ]]; then
        die "Detached HEAD. Checkout a branch first: git checkout <branch>"
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
    local base="" target_pattern="" hooks_only=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hooks)  hooks_only=true; shift ;;
            --base)   base="$2"; shift 2 ;;
            --target-pattern) target_pattern="$2"; shift 2 ;;
            --mode)   shift 2 ;;  # deprecated, ignored
            --force)  shift ;;
            -*)       die "Unknown flag: $1" ;;
            *)        die "Unexpected argument: $1" ;;
        esac
    done

    if $hooks_only; then
        _install_hooks
        return
    fi

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
        local existing_pattern
        existing_pattern=$(_get_config targetPattern)
        local target_count
        target_count=$(find_dispatch_targets "$source" | wc -l | tr -d ' ')

        warn "Warning: dispatch already configured on this branch:"
        warn "  base:   $existing_base"
        warn "  target-pattern: ${existing_pattern:-<unset>}"
        [[ "$target_count" -gt 0 ]] && warn "  targets: $target_count branches exist"
        echo ""
        warn "Overwriting config will orphan existing target branches."

        if [[ -t 0 ]]; then
            read -p "Proceed? [y/N] " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
        else
            die "Dispatch already configured. Use --force to overwrite in non-interactive mode."
        fi
    fi

    git config dispatch.base "$base"
    git config dispatch.targetPattern "$target_pattern"

    _install_hooks

    echo ""
    info "Initialized dispatch on '$source'"
    echo -e "  ${CYAN}base:${NC}   $base"
    echo -e "  ${CYAN}target-pattern:${NC} $target_pattern"
}

# ---------- apply ----------

cmd_apply() {
    _require_init
    _acquire_lock

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

    local base source
    base=$(_get_config base)
    source=$(resolve_source "")
    [[ -n "$source" ]] || die "Not on a branch and no dispatch source configured"

    # Ensure base ref is up-to-date before creating/updating targets (best-effort)
    _refresh_base "$base" || true

    # Parse trailer-tagged commits into temp file: "hash target-id" per line
    local commit_file patch_map_file
    commit_file=$(mktemp)
    patch_map_file=$(mktemp)
    trap "rm -f '$commit_file' '$patch_map_file'" RETURN

    while IFS= read -r _h; do
        # Skip merge commits (they have no Dispatch-Target-Id and that's expected)
        local _pc
        _pc=$(git rev-list --parents -n1 "$_h" | wc -w)
        (( _pc > 2 )) && continue
        # Skip commits from base (already integrated)
        git merge-base --is-ancestor "$_h" "$base" 2>/dev/null && continue
        local _t
        _t=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" "$_h" | tr -d '[:space:]')
        echo "$_h $_t"
    done < <(git log --reverse --format="%H" "$base..$source") > "$commit_file"

    if [[ ! -s "$commit_file" ]]; then
        local _total_count
        _total_count=$(git rev-list --count "$base..$source" 2>/dev/null || echo 0)
        if [[ "$_total_count" -gt 0 ]]; then
            die "No non-merge commits found between $base and $source ($_total_count merge commits skipped)"
        fi
        die "No commits found between $base and $source"
    fi

    # Check if all commits target all (Dispatch-Target-Id: all) with no specific targets
    local _has_targets
    _has_targets=$(awk '$2 != "all" {found=1; exit} END {print found+0}' "$commit_file")
    if [[ "$_has_targets" -eq 0 ]]; then
        info "All commits target all (Dispatch-Target-Id: all). No specific targets to apply."
        return
    fi

    # Validate all commits have numeric Dispatch-Target-Id or "all"
    while read -r hash tid; do
        [[ -z "$tid" ]] && die "Commit $(echo "$hash" | cut -c1-8) has no Dispatch-Target-Id trailer"
        [[ "$tid" == "all" ]] && continue
        if ! echo "$tid" | grep -Eq '^[1-9][0-9]*(\.[0-9]+)?$'; then
            if echo "$tid" | grep -Eq '^0[0-9]'; then
                die "Commit $(echo "$hash" | cut -c1-8) has Dispatch-Target-Id '$tid' with leading zero. Use '${tid#0}' instead."
            elif [[ "$tid" == "0" ]]; then
                die "Commit $(echo "$hash" | cut -c1-8) has Dispatch-Target-Id '0'. Use a positive integer."
            fi
            die "Commit $(echo "$hash" | cut -c1-8) has non-numeric Dispatch-Target-Id '$tid'"
        fi
    done < "$commit_file"

    # Ordered unique target ids (numeric sort), excluding "all"
    local -a target_ids=()
    while IFS= read -r tid; do
        target_ids+=("$tid")
    done < <(awk '$2 != "all" && !seen[$2]++ {print $2}' "$commit_file" | sort -t. -k1,1n -k2,2n)

    # --- Stale target detection ---
    _build_source_patch_id_map "$patch_map_file" "$commit_file"

    local -a stale_branches=() stale_tids=() stale_counts=() stale_target_only=()
    while IFS= read -r existing; do
        [[ -n "$existing" ]] || continue
        local etid
        etid=$(_extract_tid_from_branch "$existing")
        [[ -n "$etid" ]] || continue

        # Skip targets whose tid is still in source
        local still_active=false
        for t in "${target_ids[@]}"; do
            [[ "$t" == "$etid" ]] && { still_active=true; break; }
        done
        $still_active && continue

        # tid no longer in source - check for reassignment via patch-id
        local stale_out
        stale_out=$(_find_stale_commits "$existing" "$etid" "$base" "$patch_map_file") || true
        local sc=0
        [[ -n "$stale_out" ]] && sc=$(echo "$stale_out" | wc -l | tr -d ' ')
        local total
        total=$(git rev-list --count "$base..$existing" 2>/dev/null || echo 0)
        local to=$((total - sc))
        [[ $to -lt 0 ]] && to=0

        stale_branches+=("$existing")
        stale_tids+=("$etid")
        stale_counts+=("$sc")
        stale_target_only+=("$to")
    done < <(find_dispatch_targets "$source")

    if [[ ${#stale_branches[@]} -gt 0 ]]; then
        echo ""
        warn "Stale targets detected (Dispatch-Target-Id reassigned on source):"
        echo ""
        for i in "${!stale_branches[@]}"; do
            local sb="${stale_branches[$i]}"
            local st="${stale_tids[$i]}"
            local sc="${stale_counts[$i]}"
            local to="${stale_target_only[$i]}"
            echo -e "  ${RED}${sb}${NC} (tid ${st})"
            [[ $sc -gt 0 ]] && echo "    ${sc} commit(s) reassigned to different Dispatch-Target-Id"
            [[ $to -gt 0 ]] && echo -e "    ${RED}${to} target-only commit(s) will be lost${NC}"
        done
        echo ""
        if $dry_run; then
            for sb in "${stale_branches[@]}"; do
                echo -e "  ${YELLOW}would rebuild${NC} ${sb}"
            done
            echo ""
        elif $force; then
            for sb in "${stale_branches[@]}"; do
                local wt_path
                wt_path=$(worktree_for_branch "$sb")
                if [[ -n "$wt_path" ]]; then
                    # Warn if worktree has uncommitted changes
                    if ! git -C "$wt_path" diff --quiet 2>/dev/null || ! git -C "$wt_path" diff --cached --quiet 2>/dev/null; then
                        warn "  Worktree $wt_path has uncommitted changes. Stashing before removal."
                        git -C "$wt_path" stash push --include-untracked --quiet -m "git-dispatch: auto-stash before worktree removal" 2>/dev/null || true
                    fi
                    git worktree remove --force "$wt_path" 2>/dev/null || true
                    git worktree prune 2>/dev/null || true
                fi
                git config --remove-section "branch.${sb}" 2>/dev/null || true
                git branch -D "$sb" 2>/dev/null || true
                info "  Deleted stale ${sb}"
            done
            echo ""
        else
            warn "Run: git dispatch apply --force  to rebuild stale targets."
            exit 1
        fi
    fi

    local created=0 updated=0 skipped=0 failed=0

    # --reset <id>: delete the target branch so apply recreates it fresh
    if [[ -n "$reset_target" ]]; then
        local reset_branch
        reset_branch=$(_target_branch_name "$reset_target")
        if git rev-parse --verify "refs/heads/$reset_branch" &>/dev/null; then
            # Check for target-only commits that would be lost
            if ! $force; then
                local _target_only=0
                while IFS= read -r _rh; do
                    [[ -n "$_rh" ]] || continue
                    local _rpc
                    _rpc=$(git rev-list --parents -n1 "$_rh" | wc -w)
                    (( _rpc > 2 )) && continue
                    local _rtid
                    _rtid=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" "$_rh" | tr -d '[:space:]')
                    [[ -z "$_rtid" || "$_rtid" != "$reset_target" ]] && _target_only=$((_target_only + 1))
                done < <(git log --format="%H" "$base..$reset_branch" 2>/dev/null)
                if [[ $_target_only -gt 0 ]]; then
                    warn "$reset_branch has $_target_only target-only commit(s) that will be lost."
                    if [[ -t 0 ]]; then
                        read -p "Proceed? [y/N] " confirm
                        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                            echo "Aborted."
                            return 0
                        fi
                    else
                        die "Use --force to confirm --reset with target-only commits."
                    fi
                fi
            fi
            # Remove worktree if branch is checked out in one
            local wt_path
            wt_path=$(git worktree list --porcelain 2>/dev/null | awk -v b="$reset_branch" '
                /^worktree / { path=$2 }
                /^branch refs\/heads\// { if ($2 == "refs/heads/" b) print path }
            ')
            if [[ -n "$wt_path" ]]; then
                # Stash uncommitted changes before removing worktree
                if ! git -C "$wt_path" diff --quiet 2>/dev/null || ! git -C "$wt_path" diff --cached --quiet 2>/dev/null; then
                    warn "Worktree $wt_path has uncommitted changes. Stashing."
                    git -C "$wt_path" stash push --include-untracked --quiet -m "git-dispatch: auto-stash before worktree removal" 2>/dev/null || true
                fi
                git worktree remove --force "$wt_path" 2>/dev/null || true
                git worktree prune 2>/dev/null || true
                info "Removed worktree $wt_path"
            fi
            local delete_err
            if delete_err=$(git branch -D "$reset_branch" 2>&1); then
                info "Deleted $reset_branch (will regenerate)"
            else
                die "Could not delete $reset_branch: $delete_err"
            fi
        else
            die "Branch $reset_branch does not exist"
        fi
    fi

    # Display all-target commits in dry-run
    if $dry_run; then
        local all_count
        all_count=$(awk '$2 == "all"' "$commit_file" | wc -l | tr -d ' ')
        if [[ "$all_count" -gt 0 ]]; then
            echo -e "  ${GREEN}include${NC} $all_count commit(s) in all targets (Dispatch-Target-Id: all)"
        fi
    fi

    for tid in "${target_ids[@]}"; do
        local branch_name
        branch_name=$(_target_branch_name "$tid")

        # Collect hashes for this target (including "all" commits, in source order)
        local -a hashes=()
        while IFS= read -r h; do
            hashes+=("$h")
        done < <(awk -v t="$tid" '$2 == t || $2 == "all" {print $1}' "$commit_file")

        local parent_branch="$base"

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
                    ctid=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" "$hash" | tr -d '[:space:]')
                    [[ "$ctid" == "$tid" || "$ctid" == "all" ]] && new_count=$((new_count + 1))
                done <<< "$cherry_out"
                if [[ $new_count -gt 0 ]]; then
                    echo -e "  ${YELLOW}cherry-pick${NC} $new_count commit(s) to target $tid  $branch_name"
                else
                    echo -e "  ${GREEN}skip${NC} target $tid  $branch_name  in sync"
                fi
            else
                echo -e "  ${YELLOW}create${NC} target $tid  $branch_name  (${#hashes[@]} commits from $parent_branch)"
            fi
            continue
        fi

        if git rev-parse --verify "refs/heads/$branch_name" &>/dev/null; then
            # Guard: verify this branch is actually a dispatch target (not a pre-existing foreign branch)
            local _branch_source
            _branch_source=$(git config "branch.${branch_name}.dispatchsource" 2>/dev/null || true)
            if [[ -z "$_branch_source" ]]; then
                warn "  $branch_name exists but is not a dispatch target (missing dispatchsource)."
                warn "  Skipping to avoid corrupting a foreign branch. Delete it or run: git dispatch apply --reset $tid"
                failed=$((failed + 1))
                continue
            fi

            # Target exists locally - cherry-pick new commits (including "all" commits)
            local -a new_hashes=()
            local cherry_out
            cherry_out=$(git cherry -v "$branch_name" "$source" 2>/dev/null) || true
            while IFS= read -r line; do
                [[ "$line" == +* ]] || continue
                local hash
                hash=$(echo "$line" | awk '{print $2}')
                local ctid
                ctid=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" "$hash" | tr -d '[:space:]')
                [[ "$ctid" == "$tid" || "$ctid" == "all" ]] && new_hashes+=("$hash")
            done <<< "$cherry_out"

            if [[ ${#new_hashes[@]} -gt 0 ]]; then
                _cherry_pick_commits "$resolve" "$branch_name" "${new_hashes[@]}"
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

            git config "branch.${branch_name}.dispatchsource" "$source"

            local cherry_pick_failed=false
            if ! _cherry_pick_commits "$resolve" "$branch_name" --theirs-fallback "${hashes[@]}"; then
                cherry_pick_failed=true
            fi

            if $cherry_pick_failed; then
                warn "  $branch_name created (cherry-pick conflicted)"
            else
                info "  Created $branch_name (${#hashes[@]} commits)"
            fi
            created=$((created + 1))
        fi
    done

    echo ""
    if $dry_run; then
        echo -e "${CYAN}Summary (dry-run):${NC} ${#target_ids[@]} targets"
    else
        local summary="$created created, $updated updated, $skipped in sync"
        [[ $failed -gt 0 ]] && summary="$summary, ${RED}$failed failed${NC}"
        echo -e "${CYAN}Summary:${NC} $summary"

        # Warn if targets may be missing base commits
        if [[ $skipped -gt 0 || $updated -gt 0 ]]; then
            local _base_ahead
            _base_ahead=$(git rev-list --count "$source..$base" 2>/dev/null || echo 0)
            if [[ "$_base_ahead" -gt 0 ]]; then
                echo ""
                warn "Note: source is $_base_ahead commit(s) behind $base."
                warn "Targets may need base update. Run: git dispatch merge --from base --to all"
            fi
        fi
    fi
}

# ---------- cherry-pick ----------

cmd_cherry_pick() {
    _require_init
    _acquire_lock

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
        cmd_apply "${dry_run:+--dry-run}" "${resolve:+--resolve}" "${force:+--force}"
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
            tid=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" "$hash" | tr -d '[:space:]')
            [[ "$tid" == "$to" || "$tid" == "all" ]] && new_hashes+=("$hash")
        done <<< "$cherry_out"

        if [[ ${#new_hashes[@]} -eq 0 ]]; then
            info "Target $to already in sync"
            return
        fi

        if $dry_run; then
            echo -e "${YELLOW}[dry-run]${NC} cherry-pick ${#new_hashes[@]} commit(s) from source to $target_branch"
            return
        fi

        _cherry_pick_commits "$resolve" "$target_branch" "${new_hashes[@]}"
        info "Cherry-picked ${#new_hashes[@]} commit(s) to $target_branch"

    else
        # Cherry-pick from target <id> to source
        [[ "$to" == "source" ]] || die "Invalid --to '$to'. Use: source or a Dispatch-Target-Id"

        local target_branch
        target_branch=$(_target_branch_name "$from")
        git rev-parse --verify "refs/heads/$target_branch" &>/dev/null || \
            die "Target branch '$target_branch' does not exist locally. Run: git dispatch apply"

        local -a new_hashes=()
        local cherry_out
        cherry_out=$(git cherry -v "$source" "$target_branch" "$base" 2>/dev/null) || \
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
        _cherry_pick_commits "$resolve" "$source" --add-trailer "$from" "${new_hashes[@]}"
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
    _acquire_lock

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

    # Ensure base ref is up-to-date before rebasing (best-effort)
    _refresh_base "$base" || true

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

    _enter_branch "$source" || die "Cannot access branch $source (worktree conflict?)"
    local -a gcmd=(git -C "$_DISPATCH_WT_PATH")

    if ! "${gcmd[@]}" rebase "$base"; then
        echo ""
        warn "Rebase conflict on $source onto $base"
        _show_conflict_diff "$_DISPATCH_WT_PATH"
        if $resolve; then
            echo ""
            warn "Resolve conflicts, then run: git -C $_DISPATCH_WT_PATH rebase --continue"
            warn "Worktree left at: $_DISPATCH_WT_PATH"
            _DISPATCH_WT_CREATED=false  # prevent cleanup
            exit 1
        fi
        "${gcmd[@]}" rebase --abort 2>/dev/null || true
        _leave_branch
        echo ""
        warn "Aborted. Re-run with --resolve to keep conflict active for manual resolution."
        exit 1
    fi

    _leave_branch
    info "Rebased $source onto $base"
}

# ---------- merge ----------

cmd_merge() {
    _require_init
    _acquire_lock

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

    # Ensure base ref is up-to-date before merging (best-effort)
    _refresh_base "$base" || true

    # Build list of branches to merge into
    local -a branches=()
    if [[ "$to" == "source" ]]; then
        branches=("$source")
    elif [[ "$to" == "all" ]]; then
        branches=("$source")
        while IFS= read -r c; do
            [[ -n "$c" ]] && branches+=("$c")
        done < <(find_dispatch_targets "$source")
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

    local merged=0 uptodate=0 failed=0

    for branch in "${branches[@]}"; do
        local count
        count=$(git rev-list --count "$branch..$base" 2>/dev/null || echo 0)
        if [[ "$count" -eq 0 ]]; then
            info "  $branch: up to date"
            uptodate=$((uptodate + 1))
            continue
        fi

        _enter_branch "$branch" || {
            warn "  Cannot access $branch (worktree conflict?)"
            failed=$((failed + 1))
            continue
        }
        local -a gcmd=(git -C "$_DISPATCH_WT_PATH")

        if ! "${gcmd[@]}" merge "$base" --no-edit; then
            echo ""
            warn "Merge conflict on $branch from $base"
            _show_conflict_diff "$_DISPATCH_WT_PATH"
            if $resolve; then
                echo ""
                warn "Resolve conflicts in worktree, then run: git -C $_DISPATCH_WT_PATH commit"
                warn "Worktree left at: $_DISPATCH_WT_PATH"
                _DISPATCH_WT_CREATED=false  # prevent cleanup
                exit 1
            fi
            "${gcmd[@]}" merge --abort 2>/dev/null || true
            _leave_branch
            warn "  $branch: merge conflict (skipped)"
            failed=$((failed + 1))
            continue
        fi

        info "  Merged $base into $branch"
        merged=$((merged + 1))
        _leave_branch
    done

    echo ""
    info "Summary: $merged merged, $uptodate up to date${failed:+, $failed failed}"
}

# ---------- push ----------

cmd_push() {
    _require_init

    local target="" dry_run=false force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)  dry_run=true; shift ;;
            --force)    force=true; shift ;;
            -*)         die "Unknown flag: $1" ;;
            *)          [[ -z "$target" ]] && target="$1" || die "Unexpected argument: $1"; shift ;;
        esac
    done

    [[ -n "$target" ]] || die "Usage: git dispatch push <all|source|N> [--dry-run] [--force]"

    local base source
    base=$(_get_config base)
    source=$(resolve_source "")

    local -a branches=()

    if [[ "$target" == "all" ]]; then
        while IFS= read -r c; do
            [[ -n "$c" ]] && branches+=("$c")
        done < <(find_dispatch_targets "$source")
        [[ ${#branches[@]} -gt 0 ]] || die "No targets found"
    elif [[ "$target" == "source" ]]; then
        branches=("$source")
    else
        # Numeric target id
        local target_branch
        target_branch=$(_target_branch_name "$target")
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

    local base target_pattern source has_stale=false has_diverged=false has_cosmetic=false
    base=$(_get_config base)
    target_pattern=$(_get_config targetPattern)
    source=$(resolve_source "")

    echo -e "${CYAN}base:${NC}   $base"
    echo -e "${CYAN}source:${NC} $source"
    echo -e "${CYAN}target-pattern:${NC} ${target_pattern:-\"\"}"
    echo ""

    local -a ordered=()
    while IFS= read -r c; do
        [[ -n "$c" ]] && ordered+=("$c")
    done < <(find_dispatch_targets "$source")

    # Also find Dispatch-Target-Ids in source that don't have branches yet
    local -a source_tids=()
    local status_commit_file status_map_file
    status_commit_file=$(mktemp)
    status_map_file=$(mktemp)
    trap "rm -f '$status_commit_file' '$status_map_file'" RETURN
    while IFS= read -r _h; do
        local _t
        _t=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" "$_h" | tr -d '[:space:]')
        if [[ -n "$_t" ]]; then
            source_tids+=("$_t")
            echo "$_h $_t" >> "$status_commit_file"
        fi
    done < <(git log --format="%H" "$base..$source")
    _build_source_patch_id_map "$status_map_file" "$status_commit_file"
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

        # Check for stale commits (reassigned to different tid)
        local stale_out
        stale_out=$(_find_stale_commits "$branch_name" "$tid" "$base" "$status_map_file") || true
        local stale_count=0
        [[ -n "$stale_out" ]] && stale_count=$(echo "$stale_out" | wc -l | tr -d ' ')
        if [[ $stale_count -gt 0 ]]; then
            printf "  ${RED}%-${max_tid}s${NC}  %-${max_branch}s  ${RED}stale (%d commit(s) reassigned)${NC}${pr_suffix}\n" "$tid" "$branch_name" "$stale_count"
            has_stale=true
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
            ctid=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" "$hash" | tr -d '[:space:]')
            [[ "$ctid" == "$tid" || "$ctid" == "all" ]] && source_to_target_candidates+=("$hash")
        done <<< "$cherry_out"

        if [[ ${#source_to_target_candidates[@]} -gt 0 ]]; then
            # Fast path: check if file content matches for all files touched by candidate commits
            local -a candidate_files_arr=()
            for hash in "${source_to_target_candidates[@]}"; do
                while IFS= read -r _cf; do
                    [[ -n "$_cf" ]] && candidate_files_arr+=("$_cf")
                done < <(git diff-tree --no-commit-id --name-only -r "$hash" 2>/dev/null)
            done
            # Deduplicate
            local -a candidate_files_uniq=()
            while IFS= read -r _cf; do
                [[ -n "$_cf" ]] && candidate_files_uniq+=("$_cf")
            done < <(printf '%s\n' "${candidate_files_arr[@]}" | sort -u)

            if [[ ${#candidate_files_uniq[@]} -gt 0 ]] && git diff --quiet "$source" "$branch_name" -- "${candidate_files_uniq[@]}" 2>/dev/null; then
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
        local -a target_to_source_candidates=()
        cherry_out=$(git cherry -v "$source" "$branch_name" "$base" 2>/dev/null) || true
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
            local -a t2s_files_arr=()
            for hash in "${target_to_source_candidates[@]}"; do
                while IFS= read -r _tf; do
                    [[ -n "$_tf" ]] && t2s_files_arr+=("$_tf")
                done < <(git diff-tree --no-commit-id --name-only -r "$hash" 2>/dev/null)
            done
            # Deduplicate
            local -a t2s_files_uniq=()
            while IFS= read -r _tf; do
                [[ -n "$_tf" ]] && t2s_files_uniq+=("$_tf")
            done < <(printf '%s\n' "${t2s_files_arr[@]}" | sort -u)

            if [[ ${#t2s_files_uniq[@]} -gt 0 ]] && git diff --quiet "$source" "$branch_name" -- "${t2s_files_uniq[@]}" 2>/dev/null; then
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

        # Count untracked commits: target commits with no Dispatch-Target-Id or mismatched Dispatch-Target-Id
        local untracked=0
        while IFS= read -r thash; do
            [[ -n "$thash" ]] || continue
            # Skip merge commits
            local _pcount
            _pcount=$(git rev-list --parents -n1 "$thash" | wc -w)
            (( _pcount > 2 )) && continue
            local _ctid
            _ctid=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" "$thash" | tr -d '[:space:]')
            [[ -z "$_ctid" || ( "$_ctid" != "$tid" && "$_ctid" != "all" ) ]] && untracked=$((untracked + 1))
        done < <(git log --format="%H" "$base..$branch_name" 2>/dev/null)

        if [[ $source_to_target -eq 0 && $target_to_source -eq 0 && $untracked -eq 0 ]]; then
            printf "  ${GREEN}%-${max_tid}s${NC}  %-${max_branch}s  in sync${pr_suffix}\n" "$tid" "$branch_name"
        else
            local status_parts=""
            [[ $source_to_target -gt 0 ]] && status_parts="${source_to_target} behind source"
            [[ $target_to_source -gt 0 ]] && status_parts="${status_parts:+$status_parts, }${target_to_source} ahead"
            [[ $untracked -gt 0 ]] && status_parts="${status_parts:+$status_parts, }${CYAN}${untracked} untracked${NC}"

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

    # Detect orphaned targets (tid no longer in source)
    local -a orphaned_branches=() orphaned_tids=()
    while IFS= read -r existing; do
        [[ -n "$existing" ]] || continue
        local etid
        etid=$(_extract_tid_from_branch "$existing")
        [[ -n "$etid" ]] || continue
        local found=false
        for t in "${unique_tids[@]}"; do
            [[ "$t" == "$etid" ]] && { found=true; break; }
        done
        $found && continue
        orphaned_branches+=("$existing")
        orphaned_tids+=("$etid")
    done < <(find_dispatch_targets "$source")

    if [[ ${#orphaned_branches[@]} -gt 0 ]]; then
        echo ""
        warn "Stale targets (Dispatch-Target-Id no longer in source):"
        for i in "${!orphaned_branches[@]}"; do
            printf "  ${RED}%-${max_tid}s${NC}  %-${max_branch}s  ${RED}stale (all commits reassigned)${NC}\n" \
                "${orphaned_tids[$i]}" "${orphaned_branches[$i]}"
        done
        has_stale=true
    fi

    if [[ "${has_diverged:-}" == "true" ]]; then
        echo ""
        warn "Diverged targets have different file content than source."
        warn "Run: git dispatch diff --to <id>  to inspect."
    fi
    if [[ "${has_cosmetic:-}" == "true" ]]; then
        echo ""
        echo "  \"cosmetic\" = same file content, different commit SHAs (normal after"
        echo "  conflict resolution). Safe to ignore, or fix by regenerating the target:"
        echo "  git dispatch apply --reset <id>"
    fi
    if [[ "${has_stale:-}" == "true" ]]; then
        echo ""
        warn "Run: git dispatch apply --force  to rebuild stale targets."
    fi

}

# ---------- diff ----------

cmd_diff() {
    _require_init

    local target=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to) target="$2"; shift 2 ;;
            -*)   die "Unknown flag: $1" ;;
            *)    die "Unexpected argument: $1" ;;
        esac
    done

    [[ -n "$target" ]] || die "Missing --to <id>"

    local base source target_branch
    base=$(_get_config base)
    source=$(resolve_source "")
    target_branch=$(_target_branch_name "$target")

    git rev-parse --verify "refs/heads/$target_branch" &>/dev/null || \
        die "Target branch '$target_branch' does not exist locally."

    local -a target_files_arr=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && target_files_arr+=("$f")
    done < <(_target_id_files "$base" "$target_branch" "$target" | sort -u)

    if [[ ${#target_files_arr[@]} -eq 0 ]]; then
        info "No files changed by target $target on $target_branch"
        return
    fi

    local diff_files
    diff_files=$(git diff --name-only "$source" "$target_branch" -- "${target_files_arr[@]}" 2>/dev/null)

    if [[ -z "$diff_files" ]]; then
        info "No content difference between $source and $target_branch"
    else
        warn "Files diverged between $source and $target_branch:"
        echo "$diff_files" | while IFS= read -r f; do echo "  $f"; done
        echo ""
        git diff "$source" "$target_branch" -- "${target_files_arr[@]}" 2>/dev/null
        echo ""
        echo -e "${CYAN}To resolve:${NC}"
        echo "  git dispatch cherry-pick --from $target --to source --resolve   # bring target changes to source"
        echo "  git dispatch cherry-pick --from source --to $target              # push source version to target"
        echo -e "${CYAN}Then sync:${NC}"
        echo "  git dispatch apply"
    fi
}

# ---------- verify ----------

cmd_verify() {
    _require_init

    local base source
    base=$(_get_config base)
    source=$(resolve_source "")

    # Parse source commits (same pattern as cmd_apply)
    local commit_file
    commit_file=$(mktemp)
    local files_dir
    files_dir=$(mktemp -d)
    local base_files
    base_files=$(mktemp)
    local introducer_file
    introducer_file=$(mktemp)
    trap "rm -rf '$commit_file' '$files_dir' '$base_files' '$introducer_file'" RETURN

    while IFS= read -r _h; do
        local _pc
        _pc=$(git rev-list --parents -n1 "$_h" | wc -w)
        (( _pc > 2 )) && continue
        local _t
        _t=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" "$_h" | tr -d '[:space:]')
        echo "$_h $_t"
    done < <(git log --reverse --format="%H" "$base..$source") > "$commit_file"

    [[ -s "$commit_file" ]] || die "No commits found between $base and $source"

    # Ordered unique target ids
    local -a target_ids=()
    while IFS= read -r tid; do
        target_ids+=("$tid")
    done < <(awk '!seen[$2]++ {print $2}' "$commit_file" | sort -t. -k1,1n -k2,2n)

    # Phase 1: Build per-target file sets + track introducers
    git ls-tree -r --name-only "$base" > "$base_files" 2>/dev/null || true

    while read -r hash tid; do
        [[ -n "$hash" ]] || continue
        while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            echo "$file" >> "$files_dir/$tid"
            # Track first introducer for new files
            if ! grep -Fxq "$file" "$base_files" 2>/dev/null; then
                if ! grep -q "^${file} " "$introducer_file" 2>/dev/null; then
                    echo "$file $tid" >> "$introducer_file"
                fi
            fi
        done < <(git diff-tree --no-commit-id --name-only -r "$hash" 2>/dev/null)
    done < "$commit_file"

    # Deduplicate per-target file lists
    for tid in "${target_ids[@]}"; do
        [[ -f "$files_dir/$tid" ]] && sort -u "$files_dir/$tid" -o "$files_dir/$tid"
    done

    # Phase 2: Detect cross-dependencies
    local has_deps=false
    local clean_count=0

    echo -e "${CYAN}Cross-dependency analysis (independent mode):${NC}"
    echo ""

    for tid_a in "${target_ids[@]}"; do
        [[ -f "$files_dir/$tid_a" ]] || { clean_count=$((clean_count + 1)); continue; }
        local -a deps=()

        while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            if ! grep -Fxq "$file" "$base_files" 2>/dev/null; then
                # New file - check introducer
                local intro_tid
                intro_tid=$(awk -v f="$file" '$0 ~ "^"f" " {print $NF; exit}' "$introducer_file")
                [[ -n "$intro_tid" && "$intro_tid" != "$tid_a" ]] && \
                    deps+=("${intro_tid}|new|${file}")
            else
                # Shared file - check other targets
                for tid_b in "${target_ids[@]}"; do
                    [[ "$tid_b" == "$tid_a" ]] && continue
                    if [[ -f "$files_dir/$tid_b" ]] && grep -Fxq "$file" "$files_dir/$tid_b" 2>/dev/null; then
                        deps+=("${tid_b}|shared|${file}")
                    fi
                done
            fi
        done < "$files_dir/$tid_a"

        if [[ ${#deps[@]} -gt 0 ]]; then
            has_deps=true
            local branch_name
            branch_name=$(_target_branch_name "$tid_a")
            printf "  ${YELLOW}%-6s${NC}  %s  depends on:\n" "$tid_a" "$branch_name"
            for dep in "${deps[@]}"; do
                IFS='|' read -r dtid dtype dfile <<< "$dep"
                if [[ "$dtype" == "new" ]]; then
                    printf "    target %-4s  ${RED}new file${NC}: %s\n" "$dtid" "$dfile"
                else
                    printf "    target %-4s  ${CYAN}shared file${NC}: %s\n" "$dtid" "$dfile"
                fi
            done
        else
            clean_count=$((clean_count + 1))
        fi
    done

    echo ""
    if $has_deps; then
        local dep_count=$(( ${#target_ids[@]} - clean_count ))
        echo -e "${CYAN}Summary:${NC} $dep_count target(s) with cross-dependencies, $clean_count clean"
        echo ""
        echo "New file dependencies will cause cherry-pick failures on apply."
        echo "Shared file modifications may cause CI failures on targets."
        echo ""
        echo -e "${CYAN}Options:${NC}"
        echo "  1. Move commits so dependent files share a Dispatch-Target-Id"
        echo "  2. Accept and resolve conflicts during apply"
        echo "  3. Tag shared commits with Dispatch-Target-Id: all and use Dispatch-Source-Keep for auto-resolve"
    else
        info "All ${#target_ids[@]} targets are file-independent."
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
    echo "  - hooks and core.hooksPath config"

    if ! $force; then
        echo ""
        read -p "Proceed? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi

    local cur
    cur=$(current_branch)

    # Delete target branches and metadata
    for target in "${targets[@]}"; do
        git config --unset "branch.${target}.dispatchsource" 2>/dev/null || true
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
    git config --unset dispatch.mode 2>/dev/null || true

    # Remove hooks and core.hooksPath
    local common_hooks
    common_hooks="$(cd "$(git rev-parse --git-common-dir)" && pwd)/hooks"
    rm -f "$common_hooks/commit-msg" "$common_hooks/prepare-commit-msg"
    git config --unset core.hooksPath 2>/dev/null || true

    echo ""
    info "Reset complete."
}

# ---------- continue ----------

# Find dispatch temp worktrees by naming convention
_find_dispatch_worktrees() {
    git worktree list --porcelain | awk '/^worktree / {path=substr($0, 10)} /^branch / {if (path ~ /git-dispatch-wt\./) print path}'
}

cmd_continue() {
    local -a wt_paths=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && wt_paths+=("$line")
    done < <(_find_dispatch_worktrees)

    if [[ ${#wt_paths[@]} -eq 0 ]]; then
        info "No pending dispatch operations."
        return
    fi

    for wt in "${wt_paths[@]}"; do
        local branch
        branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || echo "unknown")
        local git_dir
        git_dir=$(git -C "$wt" rev-parse --git-dir 2>/dev/null)

        if git -C "$wt" rev-parse --verify CHERRY_PICK_HEAD &>/dev/null; then
            warn "Cherry-pick conflict pending on $branch"
            warn "  Resolve in: $wt"
            warn "  Then run:   git -C $wt cherry-pick --continue"
        elif git -C "$wt" rev-parse --verify MERGE_HEAD &>/dev/null; then
            warn "Merge conflict pending on $branch"
            warn "  Resolve in: $wt"
            warn "  Then run:   git -C $wt commit"
        elif [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]; then
            warn "Rebase conflict pending on $branch"
            warn "  Resolve in: $wt"
            warn "  Then run:   git -C $wt rebase --continue"
        else
            info "Operation complete on $branch. Cleaning up $wt"
            git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
        fi
    done
    git worktree prune 2>/dev/null || true
}

# ---------- clean ----------

cmd_clean() {
    local force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            -*)      die "Unknown flag: $1" ;;
            *)       die "Unexpected argument: $1" ;;
        esac
    done

    local -a wt_paths=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && wt_paths+=("$line")
    done < <(_find_dispatch_worktrees)

    if [[ ${#wt_paths[@]} -eq 0 ]]; then
        info "No dispatch worktrees to clean."
        return
    fi

    for wt in "${wt_paths[@]}"; do
        local branch
        branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || echo "unknown")
        if $force; then
            git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
            info "  Removed $wt ($branch)"
        else
            echo "  $wt ($branch)"
        fi
    done

    if ! $force; then
        echo ""
        warn "Run: git dispatch clean --force  to remove all."
    fi
    git worktree prune 2>/dev/null || true
}

# ---------- checkout ----------

cmd_checkout() {
    local resolve=false force=false
    local subcmd=""
    local -a positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --resolve)  resolve=true; shift ;;
            --force)    force=true; shift ;;
            -*)         die "Unknown flag: $1" ;;
            *)          positional+=("$1"); shift ;;
        esac
    done

    [[ ${#positional[@]} -gt 0 ]] || die "Usage: git dispatch checkout <N|source|clear>"
    subcmd="${positional[0]}"

    case "$subcmd" in
        source) _checkout_source ;;
        clear)  _checkout_clear "$force" ;;
        *)      _checkout_create "$subcmd" "$resolve" ;;
    esac
}

_checkout_branch_name() {
    local source="$1" n="$2"
    echo "dispatch-checkout/${source}/${n}"
}

_find_checkout_branch() {
    local source="$1"
    git for-each-ref --format='%(refname:short)' "refs/heads/dispatch-checkout/${source}/" 2>/dev/null | head -1
}

_checkout_create() {
    local n="$1" resolve="$2"
    _require_init

    # Validate N is numeric
    if ! echo "$n" | grep -Eq '^[1-9][0-9]*(\.[0-9]+)?$'; then
        die "Invalid target id '$n'. Use a positive number (e.g., 3, 1.5)"
    fi

    local base source
    base=$(_get_config base)
    source=$(current_branch)

    # Must be on source branch
    local dispatch_base
    dispatch_base=$(_get_config base)
    [[ -n "$dispatch_base" ]] || die "Not initialized. Run: git dispatch init"
    # Verify we're on source (has dispatch config and is not a target)
    local cur_source
    cur_source=$(git config "branch.${source}.dispatchsource" 2>/dev/null || true)
    [[ -z "$cur_source" ]] || die "Cannot checkout from target branch. Switch to source first."

    local checkout_branch
    checkout_branch=$(_checkout_branch_name "$source" "$n")

    # Error if already exists
    if git rev-parse --verify "refs/heads/$checkout_branch" &>/dev/null; then
        die "Checkout branch '$checkout_branch' already exists. Run: git dispatch checkout clear"
    fi

    # Parse source commits
    local commit_file
    commit_file=$(mktemp)
    trap "rm -f '$commit_file'" RETURN

    while IFS= read -r hash; do
        local tid
        tid=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" "$hash" | tr -d '[:space:]')
        [[ -n "$tid" ]] && echo "$hash $tid"
    done < <(git log --reverse --format="%H" "$base..$source") > "$commit_file"

    # Filter: tid <= N (numeric) or tid == "all"
    local -a hashes=()
    while read -r hash tid; do
        if [[ "$tid" == "all" ]]; then
            hashes+=("$hash")
        elif echo "$tid" | grep -Eq '^[1-9][0-9]*(\.[0-9]+)?$'; then
            if awk "BEGIN {exit !($tid <= $n)}"; then
                hashes+=("$hash")
            fi
        fi
    done < "$commit_file"

    if [[ ${#hashes[@]} -eq 0 ]]; then
        die "No commits with Dispatch-Target-Id <= $n"
    fi

    # Create branch from base
    git branch --no-track "$checkout_branch" "$base" -q

    # Store active checkout in config
    git config dispatch.checkoutBranch "$checkout_branch"

    info "Creating checkout branch: $checkout_branch (${#hashes[@]} commits)"

    # Cherry-pick all filtered commits
    if ! _cherry_pick_commits "$resolve" "$checkout_branch" "${hashes[@]}"; then
        warn "Conflict during checkout. Resolve and run: git dispatch continue"
        return 1
    fi

    info "Checkout ready: $checkout_branch ($DISPATCH_LAST_PICKED picked, $DISPATCH_LAST_SKIPPED skipped)"

    # Print worktree path if one was created, or show how to use it
    local wt_path
    wt_path=$(worktree_for_branch "$checkout_branch")
    if [[ -n "$wt_path" ]]; then
        echo -e "  ${CYAN}worktree:${NC} $wt_path"
    else
        echo -e "  ${CYAN}branch:${NC} $checkout_branch"
        echo "  Switch with: git checkout $checkout_branch"
    fi
}

_checkout_source() {
    local cur
    cur=$(current_branch)

    # Check if on a checkout branch
    if [[ "$cur" == dispatch-checkout/* ]]; then
        # Extract source from branch name: dispatch-checkout/<source>/<N>
        # Source may contain slashes, N is the last segment
        local rest="${cur#dispatch-checkout/}"
        local source="${rest%/*}"
        if [[ -n "$source" ]]; then
            git checkout "$source" -q
            info "Switched to source: $source"
            return
        fi
    fi

    # Try dispatch config
    local dispatch_base
    dispatch_base=$(_get_config base 2>/dev/null || true)
    if [[ -n "$dispatch_base" ]]; then
        # Already on source
        info "Already on source: $cur"
        return
    fi

    # On a target branch? Find source from config
    local csource
    csource=$(git config "branch.${cur}.dispatchsource" 2>/dev/null || true)
    if [[ -n "$csource" ]]; then
        git checkout "$csource" -q
        info "Switched to source: $csource"
        return
    fi

    die "Cannot determine source branch."
}

_checkout_clear() {
    local force="$1"
    local source checkout_branch

    local cur
    cur=$(current_branch)

    # If on checkout branch, find source and switch first
    if [[ "$cur" == dispatch-checkout/* ]]; then
        local rest="${cur#dispatch-checkout/}"
        source="${rest%/*}"
        checkout_branch="$cur"
        git checkout "$source" -q
        info "Switched to source: $source"
    else
        source=$(resolve_source "")
        checkout_branch=$(_find_checkout_branch "$source")
    fi

    if [[ -z "$checkout_branch" ]]; then
        info "No checkout branch found."
        return
    fi

    # Check for unpicked commits
    if ! $force; then
        local base
        base=$(_get_config base)
        # Count commits on checkout that aren't on source (by patch-id)
        local checkout_count source_pids unpicked=0
        source_pids=$(git log --format="%H" "$base..$source" | while read -r h; do
            git show "$h" 2>/dev/null
        done | git patch-id --stable 2>/dev/null | awk '{print $1}')

        while IFS= read -r ch; do
            [[ -z "$ch" ]] && continue
            local cpid
            cpid=$(git show "$ch" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}')
            [[ -z "$cpid" ]] && continue
            if ! echo "$source_pids" | grep -Fxq "$cpid"; then
                unpicked=$((unpicked + 1))
            fi
        done < <(git log --format="%H" "$base..$checkout_branch")

        if [[ $unpicked -gt 0 ]]; then
            warn "$unpicked unpicked commit(s) on $checkout_branch"
            warn "Run: git dispatch checkin  (to pick back to source)"
            warn "  or: git dispatch checkout clear --force  (to discard)"
            return 1
        fi
    fi

    # Remove worktree if exists
    local wt_path
    wt_path=$(worktree_for_branch "$checkout_branch")
    if [[ -n "$wt_path" ]]; then
        git worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path"
    fi

    # Delete branch
    git branch -D "$checkout_branch" -q 2>/dev/null
    git config --unset dispatch.checkoutBranch 2>/dev/null || true
    git worktree prune 2>/dev/null || true

    info "Cleared: $checkout_branch"
}

# ---------- checkin ----------

cmd_checkin() {
    local resolve=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --resolve)  resolve=true; shift ;;
            -*)         die "Unknown flag: $1" ;;
            *)          die "Unexpected argument: $1" ;;
        esac
    done

    local cur
    cur=$(current_branch)

    # Must be on a checkout branch
    [[ "$cur" == dispatch-checkout/* ]] || die "Not on a checkout branch. Run from dispatch-checkout/<source>/<N>"

    # Extract source from branch name
    local rest="${cur#dispatch-checkout/}"
    local source="${rest%/*}"
    [[ -n "$source" ]] || die "Cannot parse source from branch name: $cur"

    local base
    base=$(git -C "$(git rev-parse --show-toplevel)" config dispatch.base 2>/dev/null || true)
    # Try reading base from source branch config
    if [[ -z "$base" ]]; then
        local source_wt
        source_wt=$(worktree_for_branch "$source")
        if [[ -n "$source_wt" ]]; then
            base=$(git -C "$source_wt" config dispatch.base 2>/dev/null || true)
        fi
    fi
    [[ -n "$base" ]] || die "Cannot determine base branch."

    # Build patch-id set for source commits
    local source_pids
    source_pids=$(git log --format="%H" "$base..$source" | while read -r h; do
        git show "$h" 2>/dev/null
    done | git patch-id --stable 2>/dev/null | awk '{print $1}')

    # Find new commits on checkout (not in source by patch-id)
    local -a new_hashes=()
    while IFS= read -r ch; do
        [[ -z "$ch" ]] && continue
        local cpid
        cpid=$(git show "$ch" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}')
        [[ -z "$cpid" ]] && continue
        if ! echo "$source_pids" | grep -Fxq "$cpid"; then
            new_hashes+=("$ch")
        fi
    done < <(git log --reverse --format="%H" "$base..$cur")

    if [[ ${#new_hashes[@]} -eq 0 ]]; then
        info "No new commits to pick."
        return
    fi

    info "Picking ${#new_hashes[@]} commit(s) to source: $source"

    # Cherry-pick to source, honoring Dispatch-Source-Keep
    if ! _cherry_pick_commits "$resolve" "$source" "${new_hashes[@]}"; then
        warn "Conflict during checkin. Resolve and run: git dispatch continue"
        return 1
    fi

    info "Checked in $DISPATCH_LAST_PICKED commit(s) to $source"
    echo -e "  ${CYAN}Next:${NC} git dispatch checkout source && git dispatch apply"
}

# ---------- help ----------

cmd_help() {
    cat <<'HELP'
git-dispatch: Create target branches from a source branch and keep them in sync.

SETUP
  git dispatch init --base <branch> --target-pattern <pattern>
  git dispatch init --hooks

  Initialize dispatch on the current branch. Stores config, installs hooks.
  Required: --base (recommended: "origin/master").
  Required: --target-pattern (must include "{id}"), e.g. "user/feat/task-{id}".

  --hooks installs only the commit hooks (useful in worktrees).

WORKFLOW
  1. Tag every commit with a Dispatch-Target-Id trailer:
       git commit -m "Add feature" --trailer "Dispatch-Target-Id=1"

  2. Create target branches and push:
       git dispatch apply
       git dispatch push all

  3. Integration testing:
       git dispatch checkout 3                          # branch with targets 1..3
       # run tests, fix bugs, commit with Dispatch-Target-Id
       git dispatch checkin                             # pick fixes back to source
       git dispatch checkout source                     # return to source
       git dispatch apply                               # propagate to targets
       git dispatch checkout clear                      # clean up test branch

  4. Propagate changes:
       git dispatch apply                               # source to all targets
       git dispatch cherry-pick --from source --to 2    # source to one target
       git dispatch cherry-pick --from 2 --to source    # target back to source

  5. Update with base changes:
       git dispatch merge --from base --to source       # source only, safe
       git dispatch merge --from base --to all          # source + all targets
       git dispatch rebase --from base --to source      # rewrites history

COMMANDS
  init        Configure dispatch on current source branch
  apply       Make all targets match source (create/update). Detects stale targets
              after Dispatch-Target-Id reassignment. --reset <id> to regenerate.
  checkout    Integration testing and navigation:
                checkout <N>       Create test branch with targets 1..N
                checkout source    Return to source branch
                checkout clear     Remove test branch (--force to discard unpicked)
  checkin     Cherry-pick new commits from checkout branch back to source.
              Honors Dispatch-Source-Keep for auto-conflict resolution.
  cherry-pick Move commits between source and target (--from/--to)
  rebase      Rebase source onto base (--from base --to source)
  merge       Merge base into branches (--from base --to <source|id|all>)
  push        Push branches (push <all|source|N>)
  status      Show base, source, and all targets with sync state
  verify      Detect cross-target file dependencies
  continue    Check pending conflict resolutions, clean up completed worktrees
  clean       List (or --force remove) leftover dispatch worktrees
  reset       Delete all dispatch metadata and target branches

FLAGS (on propagation commands)
  --dry-run   Show plan, make no changes
  --resolve   Leave conflict active in a temp worktree for manual resolution.
              The worktree path is printed. After resolving, run the shown
              git command, then: git dispatch continue
  --force     Override safety checks (apply: rebuild stale targets)

TRAILERS
  Dispatch-Target-Id (required): numeric integer or decimal (1, 2, 1.5), or "all"
    git commit -m "message" --trailer "Dispatch-Target-Id=1"
    git commit -m "shared change" --trailer "Dispatch-Target-Id=all"

  "all" includes the commit in every target during apply.
  Hook auto-carries Dispatch-Target-Id from previous commit when absent.

  Dispatch-Source-Keep (optional): force-accept source version on conflict
    git commit -m "regen files" --trailer "Dispatch-Target-Id=3" --trailer "Dispatch-Source-Keep=true"

  When a cherry-pick conflicts on a commit with this trailer, the source
  version is auto-accepted with --strategy-option theirs.

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
        verify)       cmd_verify "$@" ;;
        checkout)     cmd_checkout "$@" ;;
        checkin)      cmd_checkin "$@" ;;
        continue)     cmd_continue "$@" ;;
        clean)        cmd_clean "$@" ;;
        reset)        cmd_reset "$@" ;;
        help|--help|-h) cmd_help ;;
        *)            die "Unknown command: $cmd" ;;
    esac
}

main "$@"
