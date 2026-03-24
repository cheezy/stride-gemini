# Stride for Gemini CLI

Task lifecycle skills and custom agents for [Stride](https://www.stridelikeaboss.com) kanban — a task management platform designed for AI agents.

This is the Gemini CLI extension version of the [Stride plugin](https://github.com/cheezy/stride). It provides the same workflow enforcement through Gemini's skill and custom agent systems.

> **GitHub Topic:** This repo should be tagged with `gemini-cli-extension` for auto-indexing in the Gemini extension gallery.

## Installation

Install directly from GitHub using the Gemini CLI:

```bash
gemini extensions install https://github.com/cheezy/stride-gemini
```

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

When working on tasks, skills MUST be activated in this order:

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

### stride-claiming-tasks

**MANDATORY** before any task claiming or discovery API call. Enforces proper before_doing hook execution, prerequisite verification, and immediate transition to active work. Contains the claim request format including `before_doing_result`.

### stride-completing-tasks

**MANDATORY** before any task completion API call. Contains ALL 5 required completion fields and both hook execution patterns (after_doing + before_review). Skipping causes 3+ failed API calls as missing fields are discovered one at a time.

### stride-creating-tasks

**MANDATORY** before creating work tasks or defects. Contains all required field formats — `verification_steps` must be objects (not strings), `key_files` must be objects (not strings), `testing_strategy` arrays must be arrays (not strings).

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

A pre-completion code review agent dispatched after implementation but before running hooks. Validates the git diff against `acceptance_criteria`, detects `pitfalls` violations, checks `patterns_to_follow` compliance, and verifies `testing_strategy` alignment. Returns categorized issues (Critical/Important/Minor) with file and line references.

### hook-diagnostician

Analyzes hook failure output and returns a prioritized fix plan. Parses compilation errors, test failures, security warnings, credo issues, format failures, and git failures with structured diagnosis per issue. Dispatched automatically when blocking hooks fail during the completion workflow.

## Configuration

Before using Stride skills, you need two configuration files in your project root:

### `.stride_auth.md`

Contains your API credentials (never commit this file):

```markdown
- **API URL:** `https://www.stridelikeaboss.com`
- **API Token:** `your-token-here`
- **User Email:** `your-email@example.com`
```

### `.stride.md`

Contains hook scripts that run during the task lifecycle:

```markdown
## before_doing
git pull origin main
mix deps.get

## after_doing
mix test
mix credo --strict
```

## Updating

To get the latest skills and agents:

```bash
gemini extensions install https://github.com/cheezy/stride-gemini
```

Or if you cloned manually:

```bash
cd stride-gemini && git pull origin main
```

Then re-copy the `skills/` and `agents/` directories into your project.

## License

MIT — see [LICENSE](LICENSE) for details.
