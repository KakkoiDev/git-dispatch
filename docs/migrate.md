# Migration: old git-dispatch -> new redesign

## Overview

The redesign introduces `.dispatch/state.json` as authoritative state and renames commands for clearer semantics. Old commands still work in this release with deprecation warnings; they will be removed in a future release.

## One-time bootstrap

On any existing dispatch-configured branch:

```
git dispatch migrate --dry-run    # see what would be migrated
git dispatch migrate              # write .dispatch/state.json
```

The migrate command:
- Reads existing `branch.<source>.dispatch*` git config keys
- Scans POC for `Dispatch-Target-Id` trailers
- Detects matching target branches via `--target-pattern`
- Populates `.dispatch/state.json`
- Safe to re-run (idempotent)

## Command mapping

| Old command | New command | Notes |
|---|---|---|
| `git dispatch apply` | `git dispatch project` | state.json-driven, incremental by default |
| `git dispatch apply --base` | `git dispatch update-base` + `git dispatch project` | split into two explicit steps |
| `git dispatch apply reset N` | `git dispatch project N --force` | scoped, no cascade to other PRs |
| `git dispatch apply reset all` | `git dispatch project --force` | applies to all PRs |
| `git dispatch sync` | `git dispatch update-base` + `git dispatch project` | merge into POC + re-derive ships |
| `git dispatch checkout N` | `git dispatch combined --include PR-1,...,PR-N` | arbitrary subset, not just 1..N range |
| `git dispatch checkout source` | (just `git checkout <poc>`) | no longer needs tool support |
| `git dispatch checkout clear` | `git dispatch combined --dissolve [<name>]` | renamed |
| `git dispatch checkin` | `git dispatch absorb` | watermark tracked in state.json |
| `git dispatch restack` | `git dispatch clean` + `git dispatch project` | recomposed |
| `git dispatch retarget --commit X` | `git dispatch untag --commit X` + `git dispatch tag PR-Y --commit X` | two-step explicit (planned) |
| `git dispatch retarget --target X` | `git dispatch retarget --target X` | unchanged (tranche-move) |
| `git dispatch delete N` | `git dispatch close PR-N` | PR-aware close + delete (planned) |
| `git dispatch delete --prune` | `git dispatch clean` | recomposed |
| `git dispatch reset` | `git dispatch dissolve` (planned) | renamed |
| `git dispatch status` | `git dispatch status [--json]` | gains structured output (planned) |
| `git dispatch push N` | `git dispatch push PR-N` | state.json-aware (planned) |
| `git dispatch init` | `git dispatch init` | unchanged; also seeds state.json |
| `git dispatch commit --target N` | `git dispatch commit --tag PR-N` | `--target` accepted as synonym |
| `--target all` | (removed) | tag commits individually |

## State files

| File | Purpose |
|---|---|
| `.dispatch/state.json` | authoritative state (config, projections, watermarks) |
| `.dispatch/state.json.bak` | backup written before every mutation |
| `.dispatch/conflict.json` | present when a command is paused for conflict resolution |
| `.dispatch/lock` | process lock |

## Inspection

```
git dispatch state show       # pretty-print state.json
git dispatch state show --json # raw JSON
git dispatch state hash       # stable hash for idempotency tests
git dispatch state path       # absolute path to state.json
git dispatch repair           # rebuild state.json from git refs + trailers
```

## Backward compat

- Existing `Dispatch-Target-Id: <numeric>` trailers continue working
- Existing `branch.<source>.dispatch*` git config keys still read (one release cycle)
- `--target` accepted as synonym for `--tag` (one release cycle)
- All old commands emit deprecation warning on stderr but continue functioning
