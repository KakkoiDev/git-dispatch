# TASK: Remove stacked mode

## Context

Stacked mode is dead weight. The checkout command makes it redundant.

**Why stacked mode existed:** CI needs to pass on each target. Stacked targets
include parent commits so CI works.

**Why it's now unnecessary:** `checkout <N>` gives the combined 1..N view for
testing without permanently stacking branches. Independent mode + checkout =
best of both worlds.

**Catchphrase:** "Stacked PRs without the stack."

Independent targets + checkout for integration = no force-push, no restack,
no cascade, no destroyed review context. Ever.

## What to remove

### Functions to delete
- `stack_add()` (lines 31-38)
- `stack_remove()` (lines 40-50)
- `order_by_stack()` (lines 629-674)
- `find_stack_parent()` (lines 676-685)

### Logic to simplify
- `cmd_init()`: remove --mode flag, remove mode validation, remove mode config storage
- `cmd_apply()`: remove mode variable, remove stacked branching logic (always use base as parent), remove `stack_add` calls
- `cmd_apply()` stale cleanup: remove `find_stack_parent`/`stack_remove` calls
- `cmd_apply()` reset: remove `find_stack_parent` call
- `cmd_cherry_pick()`: remove `find_stack_parent` call
- `cmd_push()`: remove `order_by_stack` pipe (just iterate targets)
- `cmd_status()`: remove `order_by_stack` pipe, remove stacked parent display
- `cmd_verify()`: remove stacked mode skip
- `cmd_reset()`: remove `find_stack_parent`/`stack_remove` calls, remove mode unset
- `cmd_help()`: remove mode references
- `_get_config mode` calls: remove

### Config to remove
- `dispatch.mode` - no longer stored
- `branch.<name>.dispatchtargets` - no longer needed (was for stack hierarchy)

### Tests to remove
- `test_init_stacked_mode`
- `test_apply_stacked_mode`
- `test_verify_stacked_mode_skips`

### Tests to update
- `test_init_basic`: remove mode assertion
- `test_init_reinit_warns`: may reference mode
- `test_status_shows_mode`: remove or simplify (no mode to show)
- Any test using `order_by_stack` in assertions

### Docs to update
- README.md: remove two-modes section, add "Stacked PRs without the stack" positioning
- DESIGN.md: remove stacked references, add explanation of why
- SKILL.md: remove stacked mode references
- AGENTS.md: remove stacked mode references
- install.sh: remove --mode from usage examples
- Help text in cmd_help()

## Acceptance criteria
- [ ] No references to "stacked" in git-dispatch.sh
- [ ] No references to "stacked" in test.sh
- [ ] No --mode flag
- [ ] No dispatchtargets config
- [ ] No stack_add/stack_remove/order_by_stack/find_stack_parent functions
- [ ] All tests pass
- [ ] Docs explain why: checkout replaces stacked mode
- [ ] Catchphrase in README
- [ ] Skill and agent reinstalled
