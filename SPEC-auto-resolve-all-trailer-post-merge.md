# SPEC: Auto-resolve `Dispatch-Target-Id: all` cherry-pick conflicts after a target merges

## Status

Proposed. No implementation yet. See "Implementation plan" section.

## Companion docs

- Cause analysis: `REPORT-all-trailer-footgun-and-detection.md`
- Agent recipe: `REPORT-post-merge-agent-recipe.md`
- Related pitfalls: `pitfall-cherry-pick-divergence-after-conflict.md`, `pitfall-apply-reset-force-push-trap.md`

## Why this exists

A real session hit the same `all`-trailer cherry-pick conflict on every `apply` after target 1 was merged - twice in one workflow, three times in two workflows. The root cause is documented in the companion reports. This spec defines the **automatic** resolution so the user (or an agent) never has to enter the worktree to run `git checkout --ours` + `cherry-pick --skip` by hand.

The user's pain in two sentences: "Every time I run `apply N` after a target merges, I get the same conflict on the same `all`-tagged commit. I just want it to skip silently because the content is already on master."

## Problem in one paragraph

When a source commit tagged `Dispatch-Target-Id: all` whose content ends up only semantically belonging to one target (or whose content is delivered to base via a squash-merge of that target), `apply N` for the OTHER targets re-cherry-picks the commit. The cherry-pick computes its diff from the commit's parent, which no longer matches the post-merge target tree. The result is a conflict on files the FE/other target shouldn't even own (e.g., a BE test file). The user's only safe move is `--ours` then skip the empty cherry-pick. This loop never self-heals.

## Concrete reproduction

From session `cyril/poc/bulk-transaction-registration-from-the-purchase-order-list`:

- Source commit `a7529a53a0` tagged `Dispatch-Target-Id: all`, touches only `apps/server/src/transactions/transactions-bulk-purchase-order.integration.spec.ts` (a BE test file).
- Target 1 (BE) merged via squash. Master now has the post-rename version of the file.
- `git dispatch apply 2` cherry-picks `a7529a53a0` onto target 2 (FE). Cherry-pick conflicts because the diff is from the pre-rename parent.
- User resolves with `git -C <wt> checkout --ours <file>` + `git add` + `git -C <wt> cherry-pick --skip`, then `git dispatch continue`.
- Three days later, `apply 2` runs again for an unrelated FE change. **Same conflict, same resolution.**

## Goal

A single `git dispatch apply N` invocation should silently skip the `all`-trailer commit when:

