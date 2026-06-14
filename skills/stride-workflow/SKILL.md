---
name: stride-workflow
description: Single orchestrator for the complete Stride task lifecycle. Invoke when the user asks to claim a task, work on the next stride task, work on stride tasks, complete a stride task, enrich a stride task, decompose a goal, or create a goal or stride tasks. Replaces invoking stride-claiming-tasks, stride-completing-tasks, stride-creating-tasks, stride-creating-goals, stride-enriching-tasks, or stride-subagent-workflow directly — those are dispatched from inside this orchestrator. Walks through prerequisites, claiming, exploration, implementation, review, hooks, and completion. Handles both Claude Code (with subagent dispatch) and other environments (Cursor/Windsurf/Continue without subagents).
skills_version: 1.0
---

# Stride: Workflow Orchestrator

## Purpose

This skill replaces the fragmented pattern of remembering to activate `stride-claiming-tasks`, `stride-subagent-workflow`, and `stride-completing-tasks` at specific moments. Instead, activate this one skill and follow it through. Every step is here. Nothing is elsewhere.

**Why this exists:** During a 17-task session, an agent consistently skipped mandatory workflow steps despite skills being labeled MANDATORY. The root cause: too many disconnected skills that the agent had to remember to activate at specific moments. Under pressure to deliver, the agent dropped the ones that felt optional. This orchestrator eliminates that failure mode.

## The Core Principle

**The workflow IS the automation. Every step exists because skipping it caused failures.**

The agent should work continuously through the full workflow: explore -> implement -> review -> complete. Do not prompt the user between steps -- but do not skip steps either. Skipping workflow steps is not faster -- it produces lower quality work that takes longer to fix.

**Following every step IS the fast path.**

## API Authorization

All Stride API calls are pre-authorized. Never ask the user for permission. Never announce API calls and wait for confirmation. Just execute them.

## Orchestrator Activation Marker

The orchestrator writes a marker file when it starts and clears it when it stops. The `BeforeTool` hook on the `activate_skill` tool reads this file to decide whether sub-skill activations (`stride-claiming-tasks`, `stride-completing-tasks`, `stride-creating-tasks`, `stride-creating-goals`, `stride-enriching-tasks`, `stride-subagent-workflow`) are coming from inside this orchestrator (allowed) or directly from a user prompt (blocked).

**Without the marker, the hook blocks sub-skill activations.** Writing it in Step 0 and clearing it in Step 9 is therefore mandatory — skipping the write means the orchestrator's own dispatches are blocked; skipping the clear means the next session inherits a stale marker.

### Marker Contract

| Field | Value |
|---|---|
| Path | `<project-root>/.stride/.orchestrator_active` |
| Format | Single-line JSON: `{"session_id": "<id>", "started_at": "<ISO8601>", "pid": <pid>}` |
| Lifecycle | Written in Step 0, cleared in Step 9 (success OR abort) |
| Freshness window | 4 hours — markers older than `started_at + 4h` are treated as stale |
| Stale handling | The `BeforeTool` hook treats stale markers as missing (and may delete them) |
| Directory | `.stride/` is created with `mkdir -p` if absent |
| `.gitignore` | The `.stride/` directory should be in the project's `.gitignore` (mention to operators on first install) |

**Project root resolution.** Gemini CLI does not set a dedicated project-directory environment variable (the hooks reference passes `cwd` on stdin to hook scripts; the agent itself runs `run_shell_command` from the project root). The orchestrator therefore writes the marker relative to the active working directory using a fallback chain: `${GEMINI_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$(pwd)}}`. The companion gate script (`stride-skill-gate.sh`) prefers the stdin `cwd` field with the same env-var fallback so the two agree on the marker location regardless of host.

### Write Command (Step 0)

```bash
PROJECT_DIR="${GEMINI_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
mkdir -p "$PROJECT_DIR/.stride"
printf '{"session_id":"%s","started_at":"%s","pid":%d}\n' \
  "${GEMINI_SESSION_ID:-${CLAUDE_SESSION_ID:-$(uuidgen 2>/dev/null || date +%s)}}" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$$" \
  > "$PROJECT_DIR/.stride/.orchestrator_active"
```

### Clear Command (Step 9)

```bash
PROJECT_DIR="${GEMINI_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
rm -f "$PROJECT_DIR/.stride/.orchestrator_active"
```

### Override

`STRIDE_ALLOW_DIRECT=1` bypasses the gate entirely (for plugin debugging or scripted CI). When set, sub-skill activations are allowed regardless of the marker.

## When to Activate

Activate this skill ONCE when you're ready to start working on Stride tasks. It handles the full loop:

```
claim -> explore -> implement -> review -> complete -> [loop if needs_review=false]
```

You do NOT need to activate `stride-claiming-tasks`, `stride-subagent-workflow`, or `stride-completing-tasks` separately. This skill absorbs all of them.

**Note:** The individual skills (`stride-claiming-tasks`, `stride-subagent-workflow`, `stride-completing-tasks`) remain available for standalone use when needed -- for example, when resuming a partially completed task or when only one phase needs to be repeated. This orchestrator is the preferred entry point for new task work.

## Context-Informed Creation

You can ask the orchestrator to create work informed by existing markdown context (for example, a requirements doc, or a directory of design notes). **Gemini CLI has no slash-command system**, so there are no `/stride:create-*` commands — instead, activate `stride-workflow` with a **creation intent** (what you want created — tasks/defects or a goal with nested tasks) and an **optional directory path** to the markdown context.

