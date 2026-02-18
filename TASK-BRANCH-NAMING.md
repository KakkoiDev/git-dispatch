# Bug: Hardcoded `task-` prefix causes double-prefixed branch names

## Problem

`git dispatch split` hardcodes a `task-` prefix when building branch names from `Task-Id` trailer values.

Users who write `Task-Id: task-6` (a valid convention) get double-prefixed branches:
```
prefix/task-task-6   # actual
prefix/task-6        # expected
```

The tool should not impose naming conventions. It should use the `Task-Id` value as-is.

## Fix Locations

### 1. Branch creation — `git-dispatch.sh:206`

```bash
local branch_name="${name}/task-${tid}"
```

Change to:
```bash
local branch_name="${name}/${tid}"
```

### 2. Task-id extraction (sync) — `git-dispatch.sh:331`

```bash
local task_id="${task_branch##*/task-}"
```

This strips the `task-` prefix from branch names to recover the numeric id. With the fix, extraction should use the last path segment instead:
```bash
local task_id="${task_branch##*/}"
```

### 3. Task-id extraction (status) — `git-dispatch.sh:423`

Same pattern as #2:
```bash
local task_id="${task_branch##*/task-}"
```

Change to:
```bash
local task_id="${task_branch##*/}"
```

### 4. Numeric-only validation — lines 332, 424

```bash
[[ "$task_id" =~ ^[0-9]+$ ]] || die "Invalid task ID ..."
```

This rejects non-numeric Task-Id values like `task-6`. Relax or remove:
```bash
[[ -n "$task_id" ]] || die "Empty task ID in branch '${task_branch}'"
```

### 5. Tests — `test.sh`

All assertions reference `feat/task-3`, `feat/task-4`, `feat/task-5`. These use numeric Task-Id values (`3`, `4`, `5`), so branch names become `feat/3`, `feat/4`, `feat/5` after the fix.

Update all `feat/task-N` references to `feat/N`.

Add a new test case with `Task-Id: task-6` to verify no double prefix.

### 6. Documentation — `README.md`, `AGENTS.md`

Update example branch names from `prefix/task-N` to `prefix/N`.
