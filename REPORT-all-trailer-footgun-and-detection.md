# REPORT: `Dispatch-Target-Id: all` footgun - detection and mitigation

## Summary

A source commit tagged `Dispatch-Target-Id: all` whose content only semantically belongs to ONE target silently breaks incremental `apply` after that one target is merged. The other targets get stuck unable to receive new commits without a full `apply reset`, because the `all`-tagged commit keeps conflict-cherry-picking against content those targets already have (via the squash-merged base).

This is diagnosable but only after it bites. There is today no lint, dry-run warning, or auto-skip that catches it.

## Observed behavior

Session: target 1 (BE) merged via squash. Target 2 (FE, WIP) still open. User commits a trivial 3-line FE config change on source with `--target 2`. Runs `git dispatch apply 2`.

```
$ git dispatch apply 2
<<<<<<< HEAD
    const purchaseOrder = await createPurchaseOrderWithLines(user, job.id)
=======
    const ids = Array.from(
      { length: 1001 },
      (_, i) => `fake-purchase-order-id-${i}`,
    )
>>>>>>> a7529a53a0 ([NONE-30035] style: format test file after variable renames)

Aborted. Re-run with --resolve to keep conflict active for manual resolution.
```

The conflict is on `apps/server/src/transactions/transactions-bulk-purchase-order.integration.spec.ts` - a BE test file that has nothing to do with the FE change the user was trying to apply.

### Root cause chain

1. Commit `a7529a53a0` has `Dispatch-Target-Id: all` despite being pure BE test-file formatting (should have been `1`).
2. The commit uses OLD variable names (`ids` array). A later commit renamed those variables (`purchaseOrder`).
3. Target 1 merged as a squash commit - master now has only the POST-RENAME version.
4. Target 2 synced from master - its working tree has the post-rename version.
5. `apply 2` walks source commits, sees `a7529a53a0` tagged `all`, tries to cherry-pick.
6. The cherry-pick's diff is against OLD variable names; target 2's tree has NEW variable names -> conflict.
7. The user has no hint that this conflict is caused by a mis-tagged commit from a DIFFERENT target's work.

### Why it survives sync

`sync` merges base into target via `git merge`. `git merge` uses recursive 3-way merging and is tolerant of "same content, different SHAs." So sync completes cleanly.

`apply` cherry-picks source commits one at a time. Cherry-pick is less forgiving - it reconstructs the diff from the commit's parent, which doesn't match target 2's current state, hence the conflict.

## Proposed fixes (tool)

### Fix 1: patch-id-based auto-skip during `apply` (recommended, medium effort)

Before cherry-picking any source commit onto a target, compute its `git patch-id`. Check if the target's reachable history already contains a commit with the same patch-id. If yes, skip silently:

```bash
incoming_pid=$(git show "$src_commit" | git patch-id --stable | awk '{print $1}')
# cheap check: limit to recent target history
if git log --format='%H' "$target" --since="6 months ago" \
   | while read h; do git show "$h" | git patch-id --stable; done \
   | grep -q "^$incoming_pid "; then
    info "Skipping $src_commit (patch-id already present on $target)"
    continue
fi
```

Optimization: cache patch-ids per target in `.git/dispatch-patch-ids-<target>` invalidated on target HEAD change.

Trade-off: squash-merges have DIFFERENT patch-ids than the individual commits they bundle, so patch-id alone doesn't catch squash-merged content. To cover that case, also check `git cherry` or `git log --cherry-mark` for commits equivalent up to merge resolution.

### Fix 2: track "base-merged" target-ids and auto-skip (lightweight, catches this case)

When a target is marked `merged` in status, record the base SHA at merge time. During apply, any `all` commit whose timestamp / topological position is reachable from that base SHA is skipped for other targets automatically:

```
[branch.cyril/dispatch/.../1]
    dispatchmergedbase = <master SHA at merge time>
```

Apply to target 2 consults the merged-base of every OTHER merged target; if the `all` commit's content is covered by any of those merged bases, skip.

### Fix 3: strict mode - no implicit `all` defaults

Today `all` requires explicit opt-in, but commits without `--target` can silently inherit a default in some paths. Harden `git dispatch commit`:

- Always require `--target` (error if missing, no default).
- Warn when `--target all` is used on a commit touching files that look target-specific (based on `.git-dispatch.yaml` ownership, see Detection).

## Detection (ranked by effort)

### Detection 1: file-ownership config + lint command (high value, medium effort)

Add `.git-dispatch.yaml` at repo root:

```yaml
target-ownership:
  1: apps/server/**
  2: apps/web/**
  3: mobile/**
shared:
  - docs/**
  - .github/**
  - package.json
```

