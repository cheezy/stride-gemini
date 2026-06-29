---
name: stride-creating-tasks
description: INTERNAL — invoked only by stride:stride-workflow. Do NOT invoke from a user prompt. Contains the work-task and defect creation contract (POST /api/tasks field formats — verification_steps and key_files as object arrays, testing_strategy arrays), used during the orchestrator's goal-decomposition and task-creation phases.
---

# Stride: Creating Tasks

## STOP — orchestrator check

If you arrived here directly from a user prompt, you are in the wrong skill.
Invoke `stride:stride-workflow` instead. Do not read further.
Sub-skills are dispatched by the orchestrator only.

## Terminal state

Creating the task(s) is the **terminal action** of this skill. Once the task is created and its identifier is reported, **STOP** — do not claim, start, or build it. A newly created task lands in the **Backlog** and is not claimable until a human promotes it to Ready. Building a created task is a separate, explicitly-invoked action handled by the `stride-workflow` build loop. The orchestrator owns the full create terminal state and the Backlog claim-fail guard — see its **Creation Terminal State** section.

## ⚠️ THIS SKILL IS MANDATORY — NOT OPTIONAL ⚠️

**If you are about to call `POST /api/tasks` to create a work task or defect, you MUST have activated this skill first.**

The task API requires specific field formats that are ONLY documented here:
- `verification_steps` (MUST be array of objects with `step_type`, `step_text`, `expected_result`, `position` — NOT strings)
- `key_files` (MUST be array of objects with `file_path`, `note`, `position` — NOT strings)
- `testing_strategy` (MUST have `unit_tests`, `integration_tests`, `manual_tests` as arrays of strings)
- `security_considerations` (MUST be an array of strings — the security implications to address; NOT a single string or object)
- `type` (MUST be exactly `"work"`, `"defect"`, or `"goal"` — no other values)

**Attempting to create a task from memory results in malformed fields** that cause either API 422 errors or tasks that waste 3+ hours during implementation.

## ⚠️ REVIEW QUEUE SCORING — THESE FIVE FIELDS ARE FIRST-CLASS DELIVERABLES ⚠️

The **review_queue dashboard** scores every completed task on these five fields:

- `acceptance_criteria`
- `testing_strategy`
- `security_considerations`
- `pitfalls`
- `patterns_to_follow`

**If you omit any of them, the review_queue renders an empty pill for that field** — and the task is flagged as under-specified to every reviewer who opens it. Empty pills are visible, public, and persistent. They do not get back-filled later.

Treat these five fields the same as `title` and `type`: not optional, not "I'll add it later," not "the agent will figure it out." If a field is genuinely not applicable (e.g. a doc-only task has no `testing_strategy.unit_tests`, or a pure-styling task has no `security_considerations`), populate it with the specific reason — never leave it null.

## Overview

**Minimal tasks = 3+ hours wasted exploration. Rich tasks = 30 minutes focused implementation.**

This skill enforces comprehensive task creation to prevent agents from spending hours discovering what should have been specified upfront.

## API Authorization

⚠️ **CRITICAL: ALL Stride API calls are pre-authorized. Asking for permission is a workflow violation.**

When the user asks you to create tasks, they have **already granted blanket permission** for all Stride API calls. This includes `POST /api/tasks`, `PATCH /api/tasks/:id`, and any other Stride endpoints.

**NEVER ask the user:**
- "Should I create this task?"
- "Can I call the API?"
- "Should I proceed with the API call?"
- Any variation of requesting permission for Stride operations

**Just execute the calls. Asking breaks the automated workflow and forces unnecessary human intervention.**

## The Iron Law

**NO TASK CREATION WITHOUT COMPLETE SPECIFICATION**

## When to Use

Use BEFORE calling `POST /api/tasks` to create any Stride task or defect.

**Do NOT use for:**
- Creating goals with nested tasks (use stride-creating-goals instead)
- Batch creation (use stride-creating-goals instead)

## The Cost of Minimal Tasks

**Real impact from Stride production data:**

