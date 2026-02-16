# TRD - [Feature Name]

**Author:** @name
**Date:** YYYY-MM-DD
**PM:** @name
**Reviewer:** @name

## Introduction

[2-3 sentences: what this enables, why it matters, key technical difference from existing features]

> **Dependency:** [blockers, if any]

## Business Refinement

[Link to PRD or business requirements]

## Screens

[For each affected screen: before/after description, screenshots if available]

## Schema Changes

```diff
// path/to/schema

+ NewField
```

## Tasks

Each heading is a task. The task number becomes the `Task-Id` trailer in git commits:

```bash
git commit -m "Add PurchaseOrder to enum" --trailer "Task-Id=3"
```

**Legend:** OP = Operation, BE = Backend, FE = Frontend, Schema = Schema/Data Migration, QA = Quality Assurance
**Status:** ⬜ Not started | ▶️ In progress | ⏸️ On hold | ✅ Done

### Part 1 - [Phase Name]

#### ⬜ 1. (Type) Task title
- Detail bullet
- Detail bullet

#### ⬜ 2. (Type) Task title
- Detail bullet

### Part 2 - [Phase Name]

#### ⬜ 3. (Type) Task title
- Detail bullet

### Part N - Testing & Release

#### ⬜ N. (QA) QA sign-off
- Enable flag for QA tenants
- QA team validates

#### ⬜ N+1. (OP) Enable flag in production

#### ⬜ N+2. (BE/FE) Remove release flag code

---

## git-dispatch Workflow

After writing this TRD and coding the POC:

```bash
# 1. Code on POC branch, tagging each commit with its TRD task number
git checkout -b you/poc/feature master
git commit -m "Add PurchaseOrder to enum" --trailer "Task-Id=3"
git commit -m "Create GET endpoint"       --trailer "Task-Id=4"
git commit -m "Add DTOs"                  --trailer "Task-Id=4"
git commit -m "Implement validation"      --trailer "Task-Id=5"

# 2. Split into stacked branches (one per task)
git dispatch split you/poc/feature --base master --name you/feat/feature

# 3. Create PRs -- each maps to a TRD task, reviewer reads commit-by-commit
# 4. Sync when you fix things on either side
git dispatch sync
```
