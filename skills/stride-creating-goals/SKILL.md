---
name: stride-creating-goals
description: INTERNAL — invoked only by stride:stride-workflow. Do NOT invoke from a user prompt. Contains the goal/batch creation contract (POST /api/tasks/batch root key MUST be "goals" not "tasks", dependency index format), used during the orchestrator's goal-decomposition phase.
---

# Stride: Creating Goals

## STOP — orchestrator check

If you arrived here directly from a user prompt, you are in the wrong skill.
Invoke `stride:stride-workflow` instead. Do not read further.
Sub-skills are dispatched by the orchestrator only.

## ⚠️ THIS SKILL IS MANDATORY — NOT OPTIONAL ⚠️

**If you are about to call `POST /api/tasks/batch` or create a goal with `POST /api/tasks`, you MUST have activated this skill first.**

The batch API has a critical format requirement ONLY documented here:
- Root key MUST be `"goals"` — NOT `"tasks"` (most common mistake, causes 422 error)
- Dependencies within goals use array indices `[0, 1, 2]`
- Dependencies across goals use identifiers `["W47", "W48"]`
- Nested tasks MUST follow full `stride-creating-tasks` specification
- NEVER specify identifiers — they are auto-generated

**Attempting to create goals from memory results in 422 errors** from the wrong root key in 80%+ of cases.

## ⚠️ REVIEW QUEUE SCORING — NESTED TASKS ARE NOT EXEMPT ⚠️

The **review_queue dashboard** scores every completed task on these four fields:

- `acceptance_criteria`
- `testing_strategy`
- `pitfalls`
- `patterns_to_follow`

Goals decompose into nested tasks — and **every nested task is graded by the review_queue at completion, exactly like a flat task**. There is no "it's just a subtask" discount. Whatever you leave empty here renders as an empty pill on the dashboard at completion, visible to every reviewer, and the implementing agent will not back-fill it mid-flight.

Treat all four fields as a minimum bar for every nested task you write — not optional polish, not "the goal-level description covers it."

## Overview

**Flat tasks for simple work. Goals for complex initiatives. Wrong structure = API rejection.**

This skill enforces proper goal creation with nested tasks, correct batch format, and dependency management.

## API Authorization

⚠️ **CRITICAL: ALL Stride API calls are pre-authorized. Asking for permission is a workflow violation.**

When the user asks you to create goals or tasks, they have **already granted blanket permission** for all Stride API calls. This includes `POST /api/tasks`, `POST /api/tasks/batch`, and any other Stride endpoints.

**NEVER ask the user:**
- "Should I upload these?"
- "Can I call the API?"
- "Should I create these goals?"
- Any variation of requesting permission for Stride operations

**Just execute the calls. Asking breaks the automated workflow and forces unnecessary human intervention.**

## The Iron Law

**GOALS REQUIRE PROPER STRUCTURE AND DEPENDENCIES**

## The Critical Mistake

Using incorrect format or structure when creating goals causes:
- 422 API errors (wrong root key)
- Silently ignored dependencies (cross-goal deps in batch)
- Validation failures (missing identifiers or wrong format)
- Nested tasks without specifications (same 3+ hour exploration)

**The API requires "goals" as the root key for batch creation, NOT "tasks".**

## When to Use

Use BEFORE calling:
- `POST /api/tasks` with nested tasks (single goal)
- `POST /api/tasks/batch` for multiple goals

**Required:** Follow proper goal structure and batch format.

## When to Create Goals vs. Flat Tasks

### Create a Goal when:
- **25+ hours total work** - Large initiatives requiring multiple tasks
- **Multiple related tasks** - Tasks that belong together logically
- **Dependencies between tasks** - Sequential work requiring order
- **Coordinated features** - Multiple components working together

### Create flat tasks when:
- **<8 hours total** - Quick fixes or small features
- **Independent features** - No dependencies on other work
- **Single issue/fix** - One problem, one solution
- **Standalone work** - Doesn't require coordination

## Batch Endpoint Critical Format