| Minimal Task | Time Wasted | What Was Missing |
|--------------|-------------|------------------|
| "Add dark mode" | 4.2 hours | Which files, existing patterns, color scheme, persistence |
| "Fix bug in auth" | 3.8 hours | Where in codebase, how to reproduce, expected behavior |
| "Update API endpoint" | 3.5 hours | Which endpoint, what changes, breaking changes, migration |

**Average:** Minimal tasks take **3.7x longer** than well-specified tasks.

## Required Fields Checklist

**Critical fields (task will fail without these):**

- [ ] `title` - Format: `[Verb] [What] [Where]` (e.g., "Add dark mode toggle to settings page")
- [ ] `type` - MUST be exact string: `"work"`, `"defect"`, or `"goal"` (no other values)
- [ ] `description` - WHY this matters + WHAT needs to be done
- [ ] `complexity` - String: `"small"`, `"medium"`, or `"large"`
- [ ] `priority` - String: `"low"`, `"medium"`, `"high"`, or `"critical"`
- [ ] `why` - Problem being solved / value provided
- [ ] `what` - Specific feature or change
- [ ] `where_context` - UI location or code area
- [ ] `key_files` - Array of objects with file_path, note, position
- [ ] `dependencies` - Array of task identifiers (e.g., `["W47", "W48"]`) or indices for new tasks
- [ ] `verification_steps` - Array of objects (NOT strings!)
- [ ] `testing_strategy` - Object with `unit_tests`, `integration_tests`, `manual_tests` as arrays
- [ ] `security_considerations` - Array of strings (security implications to address)
- [ ] `acceptance_criteria` - Newline-separated string
- [ ] `patterns_to_follow` - Newline-separated string with file references
- [ ] `pitfalls` - Array of strings (what NOT to do)

**Recommended fields:**

- [ ] `estimated_files` - Helps set expectations: `"1-2"`, `"3-5"`, or `"5+"`
- [ ] `required_capabilities` - Array of agent skills needed

## Field Type Validations (CRITICAL)

### type field
**MUST be exact string match:**
- ✅ Valid: `"work"`, `"defect"`, `"goal"`
- ❌ Invalid: `"task"`, `"bug"`, `"feature"`, `null`, or any other value

### testing_strategy arrays
**MUST be arrays, not strings:**
- ✅ `"unit_tests": ["Test auth flow", "Test error handling"]`
- ❌ `"unit_tests": "Run unit tests"` (will fail)

### security_considerations array
**MUST be an array of strings, not a single string or object:**
- ✅ `"security_considerations": ["Validate and sanitize the uploaded filename to prevent path traversal", "Authorize the requesting user owns the board before mutating"]`
- ❌ `"security_considerations": "Validate input"` (will fail)

### verification_steps
**MUST be array of objects:**
- ✅ `[{"step_type": "command", "step_text": "mix test", "position": 0}]`
- ❌ `["mix test"]` (array of strings - will crash)
- ❌ `"mix test"` (single string - will crash)

## Dependencies Pattern

**Rule: Use indices for NEW tasks, identifiers for EXISTING tasks**

**For existing tasks** (already in system):
```json
{
  "title": "Add JWT refresh endpoint",
  "type": "work",
  "dependencies": ["W47", "W48"]
}
```

**For new tasks** (being created in same request with a goal):
Use array indices since identifiers don't exist yet - see stride-creating-goals skill.

## Quick Reference: Complete Task Example

