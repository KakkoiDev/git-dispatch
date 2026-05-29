#!/bin/bash
# lib/tag.sh - trailer parsing + branch-scoped config helpers
#
# Owns: Dispatch-Target-Id / Dispatch-Source-Keep trailer extraction, source-branch
# resolution, get/set of branch.<source>.dispatch<key> config, sync queue, init guard.

# ---------- source-branch resolution + config ----------

# Resolve the dispatch source branch for config lookups.
# Caches result in DISPATCH_SOURCE for repeated calls.
_resolve_config_branch() {
    [[ -n "${DISPATCH_SOURCE:-}" ]] && { echo "$DISPATCH_SOURCE"; return; }
    local cur
    cur=$(current_branch 2>/dev/null || true)
    [[ -z "$cur" ]] && return 1
    # Current branch has dispatch config (is a source)
    if [[ -n "$(git config "branch.${cur}.dispatchbase" 2>/dev/null || true)" ]]; then
        DISPATCH_SOURCE="$cur"; echo "$cur"; return
    fi
    # Current branch is a target (has dispatchsource)
    local csource
    csource=$(git config "branch.${cur}.dispatchsource" 2>/dev/null || true)
    if [[ -n "$csource" ]]; then
        DISPATCH_SOURCE="$csource"; echo "$csource"; return
    fi
    # Checkout branch
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
# Stored in branch.<source>.dispatchsyncqueue so it survives worktree teardown.
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

# Require dispatch init has been run on the current source branch
_require_init() {
    local base
    base=$(_get_config base)
    [[ -n "$base" ]] || die "Not initialized. Run: git dispatch init"
}

# ---------- trailer extraction ----------

# Extract Dispatch-Target-Id from a commit with fallback for broken trailer blocks.
# git's %(trailers) parser fails when cherry-pick metadata (# Conflicts:, cherry picked from)
# appears after the trailer, breaking the "last paragraph" rule. Falls back to grepping
# the raw commit message for Dispatch-Target-Id: lines.
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