1. The commit is tagged `Dispatch-Target-Id: all`, AND
2. The cherry-pick conflicts, AND
3. Resolving the conflict with `--ours` (keep target's existing content) produces a cherry-pick result with **zero net changes** vs the target's HEAD.

Audit log every skip so the user can see what was bypassed. Never silently drop a commit that produces real content on the target.

## Non-goals

- Catching mis-tagged `all` commits at commit time (separate concern; covered by the proposed `git dispatch lint` ownership-config feature).
- Auto-skipping numeric-tagged commits (`Dispatch-Target-Id: 2`) - those are direct, intentional, and should always conflict loudly when they conflict.
- Replacing `Dispatch-Source-Keep: true`. That trailer is opt-in per-commit and uses `--theirs`. This spec is opt-out per-apply and uses `--ours` for `all`-tagged-only.

## Algorithm

Pseudocode for the `apply N` cherry-pick loop, with the new auto-resolution path:

```
for src_commit in source_commits_to_apply:
    target_id = parse_dispatch_target_id(src_commit)

    if target_id != N and target_id != "all":
        continue  # skip - belongs to a different target

    try:
        git cherry-pick --no-commit src_commit
        if no_conflict:
            git cherry-pick --continue
            continue

    except cherry_pick_conflict:
        if target_id == "all":
            # NEW: try auto-resolve
            if auto_resolve_all_conflict(src_commit):
                continue  # skipped or committed via auto-resolve

        # Existing behavior: abort and prompt user
        abort_apply()
        raise


def auto_resolve_all_conflict(src_commit):
    """
    Returns True if the conflict was auto-handled (commit either applied or skipped).
    Returns False if the user must intervene.
    """

    conflicted_files = git_status_porcelain_uu_files()
    files_in_commit = git_show_files_changed(src_commit)

    # Safety check: only auto-resolve if all conflicts are in files this commit touched.
    # If conflicts spread to other files, something else is wrong - bail to user.
    if not set(conflicted_files).issubset(set(files_in_commit)):
        return False

    # Resolve all conflicts with --ours (keep target's content).
    for file in conflicted_files:
        git_checkout_ours(file)
        git_add(file)

    # Try to continue the cherry-pick.
    diff_against_head = git_diff_cached_against_head()

    if diff_against_head_is_empty:
        # Target already has equivalent content; skip the commit.
        git_cherry_pick_skip()
        log_audit("auto-skipped", src_commit, conflicted_files,
                  reason="all-trailer + empty after --ours")
        return True

    # --ours produced a meaningful change; commit it normally.
    git_cherry_pick_continue()
    log_audit("auto-resolved", src_commit, conflicted_files,
              reason="all-trailer + non-empty after --ours")
    return True
```

### Why this is correct

The two signals together (conflict + empty after `--ours`) are the precise mathematical statement of "the target already has the equivalent content". One alone is not enough:

- Conflict alone: could be a real semantic conflict the user must resolve.
- Empty after `--ours` alone: would also catch numeric-tagged commits that drift, hiding real bugs. Restricting to `all`-tagged keeps the surface narrow.

The conjunction is rare in normal apply flows and overwhelmingly indicates the squash-merge scenario.

## Audit log

Every auto-skip and auto-resolve writes a line to `.git/dispatch-audit.log` (gitignored, per-repo) with this format:

```
<ISO-8601 UTC>  <action>  <commit-sha>  target=<N>  reason=<text>  files=<comma-separated>
```

Examples:

```
2026-04-27T15:30:42Z  auto-skipped  a7529a53a0  target=2  reason=all-trailer + empty after --ours  files=apps/server/src/transactions/transactions-bulk-purchase-order.integration.spec.ts
2026-04-27T15:31:01Z  auto-resolved 53f7a997a5  target=3  reason=all-trailer + non-empty after --ours  files=package.json,pnpm-lock.yaml
```

`git dispatch status` gains a footer line summarising the audit log:

```
Auto-resolved this session: 1 skip, 0 resolves. See .git/dispatch-audit.log
```

The audit log is append-only. Truncation policy: keep the last 500 lines on `apply` start (older entries dropped). User can `cat` it any time.

## Configuration

A new config key controls the behavior:

```
git config branch.<source>.dispatchautoresolveall <mode>
```

Where `<mode>` is one of:

| Mode | Behavior |
|------|----------|
| `skip` (default) | Auto-skip when empty after `--ours`; auto-resolve when non-empty. Audit log records both. |
| `prompt` | Detect the condition but pause and ask the user (one prompt per apply, not per commit). |
| `off` | Disable entirely; restore current behavior (manual `--ours` + `cherry-pick --skip`). |

The default (`skip`) is intentionally on for new repos because the failure mode is identical to the manual fix and saves the user a round trip into the worktree. Users who want stricter behavior can flip to `prompt` or `off`.

A `--strict` flag on `apply` overrides config to `off` for one invocation.

## Edge cases

| Case | Behavior |
|------|----------|
| Conflict in a file the source commit didn't touch | Bail to user. The conflict is real and not the `all`-trailer footgun. |
| Source commit has `Dispatch-Source-Keep: true` AND is tagged `all` | Source-Keep wins (uses `--theirs`). Auto-resolve doesn't fire. |
| Source commit tagged `all` produces non-empty diff after `--ours` | Auto-commit it. Logged as `auto-resolved`. |
| Cherry-pick conflicts but resolution is partial (some files auto-resolvable, others not) | Bail to user with a hint: "Some files were `all`-trailer + empty after `--ours` but file X has a real conflict. Resolve X manually then `git dispatch continue`." |
| User has unstaged changes in the worktree before apply starts | Pre-existing dispatch behavior: refuse to start. Unaffected by this spec. |
| `--dry-run` apply | Detect candidate auto-resolves and print "would auto-skip a7529a53a0" without modifying state. |

## Testing strategy

Three test categories.

### Unit-level (algorithm)

Test `auto_resolve_all_conflict()` in isolation with a mocked git wrapper:

- All conflicts in commit's files + empty after `--ours` -> returns True, calls `cherry-pick --skip`, logs `auto-skipped`.
- All conflicts in commit's files + non-empty after `--ours` -> returns True, calls `cherry-pick --continue`, logs `auto-resolved`.
- Conflict in non-commit file -> returns False, no log.
- Source-Keep + all-trailer commit -> Source-Keep path runs first, auto-resolve doesn't fire.

### Integration-level (real git repo fixture)

Create a fixture mirroring the bulk-transaction session:

- Repo with one source branch, two target branches.
- Source has commit `X` tagged `Dispatch-Target-Id: all` that renames a variable in a BE test file.
- Source has commit `Y` after `X` that further modifies the BE test file.
- Target 1 receives `X` and `Y`, gets squash-merged into base.
- Target 2 has only an unrelated change.
- New source commit `Z` tagged `Dispatch-Target-Id: 2`.
- Run `git dispatch apply 2`.
- Assert: `Z` lands on target 2. `X` is auto-skipped. Audit log has one line. Target 2 has no spurious BE test file changes.

### Property-level

Random fuzz: generate commits with varying trailer combinations, target merge orderings, and content overlaps. Assert that for any sequence, no commit is silently dropped that produces a non-empty diff against target HEAD when applied via `--ours`.

## Implementation plan

Five steps, each independently mergeable.

1. **Add audit log infrastructure.** New `log_audit()` helper, `.git/dispatch-audit.log` write, status footer, truncation policy. No behavior change yet. (~50 lines in `git-dispatch.sh`.)

2. **Add `auto_resolve_all_conflict()` helper as a no-op.** Plumb into the cherry-pick loop behind a hardcoded `mode == "off"` config check. Tests for the helper run in isolation. (~80 lines.)

3. **Wire the config key + flag.** `git config branch.<source>.dispatchautoresolveall` reads, `--strict` flag overrides, default `skip`. (~20 lines.)

4. **Activate for `skip` mode.** Default behavior changes; users can opt out. Document in README and AGENTS.md. (~10 lines + docs.)

5. **Add `prompt` mode** as a safer default for cautious users. Single prompt per apply listing all candidate auto-resolves; user accepts or cancels en bloc. (~30 lines.)

After step 4, this spec's user story is satisfied. Step 5 is a polish iteration.

## Backward compatibility

The default change in step 4 is a soft semantic change: behavior gets STRICTLY LESS painful. Apply runs that would have aborted with a conflict now succeed silently with an audit-log entry. Users who relied on the abort to manually inspect can flip the config to `prompt` or `off`.

For agents (Claude / Codex etc.) the new default is unambiguously better - one fewer manual step to understand from a stuck cherry-pick.

The `dispatchautoresolveall` config is per-source-branch (matching dispatch's existing config scoping), so different worktrees / branches can have different settings.

## Open questions

1. Should `--strict` mode also retroactively rewrite past auto-resolutions on the next `apply`? Probably no - they're already on the target branch.
2. Should the audit log be visible in `git dispatch status` always, or only when there's been activity? Default to "only when non-empty" to avoid clutter.
3. Should we offer a `git dispatch audit` command to read/filter the audit log nicely? Nice-to-have, not blocking.

## Success metric

After implementation, an agent (or human) running `git dispatch apply N` after a target merge should see:

```
$ git dispatch apply 2
Picking 4 commit(s) to target 2: cyril/dispatch/bulk-transaction-registration/2
  auto-skipped a7529a53a0 ([NONE-30035] style: format test file...)
  picked      23b067593c ([NONE-30048] fix: align bulk modal hook...)
  picked      8d2223af0c ([NONE-30048] feat: align bulk modal layout...)
  picked      3aba06a39b ([NONE-30048] fix: prevent double-submit...)
Auto-resolved this session: 1 skip, 0 resolves. See .git/dispatch-audit.log
```

No worktree path printed. No `--continue` instructions. No conflict markers shown. Just a clean, audit-logged completion.
