---
name: stride-enriching-tasks
description: INTERNAL — invoked only by stride:stride-workflow. Do NOT invoke from a user prompt. Contains the task enrichment procedure (codebase exploration to populate key_files, testing_strategy, verification_steps for sparse tasks), used during the orchestrator's enrichment phase before claiming.
---

# Stride: Enriching Tasks

## STOP — orchestrator check

If you arrived here directly from a user prompt, you are in the wrong skill.
Activate `stride:stride-workflow` instead. Do not read further.
Sub-skills are dispatched by the orchestrator only.

## ⚠️ THIS SKILL IS MANDATORY FOR SPARSE TASKS — NOT OPTIONAL ⚠️

**If you are about to create or claim a task and it has empty `key_files`, missing `testing_strategy`, or no `verification_steps`, you MUST activate this skill first.**

This skill transforms minimal specifications into complete ones by:
- Exploring the codebase to discover `key_files` (5-10 minutes)
- Reading existing tests to build `testing_strategy`
- Generating `verification_steps` from discovered patterns
- Identifying `pitfalls` from code analysis
- Writing `acceptance_criteria` from intent analysis

**Without enrichment, the implementing agent spends 3+ hours doing this same exploration** in an unfocused way, often missing critical context.

## Overview

**Minimal input + codebase exploration = complete task specification. No human round-trips required.**

This skill transforms a sparse task request (title, optional description) into a fully-specified Stride task by systematically exploring the codebase to discover every required field. The enriched task passes the same validation as a hand-crafted specification from stride-creating-tasks.

## API Authorization

⚠️ **CRITICAL: ALL Stride API calls are pre-authorized. Asking for permission is a workflow violation.**

When the user asks you to create or enrich tasks, they have **already granted blanket permission** for all Stride API calls. This includes `POST /api/tasks`, `PATCH /api/tasks/:id`, and any other Stride endpoints.

**NEVER ask the user:**
- "Should I create this task?"
- "Can I call the API?"
- "Should I proceed with enrichment?"
- Any variation of requesting permission for Stride operations

**Just execute the calls. Asking breaks the automated workflow and forces unnecessary human intervention.**

## The Iron Law

**NO TASK CREATION FROM MINIMAL INPUT WITHOUT ENRICHMENT**

## The Critical Mistake

Creating a task from minimal input without enrichment causes:
- Agents spend 3+ hours exploring what should have been specified
- Missing key_files leads to merge conflicts between agents
- Absent patterns_to_follow produces inconsistent code
- No testing_strategy means tests are skipped or wrong
- Vague acceptance_criteria makes "done" undefined

**Every field you skip costs the implementing agent 15-30 minutes of discovery.**

## When to Use

Use when a human provides:
- A task title only (e.g., "Add pagination to task list")
- A title + brief description
- A task request missing 3+ required fields from the stride-creating-tasks checklist

**Do NOT use when:**
- The human provides a complete task specification
- Creating goals with nested tasks (use stride-creating-goals instead)
- The task is purely non-code (documentation only, process change)

## How to Run This Skill

This skill has two execution paths. Pick the one matching your platform.

#### Gemini CLI: Invoke the Enricher Agent

