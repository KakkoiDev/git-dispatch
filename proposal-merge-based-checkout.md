# Proposal: Merge-based checkout (replaces cherry-pick replay)

## Problem

`git dispatch checkout N` builds an integration branch by cherry-picking source commits onto base. When source commits were authored against an older base, this produces conflicts even when the individual target branches are perfectly clean.

This is because cherry-picking replays the original patch against a different context. If base changed the same files, the patch doesn't apply.

The irony: `apply` already built correct target branches. Checkout then ignores those targets and replays source commits from scratch, hitting conflicts that apply already resolved.

## Current behavior

```
checkout N:
  1. Create branch from origin/master
  2. Cherry-pick source commits (filtered by target IDs 1..N) onto master
  3. Conflicts if source commits are incompatible with current master
```

## Proposed behavior

```
checkout N:
  1. Create branch from origin/master
  2. Merge target-1 branch into it
  3. Merge target-2 branch into it
  4. ...
  5. Merge target-N branch into it
```

## Why this works

- Target branches already have the correct content (built by `apply`)
- Merging targets is additive - no replay of old patches against a new base
- Conflicts only happen when two targets modify the same file (real conflicts, not artifacts)
- Combined with `apply --base` (merge master into targets), this eliminates all base-incompatibility issues

## Combined workflow

With both `apply --base` (already implemented) and merge-based checkout:

```bash
# Master advances
git dispatch apply --base          # merges master into source + all targets
git dispatch checkout 11           # merges target branches 8, 9, 11 together
pnpm test                          # integration test
git dispatch checkout source       # back to source
```

No force push. No cherry-pick conflicts. No divergence.

## Properties

| Property | Cherry-pick checkout (current) | Merge-based checkout (proposed) |
|----------|-------------------------------|--------------------------------|
| Uses target branches | No (replays source commits) | Yes (merges targets) |
| Conflict when base advances | Yes (patch context mismatch) | No (targets already resolved) |
| Force push needed | N/A | N/A |
| Commit history on checkout | Individual source commits | Merge commits from each target |
| Inter-target conflicts | Hidden (sequential cherry-pick) | Explicit (merge conflict) |
| Requires apply first | No | Yes (targets must exist) |

## Edge cases

### Target not yet created
If `checkout 5` is requested but target 3 doesn't exist yet, either:
- Error: "Target 3 not created. Run git dispatch apply first."
- Auto-create: run apply for missing targets, then merge

Recommend: error with clear message. Keep checkout simple.

### "all" tagged commits
Currently cherry-picked into every checkout. With merge-based checkout, "all" commits are already on every target branch (applied by `apply`). No special handling needed.

### Checkout + fix + checkin
The checkin flow (cherry-pick fixes from checkout back to source) should work the same. Commits made on the checkout branch get picked back to source with their Dispatch-Target-Id trailers. No change needed.

### Merge conflicts between targets
Two targets modifying the same file will conflict during merge. This is a real conflict that needs resolution - not an artifact. The user should resolve it on the checkout branch.

This is actually better than current behavior: currently, inter-target conflicts are silently resolved by cherry-pick order (last write wins). With merges, they're surfaced explicitly.

## Implementation sketch

```bash
checkout_merge() {
  local max_id="$1"
  local base=$(git config branch.$source.dispatchbase)
  local checkout_branch="dispatch-checkout/$source/$max_id"

  git checkout -b "$checkout_branch" "$base"

  # Get all target IDs <= max_id, sorted
  for target_id in $(get_target_ids_up_to "$max_id"); do
    local target_branch=$(resolve_target_branch "$target_id")

    if ! git branch --list "$target_branch" | grep -q .; then
      echo "Error: Target $target_id not created. Run: git dispatch apply"
      git checkout "$source"
      git branch -D "$checkout_branch"
      exit 1
    fi

    if ! git merge "$target_branch" --no-edit; then
      echo "Conflict merging target $target_id into checkout"
      echo "Resolve and run: git dispatch checkout --continue"
      exit 1
    fi
  done

  echo "Checkout ready: $checkout_branch"
}
```

## Relationship to other proposals

- **proposal-merge-base-into-targets.md**: `apply --base` merges master into existing targets. This is the prerequisite - targets must have current master code for merge-based checkout to produce correct results.
- **BUG-apply-reset-cascades-to-other-targets.md**: Separate issue, but also relevant - apply reset should be scoped to one target.
- **SESSION-2026-03-18-issues-and-proposals.md**: Full session context documenting the pain points that led to this proposal.

## Migration

No breaking changes. The checkout command signature stays the same. Internal implementation switches from cherry-pick to merge. Old checkout branches should be cleared first (`checkout clear`).

Optional: `--cherry-pick` flag to preserve old behavior for cases where merge-based checkout is not desired.
