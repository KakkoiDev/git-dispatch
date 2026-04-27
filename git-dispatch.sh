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

# Spinner for long-running operations (stderr, so stdout stays clean for piping)
_SPINNER_PID=""
_spinner_start() {
    local msg="${1:-Processing...}"
    [[ ! -t 2 ]] && return 0  # no spinner in non-interactive (pipes, tests)
    (
        trap 'exit 0' TERM
        local frames=('/' '-' '\' '|')
        local i=0
        while true; do
            printf '\r  %s %s ' "${frames[$((i % 4))]}" "$msg" >&2
            i=$((i + 1))
            sleep 0.15 || exit 0
        done
    ) &
    _SPINNER_PID=$!
    disown "$_SPINNER_PID" 2>/dev/null || true
}
_spinner_stop() {
    if [[ -n "$_SPINNER_PID" ]]; then
        kill "$_SPINNER_PID" 2>/dev/null || true
        wait "$_SPINNER_PID" 2>/dev/null || true
        _SPINNER_PID=""
    fi
    [[ -t 2 ]] && printf '\r\033[K' >&2 || true
}

DISPATCH_YES=false

_confirm() {
    local prompt="${1:-Proceed?}"
    $DISPATCH_YES && return 0
    if [[ ! -t 0 ]]; then
        return 1
    fi
    local confirm
    read -p "$prompt [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]]
}

_prompt_input() {
    local prompt="$1" default="${2:-}"
    if [[ ! -t 0 ]]; then
        [[ -n "$default" ]] && { echo "$default"; return; }
        die "Missing input in non-interactive mode. Provide flags explicitly."
    fi
    local value
    read -p "$prompt" value
    echo "${value:-$default}"
}

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

# Detect multiple worktrees (for config scoping)
_has_worktrees() {
    local count
    count=$(git worktree list --porcelain 2>/dev/null | grep -c '^worktree ' || true)
    [[ "$count" -gt 1 ]]
}

# Enable extensions.worktreeConfig when worktrees are present
_ensure_worktree_config() {
    if _has_worktrees; then
        local enabled
        enabled=$(git config extensions.worktreeConfig 2>/dev/null || true)
        if [[ "$enabled" != "true" ]]; then
            git config extensions.worktreeConfig true
        fi
    fi
}

# Find other active dispatch sessions (source branches with dispatchbase set)
_other_dispatch_sessions() {
    local exclude="${1:-}"
    git for-each-ref --format='%(refname:short)' refs/heads/ | while read -r b; do
        [[ "$b" == "$exclude" ]] && continue
        local db
        db=$(git config "branch.${b}.dispatchbase" 2>/dev/null || true)
        [[ -n "$db" ]] && echo "$b"
    done
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

# Resolve the dispatch source branch for config lookups.
# Caches result in DISPATCH_SOURCE for repeated calls.
_resolve_config_branch() {
    [[ -n "${DISPATCH_SOURCE:-}" ]] && { echo "$DISPATCH_SOURCE"; return; }
    local cur
    cur=$(current_branch 2>/dev/null || true)
    [[ -z "$cur" ]] && return 1
    # Check if current branch has dispatch config (is a source)
    if [[ -n "$(git config "branch.${cur}.dispatchbase" 2>/dev/null || true)" ]]; then
        DISPATCH_SOURCE="$cur"; echo "$cur"; return
    fi
    # Check if current branch is a target (has dispatchsource)
    local csource
    csource=$(git config "branch.${cur}.dispatchsource" 2>/dev/null || true)
    if [[ -n "$csource" ]]; then
        DISPATCH_SOURCE="$csource"; echo "$csource"; return
    fi
    # Check if on a checkout branch
    if [[ "$cur" == dispatch-checkout/* ]]; then
        local rest="${cur#dispatch-checkout/}"
        local source="${rest%/*}"
        DISPATCH_SOURCE="$source"; echo "$source"; return
    fi
    return 1
}

# Read dispatch config for current source branch
_get_config() {
    local key="$1"
    local branch
    branch=$(_resolve_config_branch 2>/dev/null || true)
    if [[ -n "$branch" ]]; then
        git config "branch.${branch}.dispatch${key}" 2>/dev/null || true
    fi
}

# Write dispatch config for a specific source branch
_set_config() {
    local key="$1" value="$2" branch="${3:-}"
    [[ -z "$branch" ]] && branch=$(_resolve_config_branch 2>/dev/null || true)
    [[ -z "$branch" ]] && branch=$(current_branch)
    git config "branch.${branch}.dispatch${key}" "$value"
}

# Sync queue: remaining target branches to merge base into after a conflict pause.
# Stored as newline-separated list in branch.<source>.dispatchsyncqueue so it
# survives worktree teardown between `continue` calls.
_sync_queue_get() {
    local source="$1"
    git config "branch.${source}.dispatchsyncqueue" 2>/dev/null || true
}

_sync_queue_set() {
    local source="$1" value="$2"
    if [[ -z "$value" ]]; then
        git config --unset "branch.${source}.dispatchsyncqueue" 2>/dev/null || true
    else
        git config "branch.${source}.dispatchsyncqueue" "$value"
    fi
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

# ---------- audit log ----------
# Track auto-resolved cherry-pick conflicts in .git/dispatch-audit.log so users
# can see what was bypassed. Append-only; truncated to last 500 lines on apply start.

_audit_log_path() {
    local gd
    gd=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
    [[ -n "$gd" ]] || return 1
    echo "$gd/dispatch-audit.log"
}

_log_audit() {
    local action="$1" sha="$2" target="$3" reason="$4" files="$5"
    local log
    log=$(_audit_log_path 2>/dev/null) || return 0
    [[ -n "$log" ]] || return 0
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    printf '%s  %s  %s  target=%s  reason=%s  files=%s\n' \
        "$ts" "$action" "$sha" "$target" "$reason" "$files" >> "$log" 2>/dev/null || true
}

_audit_log_truncate() {
    local log
    log=$(_audit_log_path 2>/dev/null) || return 0
    [[ -f "$log" ]] || return 0
    local n
    n=$(wc -l < "$log" 2>/dev/null | tr -d ' ')
    [[ -n "$n" && "$n" -gt 500 ]] || return 0
    local tmp
    tmp=$(mktemp) || return 0
    tail -500 "$log" > "$tmp" && mv "$tmp" "$log"
}

_audit_log_summary() {
    local log
    log=$(_audit_log_path 2>/dev/null) || return 0
    [[ -f "$log" ]] || return 0
    local skips resolves
    skips=$(grep -c "  auto-skipped  " "$log" 2>/dev/null || echo 0)
    resolves=$(grep -c "  auto-resolved  " "$log" 2>/dev/null || echo 0)
    skips="${skips//[^0-9]/}"; skips="${skips:-0}"
    resolves="${resolves//[^0-9]/}"; resolves="${resolves:-0}"
    [[ "$skips" -eq 0 && "$resolves" -eq 0 ]] && return 0
    local sw="skips" rw="resolves"
    [[ "$skips" -eq 1 ]] && sw="skip"
    [[ "$resolves" -eq 1 ]] && rw="resolve"
    echo "$skips $sw, $resolves $rw"
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

# Remove legacy dispatch hooks from .git/hooks and core.hooksPath if present.
_remove_hooks() {
    local dir removed=false
    # Check both common hooks dir and core.hooksPath target
    local common_dir
    common_dir="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)/hooks"
    local hooks_path
    hooks_path=$(git config core.hooksPath 2>/dev/null || true)

    for dir in "$common_dir" "$hooks_path"; do
        [[ -n "$dir" ]] || continue
        for hook in prepare-commit-msg commit-msg; do
            if [[ -f "$dir/$hook" ]] && grep -q "git-dispatch" "$dir/$hook" 2>/dev/null; then
                rm "$dir/$hook"
                removed=true
            fi
        done
    done

    if $removed && [[ -n "$hooks_path" ]]; then
        _ensure_worktree_config
        local wt_enabled
        wt_enabled=$(git config extensions.worktreeConfig 2>/dev/null || true)
        if [[ "$wt_enabled" == "true" ]]; then
            git config --worktree --unset core.hooksPath 2>/dev/null || true
        fi
        git config --unset core.hooksPath 2>/dev/null || true
    fi
}

# Check if a branch's content has been merged (e.g. squash-merged) into base
_is_content_merged() {
    local branch_tip="$1" base_ref="$2"
    local mb
    mb=$(git merge-base "$base_ref" "$branch_tip" 2>/dev/null) || return 1
    local -a changed_files_arr=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && changed_files_arr+=("$f")
    done < <(git diff --name-only "$mb" "$branch_tip" 2>/dev/null)
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

# Extract Dispatch-Target-Id from a commit with fallback for broken trailer blocks.
# git's %(trailers) parser fails when cherry-pick metadata (# Conflicts:, cherry picked from)
# appears after the trailer, breaking the "last paragraph" rule. This function falls back to
# grepping the raw commit message for Dispatch-Target-Id: lines.
_extract_dispatch_tid() {
    local hash="$1"
    local tid
    tid=$(git log -1 --format="%(trailers:key=Dispatch-Target-Id,valueonly)" "$hash" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$tid" ]]; then
        echo "$tid"
        return
    fi
    tid=$(git log -1 --format="%B" "$hash" 2>/dev/null | \
        (grep -m1 "^Dispatch-Target-Id:" || true) | \
        sed 's/^Dispatch-Target-Id:[[:space:]]*//' | tr -d '[:space:]')
    [[ -n "$tid" ]] && echo "$tid"
    return 0
}

# Extract Dispatch-Source-Keep from a commit with fallback.
_extract_dispatch_source_keep() {
    local hash="$1"
    local val
    val=$(git log -1 --format="%(trailers:key=Dispatch-Source-Keep,valueonly)" "$hash" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$val" ]]; then
        echo "$val"
        return
    fi
    val=$(git log -1 --format="%B" "$hash" 2>/dev/null | \
        (grep -m1 "^Dispatch-Source-Keep:" || true) | \
        sed 's/^Dispatch-Source-Keep:[[:space:]]*//' | tr -d '[:space:]')
    [[ -n "$val" ]] && echo "$val"
    return 0
}

# Attempt to auto-resolve a sync merge conflict in $wt by honoring
# Dispatch-Source-Keep trailers on target commits. For each conflicted path,
# if any commit in <merge-base..target> that touches that path has
# Source-Keep=true, keep the target's version (file-scoped --ours; sync merges
# base INTO target so target = ours, base = theirs). Returns 0 iff all
# conflicts were resolved and a merge commit was produced.
_sync_try_source_keep_resolve() {
    local wt="$1" target="$2" base="$3"
    local -a unmerged=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && unmerged+=("$p")
    done < <(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)

    [[ ${#unmerged[@]} -gt 0 ]] || return 1

    local mb
    mb=$(git merge-base "$target" "$base" 2>/dev/null) || return 1

    local resolved=0
    for p in "${unmerged[@]}"; do
        local hashes
        hashes=$(git log "$mb..$target" --format="%H" -- "$p" 2>/dev/null)
        [[ -n "$hashes" ]] || continue
        while IFS= read -r h; do
            [[ -n "$h" ]] || continue
            local sk
            sk=$(_extract_dispatch_source_keep "$h")
            if [[ -n "$sk" ]]; then
                git -C "$wt" checkout --ours -- "$p" >/dev/null 2>&1 || return 1
                git -C "$wt" add -- "$p" >/dev/null 2>&1 || return 1
                info "  Source-Keep auto-resolved: $p (kept target version)"
                resolved=$((resolved + 1))
                break
            fi
        done <<< "$hashes"
    done

    local remaining
    remaining=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)
    [[ -z "$remaining" ]] || return 1
    [[ $resolved -gt 0 ]] || return 1

    git -C "$wt" commit --no-edit --no-verify >/dev/null 2>&1 || return 1
    return 0
}

# Validate a Dispatch-Target-Id value. Dies with descriptive error if invalid.
# Valid: positive integer, positive decimal, "all"
_validate_target_id() {
    local tid="$1"
    [[ -n "$tid" ]] || die "Dispatch-Target-Id is empty."
    [[ "$tid" == "all" ]] && return 0
    if ! echo "$tid" | grep -Eq '^[1-9][0-9]*(\.[0-9]+)?$'; then
        if echo "$tid" | grep -Eq '^0[0-9]'; then
            die "Dispatch-Target-Id '$tid' has a leading zero. Use '${tid#0}' instead."
        elif [[ "$tid" == "0" ]]; then
            die "Dispatch-Target-Id '0' is not valid. Use a positive integer."
        else
            die "Dispatch-Target-Id '$tid' is not numeric. Use integer or decimal (e.g., 1, 2, 1.5) or 'all'."
        fi
    fi
}

# Encode a target id for use in a git config variable name.
# git config vars allow only alphanumeric and '-' (no '.' or '_'), but decimal
# tids (e.g., 17.1) contain '.'. We map '.' -> '-' on write and reverse when
# parsing the key back. Safe because _validate_target_id restricts tids to
# digits and a single '.' (never contain '-' already).
_tid_cfg_encode() {
    printf '%s' "$1" | tr '.' '-'
}

_tid_cfg_decode() {
    printf '%s' "$1" | tr '-' '.'
}

# Find source commits not yet on a target branch.
# Primary: subject-line matching (handles cosmetic divergence from different cherry-pick contexts).
# Fallback: patch-id matching (handles amended subjects with identical diffs).
# Args: base target_branch hash1 [hash2 ...]
# Output: one hash per line for commits needing cherry-pick
_find_new_commits_for_target() {
    local base="$1" target_branch="$2"
    shift 2
    [[ $# -eq 0 ]] && return 0

    # Collect target subjects in one pass
    local target_subjects
    target_subjects=$(git log --no-merges --format="%s" "$base..$target_branch" 2>/dev/null) || true

    # If target has no commits, all source commits are new
    if [[ -z "$target_subjects" ]]; then
        printf '%s\n' "$@"
        return 0
    fi

    # Collect target patch-ids in one batched pass (fallback)
    local target_pids
    target_pids=$(git log --no-merges --format="%H" "$base..$target_branch" 2>/dev/null | \
        while read -r _h; do [[ -n "$_h" ]] && git show "$_h" 2>/dev/null; done | \
        git patch-id --stable 2>/dev/null | awk '{print $1}') || true

    local hash
    for hash in "$@"; do
        local subject
        subject=$(git log -1 --format="%s" "$hash")

        # Primary: subject-line match (handles cosmetic divergence)
        if [[ -n "$subject" ]] && printf '%s\n' "$target_subjects" | grep -Fxq "$subject"; then
            continue
        fi

        # Fallback: patch-id match (handles amended subjects)
        if [[ -n "$target_pids" ]]; then
            local spid
            spid=$(git show "$hash" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}')
            if [[ -n "$spid" ]] && printf '%s\n' "$target_pids" | grep -Fxq "$spid"; then
                continue
            fi
        fi

        echo "$hash"
    done
}

# Find commits on target that have no match in source (target-only commits).
# Output: one hash per line (in chronological order).
_find_target_only_commits() {
    local base="$1" target_branch="$2" source="$3"

    # Collect source subjects in one pass
    local source_subjects
    source_subjects=$(git log --no-merges --format="%s" "$base..$source" 2>/dev/null) || true

    # Collect source patch-ids in one batched pass
    local source_pids
    source_pids=$(git log --no-merges --format="%H" "$base..$source" 2>/dev/null | \
        while read -r _h; do [[ -n "$_h" ]] && git show "$_h" 2>/dev/null; done | \
        git patch-id --stable 2>/dev/null | awk '{print $1}') || true

    while IFS= read -r hash; do
        [[ -n "$hash" ]] || continue
        # Skip merge commits
        local _pc
        _pc=$(git rev-list --parents -n1 "$hash" | wc -w)
        (( _pc > 2 )) && continue

        local subject
        subject=$(git log -1 --format="%s" "$hash")

        # Check subject-line match
        if [[ -n "$subject" ]] && [[ -n "$source_subjects" ]] && printf '%s\n' "$source_subjects" | grep -Fxq "$subject"; then
            continue
        fi

        # Check patch-id match
        if [[ -n "$source_pids" ]]; then
            local tpid
            tpid=$(git show "$hash" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}')
            if [[ -n "$tpid" ]] && printf '%s\n' "$source_pids" | grep -Fxq "$tpid"; then
                continue
            fi
        fi

        echo "$hash"
    done < <(git log --reverse --format="%H" "$base..$target_branch" 2>/dev/null)
}

# Get files touched by commits with a specific Dispatch-Target-Id on a branch.
_target_id_files() {
    local base="$1" branch="$2" tid="$3"
    while IFS= read -r hash; do
        local ctid
        ctid=$(_extract_dispatch_tid "$hash")
        [[ "$ctid" == "$tid" ]] && git diff-tree --no-commit-id --name-only -r "$hash" 2>/dev/null
    done < <(git log --format="%H" "$base..$branch")
}

# Check if source and target have diverged content (not just different SHAs).
# Only checks files from commits with the matching Dispatch-Target-Id (avoids false
# positives from generated files or other tasks' changes in independent mode).
# Returns 0 if content actually differs, 1 if same content (different commits only).
#
# When files differ, uses commit-message traceability to distinguish base drift
# (source behind master) from real divergence. Cherry-pick preserves the original
# commit subject, so if every target commit matches a source commit by subject,
# the difference is from base drift / auto-conflict resolution, not independent changes.
_target_content_diverged() {
    local source="$1" target_branch="$2" base="$3" tid="$4" commit_file="${5:-}"
    local -a target_files_arr=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && target_files_arr+=("$f")
    done < <(_target_id_files "$base" "$target_branch" "$tid" | sort -u)
    [[ ${#target_files_arr[@]} -eq 0 ]] && return 1

    # Collect files from Source-Keep commits on target - these are generated
    # files expected to drift and should not count as divergence evidence.
    local -a sk_files=()
    while IFS= read -r hash; do
        local _sk
        _sk=$(_extract_dispatch_source_keep "$hash")
        [[ "$_sk" == "true" ]] || continue
        while IFS= read -r f; do
            [[ -n "$f" ]] && sk_files+=("$f")
        done < <(git diff-tree --no-commit-id --name-only -r "$hash" 2>/dev/null)
    done < <(git log --format="%H" "$base..$target_branch" 2>/dev/null)

    if [[ ${#sk_files[@]} -gt 0 ]]; then
        # Subtract Source-Keep files from the check set
        local -a filtered=()
        local sk_set
        sk_set=$(printf '%s\n' "${sk_files[@]}" | sort -u)
        for f in "${target_files_arr[@]}"; do
            echo "$sk_set" | grep -qxF "$f" || filtered+=("$f")
        done
        target_files_arr=("${filtered[@]+"${filtered[@]}"}")
        [[ ${#target_files_arr[@]} -eq 0 ]] && return 1
    fi

    git diff --quiet "$source" "$target_branch" -- "${target_files_arr[@]}" 2>/dev/null && return 1

    # Files differ. Check if all target commits trace back to source commits
    # by subject line. If they do, the diff is from base drift, not real divergence.
    if [[ -n "$commit_file" && -f "$commit_file" ]]; then
        local source_subjects=""
        while read -r _hash _ctid; do
            [[ "$_ctid" == "$tid" || "$_ctid" == "all" ]] || continue
            local _subj
            _subj=$(git log -1 --format="%s" "$_hash" 2>/dev/null)
            [[ -n "$_subj" ]] && source_subjects+="${_subj}"$'\n'
        done < "$commit_file"

        if [[ -n "$source_subjects" ]]; then
            local all_traced=true
            while IFS= read -r _tsubj; do
                [[ -n "$_tsubj" ]] || continue
                echo "$source_subjects" | grep -qxF "$_tsubj" || { all_traced=false; break; }
            done < <(git log --no-merges --format="%s" "$base..$target_branch" 2>/dev/null)
            $all_traced && return 1  # all matched = cosmetic (base drift)
        fi
    fi

    return 0
}

# Extract Dispatch-Target-Id from a branch name by reversing the target-pattern.
# Falls back to scanning aliases if pattern match fails.
_extract_tid_from_branch() {
    local branch="$1"
    local pattern
    pattern=$(_get_config targetPattern)
    local prefix="${pattern%%\{id\}*}"
    local suffix="${pattern#*\{id\}}"
    # Use literal string removal to avoid glob interpretation of [ ] * ? in pattern
    local tid=""
    if [[ "$branch" == "${prefix}"*"${suffix}" ]]; then
        tid="${branch#"$prefix"}"
        [[ -n "$suffix" ]] && tid="${tid%"$suffix"}"
    fi
    if [[ -n "$tid" ]] && echo "$tid" | grep -Eq '^[1-9][0-9]*(\.[0-9]+)?$'; then
        echo "$tid"; return 0
    fi
    # Fallback: check aliases for a match
    local source_branch
    source_branch=$(_resolve_config_branch 2>/dev/null || true)
    if [[ -n "$source_branch" ]]; then
        local alias_line akey aval atid
        while IFS= read -r alias_line; do
            [[ -n "$alias_line" ]] || continue
            akey="${alias_line%% *}"
            aval="${alias_line#* }"
            if [[ "$aval" == "$branch" ]]; then
                atid=$(_tid_cfg_decode "${akey##*dispatchtargetalias-}")
                echo "$atid"; return 0
            fi
        done < <(git config --get-regexp "^branch\.${source_branch}\.dispatchtargetalias-" 2>/dev/null || true)
    fi
    return 1
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
        # "all" commits legitimately appear on every target - not stale
        [[ -n "$match_tid" && "$match_tid" != "$tid" && "$match_tid" != "all" ]] && echo "$hash $match_tid"
    done <<< "$pid_output"
}

# Path to the ownership config at repo root.
_dispatch_targets_file_path() {
    local top
    top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    echo "$top/.git-dispatch-targets"
}

# Load ownership pairings. Emits "key<TAB>glob" per line on stdout.
# Returns 1 if file missing.
_load_ownership_globs() {
    local path
    path=$(_dispatch_targets_file_path) || return 1
    [[ -f "$path" ]] || return 1
    local line key glob
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        key="${line%%:*}"
        glob="${line#*:}"
        key="${key%"${key##*[![:space:]]}"}"
        glob="${glob#"${glob%%[![:space:]]*}"}"
        [[ -n "$key" && -n "$glob" && "$key" != "$line" ]] || continue
        printf '%s\t%s\n' "$key" "$glob"
    done < "$path"
}

# Bash-3-compatible glob matcher. Handles ** (span-directories), * (single segment),
# and ? (single char), without depending on shopt globstar.
_glob_match() {
    local path="$1" pat="$2"
    [[ "$path" == "$pat" ]] && return 0
    local re="" ch next i=0
    while (( i < ${#pat} )); do
        ch="${pat:i:1}"
        next="${pat:i+1:1}"
        case "$ch" in
            '*')
                if [[ "$next" == '*' ]]; then
                    re+=".*"
                    (( i += 2 ))
                    continue
                fi
                re+='[^/]*'
                ;;
            '?')
                re+='[^/]'
                ;;
            '.'|'+'|'('|')'|'['|']'|'{'|'}'|'|'|'^'|'$'|'\\')
                re+='\'"$ch"
                ;;
            *)
                re+="$ch"
                ;;
        esac
        (( i++ ))
    done
    [[ "$path" =~ ^${re}$ ]]
}

# Match a file path against ownership globs. Echoes the key (tid or "shared")
# of the first matching glob. Empty output means unmatched.
_match_file_owner() {
    local path="$1" globs="$2"
    local key glob
    while IFS=$'\t' read -r key glob; do
        [[ -n "$glob" ]] || continue
        if _glob_match "$path" "$glob"; then
            echo "$key"
            return 0
        fi
    done <<< "$globs"
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
        warn "Resolve conflicts, then run: ${gcmd[*]} cherry-pick --continue"
        if [[ ${#remaining_hashes[@]} -gt 0 ]]; then
            warn "Remaining commits to cherry-pick after resolution:"
            for rh in "${remaining_hashes[@]}"; do
                echo "  $(git log -1 --oneline "$rh")"
            done
            # Persist queue for continue to resume
            printf '%s\n' "${remaining_hashes[@]}" > "$wt_path/.dispatch-queue"
        fi
    else
        "${gcmd[@]}" cherry-pick --abort 2>/dev/null || "${gcmd[@]}" reset --merge 2>/dev/null || true
        echo ""
        warn "Aborted. Re-run with --resolve to keep conflict active for manual resolution."
    fi
}


# Warn when Source-Keep auto-resolves non-generated files.
# Usage: _warn_source_keep_non_generated gcmd_array hash
_warn_source_keep_non_generated() {
    local wt_path="$1" hash="$2"
    local changed_files
    # Try staged-but-uncommitted changes first (--no-commit path)
    changed_files=$(git -C "$wt_path" diff --name-only HEAD 2>/dev/null || true)
    # Fall back to last committed changes (cherry-pick -x path)
    [[ -z "$changed_files" ]] && changed_files=$(git -C "$wt_path" diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null || true)
    [[ -z "$changed_files" ]] && return 0

    # Configurable generated file patterns (comma-separated globs)
    local source_branch
    source_branch=$(_resolve_config_branch 2>/dev/null || true)
    local patterns
    patterns=$(git config "branch.${source_branch}.dispatchgeneratedpatterns" 2>/dev/null || true)
    [[ -z "$patterns" ]] && patterns="*/gen/*,*/generated/*,*.gen.*,swagger.json,openapi.gen.d.ts"

    local has_non_gen=false
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local is_generated=false
        local saved_ifs="$IFS"
        IFS=','
        for pat in $patterns; do
            pat="${pat## }"
            pat="${pat%% }"
            # shellcheck disable=SC2254
            case "$file" in
                $pat) is_generated=true; break ;;
            esac
        done
        IFS="$saved_ifs"
        if ! $is_generated; then
            warn "    Source-Keep overwrote non-generated file: $file"
            has_non_gen=true
        fi
    done <<< "$changed_files"
    $has_non_gen && warn "    Configure patterns: git config branch.<source>.dispatchgeneratedpatterns \"pattern1,pattern2\""
    return 0
}

# Auto-resolve cherry-pick conflict for `Dispatch-Target-Id: all` commits whose
# content already lives on target (e.g. delivered via squash-merge of another target).
# Stages --ours per conflicted file and reports outcome.
# Returns 0 with stdout "skip" (commit empty after --ours) or "continue" (non-empty).
# Returns 1 silently when not eligible: mode off, non-all trailer, or conflicts spread
# beyond the commit's own files. Sets _AUTO_RESOLVE_FILES (CSV) on success.
_AUTO_RESOLVE_FILES=""
_auto_resolve_all_check() {
    local wt="$1" hash="$2" mode="$3"
    _AUTO_RESOLVE_FILES=""

    [[ "$mode" == "skip" || "$mode" == "prompt" ]] || return 1

    local tid
    tid=$(_extract_dispatch_tid "$hash")
    [[ "$tid" == "all" ]] || return 1

    local -a conflicted=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && conflicted+=("$f")
    done < <(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)
    [[ ${#conflicted[@]} -gt 0 ]] || return 1

    local commit_files
    commit_files=$(git diff-tree --no-commit-id --name-only -r "$hash" 2>/dev/null)
    [[ -n "$commit_files" ]] || return 1
    local f
    for f in "${conflicted[@]}"; do
        printf '%s\n' "$commit_files" | grep -qxF -- "$f" || return 1
    done

    for f in "${conflicted[@]}"; do
        git -C "$wt" checkout --ours -- "$f" >/dev/null 2>&1 || return 1
        git -C "$wt" add -- "$f" >/dev/null 2>&1 || return 1
    done

    local _IFS_save="$IFS"
    IFS=','
    _AUTO_RESOLVE_FILES="${conflicted[*]}"
    IFS="$_IFS_save"

    if git -C "$wt" diff --cached --quiet 2>/dev/null; then
        echo "skip"
    else
        echo "continue"
    fi
    return 0
}

# Unified cherry-pick into a branch via temp worktree (no main-worktree checkout).
# Usage: _cherry_pick_commits resolve branch [--add-trailer tid] [--theirs-fallback]
#        [--autoresolve-mode <off|skip|prompt>] [--target <tid>] hash...
# Sets DISPATCH_LAST_PICKED / DISPATCH_LAST_SKIPPED globals.
_cherry_pick_commits() {
    local resolve="$1" branch="$2"; shift 2
    local add_trailer="" theirs_fallback=false no_x=false autoresolve_mode="off" target_tid=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --add-trailer) add_trailer="$2"; shift 2 ;;
            --no-x) no_x=true; shift ;;
            --theirs-fallback) theirs_fallback=true; shift ;;
            --autoresolve-mode) autoresolve_mode="$2"; shift 2 ;;
            --target) target_tid="$2"; shift 2 ;;
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
            tid=$(_extract_dispatch_tid "$hash")
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
                _source_keep=$(_extract_dispatch_source_keep "$hash")
                if [[ -n "$_source_keep" ]]; then
                    "${gcmd[@]}" cherry-pick --abort 2>/dev/null || true
                    if "${gcmd[@]}" cherry-pick --no-commit --strategy-option theirs "$hash" 2>/dev/null; then
                        warn "  Force-accepted (Source-Keep): $(git log -1 --oneline "$hash")"
                        _warn_source_keep_non_generated "$_DISPATCH_WT_PATH" "$hash"
                        # Fall through to commit with trailer rewrite below
                    else
                        _handle_cherry_pick_conflict "$_DISPATCH_WT_PATH" "$hash" "$_idx" "${#hashes[@]}" "$resolve" "$branch" "${hashes[@]:$((_idx+1))}"
                        _conflict_leave "$resolve"; return 1
                    fi
                else
                    local _ar_action=""
                    _ar_action=$(_auto_resolve_all_check "$_DISPATCH_WT_PATH" "$hash" "$autoresolve_mode" || true)
                    if [[ "$_ar_action" == "skip" ]]; then
                        "${gcmd[@]}" cherry-pick --skip 2>/dev/null || "${gcmd[@]}" reset HEAD --quiet 2>/dev/null || true
                        warn "  Auto-skipped (all-trailer): $(git log -1 --oneline "$hash")"
                        _log_audit "auto-skipped" "$hash" "${target_tid:-?}" "all-trailer + empty after --ours" "$_AUTO_RESOLVE_FILES"
                        DISPATCH_LAST_SKIPPED=$((DISPATCH_LAST_SKIPPED + 1))
                        continue
                    elif [[ "$_ar_action" == "continue" ]]; then
                        warn "  Auto-resolved (all-trailer): $(git log -1 --oneline "$hash")"
                        _log_audit "auto-resolved" "$hash" "${target_tid:-?}" "all-trailer + non-empty after --ours" "$_AUTO_RESOLVE_FILES"
                        # Fall through to commit (files staged via --ours)
                    else
                        _handle_cherry_pick_conflict "$_DISPATCH_WT_PATH" "$hash" "$_idx" "${#hashes[@]}" "$resolve" "$branch" "${hashes[@]:$((_idx+1))}"
                        _conflict_leave "$resolve"; return 1
                    fi
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
        elif $no_x; then
            # Cherry-pick without -x: avoids appending "(cherry picked from ...)" and
            # "# Conflicts:" metadata that breaks git's trailer parser.
            if ! "${gcmd[@]}" cherry-pick --no-commit "$hash" 2>/dev/null; then
                if "${gcmd[@]}" rev-parse --verify CHERRY_PICK_HEAD &>/dev/null && "${gcmd[@]}" diff --cached --quiet; then
                    _skip_empty_pick "$hash" "${gcmd[@]}"; continue
                fi
                local _source_keep_nx
                _source_keep_nx=$(_extract_dispatch_source_keep "$hash")
                if [[ -n "$_source_keep_nx" ]]; then
                    "${gcmd[@]}" cherry-pick --abort 2>/dev/null || true
                    if ! "${gcmd[@]}" cherry-pick --no-commit --strategy-option theirs "$hash" 2>/dev/null; then
                        _handle_cherry_pick_conflict "$_DISPATCH_WT_PATH" "$hash" "$_idx" "${#hashes[@]}" "$resolve" "$branch" "${hashes[@]:$((_idx+1))}"
                        _conflict_leave "$resolve"; return 1
                    fi
                    warn "  Force-accepted (Source-Keep): $(git log -1 --oneline "$hash")"
                    _warn_source_keep_non_generated "$_DISPATCH_WT_PATH" "$hash"
                else
                    local _ar_action_nx=""
                    _ar_action_nx=$(_auto_resolve_all_check "$_DISPATCH_WT_PATH" "$hash" "$autoresolve_mode" || true)
                    if [[ "$_ar_action_nx" == "skip" ]]; then
                        "${gcmd[@]}" cherry-pick --skip 2>/dev/null || "${gcmd[@]}" reset HEAD --quiet 2>/dev/null || true
                        warn "  Auto-skipped (all-trailer): $(git log -1 --oneline "$hash")"
                        _log_audit "auto-skipped" "$hash" "${target_tid:-?}" "all-trailer + empty after --ours" "$_AUTO_RESOLVE_FILES"
                        DISPATCH_LAST_SKIPPED=$((DISPATCH_LAST_SKIPPED + 1))
                        continue
                    elif [[ "$_ar_action_nx" == "continue" ]]; then
                        warn "  Auto-resolved (all-trailer): $(git log -1 --oneline "$hash")"
                        _log_audit "auto-resolved" "$hash" "${target_tid:-?}" "all-trailer + non-empty after --ours" "$_AUTO_RESOLVE_FILES"
                        # Fall through to commit (files staged via --ours)
                    else
                        _handle_cherry_pick_conflict "$_DISPATCH_WT_PATH" "$hash" "$_idx" "${#hashes[@]}" "$resolve" "$branch" "${hashes[@]:$((_idx+1))}"
                        _conflict_leave "$resolve"; return 1
                    fi
                fi
            fi
            if "${gcmd[@]}" diff --cached --quiet; then
                _skip_empty_pick "$hash" "${gcmd[@]}"; continue
            fi
            # Commit with clean message (strip cherry-pick/conflict metadata from source commit)
            local _cp_msg
            _cp_msg=$(git log -1 --format="%B" "$hash" | \
                sed '/^(cherry picked from commit /d' | \
                sed '/^# Conflicts:$/,/^[^#]/{/^#/d;}' | \
                awk '/^$/{blank++; next} {for(i=0;i<blank;i++) print ""; blank=0; print}')
            if ! "${gcmd[@]}" commit -m "$_cp_msg" --quiet 2>/dev/null; then
                if "${gcmd[@]}" diff --cached --quiet; then
                    _skip_empty_pick "$hash" "${gcmd[@]}"; continue
                fi
                die "Cherry-pick into $branch failed on $hash"
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
                _source_keep2=$(_extract_dispatch_source_keep "$hash")
                if [[ -n "$_source_keep2" ]]; then
                    "${gcmd[@]}" cherry-pick --abort 2>/dev/null || true
                    if "${gcmd[@]}" cherry-pick -x --strategy-option theirs "$hash" 2>/dev/null; then
                        warn "  Force-accepted (Source-Keep): $(git log -1 --oneline "$hash")"
                        _warn_source_keep_non_generated "$_DISPATCH_WT_PATH" "$hash"
                        DISPATCH_LAST_PICKED=$((DISPATCH_LAST_PICKED + 1))
                        continue
                    fi
                else
                    local _ar_action_x=""
                    _ar_action_x=$(_auto_resolve_all_check "$_DISPATCH_WT_PATH" "$hash" "$autoresolve_mode" || true)
                    if [[ "$_ar_action_x" == "skip" ]]; then
                        "${gcmd[@]}" cherry-pick --skip 2>/dev/null || "${gcmd[@]}" reset HEAD --quiet 2>/dev/null || true
                        warn "  Auto-skipped (all-trailer): $(git log -1 --oneline "$hash")"
                        _log_audit "auto-skipped" "$hash" "${target_tid:-?}" "all-trailer + empty after --ours" "$_AUTO_RESOLVE_FILES"
                        DISPATCH_LAST_SKIPPED=$((DISPATCH_LAST_SKIPPED + 1))
                        continue
                    elif [[ "$_ar_action_x" == "continue" ]]; then
                        if GIT_EDITOR=true "${gcmd[@]}" cherry-pick --continue 2>/dev/null; then
                            warn "  Auto-resolved (all-trailer): $(git log -1 --oneline "$hash")"
                            _log_audit "auto-resolved" "$hash" "${target_tid:-?}" "all-trailer + non-empty after --ours" "$_AUTO_RESOLVE_FILES"
                            DISPATCH_LAST_PICKED=$((DISPATCH_LAST_PICKED + 1))
                            continue
                        fi
                        # cherry-pick --continue failed - fall through to fallback
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

# Derive target branch name from configured pattern and target id.
# Checks for a per-tid alias first; falls back to pattern substitution.
_target_branch_name() {
    local tid="$1"
    local alias_name
    alias_name=$(_get_config "targetalias-$(_tid_cfg_encode "${tid}")")
    if [[ -n "$alias_name" ]]; then
        echo "$alias_name"; return
    fi
    local pattern
    pattern=$(_get_config targetPattern)
    [[ -n "$pattern" ]] || die "Missing dispatch.targetPattern. Re-run: git dispatch init"
    [[ "$pattern" == *"{id}"* ]] || die "Invalid dispatch.targetPattern (missing {id})"
    echo "${pattern//\{id\}/$tid}"
}

# Compute the pattern-based branch name (ignoring aliases).
_target_branch_name_pattern() {
    local tid="$1"
    local pattern
    pattern=$(_get_config targetPattern)
    [[ -n "$pattern" ]] || die "Missing dispatch.targetPattern. Re-run: git dispatch init"
    [[ "$pattern" == *"{id}"* ]] || die "Invalid dispatch.targetPattern (missing {id})"
    echo "${pattern//\{id\}/$tid}"
}

# ---------- init ----------

cmd_init() {
    local base="" target_pattern=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base)   base="$2"; shift 2 ;;
            --target-pattern) target_pattern="$2"; shift 2 ;;
            --mode)   shift 2 ;;  # deprecated, ignored
            --yes) DISPATCH_YES=true; shift ;;
            --force) DISPATCH_YES=true; shift ;;  # deprecated alias for -y
            -*)       die "Unknown flag: $1" ;;
            *)        die "Unexpected argument: $1" ;;
        esac
    done

    local source
    source=$(current_branch)
    [[ -n "$source" ]] || die "Not on a branch (detached HEAD)"

    # Interactive mode: prompt for missing args
    if [[ -z "$base" ]]; then
        base=$(_prompt_input "Base branch [origin/master]: " "origin/master")
    fi
    if [[ -z "$target_pattern" ]]; then
        target_pattern=$(_prompt_input "Target pattern (must include {id}): " "")
    fi

    [[ -n "$base" ]] || die "Missing --base"
    [[ -n "$target_pattern" ]] || die "Missing --target-pattern"
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

        _confirm "Proceed?" || { echo "Aborted."; exit 0; }
    fi

    _ensure_worktree_config

    _set_config base "$base" "$source"
    _set_config targetPattern "$target_pattern" "$source"

    _remove_hooks 2>/dev/null || true

    echo ""
    info "Initialized dispatch on '$source'"
    echo -e "  ${CYAN}base:${NC}   $base"
    echo -e "  ${CYAN}target-pattern:${NC} $target_pattern"
}

# ---------- sync ----------

cmd_sync() {
    _require_init
    _acquire_lock

    local dry_run=false resolve=false include_merged=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)  dry_run=true; shift ;;
            --resolve|--continue) resolve=true; shift ;;
            --all)      include_merged=true; shift ;;
            -*)         die "Unknown flag: $1" ;;
            *)          die "Unexpected argument: $1" ;;
        esac
    done

    local base source
    base=$(_get_config base)
    source=$(resolve_source "")
    [[ -n "$source" ]] || die "Not on a branch and no dispatch source configured"

    # Block sync during active checkout
    local _active_checkout
    _active_checkout=$(_find_checkout_branch "$source" 2>/dev/null || true)
    [[ -z "$_active_checkout" ]] || die "Cannot sync while checkout is active: $_active_checkout. Run: git dispatch checkout source && git dispatch checkout clear"

    # Refresh base ref
    _spinner_start "Fetching base..."
    _refresh_base "$base" || true
    _spinner_stop

    # Fresh sync run: drop any stale queue from a previous aborted session
    $dry_run || _sync_queue_set "$source" ""

    # Merge base into source
    local base_count
    base_count=$(git rev-list --count "$source..$base" 2>/dev/null || echo 0)
    if [[ "$base_count" -eq 0 ]]; then
        info "Source is up to date with $base."
    elif $dry_run; then
        echo -e "${YELLOW}[dry-run]${NC} merge $base ($base_count commits) into $source"
    else
        _spinner_start "Merging $base into $source..."
        _enter_branch "$source" || die "Cannot access source branch (worktree conflict?)"
        local -a gcmd=(git -C "$_DISPATCH_WT_PATH")
        _spinner_stop
        if ! "${gcmd[@]}" merge "$base" --no-edit; then
            echo ""
            warn "Merge conflict on $source from $base"
            _show_conflict_diff "$_DISPATCH_WT_PATH"
            if $resolve; then
                echo ""
                warn "Resolve conflicts in worktree: $_DISPATCH_WT_PATH"
                warn "Then:       git -C $_DISPATCH_WT_PATH add <resolved-files>"
                warn "Then run:   git dispatch continue"
                _DISPATCH_WT_CREATED=false
                exit 1
            fi
            "${gcmd[@]}" merge --abort 2>/dev/null || true
            _leave_branch
            die "Merge conflict. Re-run with --resolve to resolve manually."
        fi
        info "Merged $base into $source ($base_count commits)"
        _leave_branch
    fi

    # Merge base into existing targets
    local -a existing_targets=()
    while IFS= read -r _et; do
        [[ -n "$_et" ]] && existing_targets+=("$_et")
    done < <(find_dispatch_targets "$source")

    if [[ ${#existing_targets[@]} -gt 0 ]]; then
        local merged_targets=0 target_merge_skipped=0

        local target_merged_skipped=0

        local _et_idx
        for _et_idx in "${!existing_targets[@]}"; do
            local _et_branch="${existing_targets[$_et_idx]}"
            # Skip targets whose content is already merged into base
            if ! $include_merged && _is_content_merged "$_et_branch" "$base"; then
                target_merged_skipped=$((target_merged_skipped + 1))
                continue
            fi

            local _et_behind
            _et_behind=$(git rev-list --count "$_et_branch..$base" 2>/dev/null || echo 0)
            if [[ "$_et_behind" -eq 0 ]]; then
                target_merge_skipped=$((target_merge_skipped + 1))
                continue
            fi

            if $dry_run; then
                echo -e "  ${YELLOW}merge${NC} $base ($_et_behind commits) into $_et_branch"
                merged_targets=$((merged_targets + 1))
                continue
            fi

            _spinner_start "Merging $base into $_et_branch..."
            _enter_branch "$_et_branch" || {
                _spinner_stop
                warn "  Cannot access $_et_branch for base merge (worktree conflict?)"
                continue
            }
            local -a _et_gcmd=(git -C "$_DISPATCH_WT_PATH")
            _spinner_stop
            if ! "${_et_gcmd[@]}" merge "$base" --no-edit 2>/dev/null; then
                # Try Source-Keep auto-resolution before surfacing conflict
                if _sync_try_source_keep_resolve "$_DISPATCH_WT_PATH" "$_et_branch" "$base"; then
                    info "  Merged $base into $_et_branch ($_et_behind commits, Source-Keep auto-resolved)"
                    _leave_branch
                    merged_targets=$((merged_targets + 1))
                    continue
                fi
                if $resolve; then
                    local -a _remaining=("${existing_targets[@]:$((_et_idx+1))}")
                    if [[ ${#_remaining[@]} -gt 0 ]]; then
                        _sync_queue_set "$source" "$(printf '%s\n' "${_remaining[@]}")"
                    fi
                    echo ""
                    warn "Merge conflict on $_et_branch from $base"
                    _show_conflict_diff "$_DISPATCH_WT_PATH"
                    echo ""
                    warn "Resolve conflicts in worktree: $_DISPATCH_WT_PATH"
                    warn "Then:       git -C $_DISPATCH_WT_PATH add <resolved-files>"
                    warn "Then run:   git dispatch continue"
                    if [[ ${#_remaining[@]} -gt 0 ]]; then
                        warn "${#_remaining[@]} target(s) remaining after this one."
                    fi
                    _DISPATCH_WT_CREATED=false
                    _DISPATCH_WT_STASHED=false
                    exit 1
                fi
                "${_et_gcmd[@]}" merge --abort 2>/dev/null || true
                _leave_branch
                die "Merge conflict on $_et_branch from $base. Re-run with --resolve to resolve manually."
            fi
            info "  Merged $base into $_et_branch ($_et_behind commits)"
            _leave_branch
            merged_targets=$((merged_targets + 1))
        done

        if [[ $merged_targets -gt 0 && ! $dry_run ]]; then
            info "Synced. Source and $merged_targets target(s) up to date with $base."
        fi
        if [[ $target_merged_skipped -gt 0 ]]; then
            info "$target_merged_skipped target(s) already merged into $base, skipped. Use --all to include."
        fi
    fi
}

# ---------- apply ----------

cmd_apply() {
    _require_init
    _acquire_lock
    _audit_log_truncate

    local dry_run=false resolve=false force=false reset_target="" include_merged=false no_sync=false no_replay=false
    local -a positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)  dry_run=true; shift ;;
            --resolve|--continue) resolve=true; shift ;;
            --force)    force=true; shift ;;
            --all)      include_merged=true; shift ;;
            --no-sync)  no_sync=true; shift ;;
            --no-replay) no_replay=true; shift ;;
            --base)     die "--base removed. Use: git dispatch sync" ;;
            --yes)      DISPATCH_YES=true; shift ;;
            -*)         die "Unknown flag: $1" ;;
            *)          positional+=("$1"); shift ;;
        esac
    done

    # Parse positional args
    local apply_target=""
    if [[ ${#positional[@]} -gt 0 ]]; then
        if [[ "${positional[0]}" == "reset" ]]; then
            [[ ${#positional[@]} -ge 2 ]] || die "Usage: git dispatch apply reset <id|all>"
            reset_target="${positional[1]}"
            # Scope apply to just this target (don't cascade to others)
            [[ "$reset_target" != "all" ]] && apply_target="$reset_target"
        else
            apply_target="${positional[0]}"
        fi
    fi

    local base source
    base=$(_get_config base)
    source=$(resolve_source "")
    [[ -n "$source" ]] || die "Not on a branch and no dispatch source configured"

    # Ensure base ref is up-to-date before creating/updating targets (best-effort)
    _spinner_start "Refreshing base..."
    _refresh_base "$base" || true
    _spinner_stop

    # Auto-sync before apply reset; die for regular apply unless --force, --no-sync, or --dry-run
    local _drift_count
    _drift_count=$(git rev-list --count "$source..$base" 2>/dev/null || echo 0)
    if [[ "$_drift_count" -gt 0 ]]; then
        if [[ -n "$reset_target" ]] && ! $no_sync && ! $dry_run; then
            warn "Source is $_drift_count commit(s) behind $base. Syncing first..."
            if $resolve; then
                cmd_sync --resolve
            else
                cmd_sync
            fi
        elif $dry_run || $force || $no_sync; then
            warn "Source is $_drift_count commit(s) behind $base. Run: git dispatch sync"
        else
            die "Source is $_drift_count commit(s) behind $base. Run: git dispatch sync (or use --force to override)"
        fi
    fi

    # Parse trailer-tagged commits into temp file: "hash target-id" per line
    local commit_file patch_map_file replay_file
    commit_file=$(mktemp)
    patch_map_file=$(mktemp)
    replay_file=$(mktemp)
    trap "rm -f '$commit_file' '$patch_map_file' '$replay_file'" RETURN

    while IFS= read -r _h; do
        # Skip merge commits (they have no Dispatch-Target-Id and that's expected)
        local _pc
        _pc=$(git rev-list --parents -n1 "$_h" | wc -w)
        (( _pc > 2 )) && continue
        # Skip commits from base (already integrated)
        git merge-base --is-ancestor "$_h" "$base" 2>/dev/null && continue
        # Reject commits with multiple Dispatch-Target-Id trailers (defense-in-depth)
        local _tcount
        _tcount=$(git log -1 --format="%B" "$_h" | grep -c "^Dispatch-Target-Id:" || true)
        if [[ "$_tcount" -gt 1 ]]; then
            die "Commit $(echo "$_h" | cut -c1-8) has $_tcount Dispatch-Target-Id trailers. Only one is allowed."
        fi
        local _t
        _t=$(_extract_dispatch_tid "$_h")
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

    # Validate commits have numeric Dispatch-Target-Id or "all"
    # When targeting a specific id (apply <N>), warn on unrelated broken commits instead of dying
    local _valid_file
    _valid_file=$(mktemp)
    while read -r hash tid; do
        if [[ -z "$tid" ]]; then
            if [[ -n "$apply_target" ]]; then
                warn "Commit $(echo "$hash" | cut -c1-8) has no Dispatch-Target-Id trailer (skipped)" >&2
                continue
            fi
            die "Commit $(echo "$hash" | cut -c1-8) has no Dispatch-Target-Id trailer"
        fi
        if [[ "$tid" != "all" ]] && ! echo "$tid" | grep -Eq '^[1-9][0-9]*(\.[0-9]+)?$'; then
            if [[ -n "$apply_target" && "$tid" != "$apply_target" ]]; then
                warn "Commit $(echo "$hash" | cut -c1-8) has invalid Dispatch-Target-Id '$tid' (skipped)" >&2
                continue
            fi
            if echo "$tid" | grep -Eq '^0[0-9]'; then
                die "Commit $(echo "$hash" | cut -c1-8) has Dispatch-Target-Id '$tid' with leading zero. Use '${tid#0}' instead."
            elif [[ "$tid" == "0" ]]; then
                die "Commit $(echo "$hash" | cut -c1-8) has Dispatch-Target-Id '0'. Use a positive integer."
            fi
            die "Commit $(echo "$hash" | cut -c1-8) has non-numeric Dispatch-Target-Id '$tid'"
        fi
        echo "$hash $tid"
    done < "$commit_file" > "$_valid_file"
    mv "$_valid_file" "$commit_file"

    # Ordered unique target ids (numeric sort), excluding "all"
    local -a target_ids=()
    while IFS= read -r tid; do
        target_ids+=("$tid")
    done < <(awk '$2 != "all" && !seen[$2]++ {print $2}' "$commit_file" | sort -t. -k1,1n -k2,2n)

    # Validate apply_target: if user requested a specific target, ensure commits exist for it
    # (unless the target branch already exists and might need "all" commit propagation)
    if [[ -n "$apply_target" && "$apply_target" != "all" ]]; then
        local _target_in_source=false
        for _t in "${target_ids[@]}"; do
            [[ "$_t" == "$apply_target" ]] && { _target_in_source=true; break; }
        done
        if ! $_target_in_source; then
            local _target_branch
            _target_branch=$(_target_branch_name "$apply_target")
            if ! git rev-parse --verify "refs/heads/$_target_branch" &>/dev/null; then
                die "No commits on source have Dispatch-Target-Id: $apply_target. Target cannot be created."
            fi
        fi
    fi

    # --- Stale target detection ---
    _build_source_patch_id_map "$patch_map_file" "$commit_file"

    local -a stale_branches=() stale_tids=() stale_counts=() stale_target_only=()
    while IFS= read -r existing; do
        [[ -n "$existing" ]] || continue
        local etid
        etid=$(_extract_tid_from_branch "$existing")
        [[ -n "$etid" ]] || continue

        # Skip targets whose tid is still in source (handled separately below)
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
        elif [[ -n "$reset_target" ]]; then
            # --reset specified: don't block on stale, just warn
            warn "Stale targets exist. Continuing with reset $reset_target only."
            echo ""
        else
            warn "Run: git dispatch apply --force  to rebuild stale targets."
            exit 1
        fi
    fi

    # --- Partial reassignment: active targets with commits now targeting a different tid ---
    # Only matters with --force (auto-reset) or --dry-run (report).
    if $force || $dry_run; then
        local -a partial_stale_branches=()
        while IFS= read -r existing; do
            [[ -n "$existing" ]] || continue
            local etid
            etid=$(_extract_tid_from_branch "$existing")
            [[ -n "$etid" ]] || continue

            # Only check targets whose tid IS still in source
            local is_active=false
            for t in "${target_ids[@]}"; do
                [[ "$t" == "$etid" ]] && { is_active=true; break; }
            done
            $is_active || continue

            local stale_out
            stale_out=$(_find_stale_commits "$existing" "$etid" "$base" "$patch_map_file") || true
            [[ -n "$stale_out" ]] && partial_stale_branches+=("$existing")
        done < <(find_dispatch_targets "$source")

        if [[ ${#partial_stale_branches[@]} -gt 0 ]]; then
            echo ""
            warn "Targets with reassigned commits:"
            for sb in "${partial_stale_branches[@]}"; do
                echo -e "  ${YELLOW}${sb}${NC}"
            done
            echo ""
            if $dry_run; then
                for sb in "${partial_stale_branches[@]}"; do
                    echo -e "  ${YELLOW}would reset${NC} ${sb}"
                done
                echo ""
            elif $force; then
                for sb in "${partial_stale_branches[@]}"; do
                    local wt_path
                    wt_path=$(worktree_for_branch "$sb")
                    if [[ -n "$wt_path" ]]; then
                        if ! git -C "$wt_path" diff --quiet 2>/dev/null || ! git -C "$wt_path" diff --cached --quiet 2>/dev/null; then
                            warn "  Worktree $wt_path has uncommitted changes. Stashing before removal."
                            git -C "$wt_path" stash push --include-untracked --quiet -m "git-dispatch: auto-stash before worktree removal" 2>/dev/null || true
                        fi
                        git worktree remove --force "$wt_path" 2>/dev/null || true
                        git worktree prune 2>/dev/null || true
                    fi
                    git config --unset "branch.${sb}.dispatchsource" 2>/dev/null || true
                    git branch -D "$sb" 2>/dev/null || true
                    info "  Reset ${sb} (will regenerate)"
                done
                echo ""
            fi
        fi
    fi

    local created=0 updated=0 skipped=0 failed=0

    # --reset <id|all>: delete target branch(es) so apply recreates them fresh
    if [[ -n "$reset_target" ]]; then
        local -a reset_branches=() reset_tids=()

        if [[ "$reset_target" == "all" ]]; then
            # Collect all existing targets
            while IFS= read -r _rb; do
                [[ -n "$_rb" ]] || continue
                local _rtid
                _rtid=$(_extract_tid_from_branch "$_rb") || true
                if [[ -n "$_rtid" ]]; then
                    reset_branches+=("$_rb")
                    reset_tids+=("$_rtid")
                fi
            done < <(find_dispatch_targets "$source")

            # Also find "foreign" branches matching pattern but missing dispatchsource
            local _pattern
            _pattern=$(_get_config targetPattern)
            if [[ -n "$_pattern" ]]; then
                local _prefix="${_pattern%%\{id\}*}"
                local _suffix="${_pattern#*\{id\}}"
                while IFS= read -r _ref; do
                    local _bname="${_ref#refs/heads/}"
                    # Already in list?
                    local _already=false
                    for _rb in ${reset_branches[@]+"${reset_branches[@]}"}; do
                        [[ "$_rb" == "$_bname" ]] && { _already=true; break; }
                    done
                    $_already && continue
                    # Matches pattern?
                    if [[ "$_bname" == "${_prefix}"*"${_suffix}" ]]; then
                        local _ftid="${_bname#"$_prefix"}"
                        [[ -n "$_suffix" ]] && _ftid="${_ftid%"$_suffix"}"
                        if echo "$_ftid" | grep -Eq '^[1-9][0-9]*(\.[0-9]+)?$'; then
                            reset_branches+=("$_bname")
                            reset_tids+=("$_ftid")
                        fi
                    fi
                done < <(git for-each-ref --format='%(refname)' refs/heads/)
            fi

            [[ ${#reset_branches[@]} -gt 0 ]] || die "No target branches found to reset"

            echo -e "${CYAN}Will reset ${#reset_branches[@]} target(s):${NC}"
            for _rb in "${reset_branches[@]}"; do
                echo "  $_rb"
            done
            _confirm "Proceed?" || { echo "Aborted."; return 0; }
        else
            local _rb
            _rb=$(_target_branch_name "$reset_target")
            git rev-parse --verify "refs/heads/$_rb" &>/dev/null || die "Branch $_rb does not exist"
            reset_branches=("$_rb")
            reset_tids=("$reset_target")
        fi

        for _ri in "${!reset_branches[@]}"; do
            local reset_branch="${reset_branches[$_ri]}"
            local reset_tid="${reset_tids[$_ri]}"

            if ! git rev-parse --verify "refs/heads/$reset_branch" &>/dev/null; then
                continue
            fi

            # Detect target-only commits (not traceable to source)
            local -a _to_hashes=()
            while IFS= read -r _rh; do
                [[ -n "$_rh" ]] && _to_hashes+=("$_rh")
            done < <(_find_target_only_commits "$base" "$reset_branch" "$source")

            if [[ ${#_to_hashes[@]} -gt 0 ]]; then
                if ! $no_replay; then
                    for _rh in "${_to_hashes[@]}"; do
                        echo "$reset_tid $_rh" >> "$replay_file"
                    done
                    info "$reset_branch has ${#_to_hashes[@]} target-only commit(s) (will replay after rebuild)."
                else
                    warn "$reset_branch has ${#_to_hashes[@]} target-only commit(s) that will be lost (--no-replay)."
                    _confirm "Proceed?" || { echo "Aborted."; return 0; }
                fi
            fi

            # Remove worktree if branch is checked out in one
            local wt_path
            wt_path=$(git worktree list --porcelain 2>/dev/null | awk -v b="$reset_branch" '
                /^worktree / { path=$2 }
                /^branch refs\/heads\// { if ($2 == "refs/heads/" b) print path }
            ')
            if [[ -n "$wt_path" ]]; then
                if ! git -C "$wt_path" diff --quiet 2>/dev/null || ! git -C "$wt_path" diff --cached --quiet 2>/dev/null; then
                    warn "Worktree $wt_path has uncommitted changes. Stashing."
                    git -C "$wt_path" stash push --include-untracked --quiet -m "git-dispatch: auto-stash before worktree removal" 2>/dev/null || true
                fi
                git worktree remove --force "$wt_path" 2>/dev/null || true
                git worktree prune 2>/dev/null || true
                info "Removed worktree $wt_path"
            fi

            # Clean dispatchsource config
            git config --unset "branch.${reset_branch}.dispatchsource" 2>/dev/null || true

            local delete_err
            if delete_err=$(git branch -D "$reset_branch" 2>&1); then
                info "Deleted $reset_branch (will regenerate)"
            else
                warn "Could not delete $reset_branch: $delete_err"
            fi
        done
    fi

    # Display all-target commits in dry-run
    if $dry_run; then
        local all_count
        all_count=$(awk '$2 == "all"' "$commit_file" | wc -l | tr -d ' ')
        if [[ "$all_count" -gt 0 ]]; then
            echo -e "  ${GREEN}include${NC} $all_count commit(s) in all targets (Dispatch-Target-Id: all)"
        fi
    fi

    local apply_merged_skipped=0

    for tid in "${target_ids[@]}"; do
        # If applying to a specific target, skip others
        if [[ -n "$apply_target" && "$tid" != "$apply_target" ]]; then
            continue
        fi

        local branch_name
        branch_name=$(_target_branch_name "$tid")

        # Skip targets whose content is already merged into base
        if ! $include_merged && [[ -z "$reset_target" ]] && \
           git rev-parse --verify "refs/heads/$branch_name" &>/dev/null && \
           _is_content_merged "$branch_name" "$base"; then
            if $dry_run; then
                echo -e "  ${GREEN}skip${NC} target $tid  $branch_name  (merged)"
            fi
            apply_merged_skipped=$((apply_merged_skipped + 1))
            continue
        fi

        # Collect hashes for this target (including "all" commits, in source order)
        local -a hashes=()
        while IFS= read -r h; do
            hashes+=("$h")
        done < <(awk -v t="$tid" '$2 == t || $2 == "all" {print $1}' "$commit_file")

        local parent_branch="$base"

        if $dry_run; then
            if git rev-parse --verify "refs/heads/$branch_name" &>/dev/null; then
                # Check for new commits (subject-line matching with patch-id fallback)
                local -a _new_all=() _new_specific=()
                while IFS= read -r _nh; do
                    [[ -n "$_nh" ]] || continue
                    local _nt
                    _nt=$(_extract_dispatch_tid "$_nh")
                    if [[ "$_nt" == "all" ]]; then
                        _new_all+=("$_nh")
                    else
                        _new_specific+=("$_nh")
                    fi
                done < <(_find_new_commits_for_target "$base" "$branch_name" "${hashes[@]}")
                local _new_total=$(( ${#_new_all[@]} + ${#_new_specific[@]} ))
                if [[ $_new_total -gt 0 ]]; then
                    echo -e "  ${YELLOW}cherry-pick${NC} $_new_total commit(s) to target $tid  $branch_name"
                    [[ ${#_new_specific[@]} -gt 0 ]] && echo -e "    ${GREEN}${#_new_specific[@]} tagged target $tid${NC}"
                    [[ ${#_new_all[@]} -gt 0 ]] && echo -e "    ${CYAN}${#_new_all[@]} tagged 'all'${NC}"
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
                warn "  Skipping to avoid corrupting a foreign branch. Delete it or run: git dispatch apply reset $tid"
                failed=$((failed + 1))
                continue
            fi

            # Target exists locally - find new commits (subject-line matching with patch-id fallback)
            local -a new_hashes=()
            while IFS= read -r _nh; do
                [[ -n "$_nh" ]] && new_hashes+=("$_nh")
            done < <(_find_new_commits_for_target "$base" "$branch_name" "${hashes[@]}")

            if [[ ${#new_hashes[@]} -gt 0 ]]; then
                # Detect suspected source rebase: if "new" commits >= existing target commits,
                # source was likely rebased and all patches look new.
                local _target_count
                _target_count=$(git rev-list --count "$base..$branch_name" 2>/dev/null || echo 0)
                if [[ ${#new_hashes[@]} -gt 1 && $_target_count -gt 0 && ${#new_hashes[@]} -ge $_target_count ]]; then
                    warn "  $branch_name: ${#new_hashes[@]} new commits detected (target has $_target_count)."
                    warn "  Source may have been rebased externally. Cherry-picking may conflict or duplicate."
                    warn "  If push fails (non-fast-forward), use: git dispatch push $tid --force"
                fi
                _cherry_pick_commits "$resolve" "$branch_name" "${new_hashes[@]}"
                info "  Updated $branch_name ($DISPATCH_LAST_PICKED picked, $DISPATCH_LAST_SKIPPED skipped)"
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

            # Replay target-only commits saved from reset
            if [[ -s "$replay_file" ]]; then
                local -a _replay_hashes=()
                while IFS=' ' read -r _rtid _rhash; do
                    [[ "$_rtid" == "$tid" ]] && _replay_hashes+=("$_rhash")
                done < "$replay_file"
                if [[ ${#_replay_hashes[@]} -gt 0 ]]; then
                    info "  Replaying ${#_replay_hashes[@]} target-only commit(s)..."
                    if ! _cherry_pick_commits "$resolve" "$branch_name" "${_replay_hashes[@]}"; then
                        warn "  Some target-only commits could not be replayed"
                    fi
                fi
            fi

            created=$((created + 1))
        fi
    done

    echo ""
    if $dry_run; then
        echo -e "${CYAN}Summary (dry-run):${NC} ${#target_ids[@]} targets"
    else
        local summary="$created created, $updated updated, $skipped in sync"
        [[ $apply_merged_skipped -gt 0 ]] && summary="$summary, $apply_merged_skipped merged"
        [[ $failed -gt 0 ]] && summary="$summary, ${RED}$failed failed${NC}"
        echo -e "${CYAN}Summary:${NC} $summary"

        if [[ $apply_merged_skipped -gt 0 ]]; then
            info "$apply_merged_skipped target(s) already merged into $base, skipped. Use --all to include."
        fi

        # Warn if targets may be missing base commits
        if [[ $skipped -gt 0 || $updated -gt 0 ]]; then
            local _base_ahead
            _base_ahead=$(git rev-list --count "$source..$base" 2>/dev/null || echo 0)
            if [[ "$_base_ahead" -gt 0 ]]; then
                echo ""
                warn "Note: source is $_base_ahead commit(s) behind $base."
                warn "Run: git dispatch sync  (to merge base into source and targets)"
            fi
        fi
    fi
}

# ---------- push ----------

cmd_push() {
    _require_init

    local target="" dry_run=false force=false verify=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)  dry_run=true; shift ;;
            --force)    force=true; shift ;;
            --verify)   verify=true; shift ;;
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
        if ! git rev-parse --verify "refs/heads/$target_branch" &>/dev/null; then
            # Diagnose why the target is missing to give an actionable suggestion
            local _drift _has_commits
            _drift=$(git rev-list --count "$source..$base" 2>/dev/null || echo 0)
            if [[ "$_drift" -gt 0 ]]; then
                die "Target branch '$target_branch' does not exist. Source is $_drift commit(s) behind $base. Run: git dispatch sync, then git dispatch apply $target"
            fi
            _has_commits=$(git log "$base..$source" --format="%B" 2>/dev/null | grep -c "^Dispatch-Target-Id: $target$" || true)
            if [[ "$_has_commits" -eq 0 ]]; then
                die "Target branch '$target_branch' does not exist. No commits on source have Dispatch-Target-Id: $target"
            fi
            die "Target branch '$target_branch' does not exist locally. Run: git dispatch apply $target"
        fi
        branches=("$target_branch")
    fi

    local -a push_args=(-u origin)
    $force && push_args+=(--force-with-lease)

    for branch in "${branches[@]}"; do
        # Pre-push verification
        if $verify && [[ "$branch" != "$source" ]] && ! $dry_run; then
            local _vtid
            _vtid=$(_extract_tid_from_branch "$branch")
            if [[ -n "$_vtid" ]]; then
                if ! cmd_verify "$_vtid"; then
                    warn "  Skipping push for $branch (verification failed)"
                    continue
                fi
            fi
        fi
        if $dry_run; then
            echo -e "  ${YELLOW}[dry-run]${NC} git push ${push_args[*]} $branch"
        else
            _spinner_start "Pushing $branch..."
            local push_out
            if push_out=$(git push "${push_args[@]}" "$branch" 2>&1); then
                _spinner_stop
                info "  Pushed $branch"
            else
                _spinner_stop
                local reason
                reason=$(printf '%s\n' "$push_out" | sed '/^[[:space:]]*$/d' | tail -n 1)
                [[ -z "$reason" ]] && reason="unknown error"
                warn "  Push failed for $branch: $reason"
            fi
        fi
    done
}

# ---------- verify ----------

cmd_verify() {
    _require_init

    local target="" fix=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fix)  fix=true; shift ;;
            -*)     die "Unknown flag: $1" ;;
            *)      [[ -z "$target" ]] && target="$1" || die "Unexpected argument: $1"; shift ;;
        esac
    done

    [[ -n "$target" ]] || die "Usage: git dispatch verify <N> [--fix]"

    local source
    source=$(resolve_source "")

    # Get verification command from config
    local verify_cmd
    verify_cmd=$(git config "branch.${source}.dispatchverify" 2>/dev/null || true)
    [[ -n "$verify_cmd" ]] || die "No verification command configured. Set: git config branch.${source}.dispatchverify \"<command>\""

    local branch_name
    branch_name=$(_target_branch_name "$target")
    git rev-parse --verify "refs/heads/$branch_name" &>/dev/null || \
        die "Target branch '$branch_name' does not exist. Run: git dispatch apply"

    info "Verifying target $target ($branch_name)..."
    _enter_branch "$branch_name" || die "Cannot access branch $branch_name"

    local verify_exit=0
    # Run verification in the worktree directory
    ( cd "$_DISPATCH_WT_PATH" && eval "$verify_cmd" ) || verify_exit=$?

    if [[ $verify_exit -ne 0 ]]; then
        if $fix; then
            warn "Verification failed. Fix in worktree: $_DISPATCH_WT_PATH"
            warn "When done, commit and run: git dispatch continue"
            _DISPATCH_WT_CREATED=false
            _DISPATCH_WT_STASHED=false
            return 1
        else
            _leave_branch
            warn "Verification failed for target $target (exit code $verify_exit)"
            return 1
        fi
    fi

    _leave_branch
    info "Target $target verified."
    return 0
}

# ---------- status ----------

cmd_status() {
    _require_init

    local base target_pattern source has_stale=false has_diverged=false
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

    # Batch: extract all trailers in one git log pass (not per-commit)
    local -a source_tids=()
    local status_commit_file status_map_file
    status_commit_file=$(mktemp)
    status_map_file=$(mktemp)
    trap "_spinner_stop; rm -f '$status_commit_file' '$status_map_file'" RETURN
    while IFS= read -r _line; do
        local _h="${_line%% *}" _t="${_line#* }"
        _t=$(echo "$_t" | tr -d '[:space:]')
        # Fallback for broken trailer blocks
        if [[ -z "$_t" && -n "$_h" ]]; then
            _t=$(_extract_dispatch_tid "$_h")
        fi
        if [[ -n "$_t" && -n "$_h" ]]; then
            source_tids+=("$_t")
            echo "$_h $_t" >> "$status_commit_file"
        fi
    done < <(git log --format="%H %(trailers:key=Dispatch-Target-Id,valueonly)" "$base..$source")
    _build_source_patch_id_map "$status_map_file" "$status_commit_file"
    # Unique sorted, excluding "all" (not a real target)
    local -a unique_tids=()
    while IFS= read -r t; do
        [[ "$t" == "all" ]] && continue
        unique_tids+=("$t")
    done < <(printf '%s\n' "${source_tids[@]}" | sort -t. -k1,1n -k2,2n -u)

    # Cache PR info (skip if gh not available for speed)
    local pr_cache=""
    if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
        pr_cache=$(_get_open_prs "$source" 2>/dev/null) || true
    fi

    # Pre-compute column widths
    local max_tid=0 max_branch=0
    for tid in "${unique_tids[@]}"; do
        (( ${#tid} > max_tid )) && max_tid=${#tid}
        local bn
        bn=$(_target_branch_name "$tid")
        (( ${#bn} > max_branch )) && max_branch=${#bn}
    done

    _spinner_start "Analyzing ${#unique_tids[@]} target(s)..."
    local _status_outfile
    _status_outfile=$(mktemp)

    for tid in "${unique_tids[@]}"; do
        local branch_name
        branch_name=$(_target_branch_name "$tid")

        local alias_tag=""
        local _alias_check
        _alias_check=$(_get_config "targetalias-$(_tid_cfg_encode "${tid}")")
        [[ -n "$_alias_check" ]] && alias_tag=" ${CYAN}(aliased)${NC}"

        local pr_suffix=""
        if [[ -n "$pr_cache" ]]; then
            local pr_num
            pr_num=$(echo "$pr_cache" | awk -v b="$branch_name" '$1 == b {print $2}')
            [[ -n "$pr_num" ]] && pr_suffix=" [PR #${pr_num}]"
        fi

        if ! git rev-parse --verify "refs/heads/$branch_name" &>/dev/null; then
            printf "  ${YELLOW}%-${max_tid}s${NC}  %-${max_branch}s  not created${alias_tag}\n" "$tid" "$branch_name"
            continue
        fi

        # Check if target content is already merged into base
        if _is_content_merged "$branch_name" "$base"; then
            printf "  ${GREEN}%-${max_tid}s${NC}  %-${max_branch}s  ${GREEN}merged${NC}${alias_tag}${pr_suffix}\n" "$tid" "$branch_name"
            has_merged_target=true
            continue
        fi

        # Check for stale commits (reassigned to different tid)
        local stale_out
        stale_out=$(_find_stale_commits "$branch_name" "$tid" "$base" "$status_map_file") || true
        local stale_count=0
        [[ -n "$stale_out" ]] && stale_count=$(echo "$stale_out" | wc -l | tr -d ' ')
        if [[ $stale_count -gt 0 ]]; then
            printf "  ${RED}%-${max_tid}s${NC}  %-${max_branch}s  ${RED}stale (%d commit(s) reassigned)${NC}${alias_tag}${pr_suffix}\n" "$tid" "$branch_name" "$stale_count"
            has_stale=true
            continue
        fi

        # Count pending source -> target
        # Two-phase: cheap history check, then semantic filtering for candidates
        local source_to_target=0
        local -a source_to_target_candidates=()
        # Collect source hashes for this target from cached commit file
        local -a _status_hashes=()
        while IFS= read -r _sh; do
            [[ -n "$_sh" ]] && _status_hashes+=("$_sh")
        done < <(awk -v t="$tid" '$2 == t || $2 == "all" {print $1}' "$status_commit_file")
        while IFS= read -r _nh; do
            [[ -n "$_nh" ]] && source_to_target_candidates+=("$_nh")
        done < <(_find_new_commits_for_target "$base" "$branch_name" "${_status_hashes[@]}")

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
                # Fast blob check first, expensive cherry-pick check only on failures
                for hash in "${source_to_target_candidates[@]}"; do
                    _commit_effect_in_branch "$hash" "$branch_name" && continue
                    _would_cherry_pick_be_empty_on_branch "$hash" "$branch_name" && continue
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
            # Skip Source-Keep commits - generated files, expected to drift
            local _sk
            _sk=$(_extract_dispatch_source_keep "$hash")
            [[ "$_sk" == "true" ]] && continue
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
                # Fast blob check first, expensive cherry-pick check only on failures
                for hash in "${target_to_source_candidates[@]}"; do
                    _commit_effect_in_branch "$hash" "$source" && continue
                    _would_cherry_pick_be_empty_on_branch "$hash" "$source" && continue
                    target_to_source=$((target_to_source + 1))
                done
            fi
        fi

        # Count untracked commits: batch extraction, skip merges
        local untracked=0
        while IFS= read -r _uline; do
            [[ -z "$_uline" ]] && continue
            local _uhash="${_uline%% *}"
            [[ ${#_uhash} -lt 10 ]] && continue  # skip junk lines
            local _utid="${_uline#* }"
            _utid=$(echo "$_utid" | tr -d '[:space:]')
            # Fallback for broken trailer blocks
            if [[ -z "$_utid" && -n "$_uhash" ]]; then
                _utid=$(_extract_dispatch_tid "$_uhash")
            fi
            [[ -z "$_utid" || ( "$_utid" != "$tid" && "$_utid" != "all" ) ]] && untracked=$((untracked + 1))
        done < <(git log --no-merges --format="%H %(trailers:key=Dispatch-Target-Id,valueonly)" "$base..$branch_name" 2>/dev/null)

        # Check for real content divergence when target has non-matching commits
        local diverge_tag=""
        if [[ $target_to_source -gt 0 ]]; then
            if _target_content_diverged "$source" "$branch_name" "$base" "$tid" "$status_commit_file"; then
                diverge_tag=" ${RED}(DIVERGED - checkout, checkin, apply)${NC}"
                has_diverged=true
            fi
        fi

        if [[ $source_to_target -eq 0 && $untracked -eq 0 && -z "$diverge_tag" ]]; then
            printf "  ${GREEN}%-${max_tid}s${NC}  %-${max_branch}s  in sync${alias_tag}${pr_suffix}\n" "$tid" "$branch_name"
        else
            local status_parts=""
            [[ $source_to_target -gt 0 ]] && status_parts="${source_to_target} behind source"
            [[ $untracked -gt 0 ]] && status_parts="${status_parts:+$status_parts, }${CYAN}${untracked} untracked${NC}"

            printf "  ${YELLOW}%-${max_tid}s${NC}  %-${max_branch}s  $status_parts${diverge_tag}${alias_tag}${pr_suffix}\n" "$tid" "$branch_name"
        fi
    done > "$_status_outfile"

    _spinner_stop
    cat "$_status_outfile"
    rm -f "$_status_outfile"

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
        warn "Diverged targets have file content that differs from source."
        echo "  Fix: git dispatch checkout <id>, edit on source, git dispatch checkin, git dispatch apply"
    fi
    if [[ "${has_stale:-}" == "true" ]]; then
        echo ""
        warn "Run: git dispatch apply --force  to rebuild stale targets."
    fi

    if [[ "${has_merged_target:-}" == "true" ]]; then
        local _all_count
        _all_count=$(awk '$2 == "all"' "$status_commit_file" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$_all_count" -gt 0 ]]; then
            echo ""
            warn "$_all_count source commit(s) tagged 'all' may now live on base."
            warn "  Run 'git dispatch lint' to check for mis-tagged commits."
        fi
    fi

    local _audit_summary
    _audit_summary=$(_audit_log_summary)
    if [[ -n "$_audit_summary" ]]; then
        local _audit_path
        _audit_path=$(_audit_log_path 2>/dev/null)
        echo ""
        info "Auto-resolved entries: $_audit_summary. See ${_audit_path:-.git/dispatch-audit.log}"
    fi

}

# ---------- delete ----------

cmd_delete() {
    _require_init

    local target="" dry_run=false prune=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --yes)     DISPATCH_YES=true; shift ;;
            --prune)   prune=true; shift ;;
            -*)        die "Unknown flag: $1" ;;
            *)         [[ -z "$target" ]] && target="$1" || die "Unexpected argument: $1"; shift ;;
        esac
    done

    if ! $prune; then
        [[ -n "$target" ]] || die "Usage: git dispatch delete <N|all|--prune> [--dry-run] [--yes]"
    fi

    local base source
    base=$(_get_config base)
    source=$(resolve_source "")
    [[ -n "$source" ]] || die "Not on a branch and no dispatch source configured"

    local cur
    cur=$(current_branch)

    local -a branches_to_delete=()

    if $prune; then
        # Find targets whose tid no longer exists in source commits
        local -a unique_source_tids=()
        while IFS= read -r _line; do
            local _tid="${_line#* }"
            _tid=$(echo "$_tid" | tr -d '[:space:]')
            local _ph="${_line%% *}"
            # Fallback for broken trailer blocks
            if [[ -z "$_tid" && -n "$_ph" ]]; then
                _tid=$(_extract_dispatch_tid "$_ph")
            fi
            [[ -n "$_tid" && "$_tid" != "all" ]] && unique_source_tids+=("$_tid")
        done < <(git log --no-merges --format="%H %(trailers:key=Dispatch-Target-Id,valueonly)" "$base..$source" 2>/dev/null)
        # Deduplicate
        local -a _deduped=()
        while IFS= read -r _ut; do
            [[ -n "$_ut" ]] && _deduped+=("$_ut")
        done < <(printf '%s\n' "${unique_source_tids[@]}" | sort -u)
        unique_source_tids=("${_deduped[@]}")

        while IFS= read -r existing; do
            [[ -n "$existing" ]] || continue
            local etid
            etid=$(_extract_tid_from_branch "$existing") || true
            [[ -n "$etid" ]] || continue
            local found=false
            for t in "${unique_source_tids[@]}"; do
                [[ "$t" == "$etid" ]] && { found=true; break; }
            done
            $found && continue
            branches_to_delete+=("$existing")
        done < <(find_dispatch_targets "$source")
        [[ ${#branches_to_delete[@]} -gt 0 ]] || { info "No orphaned targets found."; return; }
    elif [[ "$target" == "all" ]]; then
        while IFS= read -r c; do
            [[ -n "$c" ]] && branches_to_delete+=("$c")
        done < <(find_dispatch_targets "$source")
        [[ ${#branches_to_delete[@]} -gt 0 ]] || die "No targets found"
    else
        local branch_name
        branch_name=$(_target_branch_name "$target")
        git rev-parse --verify "refs/heads/$branch_name" &>/dev/null || \
            die "Target branch '$branch_name' does not exist locally"
        branches_to_delete=("$branch_name")
    fi

    if $dry_run; then
        echo -e "${YELLOW}[dry-run]${NC} Would delete: ${branches_to_delete[*]}"
        return
    fi

    echo -e "${CYAN}Will delete:${NC} ${branches_to_delete[*]}"
    _confirm "Proceed?" || { echo "Aborted."; exit 0; }

    local deleted=0
    for branch in "${branches_to_delete[@]}"; do
        if [[ "$cur" == "$branch" ]]; then
            warn "  Skipping $branch (currently checked out)"
            continue
        fi

        # Remove worktree if branch is checked out in one
        local _wt_path
        _wt_path=$(git worktree list --porcelain 2>/dev/null | awk -v b="$branch" '
            /^worktree / { wt=$2 }
            /^branch refs\/heads\// { br=substr($2,12); if (br == b) print wt }
        ')
        if [[ -n "$_wt_path" ]]; then
            git worktree remove --force "$_wt_path" 2>/dev/null || true
        fi

        # Clean up alias config if this branch has one
        local _del_tid
        _del_tid=$(_extract_tid_from_branch "$branch") || true
        if [[ -n "$_del_tid" ]]; then
            git config --unset "branch.${source}.dispatchtargetalias-$(_tid_cfg_encode "${_del_tid}")" 2>/dev/null || true
        fi

        git config --unset "branch.${branch}.dispatchsource" 2>/dev/null || true
        git branch -D "$branch" 2>/dev/null || true
        info "  Deleted $branch"
        deleted=$((deleted + 1))
    done

    echo ""
    info "$deleted target(s) deleted."
}

# ---------- reset ----------

cmd_reset() {
    _require_init

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) DISPATCH_YES=true; shift ;;  # deprecated alias for -y
            --yes) DISPATCH_YES=true; shift ;;
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
    echo "  - legacy hooks and core.hooksPath config (if present)"

    echo ""
    _confirm "Proceed?" || { echo "Aborted."; exit 0; }

    local cur
    cur=$(current_branch)

    # Delete target branches and metadata
    for target in ${targets[@]+"${targets[@]}"}; do
        git config --unset "branch.${target}.dispatchsource" 2>/dev/null || true
        git config --unset-all "branch.${target}.dispatchtargets" 2>/dev/null || true

        if [[ "$cur" == "$target" ]]; then
            warn "  Skipping delete of $target (currently checked out)"
        else
            git branch -D "$target" 2>/dev/null || true
            info "  Deleted $target"
        fi
    done

    # Delete alias configs
    local _alias_line _alias_key
    while IFS= read -r _alias_line; do
        [[ -n "$_alias_line" ]] || continue
        _alias_key="${_alias_line%% *}"
        git config --unset "$_alias_key" 2>/dev/null || true
    done < <(git config --get-regexp "^branch\.${source}\.dispatchtargetalias-" 2>/dev/null || true)

    # Delete dispatch config (branch-scoped)
    git config --unset "branch.${source}.dispatchbase" 2>/dev/null || true
    git config --unset "branch.${source}.dispatchtargetpattern" 2>/dev/null || true
    git config --unset "branch.${source}.dispatchcheckoutbranch" 2>/dev/null || true
    # Clean old global config only if no other dispatch sessions are active
    local other_sessions
    other_sessions=$(_other_dispatch_sessions "$source")
    if [[ -z "$other_sessions" ]]; then
        git config --unset dispatch.base 2>/dev/null || true
        git config --unset dispatch.targetPattern 2>/dev/null || true
        git config --unset dispatch.mode 2>/dev/null || true
    fi

    # Remove hooks and core.hooksPath
    local common_hooks
    common_hooks="$(cd "$(git rev-parse --git-common-dir)" && pwd)/hooks"
    # Only delete hook files if no other dispatch sessions are active
    if [[ -z "$other_sessions" ]]; then
        rm -f "$common_hooks/commit-msg" "$common_hooks/prepare-commit-msg"
    fi
    # Unset core.hooksPath from worktree scope if available, then local
    local wt_enabled
    wt_enabled=$(git config extensions.worktreeConfig 2>/dev/null || true)
    if [[ "$wt_enabled" == "true" ]]; then
        git config --worktree --unset core.hooksPath 2>/dev/null || true
    fi
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
            continue
        fi

        if git -C "$wt" rev-parse --verify MERGE_HEAD &>/dev/null; then
            local _unmerged
            _unmerged=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)
            if [[ -n "$_unmerged" ]]; then
                warn "Merge conflict pending on $branch"
                warn "  Resolve in: $wt"
                warn "  Then:       git -C $wt add <resolved-files>"
                warn "  Then run:   git dispatch continue"
                continue
            fi
            info "All conflicts resolved. Creating merge commit on $branch."
            if ! git -C "$wt" commit --no-edit --no-verify >/dev/null 2>&1; then
                warn "Failed to create merge commit on $branch."
                warn "  Run: git -C $wt commit"
                continue
            fi
            # Fall through to post-merge processing (queue resume / cleanup)
        fi

        {
            # Merge-queue resolved (from merge-based checkout). Check for remaining merges.
            if [[ -f "$wt/.dispatch-merge-queue" ]]; then
                local -a mq_tids=() mq_branches=()
                while IFS=' ' read -r _mqtid _mqbranch; do
                    [[ -n "$_mqtid" ]] && mq_tids+=("$_mqtid") && mq_branches+=("$_mqbranch")
                done < "$wt/.dispatch-merge-queue"
                rm -f "$wt/.dispatch-merge-queue"

                if [[ ${#mq_branches[@]} -gt 0 ]]; then
                    info "Resuming merge on $branch (${#mq_branches[@]} remaining targets)"
                    local -a gcmd=(git -C "$wt")
                    local _mq_merged=0

                    for _mqi in "${!mq_branches[@]}"; do
                        local _mqb="${mq_branches[$_mqi]}"
                        local _mqt="${mq_tids[$_mqi]}"

                        if ! "${gcmd[@]}" merge "$_mqb" --no-edit 2>/dev/null; then
                            # Conflict - save remaining queue and pause
                            local -a mq_new_branches=("${mq_branches[@]:$((_mqi+1))}")
                            local -a mq_new_tids=("${mq_tids[@]:$((_mqi+1))}")
                            if [[ ${#mq_new_branches[@]} -gt 0 ]]; then
                                for _ri in "${!mq_new_branches[@]}"; do
                                    echo "${mq_new_tids[$_ri]} ${mq_new_branches[$_ri]}"
                                done > "$wt/.dispatch-merge-queue"
                            fi
                            echo ""
                            warn "Conflict merging target $_mqt ($_mqb) into checkout"
                            _show_conflict_diff "$wt"
                            echo ""
                            warn "Resolve conflicts, then run: ${gcmd[*]} commit"
                            warn "Then run: git dispatch continue"
                            if [[ ${#mq_new_branches[@]} -gt 0 ]]; then
                                warn "${#mq_new_branches[@]} target(s) remaining after this one."
                            fi
                            info "Resumed: $_mq_merged merged before conflict"
                            git worktree prune 2>/dev/null || true
                            return 1
                        fi
                        _mq_merged=$((_mq_merged + 1))
                    done
                    info "Resumed: $_mq_merged target(s) merged"
                fi
            fi
            # Cherry-pick resolved. Check for remaining queue.
            if [[ -f "$wt/.dispatch-queue" ]]; then
                local -a remaining=()
                while IFS= read -r qh; do
                    [[ -n "$qh" ]] && remaining+=("$qh")
                done < "$wt/.dispatch-queue"
                rm -f "$wt/.dispatch-queue"

                if [[ ${#remaining[@]} -gt 0 ]]; then
                    info "Resuming cherry-pick on $branch (${#remaining[@]} remaining commits)"
                    # Cherry-pick remaining commits in the worktree
                    local -a gcmd=(git -C "$wt")
                    local _cont_picked=0 _cont_skipped=0
                    for (( _qi=0; _qi < ${#remaining[@]}; _qi++ )); do
                        local qhash="${remaining[$_qi]}"
                        if ! "${gcmd[@]}" cherry-pick -x "$qhash" 2>/dev/null; then
                            if "${gcmd[@]}" rev-parse --verify CHERRY_PICK_HEAD &>/dev/null && "${gcmd[@]}" diff --cached --quiet; then
                                warn "  Skipping empty cherry-pick: $(git log -1 --oneline "$qhash")"
                                "${gcmd[@]}" cherry-pick --skip 2>/dev/null || "${gcmd[@]}" reset HEAD --quiet
                                _cont_skipped=$((_cont_skipped + 1))
                                continue
                            fi
                            # Auto-resolve with --theirs when Dispatch-Source-Keep trailer is present
                            local _sk
                            _sk=$(_extract_dispatch_source_keep "$qhash")
                            if [[ -n "$_sk" ]]; then
                                "${gcmd[@]}" cherry-pick --abort 2>/dev/null || true
                                if "${gcmd[@]}" cherry-pick -x --strategy-option theirs "$qhash" 2>/dev/null; then
                                    warn "  Force-accepted (Source-Keep): $(git log -1 --oneline "$qhash")"
                                    _cont_picked=$((_cont_picked + 1))
                                    continue
                                fi
                            fi
                            # Conflict - save remaining queue and pause
                            local -a new_remaining=("${remaining[@]:$((_qi+1))}")
                            if [[ ${#new_remaining[@]} -gt 0 ]]; then
                                printf '%s\n' "${new_remaining[@]}" > "$wt/.dispatch-queue"
                            fi
                            echo ""
                            warn "Conflict on commit $((_qi + 1))/${#remaining[@]}: $(git log -1 --oneline "$qhash")"
                            _show_conflict_diff "$wt"
                            echo ""
                            warn "Resolve conflicts, then run: ${gcmd[*]} cherry-pick --continue"
                            warn "Then run: git dispatch continue"
                            if [[ ${#new_remaining[@]} -gt 0 ]]; then
                                warn "${#new_remaining[@]} commits remaining after this one."
                            fi
                            info "Resumed: $_cont_picked picked, $_cont_skipped skipped before conflict"
                            git worktree prune 2>/dev/null || true
                            return 1
                        fi
                        _cont_picked=$((_cont_picked + 1))
                    done
                    info "Resumed: $_cont_picked picked, $_cont_skipped skipped"
                fi
            fi
            info "Operation complete on $branch. Cleaning up $wt"
            git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
        }

        # Resume pending sync queue, if any. The queue is keyed on the source
        # branch (not on the worktree), so it survives the cleanup above.
        local _src=""
        if git config "branch.${branch}.dispatchbase" >/dev/null 2>&1; then
            _src="$branch"   # branch is itself a dispatch source
        else
            _src=$(git config "branch.${branch}.dispatchsource" 2>/dev/null || true)
        fi
        if [[ -n "$_src" ]]; then
            local _queue
            _queue=$(_sync_queue_get "$_src")
            if [[ -n "$_queue" ]]; then
                _dispatch_resume_sync "$_src" "$_queue" || return $?
            fi
        fi
    done
    git worktree prune 2>/dev/null || true
}

# Resume `sync` over a queue of target branches persisted in
# branch.<source>.dispatchsyncqueue. Mirrors the target-merge loop in cmd_sync,
# including Source-Keep auto-resolve and conflict re-pause.
_dispatch_resume_sync() {
    local source="$1" queue="$2"
    local base
    base=$(git config "branch.${source}.dispatchbase" 2>/dev/null)
    [[ -n "$base" ]] || { _sync_queue_set "$source" ""; return 0; }

    local -a pending=()
    while IFS= read -r _qt; do
        [[ -n "$_qt" ]] && pending+=("$_qt")
    done <<< "$queue"

    [[ ${#pending[@]} -gt 0 ]] || { _sync_queue_set "$source" ""; return 0; }

    info "Resuming sync on ${#pending[@]} remaining target(s)"
    local _merged=0
    local _qi
    for _qi in "${!pending[@]}"; do
        local _qb="${pending[$_qi]}"
        git show-ref --verify --quiet "refs/heads/${_qb}" || continue

        local _qbehind
        _qbehind=$(git rev-list --count "${_qb}..${base}" 2>/dev/null || echo 0)
        if [[ "$_qbehind" -eq 0 ]]; then
            continue
        fi

        _spinner_start "Merging $base into $_qb..."
        _enter_branch "$_qb" || {
            _spinner_stop
            warn "  Cannot access $_qb for base merge (worktree conflict?)"
            continue
        }
        local -a _qcmd=(git -C "$_DISPATCH_WT_PATH")
        _spinner_stop
        if ! "${_qcmd[@]}" merge "$base" --no-edit 2>/dev/null; then
            if _sync_try_source_keep_resolve "$_DISPATCH_WT_PATH" "$_qb" "$base"; then
                info "  Merged $base into $_qb ($_qbehind commits, Source-Keep auto-resolved)"
                _leave_branch
                _merged=$((_merged + 1))
                continue
            fi
            local -a _rest=("${pending[@]:$((_qi+1))}")
            if [[ ${#_rest[@]} -gt 0 ]]; then
                _sync_queue_set "$source" "$(printf '%s\n' "${_rest[@]}")"
            else
                _sync_queue_set "$source" ""
            fi
            echo ""
            warn "Merge conflict on $_qb from $base"
            _show_conflict_diff "$_DISPATCH_WT_PATH"
            echo ""
            warn "Resolve conflicts in worktree: $_DISPATCH_WT_PATH"
            warn "Then:       git -C $_DISPATCH_WT_PATH add <resolved-files>"
            warn "Then run:   git dispatch continue"
            if [[ ${#_rest[@]} -gt 0 ]]; then
                warn "${#_rest[@]} target(s) remaining after this one."
            fi
            info "Resumed: $_merged merged before conflict"
            _DISPATCH_WT_CREATED=false
            _DISPATCH_WT_STASHED=false
            return 1
        fi
        info "  Merged $base into $_qb ($_qbehind commits)"
        _leave_branch
        _merged=$((_merged + 1))
    done

    _sync_queue_set "$source" ""
    info "Sync resumed: $_merged target(s) merged"
    return 0
}

# ---------- checkout ----------

cmd_checkout() {
    local resolve=false force=false dry_run=false
    local subcmd=""
    local -a positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --resolve|--continue) resolve=true; shift ;;
            --force)    force=true; shift ;;
            --dry-run)  dry_run=true; shift ;;
            -*)         die "Unknown flag: $1" ;;
            *)          positional+=("$1"); shift ;;
        esac
    done

    [[ ${#positional[@]} -gt 0 ]] || die "Usage: git dispatch checkout <N|source|clear>"
    subcmd="${positional[0]}"

    case "$subcmd" in
        source) _checkout_source ;;
        clear)  _checkout_clear "$force" ;;
        *)      _checkout_create "$subcmd" "$resolve" "$dry_run" ;;
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
    local n="$1" resolve="$2" dry_run="${3:-false}"
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
    # Reject if on a checkout branch
    [[ "$source" != dispatch-checkout/* ]] || die "Already on a checkout branch. Run: git dispatch checkout clear  first, or: git dispatch checkout source"
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

    # Collect target IDs <= N from source commits (sorted)
    local -a target_tids=()
    while IFS= read -r hash; do
        local tid
        tid=$(_extract_dispatch_tid "$hash")
        [[ -z "$tid" || "$tid" == "all" ]] && continue
        if echo "$tid" | grep -Eq '^[1-9][0-9]*(\.[0-9]+)?$'; then
            if awk "BEGIN {exit !($tid <= $n)}"; then
                target_tids+=("$tid")
            fi
        fi
    done < <(git log --reverse --format="%H" "$base..$source")

    # Deduplicate and sort
    local -a unique_tids=()
    while IFS= read -r t; do
        [[ -n "$t" ]] && unique_tids+=("$t")
    done < <(printf '%s\n' ${target_tids[@]+"${target_tids[@]}"} | sort -t. -k1,1n -k2,2n -u)

    if [[ ${#unique_tids[@]} -eq 0 ]]; then
        die "No commits with Dispatch-Target-Id <= $n"
    fi

    # Verify all target branches exist
    local -a merge_branches=()
    for tid in "${unique_tids[@]}"; do
        local target_branch
        target_branch=$(_target_branch_name "$tid")
        if ! git rev-parse --verify "refs/heads/$target_branch" &>/dev/null; then
            die "Target $tid ($target_branch) not created. Run: git dispatch apply"
        fi
        merge_branches+=("$target_branch")
    done

    if $dry_run; then
        echo -e "${YELLOW}[dry-run]${NC} checkout $n: merge ${#merge_branches[@]} targets from $base"
        for i in "${!unique_tids[@]}"; do
            echo "  merge target ${unique_tids[$i]}  ${merge_branches[$i]}"
        done
        return
    fi

    # Create branch from base
    git branch --no-track "$checkout_branch" "$base" -q

    # Store active checkout in config
    _set_config checkoutBranch "$checkout_branch" "$source"

    info "Creating checkout branch: $checkout_branch (merging ${#merge_branches[@]} targets)"

    # Merge each target branch sequentially
    _enter_branch "$checkout_branch" || die "Cannot access checkout branch (worktree conflict?)"
    local -a gcmd=(git -C "$_DISPATCH_WT_PATH")
    local merged=0

    for i in "${!merge_branches[@]}"; do
        local tb="${merge_branches[$i]}"
        local ttid="${unique_tids[$i]}"

        _spinner_start "Merging target $ttid..."
        if ! "${gcmd[@]}" merge "$tb" --no-edit 2>/dev/null; then
            _spinner_stop
            if $resolve; then
                echo ""
                warn "Conflict merging target $ttid ($tb) into checkout"
                _show_conflict_diff "$_DISPATCH_WT_PATH"
                echo ""
                warn "Resolve conflicts in worktree: $_DISPATCH_WT_PATH"
                warn "Then run: git -C $_DISPATCH_WT_PATH commit"

                # Save remaining targets for continue
                local -a remaining_branches=("${merge_branches[@]:$((i+1))}")
                local -a remaining_tids=("${unique_tids[@]:$((i+1))}")
                if [[ ${#remaining_branches[@]} -gt 0 ]]; then
                    # Store as "tid branch" lines
                    for ri in "${!remaining_branches[@]}"; do
                        echo "${remaining_tids[$ri]} ${remaining_branches[$ri]}"
                    done > "$_DISPATCH_WT_PATH/.dispatch-merge-queue"
                    warn "${#remaining_branches[@]} target(s) remaining after this one."
                fi
                warn "Then run: git dispatch continue"
                _DISPATCH_WT_CREATED=false
                _DISPATCH_WT_STASHED=false
                return 1
            fi
            "${gcmd[@]}" merge --abort 2>/dev/null || true
            _leave_branch
            # Clean up the checkout branch
            git branch -D "$checkout_branch" -q 2>/dev/null || true
            git config --unset "branch.${source}.dispatchcheckoutbranch" 2>/dev/null || true
            die "Conflict merging target $ttid ($tb). Re-run with --resolve to resolve manually."
        fi
        _spinner_stop
        merged=$((merged + 1))
    done

    _leave_branch

    # Store the checkout creation point (everything after this is "new work")
    local checkout_head
    checkout_head=$(git rev-parse "$checkout_branch")
    git config "branch.${checkout_branch}.dispatchcheckoutbase" "$checkout_head"

    info "Checkout ready: $checkout_branch ($merged targets merged)"

    # Switch to the checkout branch
    git checkout "$checkout_branch" -q
    info "Switched to: $checkout_branch"
    echo -e "  ${CYAN}Return:${NC} git dispatch checkout source"
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
    local source

    local cur
    cur=$(current_branch)

    # If on checkout branch, find source and switch first
    if [[ "$cur" == dispatch-checkout/* ]]; then
        local rest="${cur#dispatch-checkout/}"
        source="${rest%/*}"
        git checkout "$source" -q
        info "Switched to source: $source"
    else
        source=$(resolve_source "")
    fi

    # Collect all checkout branches for this source
    local -a all_checkouts=()
    while IFS= read -r b; do
        [[ -n "$b" ]] && all_checkouts+=("$b")
    done < <(git for-each-ref --format='%(refname:short)' "refs/heads/dispatch-checkout/${source}/" 2>/dev/null)

    if [[ ${#all_checkouts[@]} -eq 0 ]]; then
        info "No checkout branch found."
        return
    fi

    DISPATCH_SOURCE="$source"  # set cache for _get_config

    local had_failure=false
    local checkout_branch
    for checkout_branch in "${all_checkouts[@]}"; do
        # Check for unpicked commits (authored after checkout creation)
        if ! $force; then
            local checkout_base
            checkout_base=$(git config "branch.${checkout_branch}.dispatchcheckoutbase" 2>/dev/null || true)

            # Determine range of checkout commits to check
            local range_start
            if [[ -n "$checkout_base" ]]; then
                range_start="$checkout_base"
            else
                range_start=$(_get_config base)
            fi

            # Subject-line + patch-id matching against source (same strategy as apply)
            # Cherry-pick across different bases produces different diffs but same subject.
            local base
            base=$(_get_config base)
            local source_subjects
            source_subjects=$(git log --no-merges --format="%s" "$base..$source" 2>/dev/null) || true
            local source_pids
            source_pids=$(git log --no-merges --format="%H" "$base..$source" 2>/dev/null | \
                while read -r h; do [[ -n "$h" ]] && git show "$h" 2>/dev/null; done | \
                git patch-id --stable 2>/dev/null | awk '{print $1}') || true

            local unpicked=0
            while IFS= read -r ch; do
                [[ -z "$ch" ]] && continue
                local subj
                subj=$(git log -1 --format="%s" "$ch")

                # Primary: subject-line match
                if [[ -n "$subj" ]] && printf '%s\n' "$source_subjects" | grep -Fxq "$subj"; then
                    continue
                fi

                # Fallback: patch-id match
                if [[ -n "$source_pids" ]]; then
                    local cpid
                    cpid=$(git show "$ch" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}')
                    if [[ -n "$cpid" ]] && printf '%s\n' "$source_pids" | grep -Fxq "$cpid"; then
                        continue
                    fi
                fi

                unpicked=$((unpicked + 1))
            done < <(git log --no-merges --format="%H" "$range_start..$checkout_branch")

            if [[ $unpicked -gt 0 ]]; then
                warn "$unpicked unpicked commit(s) on $checkout_branch"
                warn "Run: git dispatch checkin  (to pick back to source)"
                warn "  or: git dispatch checkout clear --force  (to discard)"
                had_failure=true
                continue
            fi
        fi

        # Remove worktree if exists
        local wt_path
        wt_path=$(worktree_for_branch "$checkout_branch")
        if [[ -n "$wt_path" ]]; then
            git worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path"
        fi

        # Delete branch and config
        git config --unset "branch.${checkout_branch}.dispatchcheckoutbase" 2>/dev/null || true
        git branch -D "$checkout_branch" -q 2>/dev/null
        git worktree prune 2>/dev/null || true

        info "Cleared: $checkout_branch"
    done

    # Clean up source config once all are gone
    local remaining
    remaining=$(git for-each-ref --format='%(refname:short)' "refs/heads/dispatch-checkout/${source}/" 2>/dev/null | head -1)
    [[ -n "$remaining" ]] || git config --unset "branch.${source}.dispatchcheckoutbranch" 2>/dev/null || true

    $had_failure && return 1
    return 0
}

# ---------- checkin ----------

cmd_checkin() {
    local resolve=false dry_run=false
    local checkin_n=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --resolve|--continue) resolve=true; shift ;;
            --dry-run)  dry_run=true; shift ;;
            -*)         die "Unknown flag: $1" ;;
            *)          [[ -z "$checkin_n" ]] && checkin_n="$1" || die "Unexpected argument: $1"; shift ;;
        esac
    done

    local cur checkout_branch source base
    cur=$(current_branch)

    if [[ "$cur" == dispatch-checkout/* ]]; then
        # On checkout branch directly
        checkout_branch="$cur"
        local rest="${cur#dispatch-checkout/}"
        source="${rest%/*}"
    elif [[ -n "$checkin_n" ]]; then
        # On source, checkin from checkout <N>
        source=$(resolve_source "")
        checkout_branch=$(_checkout_branch_name "$source" "$checkin_n")
        git rev-parse --verify "refs/heads/$checkout_branch" &>/dev/null || \
            die "Checkout branch '$checkout_branch' does not exist."
    else
        die "Not on a checkout branch. Use: git dispatch checkin <N> (from source)"
    fi

    [[ -n "$source" ]] || die "Cannot determine source branch."

    # Read base from branch-scoped config
    DISPATCH_SOURCE="$source"  # set cache so _get_config resolves correctly
    local base
    base=$(_get_config base)
    [[ -n "$base" ]] || die "Cannot determine base branch."

    # Find new commits: only those authored AFTER checkout was created
    _spinner_start "Comparing commits..."
    local checkout_base
    checkout_base=$(git config "branch.${checkout_branch}.dispatchcheckoutbase" 2>/dev/null || true)

    local -a new_hashes=()
    if [[ -n "$checkout_base" ]]; then
        # Fast path: checkout base SHA recorded, only look at commits after it
        while IFS= read -r ch; do
            [[ -n "$ch" ]] && new_hashes+=("$ch")
        done < <(git log --no-merges --reverse --format="%H" "$checkout_base..$checkout_branch")
    else
        # Fallback for checkouts created before this fix: patch-id matching
        local source_pids
        source_pids=$(git log --format="%H" "$base..$source" | while read -r h; do
            git show "$h" 2>/dev/null
        done | git patch-id --stable 2>/dev/null | awk '{print $1}')

        while IFS= read -r ch; do
            [[ -z "$ch" ]] && continue
            local cpid
            cpid=$(git show "$ch" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}')
            [[ -z "$cpid" ]] && continue
            if ! echo "$source_pids" | grep -Fxq "$cpid"; then
                new_hashes+=("$ch")
            fi
        done < <(git log --reverse --format="%H" "$base..$checkout_branch")
    fi
    _spinner_stop

    if [[ ${#new_hashes[@]} -eq 0 ]]; then
        info "No new commits to pick."
        return
    fi

    if $dry_run; then
        echo -e "${YELLOW}[dry-run]${NC} checkin ${#new_hashes[@]} commit(s) to $source"
        for h in "${new_hashes[@]}"; do
            echo "  $(git log -1 --oneline "$h")"
        done
        return
    fi

    info "Picking ${#new_hashes[@]} commit(s) to source: $source"

    # Cherry-pick to source, honoring Dispatch-Source-Keep
    # Use --no-x to avoid appending cherry-pick metadata that breaks trailer parsing
    if ! _cherry_pick_commits "$resolve" "$source" --no-x "${new_hashes[@]}"; then
        warn "Conflict during checkin. Resolve and run: git dispatch continue"
        return 1
    fi

    info "Checked in $DISPATCH_LAST_PICKED commit(s) to $source"

    # Advance checkout base so checkout clear knows these commits were picked
    local new_base
    new_base=$(git rev-parse "$checkout_branch")
    git config "branch.${checkout_branch}.dispatchcheckoutbase" "$new_base"

    # Switch back to source branch
    if [[ "$cur" == dispatch-checkout/* ]]; then
        git checkout "$source" -q
        info "Switched to source: $source"
    fi

    echo -e "  ${CYAN}Next:${NC} git dispatch checkout clear  (to delete checkout branch)"
    echo -e "  ${CYAN}  or:${NC} git dispatch apply"
}

# ---------- abort ----------

cmd_abort() {
    local aborted=false

    # 1. Check for dispatch temp worktrees with pending operations
    local -a wt_paths=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && wt_paths+=("$line")
    done < <(_find_dispatch_worktrees)

    for wt in ${wt_paths[@]+"${wt_paths[@]}"}; do
        local branch
        branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || echo "unknown")

        if git -C "$wt" rev-parse --verify CHERRY_PICK_HEAD &>/dev/null; then
            git -C "$wt" cherry-pick --abort 2>/dev/null || git -C "$wt" reset --merge 2>/dev/null || true
            info "Aborted cherry-pick on $branch"
            aborted=true
        elif git -C "$wt" rev-parse --verify MERGE_HEAD &>/dev/null; then
            git -C "$wt" merge --abort 2>/dev/null || true
            info "Aborted merge on $branch"
            aborted=true
        fi

        # Remove queue files
        rm -f "$wt/.dispatch-queue" "$wt/.dispatch-merge-queue"

        # Clear any sync queue persisted on this branch's source
        local _abort_src=""
        if git config "branch.${branch}.dispatchbase" >/dev/null 2>&1; then
            _abort_src="$branch"
        else
            _abort_src=$(git config "branch.${branch}.dispatchsource" 2>/dev/null || true)
        fi
        [[ -n "$_abort_src" ]] && _sync_queue_set "$_abort_src" ""

        # Clean up temp worktree
        git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
        info "Cleaned up worktree: $wt"
        aborted=true
    done

    # 2. Check if current branch has pending merge/cherry-pick
    if git rev-parse --verify CHERRY_PICK_HEAD &>/dev/null; then
        git cherry-pick --abort 2>/dev/null || git reset --merge 2>/dev/null || true
        info "Aborted cherry-pick on $(current_branch)"
        aborted=true
    elif git rev-parse --verify MERGE_HEAD &>/dev/null; then
        git merge --abort 2>/dev/null || true
        info "Aborted merge on $(current_branch)"
        aborted=true
    fi

    # 3. Check for checkout branch and offer to clean it
    local cur
    cur=$(current_branch 2>/dev/null || true)
    if [[ "$cur" == dispatch-checkout/* ]]; then
        local rest="${cur#dispatch-checkout/}"
        local source="${rest%/*}"
        if [[ -n "$source" ]]; then
            git checkout "$source" -q 2>/dev/null || true
            git branch -D "$cur" -q 2>/dev/null || true
            git config --unset "branch.${source}.dispatchcheckoutbranch" 2>/dev/null || true
            info "Deleted checkout branch $cur, switched to $source"
            aborted=true
        fi
    fi

    git worktree prune 2>/dev/null || true

    if $aborted; then
        info "Abort complete."
    else
        info "Nothing to abort."
    fi
}

# ---------- retarget ----------

cmd_retarget() {
    _require_init
    _acquire_lock

    local dry_run=false auto_apply=false
    local from_target="" commit_hash="" to_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)    dry_run=true; shift ;;
            --apply)      auto_apply=true; shift ;;
            --target)     [[ -n "${2:-}" ]] || die "--target requires a value"; from_target="$2"; shift 2 ;;
            --commit)     [[ -n "${2:-}" ]] || die "--commit requires a value"; commit_hash="$2"; shift 2 ;;
            --to-target)  [[ -n "${2:-}" ]] || die "--to-target requires a value"; to_id="$2"; shift 2 ;;
            -*)           die "Unknown flag: $1" ;;
            *)            die "Unexpected argument: $1" ;;
        esac
    done

    # Validate required flags
    [[ -n "$to_id" ]] || die "Missing --to-target. Usage: dispatch retarget --target <id> --to-target <id>"
    [[ -n "$from_target" || -n "$commit_hash" ]] || die "Missing --target or --commit. Usage: dispatch retarget --target <id> --to-target <id>"
    [[ -z "$from_target" || -z "$commit_hash" ]] || die "Cannot use both --target and --commit. Pick one."

    _validate_target_id "$to_id"

    local base source
    base=$(_get_config base)
    source=$(resolve_source "")
    [[ -n "$source" ]] || die "Not on a branch and no dispatch source configured"

    # Must be on source branch (not checkout)
    local cur
    cur=$(current_branch)
    if [[ "$cur" == dispatch-checkout/* ]]; then
        die "Cannot retarget from checkout branch. Switch to source first: git dispatch checkout source"
    fi

    local from_id=""
    local -a from_hashes=() from_subjects=()

    if [[ -n "$commit_hash" ]]; then
        # Single commit mode
        commit_hash=$(git rev-parse --verify "$commit_hash" 2>/dev/null) || die "Invalid commit: $commit_hash"
        git merge-base --is-ancestor "$commit_hash" "$source" 2>/dev/null || die "Commit $commit_hash is not on source branch"
        from_id=$(_extract_dispatch_tid "$commit_hash")
        [[ -n "$from_id" ]] || die "Commit $(echo "$commit_hash" | cut -c1-8) has no Dispatch-Target-Id trailer"
        [[ "$from_id" != "$to_id" ]] || die "Commit already has Dispatch-Target-Id: $to_id"
        [[ "$from_id" != "all" ]] || die "Cannot retarget from 'all'. Shared commits cannot be moved."
        from_hashes+=("$commit_hash")
        from_subjects+=("$(git log -1 --format='%s' "$commit_hash")")
    else
        # Target mode - find all commits with matching target id
        _validate_target_id "$from_target"
        [[ "$from_target" != "$to_id" ]] || die "--target and --to-target are the same: $from_target"
        [[ "$from_target" != "all" ]] || die "Cannot retarget from 'all'. Shared commits cannot be moved."
        from_id="$from_target"

        while IFS= read -r _h; do
            [[ -n "$_h" ]] || continue
            local _pc
            _pc=$(git rev-list --parents -n1 "$_h" | wc -w)
            (( _pc > 2 )) && continue
            git merge-base --is-ancestor "$_h" "$base" 2>/dev/null && continue
            local _t
            _t=$(_extract_dispatch_tid "$_h")
            if [[ "$_t" == "$from_id" ]]; then
                from_hashes+=("$_h")
                from_subjects+=("$(git log -1 --format='%s' "$_h")")
            fi
        done < <(git log --reverse --format="%H" "$base..$source")

        [[ ${#from_hashes[@]} -gt 0 ]] || die "No commits found with Dispatch-Target-Id: $from_id"
    fi

    echo -e "${CYAN}Retarget ${#from_hashes[@]} commit(s) from target $from_id to target $to_id${NC}"
    echo ""
    for i in "${!from_hashes[@]}"; do
        echo "  $(echo "${from_hashes[$i]}" | cut -c1-8) ${from_subjects[$i]}"
    done
    echo ""

    if $dry_run; then
        echo "For each commit above, retarget will create on source:"
        echo "  1. revert commit  (Dispatch-Target-Id: $from_id) - cancels original on old target"
        echo "  2. re-apply commit (Dispatch-Target-Id: $to_id) - adds changes to new target"
        echo ""
        echo -e "${YELLOW}Dry run - no changes made.${NC}"
        return 0
    fi

    # Create revert + re-apply pairs on source
    # Reverts in reverse order (last commit reverted first), re-applies in original order
    local -a revert_hashes=()
    for (( i=${#from_hashes[@]}-1; i>=0; i-- )); do
        local hash="${from_hashes[$i]}"
        local subj="${from_subjects[$i]}"

        # Create revert commit
        local revert_msg
        revert_msg="revert: ${subj}

Retargeted from $from_id to $to_id by git dispatch retarget.
This reverts the content of $(echo "$hash" | cut -c1-8).

Dispatch-Target-Id: $from_id"

        if ! git revert --no-commit "$hash" 2>/dev/null; then
            # Revert conflict - this shouldn't normally happen on source
            if git diff --cached --quiet 2>/dev/null; then
                warn "Revert of $(echo "$hash" | cut -c1-8) produced no changes (already reverted?). Skipping."
                git revert --abort 2>/dev/null || git reset --merge 2>/dev/null || true
                continue
            fi
            warn "Conflict reverting $(echo "$hash" | cut -c1-8): $subj"
            warn "Resolve the conflict, then run: git dispatch retarget --target $from_id --to-target $to_id"
            exit 1
        fi

        if git diff --cached --quiet 2>/dev/null; then
            warn "Revert of $(echo "$hash" | cut -c1-8) produced no changes. Skipping."
            git reset --merge 2>/dev/null || true
            continue
        fi

        git commit --no-verify -m "$revert_msg" -q || die "Failed to create revert commit"
        revert_hashes+=("$(git rev-parse HEAD)")
    done

    # Re-apply in original order
    local -a reapply_hashes=()
    for i in "${!from_hashes[@]}"; do
        local hash="${from_hashes[$i]}"
        local subj="${from_subjects[$i]}"

        # Cherry-pick the original content (re-apply)
        local reapply_msg
        reapply_msg="${subj}

Retargeted from $from_id to $to_id by git dispatch retarget.

Dispatch-Target-Id: $to_id"

        if ! git cherry-pick --no-commit "$hash" 2>/dev/null; then
            if git diff --cached --quiet 2>/dev/null; then
                warn "Re-apply of $(echo "$hash" | cut -c1-8) produced no changes. Skipping."
                git cherry-pick --abort 2>/dev/null || git reset --merge 2>/dev/null || true
                continue
            fi
            warn "Conflict re-applying $(echo "$hash" | cut -c1-8): $subj"
            warn "Resolve the conflict, then run: git dispatch retarget --target $from_id --to-target $to_id"
            git cherry-pick --abort 2>/dev/null || git reset --merge 2>/dev/null || true
            exit 1
        fi

        if git diff --cached --quiet 2>/dev/null; then
            warn "Re-apply of $(echo "$hash" | cut -c1-8) produced no changes. Skipping."
            git reset --merge 2>/dev/null || true
            continue
        fi

        git commit --no-verify -m "$reapply_msg" -q || die "Failed to create re-apply commit"
        reapply_hashes+=("$(git rev-parse HEAD)")
    done

    echo ""
    info "Created ${#revert_hashes[@]} revert(s) and ${#reapply_hashes[@]} re-apply commit(s) on source."

    # Check if old target is now empty (all commits retargeted)
    local remaining=0
    while IFS= read -r _h; do
        [[ -n "$_h" ]] || continue
        local _pc
        _pc=$(git rev-list --parents -n1 "$_h" | wc -w)
        (( _pc > 2 )) && continue
        git merge-base --is-ancestor "$_h" "$base" 2>/dev/null && continue
        local _t
        _t=$(_extract_dispatch_tid "$_h")
        [[ "$_t" == "$from_id" ]] && remaining=$((remaining + 1))
    done < <(git log --reverse --format="%H" "$base..$source")

    # Subtract: for each original commit, there's now a revert, so pairs cancel out.
    # remaining counts all commits with from_id (originals + reverts).
    # If remaining == 2 * original_count, all originals have reverts = empty target.
    local original_count=${#from_hashes[@]}
    if [[ $remaining -eq $((original_count * 2)) ]]; then
        echo ""
        warn "Target $from_id is now empty (all commits retargeted to $to_id)."
        echo "  Consider: git dispatch apply reset $from_id"
    fi

    if $auto_apply; then
        echo ""
        info "Running: git dispatch apply"
        cmd_apply
    else
        echo ""
        echo "Next: git dispatch apply"
    fi
}

# ---------- lint ----------

cmd_lint() {
    _require_init
    local base source
    base=$(_get_config base)
    source=$(_resolve_config_branch 2>/dev/null || current_branch)
    [[ -n "$base" ]] || die "Missing base config. Run: git dispatch init"
    [[ -n "$source" ]] || die "Could not resolve dispatch source branch."

    local globs
    if ! globs=$(_load_ownership_globs); then
        local _path
        _path=$(_dispatch_targets_file_path 2>/dev/null || echo ".git-dispatch-targets")
        info "No ownership config at $_path"
        info "Create one to enable ownership lint. See SKILL.md."
        return 0
    fi

    local warnings=0
    while IFS= read -r hash; do
        [[ -n "$hash" ]] || continue
        local pc
        pc=$(git rev-list --parents -n1 "$hash" | wc -w)
        (( pc > 2 )) && continue
        local tid
        tid=$(_extract_dispatch_tid "$hash")
        [[ "$tid" == "all" ]] || continue

        local sole_owner="" has_shared=false has_unmatched=false empty=true
        local f owner
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            empty=false
            owner=$(_match_file_owner "$f" "$globs")
            if [[ -z "$owner" ]]; then
                has_unmatched=true
            elif [[ "$owner" == "shared" ]]; then
                has_shared=true
            elif [[ -z "$sole_owner" ]]; then
                sole_owner="$owner"
            elif [[ "$sole_owner" != "$owner" ]]; then
                sole_owner="__MULTI__"
            fi
        done < <(git diff-tree --no-commit-id --name-only -r "$hash" 2>/dev/null)

        $empty && continue
        $has_shared && continue
        $has_unmatched && continue
        [[ -n "$sole_owner" && "$sole_owner" != "__MULTI__" ]] || continue

        local short
        short=$(echo "$hash" | cut -c1-10)
        warn "$short [all] touches only target-$sole_owner paths"
        echo "  suggested: git dispatch retarget --commit $short --to-target $sole_owner"
        warnings=$((warnings + 1))
    done < <(git log --reverse --format="%H" "$base..$source" 2>/dev/null)

    if [[ $warnings -gt 0 ]]; then
        echo ""
        warn "$warnings commit(s) flagged. Re-tag with 'git dispatch retarget' before applying."
        return 1
    fi
    info "Lint clean. No 'all' commits mis-tagged by ownership rules."
    return 0
}

# ---------- commit ----------

cmd_commit() {
    _require_init

    local message="" target_id="" source_keep=false
    local -a git_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)      [[ -n "${2:-}" ]] || die "--target requires a value"; target_id="$2"; shift 2 ;;
            --source-keep) source_keep=true; shift ;;
            -*)            git_args+=("$1"); shift ;;
            *)
                [[ -z "$message" ]] || die "Unexpected argument: $1"
                message="$1"; shift
                ;;
        esac
    done

    [[ -n "$message" ]] || die "Missing commit message. Usage: dispatch commit \"message\" [--target N] [--source-keep]"

    # Auto-detect target ID on checkout branches
    if [[ -z "$target_id" ]]; then
        local cur
        cur=$(current_branch)
        if [[ "$cur" == dispatch-checkout/* ]]; then
            local rest="${cur#dispatch-checkout/}"
            target_id="${rest##*/}"
        else
            die "Missing --target. Usage: dispatch commit \"message\" --target N"
        fi
    fi

    _validate_target_id "$target_id"

    local -a trailer_args=(--trailer "Dispatch-Target-Id=$target_id")
    if $source_keep; then
        trailer_args+=(--trailer "Dispatch-Source-Keep=true")
    fi

    git commit -m "$message" "${trailer_args[@]}" ${git_args[@]+"${git_args[@]}"}
}

# ---------- alias ----------

cmd_alias() {
    _require_init

    local tid="" branch_name="" subcmd=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            clear)
                subcmd="clear"; shift ;;
            -*)
                die "Unknown flag: $1" ;;
            *)
                if [[ -z "$tid" ]]; then
                    tid="$1"
                elif [[ -z "$branch_name" ]]; then
                    branch_name="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    local source
    source=$(resolve_source "")
    [[ -n "$source" ]] || die "Not on a branch and no dispatch source configured"

    # List mode: no args
    if [[ -z "$tid" && "$subcmd" != "clear" ]]; then
        _alias_list "$source"
        return
    fi

    if [[ "$subcmd" == "clear" ]]; then
        [[ -n "$tid" ]] || die "Usage: git dispatch alias clear <N>"
        _validate_target_id "$tid"
        [[ "$tid" != "all" ]] || die "Cannot alias the 'all' pseudo-target"
        _alias_clear "$source" "$tid"
    else
        [[ -n "$branch_name" ]] || die "Usage: git dispatch alias <N> <branch-name>"
        _validate_target_id "$tid"
        [[ "$tid" != "all" ]] || die "Cannot alias the 'all' pseudo-target"
        _alias_set "$source" "$tid" "$branch_name"
    fi
}

_alias_list() {
    local source="$1"
    local found=false
    local alias_line akey aval atid
    while IFS= read -r alias_line; do
        [[ -n "$alias_line" ]] || continue
        akey="${alias_line%% *}"
        aval="${alias_line#* }"
        atid=$(_tid_cfg_decode "${akey##*dispatchtargetalias-}")
        local pattern_name
        pattern_name=$(_target_branch_name_pattern "$atid")
        if ! $found; then
            echo -e "${CYAN}Aliases:${NC}"
            found=true
        fi
        echo -e "  ${YELLOW}${atid}${NC}  ${pattern_name} -> ${GREEN}${aval}${NC}"
    done < <(git config --get-regexp "^branch\.${source}\.dispatchtargetalias-" 2>/dev/null || true)
    $found || info "No aliases configured."
}

_alias_set() {
    local source="$1" tid="$2" new_name="$3"

    # Check for collision with another alias
    local alias_line akey aval atid
    while IFS= read -r alias_line; do
        [[ -n "$alias_line" ]] || continue
        akey="${alias_line%% *}"
        aval="${alias_line#* }"
        atid=$(_tid_cfg_decode "${akey##*dispatchtargetalias-}")
        if [[ "$aval" == "$new_name" && "$atid" != "$tid" ]]; then
            die "Branch '$new_name' is already aliased to target $atid"
        fi
    done < <(git config --get-regexp "^branch\.${source}\.dispatchtargetalias-" 2>/dev/null || true)

    # Check for collision with a pattern-generated name of another target
    local reverse_tid
    reverse_tid=$(_extract_tid_from_branch "$new_name") || true
    if [[ -n "$reverse_tid" && "$reverse_tid" != "$tid" ]]; then
        die "Branch '$new_name' matches target $reverse_tid (pattern collision)"
    fi

    local old_name
    old_name=$(_target_branch_name_pattern "$tid")

    # Store the alias first (so _target_branch_name returns the alias)
    local tid_safe
    tid_safe=$(_tid_cfg_encode "${tid}")
    _set_config "targetalias-${tid_safe}" "$new_name" "$source"

    # Rename existing branch if it exists under the old pattern name
    if git rev-parse --verify "refs/heads/$old_name" &>/dev/null; then
        local cur
        cur=$(current_branch)
        if [[ "$cur" == "$old_name" ]]; then
            git config --unset "branch.${source}.dispatchtargetalias-${tid_safe}" 2>/dev/null || true
            die "Cannot rename '$old_name' (currently checked out)"
        fi

        # Check worktree
        local _wt_path
        _wt_path=$(git worktree list --porcelain 2>/dev/null | awk -v b="$old_name" '
            /^worktree / { wt=$2 }
            /^branch refs\/heads\// { br=substr($2,12); if (br == b) print wt }
        ')
        if [[ -n "$_wt_path" ]]; then
            git config --unset "branch.${source}.dispatchtargetalias-${tid_safe}" 2>/dev/null || true
            die "Cannot rename '$old_name' (checked out in worktree: $_wt_path)"
        fi

        if git rev-parse --verify "refs/heads/$new_name" &>/dev/null; then
            git config --unset "branch.${source}.dispatchtargetalias-${tid_safe}" 2>/dev/null || true
            die "Branch '$new_name' already exists"
        fi

        git branch -m "$old_name" "$new_name"
        git config "branch.${new_name}.dispatchsource" "$source"
        git config --unset "branch.${old_name}.dispatchsource" 2>/dev/null || true

        info "Renamed $old_name -> $new_name"

        # Check if remote tracking exists for old name
        local remote_ref
        remote_ref=$(git config "branch.${new_name}.merge" 2>/dev/null || true)
        if [[ -n "$remote_ref" ]] || git ls-remote --heads origin "$old_name" 2>/dev/null | grep -q .; then
            warn "Note: Remote branch 'origin/$old_name' still exists."
            warn "  Push new:    git push -u origin $new_name"
            warn "  Delete old:  git push origin --delete $old_name"
        fi
    else
        info "Alias set: target $tid -> $new_name"
    fi
}

_alias_clear() {
    local source="$1" tid="$2"

    local tid_safe
    tid_safe=$(_tid_cfg_encode "${tid}")

    local alias_name
    alias_name=$(_get_config "targetalias-${tid_safe}")
    if [[ -z "$alias_name" ]]; then
        die "No alias configured for target $tid"
    fi

    local pattern_name
    pattern_name=$(_target_branch_name_pattern "$tid")

    # Remove alias config first
    git config --unset "branch.${source}.dispatchtargetalias-${tid_safe}" 2>/dev/null || true

    # Rename branch back to pattern name if it exists
    if git rev-parse --verify "refs/heads/$alias_name" &>/dev/null; then
        local cur
        cur=$(current_branch)
        if [[ "$cur" == "$alias_name" ]]; then
            _set_config "targetalias-${tid_safe}" "$alias_name" "$source"
            die "Cannot rename '$alias_name' (currently checked out)"
        fi

        local _wt_path
        _wt_path=$(git worktree list --porcelain 2>/dev/null | awk -v b="$alias_name" '
            /^worktree / { wt=$2 }
            /^branch refs\/heads\// { br=substr($2,12); if (br == b) print wt }
        ')
        if [[ -n "$_wt_path" ]]; then
            _set_config "targetalias-${tid_safe}" "$alias_name" "$source"
            die "Cannot rename '$alias_name' (checked out in worktree: $_wt_path)"
        fi

        if git rev-parse --verify "refs/heads/$pattern_name" &>/dev/null; then
            _set_config "targetalias-${tid_safe}" "$alias_name" "$source"
            die "Branch '$pattern_name' already exists"
        fi

        git branch -m "$alias_name" "$pattern_name"
        git config "branch.${pattern_name}.dispatchsource" "$source"
        git config --unset "branch.${alias_name}.dispatchsource" 2>/dev/null || true

        info "Renamed $alias_name -> $pattern_name"

        if git ls-remote --heads origin "$alias_name" 2>/dev/null | grep -q .; then
            warn "Note: Remote branch 'origin/$alias_name' still exists."
            warn "  Push new:    git push -u origin $pattern_name"
            warn "  Delete old:  git push origin --delete $alias_name"
        fi
    else
        info "Alias cleared for target $tid"
    fi
}

# ---------- help ----------

cmd_help() {
    cat <<'HELP'
git-dispatch: Create target branches from a source branch and keep them in sync.

SETUP
  git dispatch init [--base <branch>] [--target-pattern <pattern>]

  Initialize dispatch on the current branch. Stores config.
  When --base or --target-pattern are omitted, prompts interactively.
  Recommended: --base "origin/master", --target-pattern "user/feat/task-{id}".

WORKFLOW
  1. Commit with a target trailer:
       git dispatch commit "Add feature" --target 1

  2. Create target branches and push:
       git dispatch apply
       git dispatch push all

  3. Integration testing:
       git dispatch checkout 3                          # branch with targets 1..3
       # run tests, fix bugs
       git dispatch commit "fix bug"                    # auto-detects target from branch
       git dispatch checkin                             # pick fixes back to source
       git dispatch checkout source                     # return to source
       git dispatch apply                               # propagate to targets
       git dispatch checkout clear                      # clean up test branch

  4. Apply to specific target:
       git dispatch apply 3                             # apply to target 3 only

  5. Keep up with master:
       git dispatch sync                                # merge base into source + targets
       git dispatch apply                               # propagate new commits

COMMANDS
  init        Configure dispatch on current source branch
  commit      Commit with auto-managed Dispatch-Target-Id trailer:
                commit "message" --target N    Explicit target
                commit "message"               Auto-detect from checkout branch
                commit "message" --source-keep  Add Source-Keep trailer
  sync        Merge base into source and existing targets. Run before apply.
  apply       Cherry-pick source commits to targets. apply <N> for one target.
              apply reset <N|all> to regenerate from scratch.
  retarget    Move commits between targets without rewriting history:
                retarget --target <id> --to-target <id>   All commits from target
                retarget --commit <hash> --to-target <id> Single commit
                --apply to run apply automatically after retargeting
  lint        Check for 'all'-tagged commits whose files only belong to one
              target. Requires .git-dispatch-targets at repo root. See SKILL.md.
  checkout    Integration testing and navigation:
                checkout <N>       Create test branch with targets 1..N
                checkout source    Return to source branch
                checkout clear     Remove test branch (--force to discard unpicked)
  checkin     Cherry-pick new checkout commits back to source.
              checkin           (from checkout branch)
              checkin <N>       (from source, picks from checkout N)
  push        Push branches (push <all|source|N>)
                push --verify       Run verification before pushing
  verify      Run configured verification on a target:
                verify <N>          Verify target N in a temp worktree
                verify <N> --fix    On failure, leave worktree for fixing
              Configure: git config branch.<source>.dispatchverify "<command>"
  delete      Delete target branches: delete <N|all|--prune>
  alias       Manage target branch aliases:
                alias                          List all aliases
                alias <N> <branch-name>        Alias target N to custom branch name
                alias clear <N>                Remove alias for target N
              Existing branches are renamed. Remote push/delete is manual.
  status      Show base, source, and all targets with sync state
  continue    Resume after conflict resolution
  abort       Cancel in-progress operation, clean up worktrees, return to source
  reset       Delete all dispatch targets and config

FLAGS
  --dry-run   Show plan, make no changes
  --resolve, --continue
              Leave conflict active in a temp worktree for manual resolution.
              The worktree path is printed. After resolving, run the shown
              git command, then: git dispatch continue
  --yes       Skip all confirmation prompts. Required in non-interactive mode
              (piped stdin). Applies to: init, apply, apply reset, reset.
  --all       Include merged targets (skipped by default in sync/apply)
  --no-sync   Skip auto-sync before apply reset
  --no-replay Skip replaying target-only commits after apply reset
  --force     Override safety checks. Meaning depends on command:
                apply --force       Rebuild stale targets (tid reassigned)
                push --force        Push with --force-with-lease
                checkout clear --force  Discard unpicked commits

TRAILERS
  Dispatch-Target-Id (required): numeric integer or decimal (1, 2, 1.5), or "all"
    git dispatch commit "message" --target 1
    git dispatch commit "shared change" --target all

  "all" includes the commit in every target during apply.
  On checkout branches, the target is auto-detected from the branch name.

  Dispatch-Source-Keep (optional): force-accept source version on conflict
    git dispatch commit "regen files" --target 3 --source-keep

  When a cherry-pick conflicts on a commit with this trailer, the source
  version is auto-accepted with --strategy-option theirs.
  Warns when non-generated files are overwritten. Configure patterns:
    git config branch.<source>.dispatchgeneratedpatterns "*/gen/*,*.gen.*"

OWNERSHIP CONFIG
  Optional .git-dispatch-targets at repo root maps paths to targets. Used by
  'git dispatch lint' to flag 'all'-tagged commits that semantically belong to
  one target (a common footgun that breaks apply after squash-merge).

    # .git-dispatch-targets
    1: apps/server/**
    2: apps/web/**
    shared: docs/**
    shared: .github/**

  Lines are "<tid-or-shared>: <glob>". Globs support **, *, ?.
  Lint exits 1 if any 'all' commit is flagged, 0 otherwise.

HELP
}

# ---------- main ----------

main() {
    [[ $# -gt 0 ]] || { cmd_help; exit 0; }

    local cmd="$1"; shift
    case "$cmd" in
        init)         cmd_init "$@" ;;
        commit)       cmd_commit "$@" ;;
        sync)         cmd_sync "$@" ;;
        apply)        cmd_apply "$@" ;;
        push)         cmd_push "$@" ;;
        verify)       cmd_verify "$@" ;;
        status)       cmd_status "$@" ;;
        checkout)     cmd_checkout "$@" ;;
        checkin)      cmd_checkin "$@" ;;
        continue)     cmd_continue "$@" ;;
        abort)        cmd_abort "$@" ;;
        retarget)     cmd_retarget "$@" ;;
        lint)         cmd_lint "$@" ;;
        delete)       cmd_delete "$@" ;;
        reset)        cmd_reset "$@" ;;
        alias)        cmd_alias "$@" ;;
        help|--help|-h) cmd_help ;;
        *)            die "Unknown command: $cmd" ;;
    esac
}

main "$@"
