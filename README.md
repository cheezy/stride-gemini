# Stride for Gemini CLI

Task lifecycle skills and custom agents for [Stride](https://www.stridelikeaboss.com) kanban — a task management platform designed for AI agents.

This is the Gemini CLI extension version of the [Stride plugin](https://github.com/cheezy/stride). It provides the same workflow enforcement through Gemini's skill and custom agent systems.

> **GitHub Topic:** This repo should be tagged with `gemini-cli-extension` for auto-indexing in the Gemini extension gallery.

## Installation

Install directly from GitHub using the Gemini CLI:

```bash
gemini extensions install https://github.com/cheezy/stride-gemini
```

The repo ships a [`gemini-extension.json`](gemini-extension.json) manifest at its root, so the command above installs it as a first-class Gemini CLI extension (`GEMINI.md` is loaded as the extension context file).

Or clone manually and copy files into your project:

```bash
git clone https://github.com/cheezy/stride-gemini.git

# Copy skills and agents into your project
cp -r stride-gemini/skills/ your-project/skills/
cp -r stride-gemini/agents/ your-project/agents/
cp stride-gemini/GEMINI.md your-project/GEMINI.md
```

Gemini CLI automatically discovers skills in `skills/` and custom agents in `agents/` at the project root.

## Mandatory Skill Chain

Every Stride skill is **MANDATORY** — not optional. Each skill contains required API fields, hook execution patterns, and validation rules that are ONLY documented in that skill. Attempting to call Stride API endpoints without the corresponding skill results in API rejections, malformed data, or hours of wasted rework.

### Workflow Order

**Recommended:** Use the single orchestrator skill for the complete lifecycle:

```
stride-workflow                  ← Activate ONCE — handles claim → explore → implement → review → complete
```

**Standalone mode** (when you need individual skills):

```
stride-claiming-tasks            ← BEFORE calling GET /api/tasks/next or POST /api/tasks/claim
    ↓
stride-subagent-workflow         ← AFTER claim succeeds, BEFORE implementation
    ↓
[implementation]
    ↓
stride-completing-tasks          ← BEFORE calling PATCH /api/tasks/:id/complete
```

When creating tasks or goals:

```
stride-enriching-tasks           ← WHEN task has empty key_files/testing_strategy/verification_steps
    ↓
stride-creating-tasks            ← BEFORE calling POST /api/tasks (work tasks or defects)
stride-creating-goals            ← BEFORE calling POST /api/tasks/batch (goals with nested tasks)
```

### Why This Matters

| Without skill | What happens |
|---------------|-------------|
| Claim without `stride-claiming-tasks` | API rejects — missing `before_doing_result` |
| Complete without `stride-completing-tasks` | 3+ failed API calls — missing `completion_summary`, `actual_complexity`, `actual_files_changed`, `after_doing_result`, `before_review_result` |
| Create task without `stride-creating-tasks` | Malformed `verification_steps`, `key_files`, `testing_strategy` — causes 3+ hours wasted during implementation |
| Create goal without `stride-creating-goals` | 422 error — wrong root key (`"tasks"` instead of `"goals"`) |
| Skip `stride-subagent-workflow` | No codebase exploration, no code review — wrong approach, missed acceptance criteria |
| Skip `stride-enriching-tasks` | Sparse task specs → implementing agent wastes 3+ hours on unfocused exploration |

## Skills

### stride-workflow

**RECOMMENDED** entry point for all task work. Single orchestrator that walks through the complete lifecycle: prerequisites, claiming, codebase exploration, implementation, code review, hooks, and completion. Uses Gemini custom agents for exploration and review, with automatic hook execution via hooks.json. Eliminates the need to remember which skills to activate at which moments. Also supports **context-informed creation**: activate `stride-workflow` with a creation intent plus an optional directory path, and the orchestrator reads the `.md` files into a read-only context bundle (via `glob`/`read_file`) and forwards it verbatim to the creation sub-skill. Gemini has no slash-command system, so there are no `/stride:create-*` commands — the orchestrator invocation is the entry point.

### stride-claiming-tasks

**MANDATORY** before any task claiming or discovery API call. Enforces proper before_doing hook execution, prerequisite verification, and immediate transition to active work. Contains the claim request format including `before_doing_result`.

### stride-completing-tasks

**MANDATORY** before any task completion API call. Contains ALL 5 required completion fields and both hook execution patterns (after_doing + before_review). Skipping causes 3+ failed API calls as missing fields are discovered one at a time.

### stride-creating-tasks

**MANDATORY** before creating work tasks or defects. Contains all required field formats — `verification_steps` must be objects (not strings), `key_files` must be objects (not strings), `testing_strategy` arrays must be arrays (not strings). Includes a "Consuming Provided Context" section: when dispatched with a context bundle, mine the markdown for `key_files` / `patterns_to_follow` / `acceptance_criteria` / `pitfalls` — context augments, never replaces, and the five review_queue-scored fields (now including `security_considerations`) stay required. Also documents the optional `technical_details` field — a free-form JSON object (no fixed keys) for any extra technical context; it is optional everywhere and is **not** one of the five review_queue-scored fields. (v1.30.0+) documents the optional `created_by_agent` field — set it to the plugin's own agent name (`"Gemini CLI"`, the same value sent as `agent_name` on claim/complete) so the `/agents` feed attributes the creating agent; create-only and forbidden on `PATCH`, propagated from a batch goal to its child tasks.

### stride-creating-goals

**MANDATORY** before batch creation or goal creation. Contains the only correct batch format — root key must be `"goals"` not `"tasks"`. Most common API error when skipped.

### stride-enriching-tasks

**MANDATORY** when a task has sparse specification. Transforms minimal human-provided specs into complete implementation-ready tasks through automated codebase exploration. 5 minutes of enrichment saves 3+ hours of unfocused implementation.

### stride-subagent-workflow

**MANDATORY** after claiming any task. Contains the decision matrix for dispatching task-explorer, task-reviewer, task-decomposer, and hook-diagnostician custom agents. Determines exploration and review strategy based on task complexity and key_files count.

## Custom Agents

### task-explorer

A read-only codebase exploration agent dispatched after claiming a task. Reads every file listed in `key_files`, finds related test files, searches for patterns referenced in `patterns_to_follow`, navigates to `where_context`, and returns a structured summary so the primary agent can start coding with full context.

### task-decomposer

Breaks goals and large tasks into dependency-ordered child tasks. Uses scope analysis, task boundary identification, and dependency ordering to produce implementation-ready task arrays with complexity estimates, key files, and testing strategies per task.

### task-reviewer

A pre-completion code review agent dispatched after implementation but before running hooks. Validates the git diff against `acceptance_criteria`, detects `pitfalls` violations, checks `patterns_to_follow` compliance, verifies `testing_strategy` alignment, and confirms the task's `security_considerations` were actually implemented (input validation, authorization boundaries, secret handling, injection surfaces, data exposure). Returns categorized issues (Critical/Important/Minor) with file and line references, plus a structured `reviewer_result` JSON block (**`schema_version` 1.4**) carrying `status`, `issue_counts`, `issues[]`, `acceptance_criteria[]` verdicts, `project_checks[]` (from a project-root `CODE-REVIEW.md`, when present; per-entry `status` enum `met`/`not_met`/`not_applicable`, with the full checklist emitted — no bullet omitted — as of v1.16.0), and per-section `testing_strategy` / `patterns` / `pitfalls` / `security_considerations` verdicts (the fifth review_queue-scored field). The orchestrator persists that block verbatim as `reviewer_result` (see stride-workflow Step 6, "Extracting the structured review block"); the schema is owned by `agents/task-reviewer.md`.

### hook-diagnostician

Analyzes hook failure output and returns a prioritized fix plan. Accepts both **structured JSON** from the Gemini hooks (`stride-hook.sh`) and raw text from the legacy agent-executed flow. Parses compilation errors, test failures, security warnings, credo issues, format failures, and git failures with structured diagnosis per issue. Dispatched automatically when blocking hooks fail during the completion workflow.

## Configuration

Before using Stride skills, you need two configuration files in your project root:

### `.stride_auth.md`

Contains your API credentials (never commit this file):

```markdown
- **API URL:** `https://www.stridelikeaboss.com`
- **API Token:** `your-token-here`
- **User Email:** `your-email@example.com`
```

Beyond authenticating your own API calls, the `after_doing` hook reads this file (v1.13.0+, D54) as the **primary** source for the URL + token of the fire-and-forget `changed_files` snapshot PUT — matching the production `**API Token:**` line, never `**Local API Token:**`, and falling back to credentials parsed from the intercepted completion command. This makes the snapshot upload work even when your completion curl uses `$STRIDE_API_URL` / `$STRIDE_API_TOKEN` shell variables. The token is never logged.

### `.stride.md`

Contains hook scripts that run during the task lifecycle:

```markdown
## before_doing
git pull origin main
mix deps.get

## after_doing
mix test
mix credo --strict

## after_goal
# Optional fifth hook — fires after the parent goal's final child task
# completes. Omit the section entirely for the back-compat no-op path.
./scripts/notify-team.sh "$GOAL_IDENTIFIER" "$GOAL_TITLE"
```

## Automatic Hook Execution

The extension includes automatic hook execution via `hooks.json`. When installed, Stride API calls made through the Gemini CLI are intercepted and the corresponding `.stride.md` hook commands run automatically.

### How It Works

| Stride API Call | Hook Triggered | Gemini Event | Timing |
|----------------|----------------|--------------|--------|
| `POST /api/tasks/claim` | `before_doing` | `AfterTool` | After claim succeeds |
| `PATCH /api/tasks/:id/complete` | `after_doing` | `BeforeTool` | Before completion runs (blocks on failure) |
| `PATCH /api/tasks/:id/complete` | `before_review` (+ `after_goal` if bundled) | `AfterTool` | After completion succeeds |
| `PATCH /api/tasks/:id/mark_reviewed` | `after_review` (+ `after_goal` if bundled) | `AfterTool` | After review succeeds |

**`after_goal` (v1.11.0+):** the server bundles an `after_goal` entry alongside the primary hook in the response of `/complete` or `/mark_reviewed` when the completing task is the final child of a parent goal. The extension auto-executes the local `## after_goal` section as a blocking hook (60s timeout, same shape as `after_doing`) and emits a structured result on stdout. The agent forwards the result via `PATCH /api/tasks/:goal_id/after_goal` to flip the goal to Done. A missing `## after_goal` section is a clean no-op (back-compat). The hook receives `GOAL_ID` / `GOAL_IDENTIFIER` / `GOAL_TITLE` / `GOAL_DESCRIPTION` env vars from the server's `hook.env`, and is general-purpose — Slack notifications, artifact archival, release pipelines, project-level smoke tests are all valid uses, not just PR creation.

### .stride.md Format

Hook commands are defined in `.stride.md` using `## heading` + ` ```bash ` code blocks:

```markdown
## before_doing
```bash
git pull origin main
mix deps.get
```

## after_doing
```bash
mix test
mix credo --strict
```
```

Each command runs one at a time. If any command fails, execution stops and the hook returns exit code 2 (blocking the API call for `BeforeTool` hooks).

### Platform Support

- **macOS / Linux**: `stride-hook.sh` runs directly via bash
- **Windows (Git Bash / WSL)**: `stride-hook.sh` runs directly (bash is available)
- **Windows (native PowerShell)**: `stride-hook.sh` detects the platform and delegates to `stride-hook.ps1` automatically

No platform-specific configuration needed — the single `hooks.json` entry handles all platforms.

### Gemini-Specific Notes

- Hooks use `BeforeTool`/`AfterTool` events (not `PreToolUse`/`PostToolUse`)
- Matcher targets `run_shell_command` (Gemini's shell tool name)
- Timeouts are in milliseconds (300000ms = 5 minutes)
- **JSON-only stdout**: The hook script sends all debug/progress output to stderr; only the final structured JSON result goes to stdout (Gemini requirement)
- Hooks are visible and manageable via `/hooks panel`, `/hooks enable`, `/hooks disable`

### The `after_doing` time budget

The two `run_shell_command` hook entries in `hooks/hooks.json` carry a **300000ms (5-minute) timeout** (the `activate_skill` gate stays at 10000ms — it fires on every Skill invocation and must remain fast). The timeout is a **ceiling, not a guarantee**: the entire `after_doing` section — every command in your `.stride.md` quality gate (test suite with coverage, credo, sobelow, auto-commit) plus the plugin's own snapshot work — shares this one budget.

When the budget is exceeded, Gemini CLI kills the hook process. With the early-capture fix the per-file diffs are already uploaded before your gate commands start, so a timeout no longer loses them — but the structured success JSON, the post-command snapshot refresh, and any not-yet-run gate commands are still lost, and the completion call is blocked as if the gate had failed.

If your project's quality gate runs close to the ceiling, either trim the `.stride.md` `## after_doing` section (move slow steps like a full coverage run into CI) or raise the `timeout` values further in a fork of the plugin.

### Environment Variable Caching

After a successful task claim, hook scripts extract task metadata (TASK_ID, TASK_IDENTIFIER, TASK_TITLE, etc.) from the API response and cache them to `.stride-env-cache`. Subsequent hooks can reference these variables in `.stride.md` commands (e.g., `$TASK_IDENTIFIER`). The cache is cleaned up after the `after_review` hook.

Add `.stride-env-cache`, `.stride-changed-files.json`, and `.stride-diff-upload-state` to your `.gitignore` — all three are temp files written between hook invocations (`.stride-changed-files.json` holds the per-file diff snapshot; `.stride-diff-upload-state` records the last upload's task id + HTTP code so the `before_review` hook can re-upload on a fresh timeout budget when an `after_doing` upload was lost). All three are cleaned up automatically after the `after_review` hook. Gitignoring them matters especially if your `## after_doing` hook auto-commits: once the state files are committed, their contents change on every task and would otherwise show up as spurious entries in the next task's `changed_files` snapshot. As a backstop, the hook also excludes its own root-level `.stride-diff-upload-state` and `.stride-changed-files.json` from the snapshot at capture time (bash) and strips them before upload (PowerShell) — a same-named file in a subdirectory of your project is still captured.

### Troubleshooting

- **Hooks not firing**: Check `/hooks panel` to verify hooks are registered. Reinstall the extension if needed.
- **Permission errors on Windows**: Ensure PowerShell execution policy allows scripts, or verify the `-ExecutionPolicy Bypass` flag is working
- **Hook failures blocking API calls**: `BeforeTool` hooks (after_doing) block on failure by design. Fix the underlying issue and retry.
- **Non-JSON stdout errors**: Ensure no debug output leaks to stdout. The hook script handles this, but custom `.stride.md` commands should avoid stdout output that isn't captured.
- **Missing .stride.md**: Hooks exit cleanly (code 0) when `.stride.md` is not present — no action needed

## Updating

To get the latest skills, agents, and hooks:

```bash
gemini extensions install https://github.com/cheezy/stride-gemini
```

## License

MIT — see [LICENSE](LICENSE) for details.
