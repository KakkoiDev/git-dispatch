# Pitfall: Cherry-pick divergence after manual conflict resolution

## Scenario

1. Task-8 has 4 commits ahead of source (per `git dispatch status`)
2. User runs `git dispatch cherry-pick --from 8 --to source`
3. First commit cherry-picks successfully and is committed to source
4. Second commit hits a merge conflict
5. Dispatch aborts (no `--resolve` flag) but the first commit remains on source
6. User manually resolves: cherry-picks remaining commits one by one, resolving conflicts, skipping empties
7. After resolution, `git dispatch status` shows task-8 as "2 behind source, 3 ahead"

## Why divergence happens

The cherry-picked commits on source have different content than the originals on task-8 because:
- Conflict resolution changes patch content (different context lines, different merge choices)
- Some commits become empty after resolution and are skipped
- `git cherry` (used by dispatch for sync detection) compares patch-ids - if the patch content differs even slightly, it sees the commits as different

## The dangerous part

`git dispatch status` shows "N behind, M ahead" but gives no indication whether the divergence is:
- **Cosmetic**: same effective content, just different SHAs from conflict resolution
- **Real**: source is actually missing changes that exist on the target

In this real case, the status showed "2 behind source, 3 ahead" but source was genuinely missing code changes (a perf optimization that replaced `getTransactionStatus()` with a `Set`-based lookup). The user had no way to know this from `status` alone.

## Why changes were lost

The cherry-pick batch from task-8 contained progressive refactoring:
1. Commit A: added `getTransactionStatus()` helper (intermediate step)
2. Commit B: updated openapi types (conflicted on source)
3. Commit C: added tests
4. Commit D: replaced `getTransactionStatus()` with `Set`-based lookup (final optimization)

The dispatch cherry-picked commit A successfully, then failed on B. The user manually resolved B, C, D but the conflict resolution on B/D didn't carry through the service file changes from commit D. The result: source has the intermediate version (commit A) but not the final optimization (commit D).

## Proposed improvements

### 1. `git dispatch status` should detect and flag divergence type

When a target shows "N behind, M ahead", status should run a content-level diff (not just commit-level) to distinguish:

```
  8   task-8   2 behind, 3 ahead (DIVERGED - files differ)
  8   task-8   2 behind, 3 ahead (cosmetic - no file diff)
```

Implementation: `git diff source..target -- <files touched by Target-Id=8 commits>`. If the diff is empty, it's cosmetic. If non-empty, flag it.

### 2. Add `git dispatch diff --target <id>` command

Show the actual file-level diff between source and a target, filtered to files relevant to that target's commits:

```
$ git dispatch diff --target 8
Files diverged between source and target 8:
  apps/server/src/purchase-orders/purchase-orders.service.ts

diff --git a/...service.ts b/...service.ts
- old getTransactionStatus() call
+ new Set-based lookup
```

### 3. After manual conflict resolution, suggest verification

When the user completes a conflicted cherry-pick (detected by status changing from "N ahead" to "N behind, M ahead"), dispatch should suggest:

```
Warning: target 8 diverged after cherry-pick resolution.
Run: git dispatch diff --target 8
to verify all changes transferred correctly.
```

### 4. Cherry-pick abort should roll back ALL commits in the batch

Currently, when a cherry-pick fails mid-batch:
- Previously successful commits in the batch remain
- Only the failing commit is aborted

This creates partial state. Options:
- **Option A**: Record the pre-batch HEAD, roll back to it on failure (clean but loses successful picks)
- **Option B**: Keep current behavior (partial progress preserved) but clearly report what was applied and what wasn't

Option B is probably better - rolling back successful work is wasteful. But the reporting must be clear:

```
Cherry-pick into source: 1/4 applied, conflict on commit 2/4.
  Applied:  7ae68f83d9 feat(purchase-orders): add transactionStatus to findAll response
  CONFLICT: c6789599e0 chore(openapi): update generated api types
  Pending:  241c33c065 fix(purchase-orders): add transaction mock...
  Pending:  12638ff253 fix(purchase-orders): add JSDoc, remove unused...
```

## False positive: DIVERGED from generated file drift (independent mode)

After all real code changes from task-8 were confirmed on source, `git dispatch status` still showed DIVERGED. The remaining diff was only in generated files:

```
apps/server/openapi.gen.d.ts   - source has "FORBIDDEN_FIELD_FOR_INSERT" (from other tasks)
apps/server/swagger.json        - source has "differFromSource" enum value (from other tasks)
apps/web/src/store/api/gen/purchase-order.ts - source has 3-value TransactionStatus (from other tasks)
```

In independent mode, targets branch from master, not from source. They never contain code from other tasks. Running `pnpm openapi` on task-8 won't fix it because task-8 doesn't have the server code that produces those types.

This is expected and permanent for independent mode. The DIVERGED flag is a false positive.

### Proposed fix: exclude generated files from divergence check

The divergence check should either:

**Option A**: Ignore generated files entirely (configurable pattern list, e.g. `*.gen.d.ts`, `swagger.json`, `**/gen/*.ts`)

**Option B**: Separate divergence into categories:
```
  8   task-8   3 behind, 2 ahead (generated files differ)
  8   task-8   3 behind, 2 ahead (DIVERGED - source files differ)
  8   task-8   3 behind, 2 ahead (cosmetic - no file diff)
```

**Option C**: Only check files touched by that target's commits (files modified in commits with `Target-Id=8`), not all files that differ between the branches. In independent mode, many files will differ simply because source has other tasks' changes.

Option C is the most correct - it answers "did the target's own changes make it to source?" rather than "are these branches identical?", which is never true in independent mode.

## How to verify after manual resolution

```bash
# Check if source and target have the same content for relevant files
git diff source..target -- <files>

# Or use git cherry to find unmatched commits
git cherry -v source target
# + lines = commits on target not semantically in source (potential missing changes)
# - lines = commits already matched
```
