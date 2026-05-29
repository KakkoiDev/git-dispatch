#!/bin/bash
# lib/migrate.sh - cmd_migrate: one-shot bootstrap of state.json from existing git config + branches
#
# Idempotent. Same as 'state init --from-config' + 'repair' but with --dry-run support.

cmd_migrate() {
    local dry_run=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            -*)        die "Unknown flag: $1" ;;
            *)         die "Unexpected argument: $1" ;;
        esac
    done

    # Inspect existing git config
    local source base pattern remote
    source=$(_resolve_config_branch 2>/dev/null || true)
    [[ -n "$source" ]] || die "Cannot resolve dispatch source branch. Are you on a dispatch source/target/checkout?"

    base=$(_get_config base)
    pattern=$(_get_config targetpattern)
    [[ -n "$base" && -n "$pattern" ]] || die "Source $source has no dispatch config. Run 'git dispatch init' first."

    remote=$(_get_config remote 2>/dev/null)
    [[ -n "$remote" ]] || remote="origin"

    if $dry_run; then
        info "Migrate plan (dry-run):"
        info "  source : $source"
        info "  base   : $base"
        info "  pattern: $pattern"
        info "  remote : $remote"

        # Enumerate tagged commits + their tids
        local commit tid seen=""
        info "  Tagged commits on POC:"
        while IFS= read -r commit; do
            tid=$(_extract_dispatch_tid "$commit")
            [[ -z "$tid" || "$tid" == "all" ]] && continue
            case "|$seen|" in
                *"|$tid|"*) ;;
                *) seen="${seen:+$seen|}$tid"
                   local sb="${pattern//\{id\}/$tid}"
                   local exists="no"
                   git rev-parse --verify "$sb" >/dev/null 2>&1 && exists="yes"
                   info "    PR-$tid -> $sb (branch exists: $exists)"
                   ;;
            esac
        done < <(git rev-list --reverse "$base..$source" 2>/dev/null)

        if _state_exists; then
            info "  state.json: would be REBUILT (already exists)"
        else
            info "  state.json: would be CREATED"
        fi

        info ""
        info "Re-run without --dry-run to apply."
        return 0
    fi

    cmd_repair
}
