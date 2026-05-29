#!/bin/bash
# lib/absorb.sh - cmd_absorb: pull external commits from ship branches back to POC
#
# Two modes:
#   diff (default)        - cherry-pick new commits since absorb_watermark to POC
#   replace --files X,Y   - skip cherry-pick, copy files from ship branch to POC,
#                           single commit with Dispatch-Source-Keep trailer
#
# Filters out commits already on POC (own pushed work) via patch-id matching.
#
# Depends on: state.sh, tag.sh (_extract_dispatch_tid), cherry.sh (_cherry_pick_commits),
# util.sh (lock, worktree).

# Compute stable patch-id of a commit
_absorb_patch_id() {
    local commit="$1"
    git show "$commit" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1
}

# Return 0 if commit's patch is already on POC tagged with prn
_absorb_already_on_poc() {
    local commit="$1" prn="$2"
    local poc base pid cpid c tid
    poc=$(_state_get '.config.poc_branch')
    base=$(_state_get '.config.base_ref')

    pid=$(_absorb_patch_id "$commit")
    [[ -z "$pid" ]] && return 1

    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        tid=$(_extract_dispatch_tid "$c")
        [[ "$tid" != "$prn" ]] && continue
        cpid=$(_absorb_patch_id "$c")
        [[ "$cpid" == "$pid" ]] && return 0
    done < <(git rev-list "$base..$poc" 2>/dev/null)
    return 1
}

_absorb_pick() {
    local prn="$1" ship_branch="$2" watermark="$3" current_head="$4"
    local poc
    poc=$(_state_get '.config.poc_branch')

    # New commits since watermark
    local -a new_commits=()
    local c
    while IFS= read -r c; do
        [[ -n "$c" ]] && new_commits+=("$c")
    done < <(git rev-list --reverse --no-merges "$watermark..$current_head" 2>/dev/null)

    [[ ${#new_commits[@]} -eq 0 ]] && {
        return 0
    }

    # Filter: skip commits already on POC (own pushed work)
    local -a unique=()
    for c in "${new_commits[@]}"; do
        if ! _absorb_already_on_poc "$c" "$prn"; then
            unique+=("$c")
        fi
    done

    if [[ ${#unique[@]} -eq 0 ]]; then
        info "  $prn: no new external commits (all match POC)"
        _state_apply ".absorb_watermark[\"$prn\"] = \"$current_head\""
        return 0
    fi

    info "  $prn: absorbing ${#unique[@]} commit(s) onto $poc"

    if ! _cherry_pick_commits "false" "$poc" --add-trailer "$prn" --target "$prn" "${unique[@]}"; then
        warn "Conflict during absorb. Worktree left for manual resolution."
        return 1
    fi

    _state_apply ".absorb_watermark[\"$prn\"] = \"$current_head\""
}

_absorb_replace() {
    local prn="$1" ship_branch="$2" current_head="$3"; shift 3
    local -a files=("$@")
    local poc
    poc=$(_state_get '.config.poc_branch')

    info "  $prn: replacing ${#files[@]} file(s) from $ship_branch"

    local cur_branch
    cur_branch=$(current_branch 2>/dev/null)
    local switched=false
    if [[ "$cur_branch" != "$poc" ]]; then
        git checkout "$poc" -q || die "Cannot checkout $poc for absorb"
        switched=true
    fi

    # Checkout files from ship branch
    local f
    for f in "${files[@]}"; do
        git checkout "$ship_branch" -- "$f" 2>/dev/null || warn "    file not present in $ship_branch: $f"
    done

    # Stage + commit
    git add "${files[@]}" 2>/dev/null || true
    if git diff --cached --quiet; then
        info "  $prn: replace produced no changes (files identical)"
        return 0
    fi
    git commit -q -m "absorb: regenerate files from $ship_branch" \
        --trailer "Dispatch-Target-Id=$prn" \
        --trailer "Dispatch-Source-Keep=true" \
        || die "Cannot commit absorbed files"

    _state_apply ".absorb_watermark[\"$prn\"] = \"$current_head\""

    $switched && git checkout "$cur_branch" -q 2>/dev/null || true
}

cmd_absorb() {
    if ! _state_exists; then
        die "No state.json. Run 'git dispatch state init --from-config' or 'git dispatch migrate' first."
    fi

    local mode="diff"
    local -a files=()
    local prn_filter=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)   mode="$2"; shift 2 ;;
            --files)  IFS=',' read -ra files <<< "$2"; shift 2 ;;
            -*)       die "Unknown flag: $1" ;;
            *)        prn_filter="$1"; shift ;;
        esac
    done

    [[ "$mode" == "diff" || "$mode" == "replace" ]] || die "Invalid mode: $mode (use: diff|replace)"
    if [[ "$mode" == "replace" && ${#files[@]} -eq 0 ]]; then
        die "--mode replace requires --files <paths>"
    fi

    _acquire_lock

    local -a prns=()
    if [[ -n "$prn_filter" ]]; then
        prns=("$prn_filter")
    else
        while IFS= read -r p; do
            [[ -n "$p" ]] && prns+=("$p")
        done < <(_state_get '.projections | keys[]')
    fi

    [[ ${#prns[@]} -eq 0 ]] && {
        info "No projections in state. Nothing to absorb."
        return 0
    }

    local prn ship_branch watermark current_head
    local processed=0
    for prn in "${prns[@]}"; do
        ship_branch=$(_state_get ".projections[\"$prn\"].ship_branch")
        [[ "$ship_branch" == "null" || -z "$ship_branch" ]] && continue

        # Watermark: prefer absorb_watermark, fall back to ship_head_remote, then ship_head_local
        watermark=$(_state_get ".absorb_watermark[\"$prn\"]")
        if [[ "$watermark" == "null" || -z "$watermark" ]]; then
            watermark=$(_state_get ".projections[\"$prn\"].ship_head_remote")
        fi
        if [[ "$watermark" == "null" || -z "$watermark" ]]; then
            watermark=$(_state_get ".projections[\"$prn\"].ship_head_local")
        fi
        [[ "$watermark" == "null" || -z "$watermark" ]] && {
            info "  $prn: no watermark, skipping (use 'project' first)"
            continue
        }

        current_head=$(git rev-parse "$ship_branch" 2>/dev/null || echo "")
        [[ -z "$current_head" ]] && {
            info "  $prn: ship branch $ship_branch missing, skipping"
            continue
        }
        [[ "$current_head" == "$watermark" ]] && continue

        if [[ "$mode" == "replace" ]]; then
            _absorb_replace "$prn" "$ship_branch" "$current_head" "${files[@]}"
        else
            _absorb_pick "$prn" "$ship_branch" "$watermark" "$current_head"
        fi
        processed=$((processed + 1))
    done

    info "Absorb complete. $processed PR(s) processed."
}
