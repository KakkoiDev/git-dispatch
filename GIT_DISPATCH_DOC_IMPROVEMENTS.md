# git-dispatch Skill: Documentation Improvement Report

## Goal

Make the `git-dispatch` skill self-sufficient for AI agents so they:

1. Auto-recognize when to chain `sync && apply` (drift-driven source-to-target propagation).
2. Auto-recognize when to switch to the `checkout <N>` flow for target-side fixes (auto-gen drift, target-only CI failure).
3. Burn fewer tokens per skill load via caveman compression.
4. Stay tool-agnostic. No project-specific commands in the skill.

This report references the current skill at `/Users/cyril.antoni/Code/git-dispatch/SKILL.md` (307 lines, 14 KB) and concrete moments where I, as an agent, missed the right path during the T-2 PR session.

## Failure Modes I Hit This Session (Anchor Cases)

| Symptom | What I did wrong | What docs should have made obvious |
|---------|------------------|------------------------------------|
| Target gen file (`apps/web/src/store/api/gen/transactions.ts`) had shape A, source had shape B. CI on target failed type-check. | Tried to edit POC's gen file to force a diff that `apply` would propagate. Source already had its own state; no diff produced. Spent ~5 tool calls thrashing. | "Auto-gen file diverges on target -> `checkout <N>` is the only path. Source `apply` cannot push a no-diff change." Decision table missing. |
| `git dispatch apply 2` refused with "Source is N behind base". | User had to remind me about `sync`. | Docs cover the trap (lines 277-279) but not as a top-level decision pattern an agent scans for. |
| Target-only lint failure (biome format). | I started toward source-side hand fix. User had to prompt me toward the checkout flow. | "Target CI failed on a file owned by target's regen step -> checkout flow." Symptom keywords missing. |

The skill *contains* the answers (lines 137-145, 277-293) but they are buried in long prose. An agent under context pressure does not always page them in.

## Recommendation 1: Add a Decision Triage Table at the Top

Insert just after the one-line description (after line 12), before `## Commands`:

```
## Decision Triage (agent: scan first)

| Symptom                                                                 | Path                                                |
|-------------------------------------------------------------------------|-----------------------------------------------------|
| `apply` refuses: "source behind base"                                   | `sync` then `apply <N>`                             |
| Target CI green locally, fails on remote (lint, format, type-check)     | `checkout <N>` -> fix -> commit -> `checkin` -> `apply <N>` -> `push <N>` |
| Auto-gen file (gen/, swagger, prisma, openapi) shape differs target<>source | `checkout <N>` -> run auto-gen command -> commit `--source-keep` -> `checkin` -> `apply` -> `push <N>` |
| Source `apply` produces no diff but target stays broken                 | Target has divergent state source cannot reach. Use `checkout <N>` flow. |
| Same code change applies to every target                                | Commit on source with `--target all`, then `apply`  |
| Want to verify multi-target integration before each PR ships            | `checkout <N>` -> run tests -> `checkout source` -> `checkout clear` |
| Stuck mid-operation                                                     | `git dispatch abort`                                |
```

Why first: agents scan top-down. The first concrete table is the one they reach for. Today's "Common Fixes" at line 281 is closer to what I needed, but is at the bottom and lists too many edge cases mixed with primary flows.

## Recommendation 2: Strengthen Symptom Keywords for Auto-Gen Drift

The current "Generated files" section (lines 130-145) is helpful once located but does not list trigger phrases. Add an explicit "When to reach for this" lead-in:

```
### Generated files (OpenAPI, protobuf, Prisma, codegen)

**Trigger phrases (agent scan):**
- "regen", "regenerate", "auto-gen", "code-gen", "swagger", "openapi", "prisma"
- "stale gen file on target", "drift between branches"
- "target CI fails, source CI passes" on a generated path
- "no diff on source" but target needs fix
- "force-update gen on target without touching source backend"

**Rule:** auto-gen files are owned by the branch that ran the generator. Source `apply`
cannot push a no-diff change. If the target's gen file is wrong, regen on the target.

Option A: regen on source (when source backend already produces the right shape)
[unchanged]

Option B: regen for failing target via checkout (when source cannot produce the shape)
[unchanged]
```

This gives the agent a keyword anchor inside its own context. The phrase "no diff on source" specifically would have unstuck me four tool calls earlier.

## Recommendation 3: Strip Project-Specific Commands

Current SKILL.md uses `pnpm openapi` (lines 133, 139) and `pnpm test` (line 113). These tie the skill to a specific project's tooling. An agent reading this in a different repo (say, a Bazel monorepo or an `nx` workspace) will be misled.

Replacement language:

| Before | After |
|--------|-------|
| `pnpm openapi` | `<run the auto-gen command>` (with comment) |
| `pnpm test` | `<run the test suite>` |
| `pnpm openapi` (line 139) | `<run the auto-gen command>` |

Concretely (diff for lines 110-145):

```
### Integration testing
git dispatch checkout 3           # branch with targets 1..3 + all
<run the test suite>              # e.g. pnpm test, cargo test, bazel test //...
git dispatch checkout source
git dispatch checkout clear

### Generated files (OpenAPI, protobuf, Prisma)

Option A: regen on source with Source-Keep
<run the auto-gen command>        # whatever produces the gen files in this repo
git dispatch commit "regen" --target all --source-keep
git dispatch apply

Option B: regen for failing target via checkout
git dispatch checkout 3
<run the auto-gen command>
git dispatch commit "regen swagger" --source-keep
git dispatch checkin
git dispatch checkout source
git dispatch apply
git dispatch push 3
```

Agents will infer the right command from the host repo's `package.json` / `Makefile` / `BUILD.bazel`.

## Recommendation 4: Caveman Compression