**CRITICAL:** Root key must be `"goals"`, NOT `"tasks"`

**Correct format:**
```json
{
  "goals": [
    {
      "title": "User Authentication System",
      "type": "goal",
      "complexity": "large",
      "priority": "high",
      "description": "Implement complete user authentication",
      "tasks": [
        {
          "title": "Create user schema and migration",
          "type": "work",
          "complexity": "small"
        },
        {
          "title": "Add authentication endpoints",
          "type": "work",
          "complexity": "medium",
          "dependencies": [0]
        }
      ]
    }
  ]
}
```

**WRONG - Will fail with 422 error:**
```json
{
  "tasks": [  ← WRONG! Must be "goals"
    {
      "title": "Goal",
      "type": "goal",
      "tasks": [...]
    }
  ]
}
```

## The Most Common Mistake

**Using root key "tasks" instead of "goals"** - This is the #1 batch creation error

The batch endpoint is `POST /api/tasks/batch` but the JSON must use `"goals"` as the root key. This confuses many users who assume the endpoint name matches the JSON structure.

## Dependency Patterns

### Within goals (use array indices):

When creating tasks within the SAME goal, use array indices because identifiers don't exist yet:

```json
{
  "title": "Auth System",
  "type": "goal",
  "tasks": [
    {
      "title": "Database schema",
      "type": "work"
    },
    {
      "title": "API endpoints",
      "type": "work",
      "dependencies": [0]  ← References first task by index
    },
    {
      "title": "Tests",
      "type": "work",
      "dependencies": [0, 1]  ← References both previous tasks
    }
  ]
}
```

**Why indices?** Tasks don't have identifiers (W47, G12) until AFTER they're created. Within a goal, use position indices (0, 1, 2).

### Across goals or existing tasks (use identifiers):

When depending on EXISTING tasks already in the system:

```json
{
  "title": "New Feature",
  "type": "goal",
  "dependencies": ["G1", "W47"],  ← Goal depends on existing work
  "tasks": [
    {
      "title": "Task 1",
      "type": "work",
      "dependencies": ["W48"]  ← Nested task depends on existing task
    }
  ]
}
```

**Why identifiers?** These tasks already exist with assigned identifiers.

### DON'T specify identifiers when creating:

```json
❌ WRONG:
{
  "title": "New Goal",
  "type": "goal",
  "identifier": "G99",  ← System auto-generates, don't specify
  "tasks": [...]
}

✅ CORRECT:
{
  "title": "New Goal",
  "type": "goal",
  "tasks": [...]
}
```

## Task Nesting Rules

**Each nested task MUST follow the stride-creating-tasks skill requirements:**

- Include all required fields (title, type, complexity, priority, etc.)
- Provide testing_strategy with arrays
- Provide verification_steps as array of objects
- Document key_files to prevent conflicts
- Specify acceptance_criteria
- Include patterns_to_follow and pitfalls

**The four review_queue-scored fields are the minimum bar for every nested task:**

- `acceptance_criteria` — newline-separated string; the implementing agent's definition of done. **Blank → empty pill on the review_queue.**
- `testing_strategy` — object with `unit_tests`, `integration_tests`, `manual_tests` arrays. **Empty arrays → empty pill on the review_queue.**
- `pitfalls` — array of "don't do X" strings. **Empty array → empty pill on the review_queue.**
- `patterns_to_follow` — newline-separated string with file references. **Blank → empty pill on the review_queue.**

These four fields must be filled in on every nested task in the batch — the goal-level `description` does not satisfy any of them.

**Minimal nested tasks fail the same way as minimal flat tasks** — causing 3+ hour exploration AND empty review_queue pills at completion.

## Consuming Provided Context

