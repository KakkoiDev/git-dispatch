#!/bin/bash
# lib/combined.sh - cmd_combined: build integration branch from arbitrary PR subset
#
# Usage:
#   git dispatch combined --include PR-1,PR-3,PR-5    # create integration branch
#   git dispatch combined --dissolve [<branch>]       # remove combined branch + state
#   git dispatch combined --list                      # list active combined branches
#
# Branch naming: combined/<8-char-suffix>
# State tracked in state.combined[branch-name] = { prns: [...], created_from: <base-sha> }

# Generate a random 8-char suffix using bash $RANDOM (no pipefail interaction)
_combined_random_suffix() {
    local s=""
    while [[ ${#s} -lt 8 ]]; do
        s="$s$(printf '%x' "$((RANDOM % 16))")"
    done
    echo "$s"
}

# Collect POC commits tagged for any PR in the include set, in POC order
_combined_collect_commits() {
    local include_csv="$1"
    local base poc
    base=$(_state_get '.config.base_ref')
    poc=$(_state_get '.config.poc_branch')

    # Build a lookup of included tids
    local IFS_save="$IFS"
    IFS=','
    local -a included=($include_csv)
    IFS="$IFS_save"

    local commit tid t in_set
    while IFS= read -r commit; do
        [[ -z "$commit" ]] && continue
        tid=$(_extract_dispatch_tid "$commit")
        [[ -z "$tid" ]] && continue
        # "all"-trailer commits go to every combined
        if [[ "$tid" == "all" ]]; then
            echo "$commit"
            continue
        fi
        in_set=false
        for t in "${included[@]}"; do
            [[ "$t" == "$tid" ]] && { in_set=true; break; }
        done
        $in_set && echo "$commit"
    done < <(git rev-list --reverse "$base..$poc" 2>/dev/null)
}

_combined_create() {
    local include_csv="$1"
    local base
    base=$(_state_get '.config.base_ref')

    local current_base
    current_base=$(git rev-parse "$base" 2>/dev/null) || die "Cannot resolve base ref: $base"

    local suffix branch_name
    suffix=$(_combined_random_suffix)
    branch_name="combined/$suffix"

    # Collect commits
    local -a commits=()
    local c
    while IFS= read -r c; do
        [[ -n "$c" ]] && commits+=("$c")
    done < <(_combined_collect_commits "$include_csv")

    if [[ ${#commits[@]} -eq 0 ]]; then
        die "No commits found for include set: $include_csv"
    fi

    info "Creating $branch_name from $base (${#commits[@]} commits)"

    git branch "$branch_name" "$base" >/dev/null 2>&1 || die "Cannot create $branch_name"

    if ! _cherry_pick_commits "false" "$branch_name" --theirs-fallback "${commits[@]}"; then
        warn "Cherry-pick failed for combined branch. Worktree left for resolution."
        return 1
    fi

    # Record in state
    local includes_json
    local IFS_save="$IFS"
    IFS=','
    local -a included=($include_csv)
    IFS="$IFS_save"
    includes_json=$(printf '%s\n' "${included[@]}" | jq -R . | jq -s .)

    _state_apply ".combined[\"$branch_name\"] = { includes: $includes_json, created_from: \"$current_base\", commit_count: ${#commits[@]} }"

    echo ""
    info "Combined branch ready: $branch_name"
    info "Run tests / codegen on this branch. Use 'git checkout $branch_name' to switch."
    info "When done: 'git dispatch combined --dissolve $branch_name'"
}

_combined_dissolve() {
    local branch_name="$1"
    if [[ -z "$branch_name" ]]; then
        # If no name given, try to detect a single existing combined branch
        local count names
        names=$(_state_get '.combined | keys[]' 2>/dev/null || true)
        count=$(echo "$names" | grep -c . || true)
        if [[ "$count" -eq 1 ]]; then
            branch_name=$(echo "$names" | head -1)
        else
            die "Multiple combined branches active. Specify which to dissolve."
        fi
    fi

    # Switch off if on it
    local cur
    cur=$(current_branch 2>/dev/null || true)
    if [[ "$cur" == "$branch_name" ]]; then
        local poc
        poc=$(_state_get '.config.poc_branch')
        git checkout "$poc" -q || die "Cannot leave $branch_name"
    fi

    git branch -D "$branch_name" >/dev/null 2>&1 || warn "Branch $branch_name already gone"

    _state_apply "del(.combined[\"$branch_name\"])"

    info "Dissolved: $branch_name"
}

_combined_list() {
    local active
    active=$(_state_get '.combined // {}')
    if [[ "$active" == "{}" || "$active" == "null" ]]; then
        info "No active combined branches."
        return 0
    fi
    echo "$active" | jq -r 'to_entries[] | "\(.key)  includes=\(.value.includes | join(",")) commits=\(.value.commit_count)"'
}

cmd_combined() {
    if ! _state_exists; then
        die "No state.json. Run 'git dispatch state init --from-config' or 'git dispatch migrate' first."
    fi

    local mode="" include_csv="" dissolve_target=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --include)  mode="create"; include_csv="$2"; shift 2 ;;
            --dissolve) mode="dissolve"; dissolve_target="${2:-}"
                        [[ -n "$dissolve_target" ]] && shift 2 || shift ;;
            --list)     mode="list"; shift ;;
            -*)         die "Unknown flag: $1" ;;
            *)          die "Unexpected argument: $1" ;;
        esac
    done

    [[ -z "$mode" ]] && die "Usage: dispatch combined --include PR-1,PR-2 | --dissolve [<name>] | --list"

    _acquire_lock

    case "$mode" in
        create)   _combined_create "$include_csv" ;;
        dissolve) _combined_dissolve "$dissolve_target" ;;
        list)     _combined_list ;;
    esac
}
