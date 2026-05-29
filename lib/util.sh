#!/bin/bash
# lib/util.sh - logging, color codes, prompt helpers
#
# Sourced by git-dispatch.sh and bin/git-dispatch. No side effects on source.

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging helpers
die() { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }
info() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }

# Spinner for long-running operations (stderr, so stdout stays clean for piping)
_SPINNER_PID=""
_spinner_start() {
    local msg="${1:-Processing...}"
    [[ ! -t 2 ]] && return 0
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

# Confirmation prompt. Returns 0 on yes, 1 on no.
DISPATCH_YES=${DISPATCH_YES:-false}
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

# Input prompt with optional default. Dies in non-interactive without default.
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

# ---------- branch + worktree helpers ----------

current_branch() { git symbolic-ref --short HEAD 2>/dev/null; }

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

# Worktree lifecycle globals (set by _enter_branch, cleared by _leave_branch)
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

# ---------- process lock ----------
# Prevents concurrent dispatch operations. Reentrant within the same process.

DISPATCH_LOCKFILE=""

_acquire_lock() {
    # Reentrant: skip if we already hold the lock
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

# Emit deprecation notice to stderr. Old command still runs.
# Usage: warn_deprecated <old-name> <replacement>
warn_deprecated() {
    local old="$1" new="$2"
    if [[ -t 2 ]]; then
        echo -e "${YELLOW}deprecated:${NC} 'git dispatch $old' will be removed. Use 'git dispatch $new'. See docs/migrate.md" >&2
    fi
}
