#!/bin/bash
# lib/project.sh - cmd_project: regenerate ship branches from POC tagged commits
#
# Modes (decided per PR):
#   noop            - POC commits + base unchanged, ship branch matches
#   fast_forward    - new commits appended to POC, ship branch can fast-forward
#   full_fresh      - history rewrite OR base advanced; recreate ship branch
#
# Refuses (without --force --accept-detach) when full_fresh would force-push
# a PR with reviewer comments.
#
# Depends on: state.sh (state read/write, conflict.json), tag.sh (_extract_dispatch_tid),
# cherry.sh (_cherry_pick_commits), util.sh (worktree + lock).

# List POC commits tagged for PR-id (in POC order, oldest first)
_project_poc_commits_for() {
    local prn="$1"
    local base poc
    base=$(_state_get '.config.base_ref')
    poc=$(_state_get '.config.poc_branch')
    [[ -n "$base" && -n "$poc" && "$base" != "null" && "$poc" != "null" ]] || return 1

    local commit tid
    while IFS= read -r commit; do
        [[ -z "$commit" ]] && continue
        tid=$(_extract_dispatch_tid "$commit")
        [[ "$tid" == "$prn" ]] && echo "$commit"
    done < <(git rev-list --reverse "$base..$poc" 2>/dev/null)
}

# All unique PR-ids tagged on POC
_project_all_prns() {
    local base poc
    base=$(_state_get '.config.base_ref')
    poc=$(_state_get '.config.poc_branch')
    local commit tid seen
    seen=""
    while IFS= read -r commit; do
        tid=$(_extract_dispatch_tid "$commit")
        [[ -z "$tid" || "$tid" == "all" ]] && continue
        case "|$seen|" in
            *"|$tid|"*) ;;
            *) seen="${seen:+$seen|}$tid"; echo "$tid" ;;
        esac
    done < <(git rev-list --reverse "$base..$poc" 2>/dev/null)
}

