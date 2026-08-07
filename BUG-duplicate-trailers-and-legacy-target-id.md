# BUG: Duplicate trailers and legacy Target-Id not handled

## Problem

### 1. Duplicate Dispatch-Target-Id trailers allowed

The `commit-msg` hook reads only the first `Dispatch-Target-Id` trailer:

```bash
target_id=$(grep "^Dispatch-Target-Id:" "$msg_file" | head -1 | sed 's/^Dispatch-Target-Id:[[:space:]]*//')
```

A commit can have multiple `Dispatch-Target-Id` trailers and the hook won't reject it. The `apply` command also reads only the first value via `git log --format="%(trailers:key=Dispatch-Target-Id,valueonly)"`. This creates ambiguity - the commit appears to belong to one target but could have a second conflicting trailer.

### 2. Duplicate Dispatch-Source-Keep trailers allowed

No validation exists for `Dispatch-Source-Keep`. A commit can have multiple `Dispatch-Source-Keep` trailers with different values (`true` and `false`).

### 3. Legacy Target-Id trailer not rejected

The old trailer format `Target-Id: N` is neither rejected nor stripped. When a commit has both:

```
Target-Id: 9
Dispatch-Target-Id: all
```

The hook passes (it sees a valid `Dispatch-Target-Id`), but the intent is ambiguous. `apply` reads `Dispatch-Target-Id: all` and cherry-picks the commit into every target, even though the original intent was target 9 only.

## Real-world impact

Observed on `meetsone` repo, branch `cyril/feat/purchase-order-transaction-registration/task-11`:

```
chore(openapi): add differFromSource to TransactionStatus enum

Target-Id: 9
Dispatch-Target-Id: all
Dispatch-Source-Keep: true
```

This commit was intended for target 9 only. The `Dispatch-Target-Id: all` caused it to appear in target 11's PR, adding `differFromSource` to the openapi types when target 11 had nothing to do with that change.

## Root cause

The dual-trailer situation likely happened during the transition from `Target-Id` to `Dispatch-Target-Id`. Commits were created with the old format, then edited or rebased with the new format added alongside. The hook didn't catch the conflict.

## Proposed fix

### commit-msg hook changes

1. **Reject multiple Dispatch-Target-Id trailers.** Count occurrences; if > 1, error with message.
2. **Reject multiple Dispatch-Source-Keep trailers.** Same logic.
3. **Silently ignore Target-Id.** Do not flag it, do not validate it. The old syntax is fully deprecated. Only `Dispatch-Target-Id` matters. No warning, no error - just pretend `Target-Id` doesn't exist.

### Validation logic (add to commit-msg hook)

```bash
# Reject duplicate Dispatch-Target-Id
target_count=$(grep -c "^Dispatch-Target-Id:" "$msg_file")
if [[ "$target_count" -gt 1 ]]; then
    echo "Error: Multiple Dispatch-Target-Id trailers found. Only one is allowed per commit."
    exit 1
fi

# Reject duplicate Dispatch-Source-Keep
source_keep_count=$(grep -c "^Dispatch-Source-Keep:" "$msg_file" || true)
if [[ "$source_keep_count" -gt 1 ]]; then
    echo "Error: Multiple Dispatch-Source-Keep trailers found. Only one is allowed per commit."
    exit 1
fi
```

### What NOT to do

- Do NOT warn about `Target-Id`. It's dead. Ignoring it completely avoids confusion about whether it has any effect.
- Do NOT try to merge or reconcile `Target-Id` with `Dispatch-Target-Id`. They are unrelated as far as the tool is concerned.

### apply command changes

No changes needed. `apply` already reads only `Dispatch-Target-Id` via `%(trailers:key=Dispatch-Target-Id,valueonly)`. The `Target-Id` trailer is already invisible to it. The hook fix prevents the duplicate `Dispatch-Target-Id` problem at commit time.

### Optional: apply-time validation

For defense-in-depth, `apply` could also validate that each commit has exactly one `Dispatch-Target-Id` trailer before processing. This catches commits created without the hook (e.g., cherry-picks, rebases, external tools).

```bash
_count=$(git log -1 --format="%(trailers)" "$hash" | grep -c "^Dispatch-Target-Id:" || true)
if [[ "$_count" -gt 1 ]]; then
    die "Commit $(echo "$hash" | cut -c1-8) has $_count Dispatch-Target-Id trailers. Only one is allowed."
fi
```