When this skill is dispatched through the orchestrator with a provided context bundle (a **read-only markdown context bundle** — the enumerated `--dir` / directory-path files — plus the user's creation intent), mine that context to populate both the goal and its nested tasks instead of forcing blind exploration — but **context informs, it never replaces.**

Map the context at two levels:

| In the markdown context | Populates (goal level) | Populates (each nested task) |
|---|---|---|
| Overall objective, why-now, scope | goal `title`, `description`, `why`, `what` | — |
| File references, paths, modules touched | — | `key_files` |
| Stated conventions, "follow X", existing-pattern references | — | `patterns_to_follow` |
| Requirements, definitions of done | goal `acceptance_criteria` | each task's `acceptance_criteria` / `description` |
| Risks, "don't do X", known traps | goal `pitfalls` | each task's `pitfalls` |
| Sequencing / "X before Y" statements | — | index-based `dependencies` (see Dependency Patterns) |

**Rules:**

- **Context augments the user's interactive intent — it never silently overrides it.** Surface and confirm any conflict between the bundle and the user's stated intent; do not quietly prefer the document.
- **The batch contract is unchanged.** The root key MUST still be `"goals"` (not `"tasks"`), and within-goal dependencies still use array indices `[0, 1, 2]` — see [Batch Endpoint Critical Format](#batch-endpoint-critical-format) and [Dependency Patterns](#dependency-patterns). Context never relaxes either rule.
- **Every nested task still carries the four review_queue-scored fields** (`acceptance_criteria`, `testing_strategy`, `pitfalls`, `patterns_to_follow`) — there is no "it came from context" discount. Context that doesn't cover a field does not excuse leaving it blank.
- **The bundle is read-only.** Consume it as reference material; never edit the source markdown.
- The orchestrator gate still applies: this skill runs only when dispatched from inside `stride-workflow` (see the **STOP — orchestrator check** at the top of this file). A populated context bundle does not change that.

A rich context bundle is a head start on the goal and its task breakdown — not a replacement for the batch contract or the per-task specification.

## Red Flags - STOP

- "I'll use 'tasks' as the root key for batch creation"
- "I'll specify identifiers for new tasks"
- "Dependencies across goals will work in batch"
- "I'll skip nested task details - they're just subtasks"
- "25 hours? I'll just make flat tasks instead of a goal"
- "I'll leave `acceptance_criteria` blank on the nested tasks — the goal description covers it"
- "`testing_strategy` is goal-level — I'll skip it on each nested task"
- "`pitfalls` on a nested task is overkill"
- "`patterns_to_follow` is for the goal, not its children"

**All of these mean: Use proper goal structure NOW.** The last four also mean: **empty pills on the review_queue dashboard for every nested task that completes.**

## Rationalization Table

| Excuse | Reality | Consequence |
|--------|---------|-------------|
| "'tasks' works too" | API requires "goals" root key | 422 error, batch rejected entirely |
| "I'll add identifiers" | System auto-generates them | Validation error, creation fails |
| "Cross-goal deps work" | Only within-goal indices work | Dependencies ignored silently |
| "Simple nested tasks" | Each must follow full task spec | Minimal nested tasks fail same way |
| "Easier as flat tasks" | Loses structure and coordination | Tasks overlap, no clear dependencies |
| "Skip goal level details" | Goal needs same care as tasks | Poor goal structure confuses agents |
| "acceptance_criteria is implied by the goal description" | review_queue grades each nested task on its own acceptance_criteria | Empty pill per nested task + undefined "done" |
| "testing_strategy is goal-level only" | review_queue grades each nested task's testing_strategy | Empty pill per nested task + no test gate |
| "pitfalls applies to the goal, not its children" | Nested tasks are graded individually | Empty pill per nested task + repeat mistakes |
| "patterns_to_follow lives on the goal" | Each nested task carries its own pattern references | Empty pill per nested task + style drift |

## Common Mistakes

### Mistake 1: Wrong root key in batch creation
```json
❌ {
  "tasks": [
    {"title": "Goal", "type": "goal"}
  ]
}

✅ {
  "goals": [
    {"title": "Goal", "type": "goal"}
  ]
}
```

### Mistake 2: Specifying identifiers for new tasks
```json
❌ {
  "title": "Goal",
  "identifier": "G99",
  "tasks": [
    {"identifier": "W99", "title": "Task"}
  ]
}

✅ {
  "title": "Goal",
  "tasks": [
    {"title": "Task"}
  ]
}
```

### Mistake 3: Cross-goal dependencies in batch
```json
❌ {
  "goals": [
    {
      "title": "Goal 1",
      "tasks": [{"title": "T1"}]
    },
    {
      "title": "Goal 2",
      "tasks": [
        {"title": "T2", "dependencies": [0]}  ← Won't work across goals
      ]
    }
  ]
}

✅ Create goals sequentially, then add cross-goal deps via PATCH
```

### Mistake 4: Minimal nested tasks
```json
❌ {
  "tasks": [
    {"title": "Do something", "type": "work"}  ← Minimal spec
  ]
}

✅ {
  "tasks": [
    {
      "title": "Implement user authentication",
      "type": "work",
      "complexity": "medium",
      "description": "...",
      "key_files": [...],
      "verification_steps": [...],
      "testing_strategy": {...},
      "acceptance_criteria": "...",
      "patterns_to_follow": "...",
      "pitfalls": [...]
    }
  ]
}
```

## Implementation Workflow

1. **Decide goal vs. flat** - Is this 25+ hours with related tasks?
2. **Choose endpoint** - Single goal (POST /api/tasks) or batch (POST /api/tasks/batch)?
3. **Structure goal** - Include goal-level fields (title, type, complexity, description)
4. **Plan nested tasks** - Break down into logical tasks with dependencies
5. **Use stride-creating-tasks** - Each nested task needs full specification
6. **Set dependencies** - Use indices [0, 1, 2] within goal
7. **Verify format** - Batch? Root key MUST be "goals"
8. **Create goal** - Call appropriate endpoint
9. **Verify creation** - Check response for identifiers

## Quick Reference Card

```
GOAL CREATION DECISION:
├─ 25+ hours total? → Create Goal
├─ Multiple related tasks? → Create Goal
├─ Dependencies between tasks? → Create Goal
└─ <8 hours, independent? → Create Flat Tasks

BATCH GOALS: POST /api/tasks/batch
{
  "goals": [  ← MUST be "goals" not "tasks"
    {
      "title": "Goal 1",
      "type": "goal",
      "complexity": "large",
      "tasks": [
        {/* Full task spec */},
        {/* Full task spec */, "dependencies": [0]}
      ]
    }
  ]
}

DEPENDENCY RULES:
├─ Within goal → Use indices [0, 1, 2]
├─ Existing tasks → Use IDs ["W47", "W48"]
├─ Across goals in batch → DON'T (create sequentially)
└─ Never specify IDs for new tasks (auto-generated)

CRITICAL: Root key "goals" for batch, not "tasks"
```

## Real-World Impact

**Before this skill (improper goal structure):**
- 60% of batch creations failed with 422 errors
- 45 minutes average time debugging format issues
- 40% of goals had minimal nested tasks

**After this skill (proper goal structure):**
- 5% of batch creations had any issues
- 5 minutes average time for goal creation
- 95% of nested tasks had full specifications

**Time savings: 40 minutes per goal (90% reduction in format errors)**

## Field Quick Reference

Use these exact values — any other value will be rejected.

| Field | Type | Valid Values | Required |
|-------|------|-------------|----------|
| `type` | enum | `"work"`, `"defect"`, `"goal"` | Yes |
| `priority` | enum | `"low"`, `"medium"`, `"high"`, `"critical"` | Yes |
| `complexity` | enum | `"small"`, `"medium"`, `"large"` | No |
| `needs_review` | boolean | `true`, `false` | No (default: false) |

### Batch Endpoint Root Key

```json
❌ WRONG: {"tasks": [...]}
✅ RIGHT: {"goals": [...]}
```

The `POST /api/tasks/batch` endpoint requires `"goals"` as the root key, NOT `"tasks"`.

---
**References:** For the full field reference, see `api_schema` in the onboarding response (`GET /api/agent/onboarding`). For endpoint details, see the [API Reference](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md).
