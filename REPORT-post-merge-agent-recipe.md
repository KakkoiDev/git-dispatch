# REPORT: Agent recipe for "a target just merged - now what?"

## Companion to

This report extends the existing analysis in:
- `REPORT-all-trailer-footgun-and-detection.md` (root-cause + tooling fixes for the `all`-trailer post-merge conflict)
- `restack-after-merge.md` (manual rebase fallback)
- `pitfall-apply-reset-force-push-trap.md` (why `apply reset` should be a last resort)

That report explains WHY the conflict happens and HOW to fix the tool. This report covers a different gap: an **autonomous agent (Claude / Codex) using git-dispatch via the skill prompt has no canonical recipe for "target N just merged, I need to keep working on target N+1"**. The skill prompt lists commands; it does not sequence them for this specific transition.

## Observed agent-UX gap

Session: T-1 (BE) merged via squash. T-2 (FE) still open and "in sync". User asks the agent to make additional FE quality-pass changes on T-2.

What the skill prompt told the agent:
- Each command's individual purpose (apply, sync, checkout, lint, retarget).
- The pitfalls section lists "Source behind base -> sync" and "Apply 2 conflicts on diverged target -> apply reset 2".
- The when-to-use `all` section explains the footgun and points at `retarget` for recovery.

What the skill prompt did NOT tell the agent:
1. **The canonical sequence after a target merges.** Sync first or checkout first? Does sync touch the merged target (no - it skips merged ones, but the agent has to infer this from "skips merged targets" in one bullet).
2. **The lint-before-apply rule when status warns about `all` commits.** `git dispatch status` now emits the banner "N source commit(s) tagged 'all' may now live on base. Run 'git dispatch lint' to check for mis-tagged commits." Good. But "may now live on base" doesn't tell an agent the consequence of skipping lint: a future `apply` on a non-merged target will hit a content conflict. The agent has to remember the related report's root cause to make the connection.
3. **The "fast-forward vs force-push" decision rule.** The pitfall doc explains the trap, but the skill prompt doesn't surface a one-line heuristic: "use `apply N` to preserve fast-forward push; only use `apply reset N` if `apply N` actually conflicts and retarget can't fix it."
4. **`checkout N` semantics for a non-trivial change.** The skill prompt says "checkout N is the integration view." It doesn't explain that *editing while on a checkout branch and using `dispatch commit` auto-tags the target* - which is the cleanest path to making multiple focused commits without manually managing trailers. Agents default to making one big commit on source, which loses commit granularity.

## Canonical post-merge recipe (proposed addition to skill docs)

When `git dispatch status` reports a target as `merged`, the canonical sequence to keep working on the next target is:

```
# 1. Inspect: confirm what's merged, what's behind, what's "all"-tagged risk.
git dispatch status

# 2. Pull base into source + remaining targets. Sync skips merged targets; that's expected.
git dispatch sync

# 3. Address the post-merge `all` warning, if any. Retarget mis-tagged commits BEFORE working.
git dispatch lint
# For each flagged commit:
git dispatch retarget --commit <hash> --to-target <correct-id> --apply

# 4. Open the integration branch for the target you're working on. Edits go here, not on source.
git dispatch checkout <N>

# 5. Make changes. Commit each logical change with `dispatch commit` - target N is auto-detected.
git dispatch commit "fix: ..."
git dispatch commit "test: ..."

# 6. Verify on the checkout branch (run tests, type-check, lint, dev server).

# 7. Sync edits back to source, return to source, propagate to target N incrementally.
git dispatch checkin
git dispatch checkout source
git dispatch apply <N>     # incremental - preserves fast-forward push
git dispatch status        # confirm "in sync"
git dispatch checkout clear

# 8. Push when ready (user's call).
git dispatch push <N>
```

## Decision rule: `apply N` vs `apply reset N`

Add to the skill prompt as a single-line heuristic next to the existing `apply` table:

> **Default to `apply N`** when target N is `in sync` or only behind source. It produces fast-forward-friendly commits.
> **Use `apply reset N`** only when `apply N` itself reports a conflict that can't be cleanly fixed by retarget or `--source-keep` - it rewrites target history and forces a `push --force`. Never preemptively reset.

## Why this matters more for agents than for humans

- Humans tend to run `git dispatch status` and read all the output. An agent under the skill prompt may skip `status` if the user gave it a specific task, and miss the post-merge `all` banner entirely.
- Humans recognise the visual difference between "fast-forward push" and "force-push" because the git CLI complains. An autonomous agent operating with `--yes` flags can accidentally force-push if the recipe says `apply reset` somewhere it shouldn't.
- Humans iterate: try, fail, retry. An agent benefits from a deterministic recipe so the first attempt succeeds and the user doesn't have to babysit conflict prompts.

## Suggested skill-prompt edits

In `~/.claude/skills/git-dispatch/SKILL.md` (or wherever the prompt is sourced), add a section:

```markdown
## Post-merge recipe (after a target gets squash-merged)

If `git dispatch status` shows a target as `merged`, run this sequence before
making further changes to other targets:

  1. `git dispatch sync` - merge base into source + remaining targets
  2. `git dispatch lint` - resolve any `all`-tagged commits whose content
     now lives on base. Use `retarget --commit <hash> --to-target <id>` to fix.
  3. `git dispatch checkout <N>` - open the integration branch for the target
     you intend to edit
  4. Make edits. Use `git dispatch commit "..."` (auto-detects target N).
  5. `git dispatch checkin` then `checkout source` then `apply <N>` to
     propagate. Use plain `apply <N>` (incremental, fast-forward-friendly),
     not `apply reset <N>`.

Never run `apply reset` preemptively - it rewrites target history and forces a
force-push. Reach for it only when `apply <N>` reports a real conflict that
retarget and `--source-keep` cannot resolve.
```

Also: the skill's "Common Fixes" table already contains "Stale target after tid reassignment (rebase) - `git dispatch apply --force`" - rename to make clearer what `--force` actually does (rebuilds stale target from scratch), since the word `--force` triggers agent-side caution.

## Expected outcome of these changes

- An agent encountering a post-merge state has a single block to follow, no synthesis of cross-references required.
- Fewer accidental `apply reset` invocations (agents asking for force-push permission unnecessarily).
- Better commit granularity on target branches because agents are nudged to use `dispatch commit` on a checkout branch instead of one big commit on source.

## Session context

Environment: macOS, git-dispatch from `~/Code/git-dispatch/`, Claude Code Opus 4.7.
Date: 2026-04-27.
Project: `bulk-transaction-registration-from-the-purchase-order-list`.
Stack at the time of this report: target 1 (BE, merged), target 2 (FE, in sync, WIP), target 3 (footer, 2 behind source).
Trigger: user asked agent to "use git-dispatch target 2" and "sync if T-1 not yet here". Agent had to infer the recipe from the skill prompt; the inference was correct but required reading the existing `REPORT-all-trailer-footgun-and-detection.md` to understand the consequence of the post-merge `all` banner.

## Related issues that this recipe also dodges

- `BUG-apply-silent-noop-and-push-circular-error.md` - sequencing avoids the noop case
- `BUG-checkin-replays-all-checkout-commits.md` - using fresh checkout branches per editing session avoids replay
- `BUG-checkout-conflict-after-sync-stale-targets.md` - the recipe runs sync BEFORE checkout, avoiding stale-target conflicts