The skill is 307 lines, ~14 KB. Initial agent context load is real. Compression targets ~40 percent reduction while keeping all decision content. Apply the same rules as `caveman` mode: drop articles, hedging, filler words. Keep code blocks unchanged. Keep tables tight.

### Before (lines 6-13, 8 lines)

```
# git-dispatch - Stacked PRs Without the Stack

Multi-commit grouped PRs. No force-push. No restack. No cascade.

Unlike ghstack/spr (1 commit = 1 PR), git-dispatch groups commits by Dispatch-Target-Id into multi-commit PRs. Each target branches independently from base. `checkout <N>` provides the combined view for integration testing.

**Source** = where all edits happen. **Targets** = read-only PR branches. **Checkout** = integration testing.
```

### After (compressed)

```
# git-dispatch

Multi-commit grouped PRs. No force-push, restack, or cascade.

vs ghstack/spr: groups commits by `Dispatch-Target-Id` trailer into multi-commit PRs. Each target branches independently from base. `checkout <N>` = integration view.

Source = edit here. Targets = read-only PRs. Checkout = integration test.
```

40 percent shorter. Same content.

### Other compression candidates

| Section | Before length | After (target) |
|---------|---------------|----------------|
| "When to use `Dispatch-Target-Id: all`" (lines 52-71) | 20 lines | 12 lines |
| "Ownership config" (lines 72-95) | 24 lines | 14 lines |
| "Conflict Handling" (lines 236-253) | 18 lines | 10 lines |
| "Divergence Detection" (lines 256-262) | 7 lines | 4 lines |

Total estimated savings: ~80 lines, ~3.5 KB.

### Compression rules (apply uniformly)

- Drop articles in prose. Keep in code blocks.
- "for example" -> "e.g."
- "in order to" -> "to"
- "make sure that" -> "ensure"
- Replace "The user can do X by running Y" with "X: `Y`"
- Tables for any list with two or more parallel items
- One sentence per insight. No paragraphs for what a table can show.

## Recommendation 5: Add Anti-Pattern Section

Surface what NOT to do, with the keyword the agent will use. Adds about 10 lines but saves multiple tool calls of bad attempts.

```
## Anti-Patterns

| Don't | Why | Do instead |
|-------|-----|------------|
| Edit auto-gen file on source to push diff to target | Source has no real diff. Cherry-pick to target is empty. | `checkout <N>` -> regen -> `checkin` |
| Run `apply` while source behind base | Cosmetic SHA drift, future `apply` conflicts, forces `apply reset` + `push --force` | `sync` first |
| Use `Dispatch-Target-Id: all` for one target's format fix | Once any target merges, `all` cherry-picks conflict on remaining targets | Tag the specific target |
| `apply reset <N>` preemptively | Rewrites history, forces `push --force`, breaks PR review comments | Only when `apply <N>` itself conflicts and `retarget`/`--source-keep` cannot fix |
| Manually push target branches | Easy to drift from source; `dispatch status` flags as `(DIVERGED)` | `git dispatch push <N>` |
```

## Recommendation 6: Quick-Reference Card for AI Agents

A 20-line minimal card the agent can recall from a tighter context window. Add as the second section after the description, before Decision Triage.

```
## Agent Cheat Sheet

You are on `source`. CI fails on target `N`:

1. Lint/format/type-check on a source-owned file: fix on source. `sync`, `apply <N>`, `push <N>`.
2. Lint/format/type-check on a target-owned file (gen, swagger, etc.): `checkout <N>`. Fix. `commit`. `checkin`. `checkout source`. `sync`. `apply <N>`. `push <N>`. `checkout clear`.
3. Test failure that needs cross-target context: `checkout <N>` to verify, then route fix per rule 1 or 2.

You are on `source`. Want to make new PRs:

1. `commit --target <N>` per change.
2. `sync` (if base moved).
3. `apply`.
4. `push all`.

Stuck: `git dispatch abort`. Returns to source clean.
```

This is the section an agent under heavy token pressure should be able to load alone and still pick the right command.

## Suggested Implementation Order

1. **Quick wins (no semantic change):**
   - Strip project-specific commands (`pnpm openapi`, `pnpm test`). Replace with `<run the auto-gen command>` / `<run the test suite>`.
   - Add Anti-Patterns table (10 lines).

2. **Agent-facing additions:**
   - Decision Triage table near the top.
   - Agent Cheat Sheet section.
   - Trigger-phrase list inside "Generated files".

3. **Caveman compression pass:**
   - Apply rules uniformly across all prose sections.
   - Preserve code blocks, tables, command names verbatim.
   - Aim for ~40 percent line reduction without losing any decision content.

4. **Verify:** load the compressed skill via `Skill` tool, ask an agent to fix a synthetic "target gen file diverged" scenario. Agent should reach for `checkout <N>` without prompting. If it does not, the keywords or triage table need another pass.

## Out-of-Scope Notes

- README in the tool's own repo (`/Users/cyril.antoni/Code/git-dispatch/README.md`, if it exists) is a separate concern. Skill docs are what AI agents see; the README is for human contributors. Mirror them only if practical.
- The drift gate error message itself ("Source is N commit(s) behind origin/master. Run: git dispatch sync...") is already optimal. No change needed there.
- `--help` output (`git dispatch --help`) is a separate surface area. Compress only if it loads into agent context regularly.

## Summary

Three concrete wins:

1. Triage table + Cheat Sheet up top. Agents scan top-down, decide before reading workflows.
2. Strip project commands. Skill becomes portable across repos.
3. Compress prose. ~40 percent token savings, same decision content.

After these, an agent should never need a human prompt to:
- choose between source-side fix and target-side checkout flow
- run `sync` before `apply` when behind base
- pick the auto-gen regen path for a target-only CI failure
