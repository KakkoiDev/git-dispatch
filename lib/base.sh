#!/bin/bash
# lib/base.sh - cmd_update_base + cmd_clean
#
# update-base: bring POC current with base (merge by default, rebase optional)
# clean:       drop merged commits from POC, delete merged ship branches, update merged_prs
#
# Depends on: state.sh, util.sh, tag.sh

cmd_update_base() {
    if ! _state_exists; then
        die "No state.json. Run 'git dispatch state init --from-config' or 'git dispatch migrate' first."
    fi

    local mode="merge"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --merge)  mode="merge"; shift ;;
            --rebase) mode="rebase"; shift ;;
            -*)       die "Unknown flag: $1" ;;
            *)        die "Unexpected argument: $1" ;;
        esac
    done

    _acquire_lock

    local base poc remote
    base=$(_state_get '.config.base_ref')
    poc=$(_state_get '.config.poc_branch')
    remote=$(_state_get '.config.remote')
    [[ "$remote" == "null" || -z "$remote" ]] && remote="origin"

    info "Fetching $remote..."
    git fetch "$remote" --quiet 2>/dev/null || warn "fetch $remote failed (continuing with local refs)"

    local current_base behind
    current_base=$(git rev-parse "$base" 2>/dev/null) || die "Cannot resolve base $base"
    behind=$(git rev-list --count "$poc..$base" 2>/dev/null || echo 0)

    if [[ "$behind" -eq 0 ]]; then
        info "POC is up to date with $base."
        _state_apply ".last_master_sha = \"$current_base\""
        return 0
    fi

    # Warn for --rebase if any open PRs
    if [[ "$mode" == "rebase" ]]; then
        local open_prs
        open_prs=$(_state_get '[.projections[] | select(.pr_state == "open")] | length')
        if [[ "$open_prs" -gt 0 ]]; then
            warn "Warning: $open_prs open PR(s) exist. Rebase will rewrite POC SHAs."
            warn "Use --merge to preserve PR review threads, or proceed at your own risk."
        fi
    fi

    # Switch to POC
    local cur
    cur=$(current_branch 2>/dev/null)
    local switched=false
    if [[ "$cur" != "$poc" ]]; then
        git checkout "$poc" -q || die "Cannot checkout $poc"
        switched=true
    fi

    info "$mode $base into $poc ($behind commits)"

    if [[ "$mode" == "merge" ]]; then
        if ! git merge "$base" --no-edit; then
            warn "Merge conflict. Resolve in working tree, then:"
            warn "  git add <files>"
            warn "  git commit --no-edit"
            warn "  git dispatch continue   # or abort"
            local content
            content=$(jq -n --arg cb "$current_base" \
                '{ command: "update-base", phase: "merge",
                   context: { base_sha: $cb },
                   user_action_required: "Resolve conflict, commit, then: git dispatch continue",
                   abort_command: "git merge --abort && git dispatch abort" }')
            _conflict_write "$content"
            return 1
        fi
    else
        if ! git rebase "$base"; then
            warn "Rebase conflict. Resolve, then 'git rebase --continue' + 'git dispatch continue'"
            local content
            content=$(jq -n --arg cb "$current_base" \
                '{ command: "update-base", phase: "rebase",
                   context: { base_sha: $cb },
                   user_action_required: "Resolve, git rebase --continue, then: git dispatch continue",
                   abort_command: "git rebase --abort && git dispatch abort" }')
            _conflict_write "$content"
            return 1
        fi
    fi

    _state_apply ".last_master_sha = \"$current_base\""

    $switched && git checkout "$cur" -q 2>/dev/null || true

    info "POC up to date with $base."
}

# Compute patch-id of a commit (stable, content-only)
_base_patch_id() {
    local commit="$1"
    git show "$commit" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1
}

# Returns 0 if patch-id is present on base
_base_patch_id_on_base() {
    local pid="$1"
    [[ -z "$pid" ]] && return 1
    local base
    base=$(_state_get '.config.base_ref')
    # Search ~500 base commits for matching patch-id (cheap enough for typical use)
    local c bpid
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        bpid=$(_base_patch_id "$c")
        [[ "$bpid" == "$pid" ]] && return 0
    done < <(git rev-list -n 500 "$base" 2>/dev/null)
    return 1
}

cmd_clean() {
    if ! _state_exists; then
        die "No state.json. Run 'git dispatch state init --from-config' or 'git dispatch migrate' first."
    fi

    _acquire_lock

    local base poc remote
    base=$(_state_get '.config.base_ref')
    poc=$(_state_get '.config.poc_branch')
    remote=$(_state_get '.config.remote')
    [[ "$remote" == "null" || -z "$remote" ]] && remote="origin"

    # Detect merged PRs by patch-id intersection
    local -a merged_prns=()
    local -a prns_in_state=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && prns_in_state+=("$p")
    done < <(_state_get '.projections | keys[]')

    if [[ ${#prns_in_state[@]} -eq 0 ]]; then
        info "No projections in state. Nothing to clean."
        return 0
    fi

    local prn
    for prn in "${prns_in_state[@]}"; do
        # Collect commit list
        local commits_json
        commits_json=$(_state_get ".projections[\"$prn\"].poc_commits")
        local -a commits=()
        while IFS= read -r c; do
            [[ -n "$c" ]] && commits+=("$c")
        done < <(echo "$commits_json" | jq -r '.[]?')

        [[ ${#commits[@]} -eq 0 ]] && continue

        # Check if ALL patches are on base
        local all_merged=true c pid
        for c in "${commits[@]}"; do
            pid=$(_base_patch_id "$c")
            if ! _base_patch_id_on_base "$pid"; then
                all_merged=false
                break
            fi
        done

        if $all_merged; then
            merged_prns+=("$prn")
        fi
    done

    if [[ ${#merged_prns[@]} -eq 0 ]]; then
        info "No merged PRs detected."
        return 0
    fi

    # Rebase POC on base to drop merged commits
    info "Detected ${#merged_prns[@]} merged PR(s): ${merged_prns[*]}"
    info "Rebasing $poc on $base to drop merged commits..."

    local cur
    cur=$(current_branch 2>/dev/null)
    local switched=false
    if [[ "$cur" != "$poc" ]]; then
        git checkout "$poc" -q || die "Cannot checkout $poc"
        switched=true
    fi

    # --empty=drop ensures patches that are already on base get dropped
    if ! git rebase --empty=drop "$base" 2>/dev/null; then
        warn "Rebase conflict during clean. Resolve manually and re-run."
        return 1
    fi

    # Delete merged ship branches + update state
    for prn in "${merged_prns[@]}"; do
        local ship_branch
        ship_branch=$(_state_get ".projections[\"$prn\"].ship_branch")
        if [[ -n "$ship_branch" && "$ship_branch" != "null" ]]; then
            git branch -D "$ship_branch" 2>/dev/null && info "  deleted $ship_branch" || true
            # Try delete remote ship branch (best-effort)
            git push "$remote" --delete "$ship_branch" 2>/dev/null && info "  deleted remote $ship_branch" || true
        fi

        local current_base
        current_base=$(git rev-parse "$base" 2>/dev/null || echo "")
        _state_apply ".merged_prs += [{ id: \"$prn\", merged_into: \"$current_base\" }] | del(.projections[\"$prn\"]) | del(.absorb_watermark[\"$prn\"])"
    done

    $switched && git checkout "$cur" -q 2>/dev/null || true

    info "Cleaned ${#merged_prns[@]} merged PR(s)."
}
