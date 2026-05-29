#!/bin/bash
# lib/state.sh - centralized state.json + conflict.json store
#
# Layout: <worktree-root>/.dispatch/
#   state.json       - authoritative state (config, projections, watermarks)
#   state.json.bak   - backup written before every mutation
#   conflict.json    - present when a command is paused for conflict resolution
#   lock             - process lock (separate from .git/dispatch.lock used by old code)
#
# Depends on: util.sh (die, warn, info), jq binary

_state_dir() {
    local top
    top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    echo "$top/.dispatch"
}

_state_path()         { local d; d=$(_state_dir) || return 1; echo "$d/state.json"; }
_state_bak_path()     { local d; d=$(_state_dir) || return 1; echo "$d/state.json.bak"; }
_conflict_path()      { local d; d=$(_state_dir) || return 1; echo "$d/conflict.json"; }
_state_lock_path()    { local d; d=$(_state_dir) || return 1; echo "$d/lock"; }

_state_ensure_dir() {
    local d
    d=$(_state_dir) || return 1
    [[ -d "$d" ]] || mkdir -p "$d"
}

_state_exists() {
    local p
    p=$(_state_path) || return 1
    [[ -f "$p" ]]
}

# Print state.json content (or "{}" if missing)
_state_read() {
    local p
    p=$(_state_path) || return 1
    if [[ -f "$p" ]]; then
        cat "$p"
    else
        echo "{}"
    fi
}

# Backup current state.json before mutation
_state_backup() {
    local p b
    p=$(_state_path) || return 0
    [[ -f "$p" ]] || return 0
    b=$(_state_bak_path) || return 0
    cp "$p" "$b" 2>/dev/null || true
}

# Write content to state.json. Pretty-printed via jq.
_state_write() {
    local content="$1"
    _state_ensure_dir || die "Cannot create .dispatch/ directory"
    local p
    p=$(_state_path) || die "Cannot resolve state.json path"
    _state_backup
    if ! echo "$content" | jq '.' > "$p"; then
        die "Failed to write state.json (invalid JSON?)"
    fi
}

# Stable hash of canonical (sorted) state.json for idempotency tests
_state_hash() {
    local p
    p=$(_state_path) || return 1
    if [[ ! -f "$p" ]]; then
        echo "empty"
        return
    fi
    jq -cS '.' "$p" | shasum -a 256 | cut -d' ' -f1
}

# Initialize state.json with config block. Refuses to overwrite existing.
_state_init() {
    local base_ref="$1" pattern="$2" poc_branch="$3" remote="${4:-origin}"
    if _state_exists; then
        die "state.json already exists. Use 'git dispatch repair' to rebuild or remove .dispatch/ first."
    fi
    _state_ensure_dir
    local content
    content=$(jq -n \
        --arg base "$base_ref" \
        --arg pat "$pattern" \
        --arg poc "$poc_branch" \
        --arg rem "$remote" \
        '{
            version: 1,
            config: {
                base_ref: $base,
                pattern: $pat,
                poc_branch: $poc,
                remote: $rem
            },
            projections: {},
            absorb_watermark: {},
            merged_prs: [],
            last_master_sha: null,
            pending_conflict: null
        }')
    _state_write "$content"
}

# jq query against state.json. Returns raw value.
_state_get() {
    local query="$1"
    _state_read | jq -r "$query"
}

# Update state via jq expression. Atomic via state_backup + write.
# Usage: _state_set '.config.base_ref' '"origin/main"'
_state_set() {
    local path="$1" value="$2"
    local current updated
    current=$(_state_read)
    updated=$(echo "$current" | jq "$path = $value")
    _state_write "$updated"
}

# Apply arbitrary jq transformation. For complex updates.
# Usage: _state_apply '.projections["PR-1"].ship_head_local = "abc123"'
_state_apply() {
    local jq_expr="$1"
    local current updated
    current=$(_state_read)
    updated=$(echo "$current" | jq "$jq_expr")
    _state_write "$updated"
}

# ---------- conflict.json ----------

_conflict_exists() {
    local p
    p=$(_conflict_path) || return 1
    [[ -f "$p" ]]
}

_conflict_read() {
    local p
    p=$(_conflict_path) || return 1
    if [[ -f "$p" ]]; then
        cat "$p"
    else
        echo "null"
    fi
}

# Write a conflict descriptor. Pretty-printed via jq.
_conflict_write() {
    local content="$1"
    _state_ensure_dir
    local p
    p=$(_conflict_path) || die "Cannot resolve conflict.json path"
    if ! echo "$content" | jq '.' > "$p"; then
        die "Failed to write conflict.json (invalid JSON?)"
    fi
}

_conflict_clear() {
    local p
    p=$(_conflict_path) || return 0
    rm -f "$p"
}