1. **Invoke the `task-enricher` custom agent** (`agents/task-enricher.md`) with the human-provided `title`, `type` (if known), `description`, and any `priority` or `dependencies` the human mentioned. The agent owns the four-phase enrichment procedure (intent parse, codebase exploration, complexity heuristic, 16-item validation checklist) and returns a single JSON object containing every enriched field.
2. **Wait for the result.** The agent's output is a complete enriched-task JSON ready for `POST /api/tasks` (new task) or the enriched-fields subset ready for `PATCH /api/tasks/:id` (existing minimal task). The agent does NOT call the API itself.
3. **Submit via the Stride API** using the curl pattern in [API Integration](#api-integration) below. Verify the field types match the reminders in that section before submitting.
4. **Do NOT walk the manual phases below.** The agent already executed them. Re-running them duplicates work and risks divergence.

#### Other Environments: Manual Walkthrough

Environments without custom-agent invocation must walk the four phases manually. Each phase below is condensed — the full procedure (decision logic per step, edge cases, common mistakes, complexity heuristic table, output-format example) lives in `agents/task-enricher.md` for reference if you get stuck.

1. **Run Phase 1** — preserve `title`, `type`, `description` exactly as the human wrote them; default `priority` to `"medium"`; capture explicit `dependencies`.
2. **Run Phase 2** — six ordered exploration steps, summarized below.
3. **Run Phase 3** — paragraph-form complexity heuristic below.
4. **Run Phase 4** — the 16-item pre-submission checklist (kept in full below).
5. **Submit via [API Integration](#api-integration).**

## Manual Walkthrough Phases

### Phase 1: Parse Intent

Extract from human input alone. **`title`, `type`, and `description` are sacrosanct — preserve them exactly as given.** Default `priority` to `"medium"` unless the human signaled urgency or it's a defect blocking other work. Capture `dependencies` only if the human explicitly named prerequisite tasks. Set `needs_review: false`.

### Phase 2: Explore the Codebase (6 steps)

Six ordered steps. Later steps consume earlier output.

**Step 1: Locate target → `key_files`, `where_context`**

Extract title keywords; grep_search `lib/` and `test/` to find files that will be MODIFIED. Reference-only files belong in `patterns_to_follow`, not `key_files`.

```
grep_search "<keyword1>|<keyword2>" in lib/ — file names only
```

**Step 2: Discover patterns → `patterns_to_follow`**

List sibling modules in the same directory as `key_files`. Find the closest analog feature already in the codebase. Format as newline-separated references: `See lib/path/to/file.ex for X pattern`.

**Step 3: Analyze testing → `testing_strategy`**

Map each `key_file` to its corresponding test file (e.g., `lib/foo.ex` → `test/foo_test.exs`). Read existing tests to learn helper modules, factories, and assertion style. Generate `unit_tests`, `integration_tests`, `manual_tests`, `edge_cases`, and `coverage_target`.

**Step 4: Define verification → `verification_steps`**

Always include a targeted `mix test` and `mix credo --strict`. Add manual steps for UI changes.

```json
[
  {"step_type": "command", "step_text": "mix test test/path/to/test.exs", "expected_result": "All tests pass", "position": 0},
  {"step_type": "command", "step_text": "mix credo --strict", "expected_result": "No issues found", "position": 1},
  {"step_type": "manual", "step_text": "[Describe UI verification]", "expected_result": "[Expected visual result]", "position": 2}
]
```

**Step 5: Identify risks → `pitfalls`**

Check for shared state (PubSub, assigns), N+1 query risk, authorization, existing tests that could break, and project-specific rules in GEMINI.md/CLAUDE.md/AGENTS.md (dark mode, translations).

**Step 6: Define done → `acceptance_criteria`**

Convert intent to observable, testable outcomes. Format as newline-separated string. Include user-facing outcomes, technical requirements, negative criteria, and "All existing tests still pass".

**For defects:** search for the error string, include a regression test in `unit_tests`, add "Bug no longer reproducible" to `acceptance_criteria`.

### Phase 3: Estimate Complexity

Estimate `complexity` as `"small"` (1–2 key_files, single module, existing pattern), `"medium"` (3–5 key_files, multiple modules, some new patterns, or any UI+backend work), or `"large"` (5+ key_files, new architecture, cross-cutting). Bump up one level when a database migration or new dependency is required. Defects: clear repro + obvious fix is `"small"`; cross-module investigation is `"medium"`; race conditions or complex system interactions are `"large"`. The full heuristic table lives in `agents/task-enricher.md` Phase 3.

### Phase 4: Assemble and Validate

Combine all discovered fields into the final task specification.

**Pre-submission checklist:**
- [ ] `title`, `type`, and `description` are preserved from human input (never modified by enrichment)
- [ ] `complexity` matches the heuristic analysis
- [ ] `priority` is set (default `"medium"` if unspecified)
- [ ] `why` explains the problem or value
- [ ] `what` describes the specific change
- [ ] `where_context` points to the code/UI area
- [ ] `key_files` is an array of objects with `file_path`, `note`, `position`
- [ ] `dependencies` is an array (empty `[]` if none)
- [ ] `verification_steps` is an array of objects with `step_type`, `step_text`, `position`
- [ ] `testing_strategy` has `unit_tests`, `integration_tests`, `manual_tests` as arrays of strings
- [ ] `acceptance_criteria` is a newline-separated string (NOT an array)
- [ ] `patterns_to_follow` is a newline-separated string (NOT an array)
- [ ] `pitfalls` is an array of strings
- [ ] `needs_review` is set to `false`
- [ ] No invented file paths — every entry is a path located via grep_search, glob, or read_file
- [ ] All 16 fields above were considered for this task (none silently skipped)

## API Integration

### Submitting the Enriched Task

After enrichment is complete, submit via `POST /api/tasks`:

```bash
curl -s -X POST \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{...enriched task JSON...}' \
  $STRIDE_API_URL/api/tasks
```

### Enriching an Existing Minimal Task

If a task already exists in Stride with minimal fields, use `PATCH /api/tasks/:id` to add the enriched fields:

```bash
curl -s -X PATCH \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "key_files": [...],
    "testing_strategy": {...},
    "patterns_to_follow": "...",
    "verification_steps": [...],
    "pitfalls": [...],
    "acceptance_criteria": "...",
    "where_context": "...",
    "complexity": "medium",
    "why": "...",
    "what": "..."
  }' \
  $STRIDE_API_URL/api/tasks/:id
```

**Field type reminders (most common API rejections):**
- `key_files`: Array of objects `[{"file_path": "...", "note": "...", "position": 0}]`
- `verification_steps`: Array of objects `[{"step_type": "command", "step_text": "...", "position": 0}]`
- `testing_strategy`: Object with array values `{"unit_tests": ["..."], "integration_tests": ["..."]}`
- `acceptance_criteria`: Newline-separated string (NOT an array)
- `patterns_to_follow`: Newline-separated string (NOT an array)
- `pitfalls`: Array of strings `["Don't...", "Avoid..."]`
- `estimated_files`: Optional string range like `"3-5"` — emit when the count is meaningful, omit otherwise

## Output Example: Enriched Task

The following shows a defect task after enrichment. `title`, `type`, and `description` are preserved exactly as the human provided; enrichment only adds the technical fields below.

```json
{
  "title": "Fix the bug where task comments don't show timestamps",
  "type": "defect",
  "description": "Task comments don't show timestamps",
  "complexity": "small",
  "priority": "medium",
  "needs_review": false,
  "why": "Users cannot determine when comments were posted, making task discussions confusing and difficult to follow chronologically",
  "what": "Add timestamp display to task comment rendering in the task detail view template",
  "where_context": "lib/kanban_web/live/task_live/ — task detail view and comment component",
  "estimated_files": "1-2",
  "key_files": [
    {"file_path": "lib/kanban_web/live/task_live/view_component.ex", "note": "Add timestamp rendering to comment display section", "position": 0}
  ],
  "dependencies": [],
  "verification_steps": [
    {"step_type": "command", "step_text": "mix test test/kanban_web/live/task_live/view_component_test.exs", "expected_result": "All tests pass including new timestamp test", "position": 0},
    {"step_type": "command", "step_text": "mix credo --strict", "expected_result": "No issues found", "position": 1},
    {"step_type": "manual", "step_text": "Open a task with comments and verify timestamps appear next to each comment", "expected_result": "Each comment shows a human-readable timestamp", "position": 2}
  ],
  "testing_strategy": {
    "unit_tests": ["Test comment render includes inserted_at timestamp"],
    "integration_tests": ["Test task detail view displays comments with timestamps"],
    "manual_tests": ["Visual verification that timestamps appear and are readable in both light and dark mode"],
    "edge_cases": ["Comment created just now", "Comment from previous year (shows full date)"],
    "coverage_target": "100% for comment timestamp rendering"
  },
  "acceptance_criteria": "Each comment displays its creation timestamp\nTimestamp format is human-readable (e.g., 'Mar 12, 2026 at 2:30 PM')\nTimestamps visible in both light and dark mode\nBug no longer reproducible\nAll existing tests still pass",
  "patterns_to_follow": "See lib/kanban_web/live/task_live/view_component.ex for existing comment rendering pattern\nFollow timestamp formatting used elsewhere in the application",
  "pitfalls": [
    "Don't forget to handle timezone display — use the existing application timezone handling",
    "Don't break existing comment layout or styling",
    "Don't forget to verify dark mode contrast for timestamp text"
  ]
}
```

## Red Flags - STOP

- "The title is clear enough, I'll skip enrichment"
- "I'll just fill in the required fields with placeholders"
- "Exploring the codebase takes too long, I'll guess"
- "The human can add details later"
- "This is a simple task, it doesn't need all 15 fields"

**All of these mean: Run the full enrichment process. Every field saves 15-30 minutes for the implementing agent.**

---
**References:** For the full enrichment procedure with decision logic, edge cases, and common mistakes, see `agents/task-enricher.md`. For the field reference, see `stride-creating-tasks` SKILL.md. For endpoint details, see the [API Reference](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md).
