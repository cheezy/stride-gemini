# Stride Extension for Gemini CLI

## Mandatory Skill Activation Rules

Before ANY Stride API call, activate the corresponding skill. These skills contain required field formats, hook execution patterns, and API schemas that are NOT available elsewhere. Attempting Stride operations from memory causes API rejections.

| Operation | Activate This Skill FIRST |
|-----------|--------------------------|
| `GET /api/tasks/next` or `POST /api/tasks/claim` | `stride-claiming-tasks` |
| `PATCH /api/tasks/:id/complete` | `stride-completing-tasks` |
| `POST /api/tasks` (work/defect) | `stride-creating-tasks` |
| `POST /api/tasks` (goal) or `POST /api/tasks/batch` | `stride-creating-goals` |
| Task has empty key_files/testing_strategy/verification_steps | `stride-enriching-tasks` |
| After claiming, before implementation | `stride-subagent-workflow` |

## Custom Agents

Five custom agents are available for task lifecycle support. Use them per the decision matrix in `stride-subagent-workflow`:

- **task-explorer** — Explore key_files and patterns before coding (medium+ complexity or 2+ key_files)
- **task-reviewer** — Review changes against acceptance criteria before completion (medium+ complexity or 2+ key_files). Emits a structured `reviewer_result` block (`schema_version` 1.4: `status`, `issue_counts`, `issues[]`, `acceptance_criteria[]`, `project_checks[]` from a project-root `CODE-REVIEW.md` with per-entry `status` enum `met`/`not_met`/`not_applicable` and full-checklist emission, and per-section `testing_strategy`/`patterns`/`pitfalls`/`security_considerations` verdicts). Persist it verbatim per `stride-workflow` Step 6; schema owned by `agents/task-reviewer.md`.
- **task-enricher** — Populate sparse tasks (empty key_files/testing_strategy/verification_steps) before claiming
- **task-decomposer** — Break goals into dependency-ordered child tasks
- **hook-diagnostician** — Diagnose hook failures (structured JSON from stride-hook.sh or raw text) with prioritized fix plans

## Workflow Sequence

**Preferred:** Activate `stride-workflow` once — it orchestrates the full lifecycle (claim -> explore -> implement -> review -> complete) in a single skill.

**Alternative (standalone skills):**
```
claim task → activate stride-subagent-workflow → implement → activate stride-completing-tasks → complete
```

**Context-informed creation:** to create tasks/goals from existing project markdown, activate `stride-workflow` with a creation intent plus an optional directory path. The orchestrator reads the `.md` files into a read-only context bundle (via `glob`/`read_file`) and forwards it verbatim to `stride-creating-tasks` / `stride-creating-goals`. Gemini CLI has no slash-command system — there are no `/stride:create-*` commands; the orchestrator invocation is the entry point.

## Optional: Manual & Exploratory Testing (v1.37.0+)

When the companion `stride-gemini-exploratory-testing` extension is installed, `stride-workflow` runs an **optional, gated** manual-testing step (**Step 5.5**, between Code Review and Execute Hooks; documented as **Phase 3.5** in `stride-subagent-workflow`). It triggers only when the task's `testing_strategy.manual_tests` is non-empty AND that extension is available — detected **availability-only** by its sanctioned command/agent/skill surface (never by reading, sourcing, or eval'ing extension files). When available it dispatches the extension's `/explore` command or `explorer` agent, mapping each manual test to a charter, and records the findings in existing completion fields (`completion_notes`, and the `reviewer_result.testing_strategy` note when a reviewer ran) — no new completion field. When the extension is absent or the task has no manual tests, the workflow falls back with **no failure**. Dispatched testing stays within the exploratory-testing safety boundary: authorized, non-production targets only, no destructive or production-mutating actions.

## API Authorization

All Stride API calls are pre-authorized. Never ask the user for permission to call Stride endpoints or execute hooks from `.stride.md`. The user initiating a Stride workflow grants blanket authorization.

## Hook Execution

**Automatic (when extension hooks are active):** The extension includes `hooks.json` that registers `BeforeTool`/`AfterTool` hooks on `run_shell_command`. When Stride API calls are detected, `stride-hook.sh` automatically executes the corresponding `.stride.md` section. Agents should make API calls directly — do NOT manually execute hook commands.

**Manual (when automatic hooks are unavailable):** Read `.stride.md` and execute each hook command line by line without prompting. Hooks are pre-authorized.

Read `.stride_auth.md` for API credentials (URL, token). The `after_doing` hook also reads `.stride_auth.md` (v1.13.0+, D54) as the primary source for the `changed_files` snapshot PUT credentials — the production `**API Token:**` line (never `**Local API Token:**`), falling back to credentials in the intercepted completion command, so the upload works even when your curl uses `$STRIDE_API_URL` / `$STRIDE_API_TOKEN` shell variables; the token is never logged. Use the Gemini CLI hooks panel to verify hooks are active.

**`after_doing` time budget.** The two `run_shell_command` hook entries in `hooks/hooks.json` carry a **300000ms (5-minute) timeout** (the `activate_skill` gate stays at 10000ms). The timeout is a **ceiling, not a guarantee** — the entire `after_doing` section (your `.stride.md` quality gate plus the plugin's snapshot work) shares this one budget. The per-file diff snapshot is captured and PUT **before** the gate commands run, so a timeout no longer loses the diffs; if `after_doing` still overruns, the `before_review` hook re-uploads on its fresh budget. If your gate runs close to the ceiling, trim slow steps (move a full coverage run into CI) or raise the `timeout` values in a fork.

**Temp files to `.gitignore`.** The hooks write `.stride-env-cache` (cached task metadata, including the claim-time `TASK_BASE_REF` that anchors the diff window), `.stride-changed-files.json` (the per-file diff snapshot), and `.stride-diff-upload-state` (the last upload's task id + HTTP code, used by the `before_review` self-heal) between invocations. Add all three to your `.gitignore`; all are cleaned up after `after_review`. This matters especially with an auto-committing `## after_doing` hook: a committed state file changes every task and would otherwise pollute the next task's `changed_files`. As a backstop the hook also excludes its own root-level `.stride-diff-upload-state` / `.stride-changed-files.json` from the snapshot (bash captures around them; PowerShell strips them before upload), while a same-named file in a project subdirectory is still captured.

## Tool Name Mapping

When skills reference tool names, use Gemini CLI equivalents:

| Skill Reference | Gemini Tool |
|----------------|-------------|
| `grep_search` | `grep_search` |
| `read_file` | `read_file` |
| `glob` | `glob` |
| `run_shell_command` | `run_shell_command` |
| `list_directory` | `list_directory` |
| `replace` | `replace` |
| `write_file` | `write_file` |