# ---------- commands ----------

# git dispatch state show [--json]
# git dispatch state init [--from-config]
# git dispatch state hash
cmd_state() {
    local sub="${1:-show}"; shift || true
    case "$sub" in
        show)
            if ! _state_exists; then
                info "No state.json yet. Run 'git dispatch state init' or 'git dispatch migrate'."
                return 0
            fi
            local fmt="${1:-pretty}"
            if [[ "$fmt" == "--json" || "$fmt" == "json" ]]; then
                _state_read
            else
                _state_read | jq '.'
            fi
            ;;
        init)
            local from_config=false
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --from-config) from_config=true; shift ;;
                    *) die "Unknown flag: $1" ;;
                esac
            done
            if $from_config; then
                # Use existing branch git config to seed state.json
                local source base pattern
                source=$(_resolve_config_branch 2>/dev/null || true)
                [[ -n "$source" ]] || die "No dispatch config found on current branch. Run 'git dispatch init' first."
                base=$(_get_config base)
                pattern=$(_get_config targetpattern)
                [[ -n "$base" && -n "$pattern" ]] || die "Incomplete config. Run 'git dispatch init'."
                _state_init "$base" "$pattern" "$source"
                info "Initialized state.json from git config (source=$source)"
            else
                die "state init requires --from-config (or use 'git dispatch migrate')"
            fi
            ;;
        hash)
            _state_hash
            ;;
        path)
            _state_path
            ;;
        *)
            die "Unknown state subcommand: $sub (use: show, init, hash, path)"
            ;;
    esac
}

# git dispatch repair - rebuild state.json from git refs + trailers
# Scans POC for tagged commits, finds matching ship branches via pattern, builds projections map.
cmd_repair() {
    local source base pattern remote
    source=$(_resolve_config_branch 2>/dev/null || true)
    [[ -n "$source" ]] || die "Cannot resolve source branch. Are you on a dispatch source/target/checkout?"

    base=$(_get_config base)
    pattern=$(_get_config targetpattern)
    [[ -n "$base" && -n "$pattern" ]] || die "Source $source has no dispatch config. Run 'git dispatch init'."

    remote=$(_get_config remote 2>/dev/null)
    [[ -n "$remote" ]] || remote="origin"

    # First pass: discover unique tids (bash 3.2 - no assoc arrays)
    local -a tids_seen=()
    local commit tid
    while IFS= read -r commit; do
        [[ -z "$commit" ]] && continue
        tid=$(_extract_dispatch_tid "$commit")
        [[ -z "$tid" ]] && continue
        [[ "$tid" == "all" ]] && continue
        local found=false
        local t
        for t in "${tids_seen[@]:-}"; do
            [[ "$t" == "$tid" ]] && { found=true; break; }
        done
        $found || tids_seen+=("$tid")
    done < <(git rev-list --reverse "$base..$source" 2>/dev/null)

    # Start with fresh state, fill from refs
    _conflict_clear
    rm -f "$(_state_path)" 2>/dev/null || true
    _state_init "$base" "$pattern" "$source" "$remote"

    # Populate projections from existing target branches
    local ship_branch ship_head
    for tid in "${tids_seen[@]:-}"; do
        [[ -z "$tid" ]] && continue
        ship_branch="${pattern//\{id\}/$tid}"
        ship_head=$(git rev-parse "$ship_branch" 2>/dev/null || echo "")

        # Build commits array for this tid by re-scanning source
        local commits_json="[]"
        local sc t
        while IFS= read -r sc; do
            [[ -z "$sc" ]] && continue
            t=$(_extract_dispatch_tid "$sc")
            if [[ "$t" == "$tid" ]]; then
                commits_json=$(echo "$commits_json" | jq --arg c "$sc" '. + [$c]')
            fi
        done < <(git rev-list --reverse "$base..$source" 2>/dev/null)

        local proj_json
        proj_json=$(jq -n \
            --arg sb "$ship_branch" \
            --arg sh "$ship_head" \
            --argjson commits "$commits_json" \
            '{
                ship_branch: $sb,
                ship_head_local: ($sh | select(length > 0) // null),
                ship_head_remote: ($sh | select(length > 0) // null),
                force_push_required: false,
                poc_commits: $commits,
                poc_commits_patch_ids: [],
                pr_number: null,
                pr_state: null,
                pr_review_count: 0
            }')
        _state_apply ".projections[\"$tid\"] = $proj_json"
    done

    # Last master sha
    local master_sha
    master_sha=$(git rev-parse "$base" 2>/dev/null || echo "")
    if [[ -n "$master_sha" ]]; then
        _state_apply ".last_master_sha = \"$master_sha\""
    fi

    info "Repaired state.json with ${#tids_seen[@]} projection(s) from source $source"
}