# Decide mode for a PR. Outputs: noop|fast_forward|full_fresh
_project_decide_mode() {
    local prn="$1"
    local -a current_commits=()
    local c
    while IFS= read -r c; do
        [[ -n "$c" ]] && current_commits+=("$c")
    done < <(_project_poc_commits_for "$prn")

    # Previous state
    local prev_commits_json
    prev_commits_json=$(_state_get ".projections[\"$prn\"].poc_commits // []")
    local -a prev_commits=()
    while IFS= read -r c; do
        [[ -n "$c" ]] && prev_commits+=("$c")
    done < <(echo "$prev_commits_json" | jq -r '.[]?')

    local base_ref prev_base current_base
    base_ref=$(_state_get '.config.base_ref')
    current_base=$(git rev-parse "$base_ref" 2>/dev/null || echo "")
    prev_base=$(_state_get '.last_master_sha')
    [[ "$prev_base" == "null" ]] && prev_base=""

    # First-time projection (no prior state): always fresh
    local prior_ship
    prior_ship=$(_state_get ".projections[\"$prn\"].ship_head_local")
    if [[ "$prior_ship" == "null" || -z "$prior_ship" ]]; then
        echo "full_fresh"
        return
    fi

    # Compare commit lists
    local n_current=${#current_commits[@]}
    local n_prev=${#prev_commits[@]}

    if [[ "$n_current" -eq "$n_prev" ]]; then
        # Same count - check identity
        local i
        for (( i=0; i<n_current; i++ )); do
            if [[ "${current_commits[$i]}" != "${prev_commits[$i]}" ]]; then
                echo "full_fresh"
                return
            fi
        done
        # Lists identical; check base
        if [[ -z "$prev_base" || "$current_base" == "$prev_base" ]]; then
            echo "noop"
        else
            echo "full_fresh"  # base moved, simplest path is regenerate
        fi
        return
    fi

    if [[ "$n_current" -gt "$n_prev" ]]; then
        # Possibly appended - check prefix
        local i
        for (( i=0; i<n_prev; i++ )); do
            if [[ "${current_commits[$i]}" != "${prev_commits[$i]}" ]]; then
                echo "full_fresh"
                return
            fi
        done
        if [[ -z "$prev_base" || "$current_base" == "$prev_base" ]]; then
            echo "fast_forward"
        else
            echo "full_fresh"
        fi
        return
    fi

    # n_current < n_prev: commits removed -> fresh
    echo "full_fresh"
}

# Pre-check: refuse if POC behind base
_project_check_poc_current() {
    local base poc behind
    base=$(_state_get '.config.base_ref')
    poc=$(_state_get '.config.poc_branch')
    behind=$(git rev-list --count "$poc..$base" 2>/dev/null || echo 0)
    if [[ "$behind" -gt 0 ]]; then
        die "POC ($poc) is $behind commits behind $base. Run 'git dispatch update-base' first."
    fi
}

# Pre-check: refuse if pending conflict exists
_project_check_no_pending_conflict() {
    if _conflict_exists; then
        local cmd
        cmd=$(_conflict_read | jq -r '.command // "unknown"')
        die "Pending conflict from '$cmd'. Resolve and run 'git dispatch continue', or 'git dispatch abort'."
    fi
}

# Pre-check: refuse if ship branch is ahead of state (external commits not absorbed)
_project_check_ship_clean() {
    local prn="$1"
    local ship_branch ship_head_local current_head
    ship_branch=$(_state_get ".projections[\"$prn\"].ship_branch")
    [[ "$ship_branch" == "null" || -z "$ship_branch" ]] && return 0

    ship_head_local=$(_state_get ".projections[\"$prn\"].ship_head_local")
    [[ "$ship_head_local" == "null" || -z "$ship_head_local" ]] && return 0

    current_head=$(git rev-parse "$ship_branch" 2>/dev/null || echo "")
    [[ -z "$current_head" ]] && return 0  # branch deleted; will recreate

    if [[ "$current_head" != "$ship_head_local" ]]; then
        die "Ship branch $ship_branch has diverged from state. Run 'git dispatch absorb' first."
    fi
}

# Execute full_fresh: delete + recreate ship branch from base + cherry-pick commits
_project_do_full_fresh() {
    local prn="$1" resolve="$2"
    local ship_branch base
    ship_branch=$(_state_get ".projections[\"$prn\"].ship_branch")

    # Pattern-derived if not in state
    if [[ "$ship_branch" == "null" || -z "$ship_branch" ]]; then
        local pattern
        pattern=$(_state_get '.config.pattern')
        ship_branch="${pattern//\{id\}/$prn}"
    fi

    base=$(_state_get '.config.base_ref')

    # Collect commits
    local -a commits=()
    local c
    while IFS= read -r c; do
        [[ -n "$c" ]] && commits+=("$c")
    done < <(_project_poc_commits_for "$prn")

    if [[ ${#commits[@]} -eq 0 ]]; then
        warn "  $prn: no tagged commits on POC; skipping"
        return 0
    fi

    info "  $prn: full_fresh (${#commits[@]} commits)"

    # Recreate branch
    if git rev-parse --verify "$ship_branch" >/dev/null 2>&1; then
        git branch -D "$ship_branch" >/dev/null 2>&1 || true
    fi
    git branch "$ship_branch" "$base" >/dev/null 2>&1 || die "Cannot create $ship_branch from $base"

    # Cherry-pick onto ship branch
    if ! _cherry_pick_commits "$resolve" "$ship_branch" --add-trailer "$prn" --theirs-fallback --target "$prn" "${commits[@]}"; then
        # Conflict pause - write conflict.json
        _project_write_conflict "$prn" "${commits[@]}"
        return 1
    fi

    # Update state
    local new_head commits_json
    new_head=$(git rev-parse "$ship_branch")
    commits_json=$(printf '%s\n' "${commits[@]}" | jq -R . | jq -s .)
    _state_apply ".projections[\"$prn\"] |= (. // {}) | .projections[\"$prn\"].ship_branch = \"$ship_branch\" | .projections[\"$prn\"].ship_head_local = \"$new_head\" | .projections[\"$prn\"].force_push_required = true | .projections[\"$prn\"].poc_commits = $commits_json"
}

_project_do_fast_forward() {
    local prn="$1" resolve="$2"
    local ship_branch base
    ship_branch=$(_state_get ".projections[\"$prn\"].ship_branch")
    base=$(_state_get '.config.base_ref')

    # All current commits
    local -a all_commits=()
    local c
    while IFS= read -r c; do
        [[ -n "$c" ]] && all_commits+=("$c")
    done < <(_project_poc_commits_for "$prn")

    # Previously-projected commits
    local prev_json
    prev_json=$(_state_get ".projections[\"$prn\"].poc_commits // []")
    local n_prev
    n_prev=$(echo "$prev_json" | jq '. | length')

    # New commits = all_commits[n_prev:]
    local -a new_commits=("${all_commits[@]:$n_prev}")
    if [[ ${#new_commits[@]} -eq 0 ]]; then
        return 0  # nothing new
    fi

    info "  $prn: fast_forward (+${#new_commits[@]} commits)"

    if ! _cherry_pick_commits "$resolve" "$ship_branch" --add-trailer "$prn" --target "$prn" "${new_commits[@]}"; then
        _project_write_conflict "$prn" "${new_commits[@]}"
        return 1
    fi

    local new_head commits_json
    new_head=$(git rev-parse "$ship_branch")
    commits_json=$(printf '%s\n' "${all_commits[@]}" | jq -R . | jq -s .)
    _state_apply ".projections[\"$prn\"].ship_head_local = \"$new_head\" | .projections[\"$prn\"].poc_commits = $commits_json"
}

_project_write_conflict() {
    local prn="$1"; shift
    local -a remaining=("$@")
    local ship_branch
    ship_branch=$(_state_get ".projections[\"$prn\"].ship_branch")
    local state_hash
    state_hash=$(_state_hash)
    local remaining_json
    remaining_json=$(printf '%s\n' "${remaining[@]}" | jq -R . | jq -s .)
    local content
    content=$(jq -n \
        --arg cmd "project" \
        --arg phase "cherry_pick" \
        --arg prn "$prn" \
        --arg ship "$ship_branch" \
        --arg sh "$state_hash" \
        --argjson rem "$remaining_json" \
        '{
            command: $cmd,
            phase: $phase,
            context: { prn: $prn, remaining_commits: $rem },
            ship_branch: $ship,
            user_action_required: "Resolve conflicts, then: git dispatch continue",
            abort_command: "git dispatch abort",
            started_at_state_hash: $sh
        }')
    _conflict_write "$content"
}

# Main entry
cmd_project() {
    if ! _state_exists; then
        die "No state.json. Run 'git dispatch state init --from-config' or 'git dispatch migrate' first."
    fi

    local prn_filter="" mode_flag=""
    local accept_detach=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --continue) mode_flag="continue"; shift ;;
            --abort)    mode_flag="abort"; shift ;;
            --force)    mode_flag="force"; shift ;;
            --accept-detach) accept_detach=true; shift ;;
            -*) die "Unknown flag: $1" ;;
            *) prn_filter="$1"; shift ;;
        esac
    done

    _acquire_lock

    # Pre-checks
    if [[ "$mode_flag" == "abort" ]]; then
        _conflict_clear
        info "Cleared pending conflict."
        return 0
    fi
    if [[ "$mode_flag" != "continue" ]]; then
        _project_check_no_pending_conflict
    fi
    _project_check_poc_current

    local -a prns=()
    if [[ -n "$prn_filter" ]]; then
        prns=("$prn_filter")
    else
        while IFS= read -r p; do
            [[ -n "$p" ]] && prns+=("$p")
        done < <(_project_all_prns)
    fi

    if [[ ${#prns[@]} -eq 0 ]]; then
        info "No tagged commits found on POC. Nothing to project."
        return 0
    fi

    local prn mode
    local total_changed=0
    for prn in "${prns[@]}"; do
        _project_check_ship_clean "$prn"
        if [[ "$mode_flag" == "force" ]]; then
            mode="full_fresh"
        else
            mode=$(_project_decide_mode "$prn")
        fi

        case "$mode" in
            noop)
                info "  $prn: up to date"
                ;;
            fast_forward)
                _project_do_fast_forward "$prn" "false" && total_changed=$((total_changed + 1))
                ;;
            full_fresh)
                _project_do_full_fresh "$prn" "false" && total_changed=$((total_changed + 1))
                ;;
            *)
                die "Unknown project mode: $mode"
                ;;
        esac
    done

    # Update last_master_sha
    local base current_base
    base=$(_state_get '.config.base_ref')
    current_base=$(git rev-parse "$base" 2>/dev/null || echo "")
    if [[ -n "$current_base" ]]; then
        _state_apply ".last_master_sha = \"$current_base\""
    fi

    info "Project complete. ${total_changed} projection(s) changed."
}