```json
{
  "title": "Add dark mode toggle to settings page",
  "type": "work",
  "description": "Users need dark mode to reduce eye strain during night work. Add toggle switch in settings with persistent storage.",
  "complexity": "medium",
  "priority": "high",
  "created_by_agent": "Gemini CLI",
  "why": "Reduce eye strain for users working in low-light environments",
  "what": "Dark mode toggle with theme persistence",
  "where_context": "Settings page - User Preferences section",
  "estimated_files": "3-5",
  "key_files": [
    {
      "file_path": "lib/kanban_web/live/user_live/settings.ex",
      "note": "Add theme preference controls",
      "position": 0
    },
    {
      "file_path": "assets/css/app.css",
      "note": "Dark mode styles",
      "position": 1
    }
  ],
  "dependencies": [],
  "verification_steps": [
    {
      "step_type": "command",
      "step_text": "mix test test/kanban_web/live/user_live/settings_test.exs",
      "expected_result": "All theme tests pass",
      "position": 0
    },
    {
      "step_type": "manual",
      "step_text": "Toggle dark mode in settings and refresh page",
      "expected_result": "Theme persists across sessions",
      "position": 1
    }
  ],
  "testing_strategy": {
    "unit_tests": [
      "Test theme preference update",
      "Test default theme is light"
    ],
    "integration_tests": [
      "Test theme persistence across page loads",
      "Test theme applies to all pages"
    ],
    "manual_tests": [
      "Visual verification of dark mode styles",
      "Test in multiple browsers"
    ],
    "edge_cases": [
      "User with no theme preference set",
      "Rapid toggle switching"
    ],
    "coverage_target": "100% for theme preference logic"
  },
  "security_considerations": [
    "Persist the theme preference scoped to the authenticated user — never trust a client-supplied user_id",
    "Escape the theme value before interpolating it into markup/CSS to avoid injection"
  ],
  "acceptance_criteria": "Toggle appears in settings\nDark mode applies site-wide\nPreference persists across sessions\nAll existing tests still pass",
  "patterns_to_follow": "See lib/kanban_web/live/user_live/settings.ex for preference update pattern\nFollow existing theme structure in app.css",
  "pitfalls": [
    "Don't modify existing color variables - create new dark mode variants",
    "Don't forget to test theme on all major pages",
    "Don't use localStorage directly - use Phoenix user preferences"
  ],
  "technical_details": {
    "data_shapes": {"theme_preference": "one of \"light\" | \"dark\", stored on the user record"},
    "gotchas": ["Apply the theme before first paint to avoid a flash of the wrong theme"]
  }
}
```

`technical_details` is an optional free-form object — see the Embedded Object Formats section below.

`created_by_agent` records **which agent created the task** so the `/agents` activity feed attributes the `created` row to that agent instead of an uninformative `?` avatar. Set it to **the plugin's own agent name — the exact same value you send as `agent_name` on claim and complete** (here, `"Gemini CLI"`). Use the plain agent name, never the `ai_agent:<model>` token form, so one agent stays one roster identity. `created_by_agent` is accepted **only on create** (`POST /api/tasks` and `POST /api/tasks/batch`); it is **forbidden on `PATCH`**, so it cannot be backfilled later — stamp it at creation time.

## Consuming Provided Context