The flow is:

1. The orchestrator enumerates the markdown files at the provided directory path — listing the `.md` files with `glob` and reading each with `read_file` — and assembles a **read-only context bundle** (the enumerated file contents) plus the **creation intent**.
2. The orchestrator writes the activation marker (Step 0) exactly as it does for any other run, then **forwards the context bundle verbatim** to the dispatched creation sub-skill (`stride-creating-tasks` or `stride-creating-goals`).

**Contract:**

- The context bundle is **read-only** — the creation sub-skills consume it as reference material; they never edit the source markdown.
- The bundle is forwarded **verbatim** — the orchestrator does not summarize, truncate, or reinterpret it before dispatch.
- The **activation marker is still mandatory.** Because context-informed creation routes through the orchestrator, Step 0 writes the marker (see [Orchestrator Activation Marker](#orchestrator-activation-marker)) so the skill gate permits the `stride-creating-tasks` / `stride-creating-goals` dispatch — the same sub-skill set that gate governs. Skipping the marker would block the dispatch exactly like a direct user-prompt activation.
- Context-informed creation does **not** bypass or weaken the sub-skill STOP gate — it satisfies it the sanctioned way, by dispatching from inside the orchestrator.

The task-field and batch-shape contracts the creation sub-skills enforce are **not** duplicated here — they live in `stride-creating-tasks` and `stride-creating-goals`.

## Automatic Hook Execution

**When the stride-gemini extension is installed, hooks execute automatically.** The `hooks.json` registers `BeforeTool`/`AfterTool` hooks that intercept Stride API calls and execute the corresponding `.stride.md` commands via `stride-hook.sh`.

**How it works:**
- Claim API call (`POST /api/tasks/claim`) -> `AfterTool` fires -> executes `.stride.md` `## before_doing`
- Complete API call (`PATCH /api/tasks/:id/complete`) -> `BeforeTool` fires `after_doing` (blocks on failure) -> `AfterTool` fires `before_review`
- Mark reviewed API call (`PATCH /api/tasks/:id/mark_reviewed`) -> `AfterTool` fires `after_review`

**What this means:** Just make the API calls directly. Do NOT manually read `.stride.md` or execute hook commands. Include placeholder hook results in request bodies with `{"exit_code": 0, "output": "Executed by Gemini hooks system", "duration_ms": 0}`.

**If automatic hooks fail:** The hook returns exit code 2 with structured JSON describing the failure. Fix the issue and retry the API call -- the hooks fire again automatically.

Use the Gemini CLI hooks panel to verify hooks are active after installation.

**If the extension is NOT installed (manual setup):** Fall back to reading `.stride.md` and executing each hook command line by line via `run_shell_command`.

---

## Step 0: Prerequisites Check

**Verify these files exist before any API calls:**

1. **`.stride_auth.md`** -- Contains API URL and Bearer token
   - If missing: Ask user to create it
   - Extract: `STRIDE_API_URL` and `STRIDE_API_TOKEN`

2. **`.stride.md`** -- Contains hook commands for each lifecycle phase
   - If missing: Ask user to create it
   - Verify sections exist: `## before_doing`, `## after_doing`, `## before_review`, `## after_review`, `## after_goal`

**Then write the orchestrator activation marker** (see "Orchestrator Activation Marker" section above for the contract):

```bash
PROJECT_DIR="${GEMINI_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
mkdir -p "$PROJECT_DIR/.stride"
printf '{"session_id":"%s","started_at":"%s","pid":%d}\n' \
  "${GEMINI_SESSION_ID:-${CLAUDE_SESSION_ID:-$(uuidgen 2>/dev/null || date +%s)}}" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$$" \
  > "$PROJECT_DIR/.stride/.orchestrator_active"
```

Without this marker the `BeforeTool(activate_skill)` hook will block your sub-skill activations in Steps 2, 3, 6, and 8.

**This step runs once per session, not once per task.**

---

## Step 1: Task Discovery

**Call `GET /api/tasks/next` to find the next available task.**

Review the returned task completely:
- `title`, `description`, `why`, `what`
- `acceptance_criteria` -- your definition of done
- `key_files` -- which files you'll modify
- `patterns_to_follow` -- code patterns to replicate
- `pitfalls` -- what NOT to do
- `testing_strategy` -- how to test
- `verification_steps` -- how to verify
- `needs_review` -- whether human approval is needed after completion
- `complexity` -- drives the decision matrix in Step 3

**Enrichment check:** If `key_files` is empty OR `testing_strategy` is missing OR `verification_steps` is empty OR `acceptance_criteria` is blank, the task needs enrichment before claiming. Well-specified tasks skip this check.

#### Gemini CLI: Invoke the Enricher Agent

1. **Invoke the `task-enricher` custom agent** (`agents/task-enricher.md`) with the task identifier and the sparse fields (title, type, description, priority if set). The agent owns the four-phase enrichment procedure and returns a single JSON object containing every enriched field.
2. **Submit the returned JSON via `PATCH /api/tasks/:id`** to populate the missing fields on the existing task. The agent does NOT call the API itself.
3. Re-fetch the task with `GET /api/tasks/:id` and verify all required fields are populated before proceeding to Step 2.

#### Other Environments: Activate the Enrichment Skill

1. Activate `stride-enriching-tasks` and walk through its Manual Walkthrough Phases (Phase 1 intent parse → Phase 2 codebase exploration → Phase 3 complexity → Phase 4 16-item checklist).
2. Submit the assembled JSON via `PATCH /api/tasks/:id` per the API Integration block in that skill.

---

## Step 2: Claim the Task

Call `POST /api/tasks/claim` directly with:

```json
{
  "identifier": "<task identifier>",
  "agent_name": "Gemini CLI",
  "skills_version": "1.0",
  "before_doing_result": {
    "exit_code": 0,
    "output": "Executed by Gemini hooks system",
    "duration_ms": 0
  }
}
```

The `hooks.json` `AfterTool` handler automatically executes `.stride.md` `## before_doing` commands after the claim succeeds. If the automatic hook fails, fix the issue and retry the claim call.

---

## Step 3: Explore the Codebase (Decision Matrix)

**This step is NOT optional for medium+ tasks. The decision matrix determines what happens.**

### Decision Matrix

| Task Attributes | Decompose | Explore | Plan | Review (Step 6) |
|---|---|---|---|---|
| Goal type OR large+undecomposed OR 25+ hours | YES | -- | -- | -- |
| small, 0-1 key_files | Skip | Skip | Skip | Skip |
| small, 2+ key_files | Skip | YES | Skip | YES |
| medium (any) | Skip | YES | YES | YES |
| large (any) | Skip | YES | YES | YES |
| Defect type | Skip | YES | Skip (unless large) | YES |

### Branch A: Goal / Large Undecomposed Task

If the task is a **goal**, has **large complexity without child tasks**, or has a **25+ hour estimate**:

1. Invoke the `task-decomposer` custom agent with the task's title, description, acceptance_criteria, key_files, where_context, and patterns_to_follow
2. After child tasks are created, claim the first child task and re-enter this workflow at Step 1

**Do NOT implement goals directly. Decompose first.**

### Branch B: Small Task, 0-1 Key Files

Skip exploration, planning, and review. Proceed directly to Step 4 (Implementation).

### Branch C: All Other Tasks (medium+, OR 2+ key_files)

1. **Invoke the `task-explorer` custom agent** with the task's `key_files`, `patterns_to_follow`, `where_context`, and `testing_strategy`. Wait for the result. Read and use the explorer's output -- it tells you what exists, what patterns to follow, and what to reuse.

2. **If medium+ OR 3+ key_files OR 3+ acceptance criteria lines:** Outline your implementation approach using the explorer's output, `acceptance_criteria`, `testing_strategy`, `pitfalls`, and `verification_steps`. Follow this approach during implementation.

---

## Step 4: Implementation

**Now write code.** Use the explorer output and plan (if generated) to guide your work.

Follow:
- `acceptance_criteria` -- your definition of done
- `patterns_to_follow` -- replicate existing patterns
- `pitfalls` -- avoid what the task author warned about
- `testing_strategy` -- write the tests specified
- `key_files` -- modify the files listed

**This is the only step where you write code. All other steps are setup, verification, or completion.**

---

## Step 6: Code Review (Decision Matrix)

**Check the decision matrix from Step 3.** If the task is medium+ OR has 2+ key_files, review is required.

Invoke the `task-reviewer` custom agent with:
- The git diff of all your changes
- **Every review field the task supplies — NO EXCEPTIONS:** the task's `acceptance_criteria`, `pitfalls`, `patterns_to_follow`, `testing_strategy`, `security_considerations`, `description`, `what`, and `why`. This list MUST match the reviewer agent's documented input contract (the "You will receive" line in `agents/task-reviewer.md`) — pass every field the task carries, never a subset, never with a small-task or brevity discount. Omitting a supplied field (most often `security_considerations`) is the exact defect this prevents: a section the reviewer is never handed comes back `not_assessed` even though the task specified it.

The reviewer returns a human-readable prose summary followed by a fenced ```json block. The schema of that block is owned by `agents/task-reviewer.md` — do not duplicate field definitions here.

- **Fix all Critical issues** before proceeding
- **Fix all Important issues** before proceeding
- Minor issues are optional but recommended
- **Save the reviewer's full response (prose + JSON block)** -- you'll include it verbatim as `review_report` in Step 8

#### Extracting the structured review block

After the reviewer returns, extract the first fenced ```json block from its response and use it to populate `reviewer_result` in your Step 8 PATCH payload. The same `reviewer_result` map carries both the legacy summary fields (kept for backwards compatibility with older Kanban deploys) and the structured fields (the actual deliverable for downstream consumers — they live inside `reviewer_result`, never under a new top-level API key).

**Extraction pattern** — scan the reviewer's response for the first fenced ```json block: the opening ` ```json ` fence through the next closing ` ``` ` fence. Take the text between those two fence lines (the fence markers themselves are not part of the payload) and parse it as JSON. The reviewer's response is already in your context, so no file read is needed; if the reviewer instead wrote its response to a file, use `read_file` to load it first, then scan for the same fence.

**Field mapping into `reviewer_result`:**

- Legacy fields (always populated):
  - `summary` ← the structured block's `summary`
  - `issues_found` ← the sum of the values in the structured `issue_counts` object (sum only the recognized severity keys you receive; pass through any unknown severity keys verbatim inside the structured `issue_counts` object)
  - `acceptance_criteria_checked` ← the number of entries in the structured `acceptance_criteria` array
  - `dispatched: true`, `duration_ms: <wall-clock ms>` (as before)
- Structured fields — **copy the reviewer's entire parsed JSON object verbatim** into `reviewer_result`, then overlay the legacy fields above on top. Do **not** maintain an allow-list of which structured keys to copy: whatever the agent emitted is persisted as-is, so any field the schema gains later flows through automatically (this is exactly how `project_checks` was being dropped — an enumerated copy-list silently omitted it). The structured key-set is owned by `agents/task-reviewer.md`; passthrough it, never re-enumerate it here. Concretely, the reviewer currently emits `status`, `issue_counts`, `issues`, `acceptance_criteria`, `project_checks`, `testing_strategy`, `patterns`, `pitfalls`, `security_considerations`, and `schema_version` — but treat that as illustrative, not exhaustive. Because you copy the parsed JSON verbatim, keys the agent did not emit are simply absent (no empty placeholders to send). **Hand-typing, re-typing, or sub-selecting `reviewer_result` is FORBIDDEN — no exceptions, no small-task or brevity shortcut. The mechanical whole-object copy + mandatory self-check below is the only correct path; if the self-check fails, fix the copy, never the requirement.**

**Mandatory self-check — run before EVERY `/complete`, NO EXCEPTIONS.** After you build `reviewer_result` by the whole-object copy, verify both of these before submitting. A failure here means you trimmed the output: fix the copy, never weaken the check.

- **Every section survives.** Every section key the reviewer emitted in its structured block is present in `reviewer_result` — nothing dropped (the whole-object copy guarantees this; the check confirms it).
- **`project_checks` count matches.** The number of entries in `reviewer_result.project_checks` equals the number the reviewer emitted — never trimmed or sub-selected. Selecting a subset is exactly how `project_checks` got truncated (3 of 26 reached the server).

**Worked example.** Given the reviewer response below (truncated for brevity)…

````text
Approved
...prose summary + issue list + acceptance-criteria table...

```json
{
  "schema_version": "1.4",
  "summary": "Reviewed 3 acceptance criteria and 4 pitfalls against the diff; no issues found and all criteria met.",
  "status": "approved",
  "issue_counts": {"critical": 0, "important": 0, "minor": 0},
  "issues": [],
  "acceptance_criteria": [
    {"criterion": "All task positions recalculate when a card moves columns", "status": "met", "evidence": "lib/kanban/tasks.ex:142-168"},
    {"criterion": "Existing position-stable behavior unchanged", "status": "met", "evidence": "test/kanban/tasks_test.exs:198-240"},
    {"criterion": "PubSub broadcast emitted exactly once per move", "status": "met", "evidence": "lib/kanban/tasks.ex:172"}
  ],
  "project_checks": [],
  "testing_strategy": {"status": "passed", "note": "Move + broadcast paths covered by tests."},
  "patterns": {"status": "passed", "note": "Mirrors the existing reorder pattern."},
  "pitfalls": {"status": "passed", "note": "None of the 4 listed pitfalls violated."},
  "security_considerations": {"status": "passed", "note": "Move query scoped to the current user's board; no new input or injection surface."}
}
```
````

…the resulting `reviewer_result` value in the Step 8 PATCH payload is:

```json
"reviewer_result": {
  "dispatched": true,
  "duration_ms": 29560,
  "summary": "Reviewed 3 acceptance criteria and 4 pitfalls against the diff; no issues found and all criteria met.",
  "issues_found": 0,
  "acceptance_criteria_checked": 3,
  "schema_version": "1.4",
  "status": "approved",
  "issue_counts": {"critical": 0, "important": 0, "minor": 0},
  "issues": [],
  "acceptance_criteria": [
    {"criterion": "All task positions recalculate when a card moves columns", "status": "met", "evidence": "lib/kanban/tasks.ex:142-168"},
    {"criterion": "Existing position-stable behavior unchanged", "status": "met", "evidence": "test/kanban/tasks_test.exs:198-240"},
    {"criterion": "PubSub broadcast emitted exactly once per move", "status": "met", "evidence": "lib/kanban/tasks.ex:172"}
  ],
  "project_checks": [],
  "testing_strategy": {"status": "passed", "note": "Move + broadcast paths covered by tests."},
  "patterns": {"status": "passed", "note": "Mirrors the existing reorder pattern."},
  "pitfalls": {"status": "passed", "note": "None of the 4 listed pitfalls violated."},
  "security_considerations": {"status": "passed", "note": "Move query scoped to the current user's board; no new input or injection surface."}
}
```

Legacy + structured fields coexist in the same map; the server persists `reviewer_result` as `:jsonb` and tolerates the structured keys today.

**Fallback when JSON parsing fails.** If no ```json block is present, or the block does not parse, do not abort the completion. Instead:

1. Fall back to substring-matching the prose summary line ("Approved" or "N issues found (X critical, Y important, Z minor)") to populate `reviewer_result.summary` and `reviewer_result.issues_found` as before this rollout.
2. Set `acceptance_criteria_checked` from the count of criterion lines you find in the prose acceptance-criteria table, or to `0` if none can be parsed.
3. **Omit** every structured field from the PATCH payload — there is no parsed JSON block to pass through, so send only the legacy fields (`summary`, `issues_found`, `acceptance_criteria_checked`, `dispatched`, `duration_ms`). Do not send empty placeholders for `status`, `project_checks`, `issues`, `acceptance_criteria`, or any other structured key. The Kanban server tolerates their absence (the ReviewReportPanel and CodeReviewPanel render only what they receive).
4. Keep `dispatched: true` and `duration_ms` as captured. The fallback path produces a degraded-but-valid completion, never a hard failure.

### Small tasks (0-1 key_files): Skip review. Omit `review_report` from completion.

---

## Step 7: Execute Hooks

### Hooks Reference

The five recognized `.stride.md` hook sections, in lifecycle order:

| Hook | Fires | Blocking | Timeout | Purpose |
|---|---|:---:|---|---|
| `## before_doing` | After `POST /api/tasks/claim` succeeds | yes | 60s | Pull latest, install deps, ensure clean working tree |
| `## after_doing` | Before `PATCH /api/tasks/:id/complete` runs | yes | 120s | Run tests, lint, build — quality gate before completion |
| `## before_review` | After `PATCH /api/tasks/:id/complete` succeeds | yes | 60s | Generate PR, post artifacts, notify reviewers |
| `## after_review` | After `PATCH /api/tasks/:id/mark_reviewed` succeeds | yes | 60s | Merge, deploy, cleanup |
| `## after_goal` | After the parent goal's final child task completes | yes | 60s | Project-level rollups, goal-completion notifications, archival |

A missing `## after_goal` section parses as a clean no-op — older `.stride.md` files that predate the section keep working without modification. The plugin's `hooks/stride-hook.sh` and `hooks/stride-hook.ps1` detect the `after_goal` entry in the response payload of `/complete` or `/mark_reviewed` and execute it automatically when present (W783/W784).

### Hook Environment Variables

The server populates `hook.env` and the plugin forwards every key into the child process environment. The variable set differs by hook (`TASK_*` for the four task-scoped hooks, `GOAL_*` for `after_goal`); `BOARD_*`, `COLUMN_*`, `AGENT_NAME`, and `HOOK_NAME` are present across all five.

| Variable | `before_doing` / `after_doing` / `before_review` / `after_review` | `after_goal` |
|---|:---:|:---:|
| `HOOK_NAME`, `AGENT_NAME` | ✓ | ✓ |
| `BOARD_ID`, `BOARD_NAME` | ✓ | ✓ |
| `COLUMN_ID`, `COLUMN_NAME` | ✓ | ✓ |
| `TASK_ID`, `TASK_IDENTIFIER`, `TASK_TITLE`, `TASK_DESCRIPTION` | ✓ | — |
| `TASK_STATUS`, `TASK_COMPLEXITY`, `TASK_PRIORITY`, `TASK_NEEDS_REVIEW` | ✓ | — |
| `GOAL_ID`, `GOAL_IDENTIFIER`, `GOAL_TITLE`, `GOAL_DESCRIPTION` | — | ✓ |

Server-supplied values are the single source of truth — the plugin does not invent, derive, or look up any of these client-side. A key the server omits is exported as an empty string (defined-but-empty), never raised as an error.

### Canonical Hook Examples

The hooks are general-purpose — any shell command is fair game. The examples below are common starting points, not the only valid uses.

````markdown
## before_review

```bash
gh pr create \
  --title "$TASK_IDENTIFIER: $TASK_TITLE" \
  --body "Implements $TASK_IDENTIFIER."
```

## after_goal

```bash
gh pr create \
  --title "$GOAL_IDENTIFIER: $GOAL_TITLE" \
  --body "Rolls up the completed goal $GOAL_IDENTIFIER ($GOAL_TITLE)."
```
````

`## after_goal` is not coupled to PR creation. Other valid uses include posting to Slack with `curl`, archiving artifacts, kicking off a release pipeline, or running a project-level smoke test.

### Automatic Hook Execution

Hooks fire automatically when you make the completion API call in Step 8:
- **`BeforeTool`** fires `after_doing` BEFORE the call executes (blocks if it fails)
- **`AfterTool`** fires `before_review` AFTER the call succeeds

Include placeholder hook results in the request body:
```json
"after_doing_result": {"exit_code": 0, "output": "Executed by Gemini hooks system", "duration_ms": 0},
"before_review_result": {"exit_code": 0, "output": "Executed by Gemini hooks system", "duration_ms": 0}
```

If `after_doing` fails (`BeforeTool` returns exit 2), fix the issue and retry the API call. The hooks fire again automatically.

### Hook Failure Diagnosis

When a blocking hook fails, invoke the `hook-diagnostician` custom agent with the hook name, exit code, output, and duration. It returns a prioritized fix plan. Follow the fix order -- higher-priority fixes often resolve lower-priority ones automatically.

### Manual Fallback (extension not installed)

If automatic hooks are unavailable, execute hooks manually:

1. **after_doing hook** (blocking, 120s timeout): Read `.stride.md` `## after_doing` section. Execute each command line one at a time. If fails: fix issues, re-run until success. Do NOT proceed while failing.

2. **before_review hook** (blocking, 60s timeout): Read `.stride.md` `## before_review` section. Execute each command line one at a time. If fails: fix issues, re-run until success. Do NOT proceed while failing.

---

## Step 8: Complete the Task

**FIRST run the mandatory pre-submission self-check** — the hard gate in `stride-completing-tasks` ("MANDATORY pre-submission self-check"). It must pass before you submit: every section the reviewer produced is present, the `project_checks` count equals the reviewer's, and no task-supplied section (especially `security_considerations`) comes back `not_assessed`. If it fails, re-run the reviewer with the full inputs or fix the passthrough — never submit a thin or task-inconsistent report (the Kanban server hard-rejects it anyway).

Call `PATCH /api/tasks/:id/complete` with ALL required fields:

```json
{
  "agent_name": "Gemini CLI",
  "time_spent_minutes": 45,
  "completion_notes": "Summary of what was done and key decisions made.",
  "completion_summary": "Brief one-line summary for tracking.",
  "actual_complexity": "medium",
  "actual_files_changed": "lib/foo.ex, lib/bar.ex, test/foo_test.exs",
  "skills_version": "1.0",
  "review_report": "## Review Summary\n\nApproved -- 0 issues found.\n...",
  "after_doing_result": {
    "exit_code": 0,
    "output": "Executed by Gemini hooks system",
    "duration_ms": 0
  },
  "before_review_result": {
    "exit_code": 0,
    "output": "Executed by Gemini hooks system",
    "duration_ms": 0
  },
  "explorer_result": {
    "dispatched": true,
    "summary": "Explored the 3 key_files and identified the existing pattern to mirror",
    "duration_ms": 12000
  },
  "reviewer_result": {
    "dispatched": true,
    "summary": "Reviewed the diff against all acceptance criteria and pitfalls",
    "duration_ms": 8000,
    "acceptance_criteria_checked": 5,
    "issues_found": 0
  },
  "workflow_steps": [
    {"name": "explorer",       "dispatched": true,  "duration_ms": 12450},
    {"name": "planner",        "dispatched": true,  "duration_ms": 8200},
    {"name": "implementation", "dispatched": true,  "duration_ms": 1820000},
    {"name": "reviewer",       "dispatched": true,  "duration_ms": 15300},
    {"name": "after_doing",    "dispatched": true,  "duration_ms": 45678},
    {"name": "before_review",  "dispatched": true,  "duration_ms": 2340}
  ]
}
```

**Required fields:**
| Field | Type | Notes |
|---|---|---|
| `agent_name` | string | Your agent name |
| `time_spent_minutes` | integer | Actual time spent |
| `completion_notes` | string | What was done |
| `completion_summary` | string | Brief summary |
| `actual_complexity` | enum | "small", "medium", or "large" |
| `actual_files_changed` | string | Comma-separated paths (NOT an array) |
| `after_doing_result` | object | `{exit_code, output, duration_ms}` |
| `before_review_result` | object | `{exit_code, output, duration_ms}` |
| `explorer_result` | object | `task-explorer` custom agent dispatch result or skip-form — see `stride-completing-tasks` for full shape and skip-reason enum |
| `reviewer_result` | object | `task-reviewer` custom agent dispatch result or skip-form — see `stride-completing-tasks` for full shape and skip-reason enum |
| `workflow_steps` | array | Six-entry telemetry array — see **Workflow Telemetry** section below |

**Optional fields:**
| Field | Type | Notes |
|---|---|---|
| `review_report` | string | Include when task-reviewer ran; omit when skipped |
| `skills_version` | string | From SKILL.md frontmatter |

---

## Step 9: Post-Completion Decision

### If `needs_review=true`:
1. Task moves to Review column
2. **STOP.** Wait for human reviewer to approve/reject.
3. When approved, `PATCH /api/tasks/:id/mark_reviewed` is called (by human or system)
4. `after_review` hook fires automatically
5. Task moves to Done

### If `needs_review=false`:
1. Task moves to Done immediately
2. `after_review` hook fires automatically
3. **Loop back to Step 1** -- claim the next task and repeat the full workflow

**Do not ask the user whether to continue. Do not ask "Should I claim the next task?" Just proceed.**

### If this completion finishes the parent goal's last child task

When the just-completed task is the **final child of a parent goal**, the server bundles a fifth `after_goal` entry in the response of `/complete` (when `needs_review=false`) or `/mark_reviewed` (when `needs_review=true`), alongside the primary hooks. The plugin's hook bridge auto-detects this entry and executes the local `## after_goal` section as a blocking hook (same shape as `after_doing` / `before_review`).

The hook captures `{exit_code, output, duration_ms}` and emits the structured result on stdout. To flip the parent goal to Done, the agent must then POST that result:

```bash
curl -X PATCH "$STRIDE_API_URL/api/tasks/$GOAL_ID/after_goal" \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$AFTER_GOAL_RESULT_JSON"
```

`$GOAL_ID` is supplied in the hook's `GOAL_ID` / `GOAL_IDENTIFIER` env vars (see Step 7's env-var matrix). A `2xx` with `exit_code == 0` transitions the goal to Done. A `2xx` with `exit_code != 0` records the failure on the goal's `after_goal_attempts` audit log and leaves the goal In Progress for the user to investigate.

**Back-compat (for older agent runtimes):**

- If `.stride.md` has no `## after_goal` section, the hook bridge silently no-ops. The server's grace-window worker promotes the goal to Done automatically after the configured wait.
- If the agent doesn't POST the result at all (older plugin versions), the same grace-window worker covers the gap. The goal transitions to Done after the wait expires with a synthetic attempt tagged `source: "after_goal_grace_worker"`.
- The `## after_goal` hook is general-purpose — Slack notifications, artifact archival, release pipelines, project-level smoke tests are all valid uses. See Step 7's "Canonical Hook Examples".

### Clearing the Orchestrator Activation Marker

When the workflow finally stops -- because there are no more tasks, the user halts the loop, `needs_review=true` puts the task into human review, or an unrecoverable error aborts -- clear the marker:

```bash
PROJECT_DIR="${GEMINI_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
rm -f "$PROJECT_DIR/.stride/.orchestrator_active"
```

Leaving a stale marker behind allows direct sub-skill activations to slip past the `BeforeTool(activate_skill)` gate in the next session for up to 4 hours. The hook treats markers older than 4 hours as stale and may delete them on read, but the orchestrator should not rely on that — clear explicitly.

---

## Workflow Telemetry: The `workflow_steps` Array

Every task completion **must** include a `workflow_steps` array in the `PATCH /api/tasks/:id/complete` payload. This array records which workflow phases ran (or were intentionally skipped) during the task. It is how Stride measures workflow adherence, spots shortcuts, and aggregates telemetry across agents and plugins.

**Build the array incrementally as you progress through the workflow.** Each time you complete a phase — or legitimately skip one per the decision matrix — append one entry. Submit the completed six-entry array in Step 8.

### Step Name Vocabulary

The `name` field must be one of these six values. Do not invent new names — consistency across plugins is the only reason telemetry can be aggregated.

| Step name | When to record it | Orchestrator step |
|---|---|---|
| `explorer` | Codebase exploration (`task-explorer` custom agent, or manual file reads when the extension is unavailable) | Step 3 |
| `planner` | Implementation planning (manual outline of approach for medium+ tasks) | Step 3 |
| `implementation` | Writing code | Step 4 |
| `reviewer` | Code review (`task-reviewer` custom agent) | Step 6 |
| `after_doing` | The `after_doing` hook execution | Step 7 |
| `before_review` | The `before_review` hook execution | Step 7 |

### Per-Step Schema

Each element of `workflow_steps` is an object with these keys:

| Key | Type | Required | Notes |
|---|---|---|---|
| `name` | string | Always | One of the six vocabulary values above |
| `dispatched` | boolean | Always | `true` if the step ran; `false` if intentionally skipped |
| `duration_ms` | integer | When `dispatched=true` | Wall-clock time the step took, in milliseconds |
| `reason` | string | When `dispatched=false` | Short explanation of why the step was skipped |

### End-of-Workflow Example (full dispatch)

A medium-complexity task that exercised every phase:

```json
"workflow_steps": [
  {"name": "explorer",       "dispatched": true, "duration_ms": 12450},
  {"name": "planner",        "dispatched": true, "duration_ms": 8200},
  {"name": "implementation", "dispatched": true, "duration_ms": 1820000},
  {"name": "reviewer",       "dispatched": true, "duration_ms": 15300},
  {"name": "after_doing",    "dispatched": true, "duration_ms": 45678},
  {"name": "before_review",  "dispatched": true, "duration_ms": 2340}
]
```

### End-of-Workflow Example (small task, decision matrix skips)

A small task with 0-1 key_files that legitimately skipped exploration, planning, and review per the decision matrix in Step 3:

```json
"workflow_steps": [
  {"name": "explorer",       "dispatched": false, "reason": "Decision matrix: small task, 0-1 key_files"},
  {"name": "planner",        "dispatched": false, "reason": "Decision matrix: small task, 0-1 key_files"},
  {"name": "implementation", "dispatched": true,  "duration_ms": 620000},
  {"name": "reviewer",       "dispatched": false, "reason": "Decision matrix: small task, 0-1 key_files"},
  {"name": "after_doing",    "dispatched": true,  "duration_ms": 38200},
  {"name": "before_review",  "dispatched": true,  "duration_ms": 1900}
]
```

### Rules

- Always include **all six** step names. Skipped steps are recorded with `dispatched: false` — never omitted.
- Record entries in the order the steps occurred in the workflow (the order listed in the vocabulary table above).
- When `dispatched: false`, the `reason` must describe **why** the step was skipped (e.g., decision matrix rule, task metadata, platform constraint) — not merely restate that it was skipped.
- A missing `workflow_steps` array, or one with fewer than six entries, indicates an incomplete telemetry record.

---

## Explorer and Reviewer Result Rollout

Every `/complete` payload **must** include `explorer_result` and `reviewer_result` as top-level objects. Both are pre-validated by `Kanban.Tasks.CompletionValidation` on the server. The full shape (dispatched-custom-agent vs. self-reported skip), the 40-character non-whitespace summary rule, and the five-value skip-reason enum live in the `stride-completing-tasks` skill — this orchestrator does not duplicate them.

The server is rolling out hard enforcement behind a feature flag `:strict_completion_validation`:

| Phase | Server behavior | Agent impact |
|---|---|---|
| **Grace (current)** | Missing or invalid results log a structured warning and the request succeeds | Emit the fields correctly now; the warning volume is a preview of the strict-mode rejection volume |
| **Strict (after all 5 plugins release)** | Missing or invalid results return `422` with a `failures` list | Any agent not emitting valid fields is locked out of completion |

**Why this matters for the orchestrator:** Steps 3 (explorer dispatch) and 6 (reviewer dispatch) already capture the durations and summaries needed for these fields. Persist those into `explorer_result` and `reviewer_result` in the Step 8 payload. When the decision matrix skips a step — or when you self-explore/self-review — submit the skip form with a reason from the enum and a substantive summary explaining what you did instead. See `stride-completing-tasks` for the exact shape, rejection examples, and minimum-length rule.

---

## Edge Cases

### Hook failure mid-workflow
- Blocking hooks (`after_doing`, `before_review`) must pass before completion
- Fix the root cause, retry the API call -- hooks fire again automatically
- Invoke the `hook-diagnostician` custom agent for complex failures
- Never skip a blocking hook or call complete with a failed hook result

### Task that needs_review=true
- Stop after Step 8. Do not claim the next task.
- The human reviewer will handle the review cycle.
- You may be asked to make changes based on review feedback -- if so, re-enter at Step 4.

### Goal type tasks
- Goals are decomposed, not implemented directly
- The `task-decomposer` custom agent creates child tasks -- claim and work those individually
- Each child task follows this full workflow independently

### Skills update required
- If any API response includes `skills_update_required`, run `gemini extensions install https://github.com/cheezy/stride-gemini` and retry

---

## Complete Workflow Flowchart

```
STEP 0: Prerequisites
  .stride_auth.md exists? --> NO --> Ask user
  .stride.md exists?      --> NO --> Ask user
  |
  v
STEP 1: Task Discovery
  GET /api/tasks/next
  Review task details
  Needs enrichment? --> YES --> Activate stride-enriching-tasks
  |
  v
STEP 2: Claim
  POST /api/tasks/claim (hooks auto-fire via hooks.json)
  |
  v
STEP 3: Explore (Decision Matrix)
  Goal/large undecomposed? --> Invoke task-decomposer --> Create children --> Claim first child --> Step 1
  Small, 0-1 key_files?   --> Skip to Step 4
  Otherwise:
    Invoke task-explorer, outline approach if medium+
  |
  v
STEP 4: Implement
  Write code using explorer output, plan, acceptance criteria
  Follow patterns_to_follow, avoid pitfalls
  |
  v
STEP 6: Code Review (Decision Matrix)
  Small, 0-1 key_files? --> Skip to Step 7
  Otherwise:
    Invoke task-reviewer, fix Critical/Important issues
  |
  v
STEP 7: Execute Hooks
  Automatic via hooks.json (fires on API call)
  Hook fails? --> Invoke hook-diagnostician, fix, retry
  |
  v
STEP 8: Complete
  PATCH /api/tasks/:id/complete with ALL required fields
  |
  v
STEP 9: Post-Completion
  needs_review=true?  --> STOP, wait for human
  needs_review=false? --> after_review fires automatically, loop to Step 1
```

---

## Failure Modes This Skill Prevents

| Failure Mode | Old Pattern | This Skill |
|---|---|---|
| Forgot to explore | Agent skipped stride-subagent-workflow | Step 3 is inline -- can't be missed |
| Forgot to review | Agent jumped to completion | Step 6 is inline -- can't be missed |
| Wrong API fields | Agent guessed from memory | Step 8 has the exact format |
| Skipped hooks | Agent called complete directly | Step 7 blocks Step 8 |
| Asked user permission | Agent prompted between steps | Automation notice says don't |
| Speed over process | Agent optimized for throughput | Every step is framed as mandatory |

---

## Quick Reference Card

```
GEMINI CLI WORKFLOW:
├─ 0. Prerequisites: .stride_auth.md + .stride.md exist
├─ 1. Discovery: GET /api/tasks/next, review task, enrich if needed
├─ 2. Claim: POST /api/tasks/claim (hooks auto-fire via hooks.json)
├─ 3. Explore (check decision matrix):
│     ├─ Goal/large undecomposed → Invoke task-decomposer → Claim children
│     ├─ Small, 0-1 key_files → Skip to Step 4
│     └─ Otherwise → Invoke task-explorer (+ outline approach if medium+)
├─ 4. Implement: Write code using explorer output and task metadata
├─ 6. Review (check decision matrix):
│     ├─ Small, 0-1 key_files → Skip to Step 7
│     └─ Otherwise → Invoke task-reviewer, fix issues
├─ 7. Hooks: Automatic via hooks.json (fires on API call)
├─ 8. Complete: PATCH /api/tasks/:id/complete with ALL fields
└─ 9. Loop: needs_review=false → Step 1 | needs_review=true → STOP

DECISION MATRIX QUICK CHECK:
  small + 0-1 key_files  → Skip explore, plan, review
  small + 2+ key_files   → Explore + Review
  medium/large           → Explore + Plan + Review
  goal/undecomposed      → Decompose first
```

---

## Red Flags -- STOP

If you catch yourself thinking any of these, go back to the decision matrix:

- "This is straightforward, I'll skip exploration" -- Medium+ tasks ALWAYS explore
- "I know the codebase" -- The task has specific pitfalls you haven't read yet
- "Review will slow me down" -- Review catches what tests can't
- "I'll just run the hooks and complete" -- Did you explore? Did you review?
- "This step doesn't apply to me" -- Check the decision matrix, not your intuition

**The workflow IS the automation. Follow every step.**
