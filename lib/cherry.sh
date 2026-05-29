#!/bin/bash
# lib/cherry.sh - cherry-pick engine with conflict handling + auto-resolve
#
# Depends on:
#   util.sh  -> warn, die, _enter_branch, _leave_branch, _conflict_leave,
#               _DISPATCH_WT_PATH, _confirm
#   tag.sh   -> _extract_dispatch_tid, _extract_dispatch_source_keep,
#               _resolve_config_branch
#   <main>   -> _log_audit (audit log helper still in git-dispatch.sh)

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
# beyond the commit's own files. In prompt mode, asks the user once per apply (cached
# in _AUTO_RESOLVE_PROMPT_DECIDED) before staging anything.
# Sets _AUTO_RESOLVE_FILES (CSV) on success.
_AUTO_RESOLVE_FILES=""
_AUTO_RESOLVE_PROMPT_DECIDED=""
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

    if [[ "$mode" == "prompt" ]]; then
        if [[ -z "${_AUTO_RESOLVE_PROMPT_DECIDED:-}" ]]; then
            warn "" >&2
            warn "  Detected 'all'-trailer cherry-pick conflict:" >&2
            warn "    commit: $(git log -1 --oneline "$hash")" >&2
            warn "    files:  ${conflicted[*]}" >&2
            warn "  Auto-resolve uses --ours per file, then skips if empty or commits if non-empty." >&2
            if _confirm "Apply auto-resolve here and for any subsequent 'all'-trailer conflicts in this apply?" >&2; then
                _AUTO_RESOLVE_PROMPT_DECIDED="yes"
            else
                _AUTO_RESOLVE_PROMPT_DECIDED="no"
                return 1
            fi
        elif [[ "$_AUTO_RESOLVE_PROMPT_DECIDED" == "no" ]]; then
            return 1
        fi
    fi

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
    local add_trailer="" theirs_fallback=false no_x=false autoresolve_mode="off" target_tid="" _verbose=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --add-trailer) add_trailer="$2"; shift 2 ;;
            --no-x) no_x=true; shift ;;
            --theirs-fallback) theirs_fallback=true; shift ;;
            --autoresolve-mode) autoresolve_mode="$2"; shift 2 ;;
            --target) target_tid="$2"; shift 2 ;;
            --verbose) _verbose=true; shift ;;
            *) break ;;
        esac
    done
    local hashes=("$@")

    DISPATCH_LAST_PICKED=0
    DISPATCH_LAST_SKIPPED=0
    DISPATCH_LAST_PRESKIPPED=0

    _enter_branch "$branch" || die "Cannot access branch $branch (worktree conflict?)"
    local -a gcmd=(git -C "$_DISPATCH_WT_PATH")

    for (( _idx=0; _idx < ${#hashes[@]}; _idx++ )); do
        local hash="${hashes[$_idx]}"

        # Pre-skip when patch is already on base (see _DISPATCH_PATCH_ON_BASE_FILE)
        if [[ -n "${_DISPATCH_PATCH_ON_BASE_FILE:-}" && -f "${_DISPATCH_PATCH_ON_BASE_FILE:-}" ]] && \
           grep -qxF "$hash" "$_DISPATCH_PATCH_ON_BASE_FILE" 2>/dev/null; then
            $_verbose && warn "  Pre-skipped (patch on base): $(git log -1 --oneline "$hash")"
            DISPATCH_LAST_PRESKIPPED=$((DISPATCH_LAST_PRESKIPPED + 1))
            continue
        fi

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
                        warn "  Auto-skipped (all-trailer, empty after --ours): $(git log -1 --oneline "$hash")"
                        _log_audit "auto-skipped" "$hash" "${target_tid:-?}" "all-trailer + empty after --ours" "$_AUTO_RESOLVE_FILES"
                        DISPATCH_LAST_SKIPPED=$((DISPATCH_LAST_SKIPPED + 1))
                        continue
                    elif [[ "$_ar_action" == "continue" ]]; then
                        warn "  Auto-resolved (all-trailer, non-empty after --ours): $(git log -1 --oneline "$hash")"
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
                        warn "  Auto-skipped (all-trailer, empty after --ours): $(git log -1 --oneline "$hash")"
                        _log_audit "auto-skipped" "$hash" "${target_tid:-?}" "all-trailer + empty after --ours" "$_AUTO_RESOLVE_FILES"
                        DISPATCH_LAST_SKIPPED=$((DISPATCH_LAST_SKIPPED + 1))
                        continue
                    elif [[ "$_ar_action_nx" == "continue" ]]; then
                        warn "  Auto-resolved (all-trailer, non-empty after --ours): $(git log -1 --oneline "$hash")"
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
                        warn "  Auto-skipped (all-trailer, empty after --ours): $(git log -1 --oneline "$hash")"
                        _log_audit "auto-skipped" "$hash" "${target_tid:-?}" "all-trailer + empty after --ours" "$_AUTO_RESOLVE_FILES"
                        DISPATCH_LAST_SKIPPED=$((DISPATCH_LAST_SKIPPED + 1))
                        continue
                    elif [[ "$_ar_action_x" == "continue" ]]; then
                        if GIT_EDITOR=true "${gcmd[@]}" cherry-pick --continue 2>/dev/null; then
                            warn "  Auto-resolved (all-trailer, non-empty after --ours): $(git log -1 --oneline "$hash")"
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