When this skill is dispatched through the orchestrator with a provided context bundle (a **read-only markdown context bundle** — the enumerated `--dir` / directory-path files — plus the user's creation intent), mine that context to populate task fields instead of forcing blind codebase exploration — but **context informs, it never replaces.**

Map the context to fields:

| In the markdown context | Populates |
|---|---|
| File references, paths, modules touched | `key_files` |
| Stated conventions, "follow X", existing-pattern references | `patterns_to_follow` |
| Requirements, goals, definitions of done | `acceptance_criteria` and `description` |
| Risks, "don't do X", known traps, prior failures | `pitfalls` |

**Rules:**

- **Context augments the user's interactive intent — it never silently overrides it.** When the bundle and the user's stated intent disagree, surface the conflict and confirm with the user; do not quietly prefer the document.
- **Context is a source, not a substitute for the contract.** The Required Fields Checklist and the five review_queue-scored fields (`acceptance_criteria`, `testing_strategy`, `security_considerations`, `pitfalls`, `patterns_to_follow`) are **still required** on every task. Context that doesn't cover a required field does not excuse leaving it blank — fill it from the user, the codebase, or sensible defaults.
- **The bundle is read-only.** Consume it as reference material; never edit the source markdown.
- The orchestrator gate still applies: this skill runs only when dispatched from inside `stride-workflow` (see the **STOP — orchestrator check** at the top of this file). A populated context bundle does not change that.

Context-informed creation is faster and better-grounded than blind exploration — but a rich context bundle is a head start on the specification, not a replacement for it.

## Red Flags - STOP

- "I'll just create a simple task"
- "The agent can figure out the details"
- "This is self-explanatory"
- "I'll add details later if needed"
- "Just need title and description"
- "I'll skip acceptance_criteria — it's obvious from the title"
- "testing_strategy doesn't really apply to this one"
- "security_considerations is someone else's problem — I'll leave it empty"
- "pitfalls is just nice-to-have, I'll come back to it"
- "patterns_to_follow can stay empty — the agent has the codebase"

**All of these mean: Add comprehensive details NOW.** The last five also mean: **an empty pill on the review_queue dashboard.**

## Rationalization Table

| Excuse | Reality | Consequence |
|--------|---------|-------------|
| "Simple task, no details needed" | Agent spends 3+ hours exploring | 3+ hours wasted on discovery |
| "Self-explanatory from title" | Missing context causes wrong approach | Wrong solution, must redo |
| "Agent will ask questions" | Breaks flow, causes delays | Back-and-forth wastes 2+ hours |
| "Add details later" | Never happens | Minimal task sits incomplete |
| "Time pressure, need quick" | Rich task saves MORE time | Spending 5 min now saves 3 hours later |
| "acceptance_criteria is obvious from the title" | Reviewers can't grade against a definition that doesn't exist | Empty pill on review_queue + ambiguous "done" |
| "testing_strategy doesn't apply here" | Even doc tasks have verification (render, link-check, grep) | Empty pill on review_queue + no test gate |
| "security_considerations doesn't apply here" | Almost every change touches input, authz, or data exposure; "none — pure styling change" is itself a valid considered answer | Empty pill on review_queue + unreviewed security risk |
| "pitfalls is just nice-to-have" | Pitfalls is the cheapest way to prevent the wrong fix | Empty pill on review_queue + repeat mistakes |
| "patterns_to_follow can stay empty" | Without referenced patterns, the agent invents inconsistent ones | Empty pill on review_queue + style drift |

## Common Mistakes

### Mistake 1: String arrays instead of object arrays
```json
❌ "verification_steps": ["mix test", "mix credo"]
✅ "verification_steps": [
  {"step_type": "command", "step_text": "mix test", "position": 0}
]
```

### Mistake 2: Wrong type value
```json
❌ "type": "task"
❌ "type": "bug"
✅ "type": "work"
✅ "type": "defect"
```

### Mistake 3: Missing key_files
```json
❌ No key_files specified
✅ "key_files": [
  {"file_path": "path/to/file.ex", "note": "Why modifying", "position": 0}
]
```

Result: Another agent claims overlapping task, causing merge conflicts.

### Mistake 4: Vague acceptance criteria
```json
❌ "acceptance_criteria": "Works correctly"
✅ "acceptance_criteria": "Toggle visible in settings\nDark mode applies site-wide\nPreference persists"
```

## Implementation Workflow

1. **Gather context** - Understand the full requirement
2. **Check dependencies** - Are there existing tasks this depends on?
3. **Identify files** - Which files will change?
4. **Define acceptance** - What does "done" look like?
5. **Specify tests** - How will this be verified?
6. **Document pitfalls** - What should be avoided?
7. **Create task** - Use checklist above
8. **Call API** - `POST /api/tasks` with complete JSON

## Real-World Impact

**Before this skill (5 random tasks):**
- Average time to completion: 4.7 hours
- Questions asked: 12 per task
- Rework required: 60% of tasks

**After this skill (5 random tasks):**
- Average time to completion: 1.3 hours
- Questions asked: 1.2 per task
- Rework required: 5% of tasks

**Time savings: 3.4 hours per task (72% reduction)**

## Field Quick Reference

Use these exact values — any other value will be rejected.

| Field | Type | Valid Values | Required |
|-------|------|-------------|----------|
| `type` | enum | `"work"`, `"defect"`, `"goal"` | Yes |
| `priority` | enum | `"low"`, `"medium"`, `"high"`, `"critical"` | Yes |
| `complexity` | enum | `"small"`, `"medium"`, `"large"` | No |
| `needs_review` | boolean | `true`, `false` | No (default: false) |
| `created_by_agent` | string | The plugin's agent name (same as `agent_name` on claim/complete) | No (create-only; forbidden on `PATCH`) |
| `acceptance_criteria` | string | Newline-separated text | No |
| `patterns_to_follow` | string | Newline-separated text | No |
| `dependencies` | array | Task identifiers `["W45", "W46"]` | No |
| `pitfalls` | array | Strings `["Don't do X", "Avoid Y"]` | No |
| `technical_details` | object | Free-form JSON object of any additional technical info | No |

## Embedded Object Formats — WRONG vs RIGHT

### verification_steps

```json
❌ WRONG (strings — will be rejected):
"verification_steps": ["mix test", "mix credo --strict"]

❌ WRONG (missing required fields):
"verification_steps": [{"step_text": "mix test"}]

✅ RIGHT (objects with all required fields):
"verification_steps": [
  {
    "step_type": "command",
    "step_text": "mix test",
    "expected_result": "All tests pass",
    "position": 0
  }
]
```

**Required fields:** `step_type` (`"command"` or `"manual"` only), `step_text`, `position` (integer >= 0)
**Optional fields:** `expected_result`

### key_files

```json
❌ WRONG (strings):
"key_files": ["lib/my_app/tasks.ex"]

❌ WRONG (absolute path):
"key_files": [{"file_path": "/lib/my_app/tasks.ex", "position": 0}]

✅ RIGHT:
"key_files": [
  {
    "file_path": "lib/my_app/tasks.ex",
    "note": "Add query function",
    "position": 0
  }
]
```

**Required fields:** `file_path` (relative, no leading `/` or `..`), `position` (integer >= 0)
**Optional fields:** `note`

### testing_strategy

```json
❌ WRONG (string values for test arrays):
"testing_strategy": {
  "unit_tests": "Test login with valid credentials"
}

✅ RIGHT (arrays of strings):
"testing_strategy": {
  "unit_tests": ["Test valid login", "Test invalid login"],
  "integration_tests": ["Full auth flow"],
  "edge_cases": ["Empty password", "SQL injection"],
  "coverage_target": "100% for auth module"
}
```

**Valid keys:** `unit_tests`, `integration_tests`, `manual_tests`, `edge_cases`, `coverage_target`
**All values** must be strings or arrays of strings.

### security_considerations

```json
❌ WRONG (single string):
"security_considerations": "Sanitize user input"

❌ WRONG (object):
"security_considerations": {"input": "Sanitize user input"}

✅ RIGHT (array of strings):
"security_considerations": [
  "Validate and sanitize the uploaded filename to prevent path traversal",
  "Authorize the requesting user owns the board before mutating",
  "Parameterize the query — never interpolate the search term into raw SQL"
]
```

**Shape:** array of strings, each naming a specific security implication the implementing agent must address (input validation, authorization boundaries, secret handling, injection surfaces, data exposure). If the change genuinely has no security surface, state that explicitly (e.g. `["None — pure CSS/styling change, no input or authz touched"]`) rather than leaving it empty.

### technical_details

```json
❌ WRONG (string — should be an object):
"technical_details": "Uses ULIDs and retries 3x"

✅ RIGHT (free-form object — any keys you like):
"technical_details": {
  "data_shapes": {"event": {"id": "uuid", "type": "string"}},
  "gotchas": ["The webhook retries 3x with backoff", "IDs are ULIDs, not integers"],
  "external_refs": ["https://example.com/api-docs"]
}
```

**Shape:** a free-form JSON object holding any additional technical information that doesn't fit the structured fields — data shapes, gotchas, external references, sequencing notes, anything that helps the implementing agent. **Unlike `testing_strategy`, it has NO fixed `valid_keys`** — use whatever keys best describe the task. It is optional (omit it when there is nothing extra to capture) and is **not** one of the five review_queue-scored fields.

---
**References:** For the full field reference, see `api_schema` in the onboarding response (`GET /api/agent/onboarding`). For endpoint details, see the [API Reference](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md).