New command `git dispatch lint` scans source commits and reports:

```
$ git dispatch lint
a7529a53a0 [all] touches only apps/server/** - owned by target 1
           suggested: git dispatch retarget --commit a7529a53a0 --to-target 1
```

Heuristic: if an `all` commit's changed files all match one target's ownership globs AND don't match any `shared:` glob, flag it.

This would have caught `a7529a53a0` before it caused any apply conflict.

### Detection 2: dry-run preview that highlights `all` commits (low effort, catches post-hoc)

Enhance `git dispatch apply <N> --dry-run` output:

```
$ git dispatch apply 2 --dry-run
Would cherry-pick:
  f0ed1d6517 [target:2] FE config
  a7529a53a0 [target:all, 1 BE file]  <-- warning: only touches BE paths
Cherry-pick a7529a53a0 onto target 2? (expect content already in base)
```

Just making `all` commits visually distinct in dry-run output pushes the user to question whether they really want this.

### Detection 3: post-squash-merge sanity check (light, catches regression)

When `git dispatch status` detects a target as newly `merged`:

```
$ git dispatch status
  1  ...  merged (base @ abc123)
  WARNING: 3 source commits tagged `all` have content that now lives on base.
  Run `git dispatch lint` for details.
```

## Skill documentation changes

Current skill docs mention `all` as: `| `all`: commit included in every target during apply. |`

Augment with:

```markdown
### When to use `Dispatch-Target-Id: all`

USE for:
- Shared config changes (`.github/`, root `package.json`, `CLAUDE.md`)
- Utilities genuinely consumed by every target's code
- Generated files (OpenAPI clients, protobuf) that all targets rebuild against

DO NOT USE for:
- Formatting/lint fixes to one target's files (tag the target explicitly)
- Test-file changes for tests that only exist in one target
- "It felt easier" - if unsure, tag the specific target

**Why it matters:** Once any target in the stack is squash-merged to base, `all`-tagged
commits that semantically belonged to that target start conflicting when `apply` tries
to re-cherry-pick them onto the remaining targets. Remaining targets now have the
post-merge base content, which doesn't diff-match the original commit. Result: forced
`apply reset <N>` (history rewrite + force-push).

**Recovery:** `git dispatch retarget --commit <hash> --to-target <N>` rewrites the
trailer. Safe while the target PR is still open; requires `--force` push to update a
target that was already pushed.
```

## Priority ranking

| Fix | Value | Effort | Prevents this class entirely? |
|-----|-------|--------|------------------------------|
| Detection 1 (ownership config + lint) | High | Medium | Yes, at commit time |
| Fix 1 (patch-id auto-skip) | High | Medium | No, but makes it harmless |
| Detection 2 (dry-run highlight) | Medium | Low | Only if user reads output |
| Fix 2 (track merged-base per target) | High | Medium | Covers squash-merge case |
| Skill docs update | Medium | Trivial | Reduces incidence, not 100% |
| Fix 3 (strict mode) | Low | Low | Hardens inputs, doesn't fix legacy |

**Recommended combo:** Detection 1 (catches at commit time) + Fix 1 or 2 (auto-heals when the mis-tag already exists). Together these make `all` safe: bad tags get flagged up-front, and if one slips through, apply silently does the right thing instead of conflicting.

## Session context

Environment: macOS, git-dispatch from `~/Code/git-dispatch/`, Claude Code Opus 4.7.
Date: 2026-04-23.
Project: `bulk-transaction-registration-from-the-purchase-order-list`.
Stack: target 1 (BE, merged as PR #21719), target 2 (FE, WIP), target 3 (WIP).
Mis-tagged commit: `a7529a53a0` ([NONE-30035] style: format test file after variable renames) tagged `all` instead of `1`.
Symptom: `git dispatch apply 2` of an unrelated 3-line FE config commit failed with a BE-test-file conflict.
Workaround used: direct `git cherry-pick` onto target 2 (bypassed dispatch's apply path).
Better fix (retroactive): `git dispatch retarget --commit a7529a53a0 --to-target 1 --apply` to correct the trailer.

## Related

- `BUG-apply-silent-noop-and-push-circular-error.md` - adjacent apply-path issue
- `pitfall-apply-reset-force-push-trap.md` - downstream effect (user forced into reset + force-push when apply breaks)
- `BUG-false-diverged-after-fresh-apply.md` - patch-id detection already exists for divergence, could be reused here
- `REPORT-sync-conflict-ergonomics-for-claude.md` - companion agent-UX report on sync conflicts
