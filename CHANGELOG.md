# Changelog

All notable changes to the Stride extension for Gemini CLI will be documented in this file.

## [1.5.1] - 2026-04-23

### Fixed

- **`hooks/hooks.json` path substitution** — The `command` fields referenced `${GEMINI_EXTENSION_ROOT}`, which is not a variable Gemini CLI expands. At hook-execution time Gemini passed the literal string to bash; bash treated it as an unset shell variable and expanded it to empty, leaving `/hooks/stride-hook.sh` as an absolute filesystem path that doesn't exist. The effect was that every `run_shell_command` tool call in an affected workspace was blocked with `bash: line 1: /hooks/stride-hook.sh: No such file or directory`. Replaced with `${extensionPath}` — the documented Gemini CLI variable that expands to the extension's install directory (see https://geminicli.com/docs/extensions/reference/ "Variables" section). Users upgrading from 1.5.0 should update the extension and verify that `run_shell_command` works again in a clean workspace.

## [1.5.0] - 2026-04-16

### Added

- **`stride-completing-tasks` skill** — Surfaced `explorer_result` and `reviewer_result` in six places so agents cannot forget them: (1) the MANDATORY teaser at the top of the skill lists both as required alongside the hook results; (2) the pre-completion Verification Checklist asks whether both are included; (3) the primary API Request Format example includes both with dispatched-custom-agent shapes; (4) a new "Explorer/Reviewer Result Schema" section documents the dispatched shape, the skip shape, the five-value skip-reason enum (`no_subagent_support`, `small_task_0_1_key_files`, `trivial_change_docs_only`, `self_reported_exploration`, `self_reported_review`), the 40-character non-whitespace summary minimum, a 422 rejection example, and the feature-flag grace-period rollout; (5) the Completion Request Field Reference table lists both as required objects; (6) the Quick Reference Card's `REQUIRED BODY` includes both plus a SKIP FORM snippet.
- **`stride-workflow` skill** — Step 8's Required Fields table and JSON payload example now include `explorer_result` and `reviewer_result`. A new "Explorer and Reviewer Result Rollout" section after "Workflow Telemetry" describes the grace-mode/strict-mode feature-flag phases and directs readers to `stride-completing-tasks` for the full shape (no schema duplication). Orchestrator prose explains that Steps 3 and 6 already capture the data needed to populate these fields in Step 8.

## [1.4.0] - 2026-04-14

### Added

- **`stride-workflow` skill** — New "Workflow Telemetry: The `workflow_steps` Array" section documenting the six-entry step-name vocabulary (`explorer`, `planner`, `implementation`, `reviewer`, `after_doing`, `before_review`), per-step schema (`name`, `dispatched`, `duration_ms`, `reason`), full-dispatch and skipped-step examples, and rules for assembling the array. Step names are identical to the main stride plugin so Stride can aggregate telemetry across agents and plugins.
- **`stride-completing-tasks` skill** — `workflow_steps` now appears in the verification checklist, the API Request Format example, the Completion Request Field Reference table, and the Quick Reference Card REQUIRED BODY. Added a Schema Reference paragraph pointing at `stride-workflow` as the source of truth for the array shape.

### Changed

- **`stride-completing-tasks` skill** — "Critical" note under the payload example now lists `workflow_steps` alongside the two hook-result fields as required. The API will reject completions that omit it.

## [1.3.1] - 2026-04-14

### Fixed

- **`hooks/stride-hook.sh` and `hooks/stride-hook.ps1`** — Env-cache parsing now handles the `{"stdout": "<api-json-string>", ...}` wrapper shape that some hosts use when passing the shell-command response to hooks. Prior versions only matched a bare JSON-encoded string or a raw object, so wrapped hosts silently fell through and `TASK_IDENTIFIER`/`TASK_TITLE` never got exported. `.stride.md` commands that referenced those vars (e.g. `git commit -m "Completed task $TASK_IDENTIFIER"`) then ran with empty values. The hook now tries the wrapper shape first, then falls back to the two legacy shapes.
- **`hooks/stride-hook.sh`** — User commands no longer abort on unset env vars. The hook ran with `set -uo pipefail`, which propagated into each `eval` and killed the command before it executed if it referenced an unset variable. `set +uo pipefail` is now toggled around the `eval`.
- **`hooks/test-stride-hook.sh`** — New regression test (6e) for the wrapped `tool_response.stdout` shape.

## [1.3.0] - 2026-04-13

### Changed

- **`stride-claiming-tasks`** — Replaced soft "Recommended" orchestrator section with non-negotiable "YOUR NEXT STEP" gate demanding stride-workflow activation immediately after claiming. Added workflow violation warning to standalone mode.
- **`stride-completing-tasks`** — Added "BEFORE CALLING COMPLETE: Verification Checklist" with 4 yes/no items covering orchestrator activation, codebase exploration, acceptance criteria review, and hook readiness.

## [1.2.0] - 2026-04-13

### Added

- **`stride-workflow` skill** — Single orchestrator for the complete Stride task lifecycle adapted for Gemini CLI. Walks through prerequisites, claiming, codebase exploration (via custom agents), implementation, code review, hooks, and completion in a single skill. Uses automatic hook execution via `BeforeTool`/`AfterTool` and process-over-speed messaging. Eliminates the need to remember which skills to activate at which moments.

### Changed

- **`stride-claiming-tasks` skill** — Reframed automation notice from throughput-emphasizing ("FULLY AUTOMATED") to process-over-speed ("The workflow IS the automation"). Added "Recommended: Use the Workflow Orchestrator" section pointing to `stride-workflow`. Renamed "MANDATORY: Next Skill After Claiming" to "Next Skill After Claiming (Standalone Mode)".
- **`stride-completing-tasks` skill** — Reframed automation notice from throughput-emphasizing to process-over-speed. Added "Arriving from stride-workflow" section. Renamed "MANDATORY: Previous Skill Before Completing" to "Previous Skill Before Completing (Standalone Mode)". Added `stride-workflow` as first entry in the prerequisite skills list.
- **`GEMINI.md`** — Updated Workflow Sequence to recommend `stride-workflow` as preferred entry point, with standalone skill chain as alternative.
- **`README.md`** — Added `stride-workflow` to Workflow Order (as recommended) and Skills section. Existing standalone workflow preserved as alternative.

## [1.1.0] - 2026-03-25

### Added

- **`hooks/hooks.json`** — Gemini CLI hook configuration that registers `BeforeTool` and `AfterTool` hooks on `run_shell_command`. Uses Gemini-specific event names, regex matchers, millisecond timeouts (120000ms), and `name`/`description` fields for `/hooks panel` visibility.
- **`hooks/stride-hook.sh`** — Bash hook script adapted for Gemini CLI. Uses `GEMINI_PROJECT_DIR` with `CLAUDE_PROJECT_DIR` fallback. All non-JSON output goes to stderr (Gemini requires JSON-only stdout). Includes platform detection that auto-delegates to PowerShell on native Windows.
- **`hooks/stride-hook.ps1`** — PowerShell companion script for Windows compatibility. Uses `GEMINI_PROJECT_DIR` with `CLAUDE_PROJECT_DIR` fallback. Supports PowerShell 5.1+ and 7+.
- **`hooks/test-stride-hook.sh`** — Bash test suite with 67 tests across 6 groups using `GEMINI_PROJECT_DIR`.
- **`hooks/test-stride-hook.ps1`** — PowerShell test suite with 70 assertions mirroring the bash test suite using `GEMINI_PROJECT_DIR`.
- **Automatic Hook Execution documentation** in README.md — covers Gemini-specific hook routing (BeforeTool/AfterTool), .stride.md format, platform support, `/hooks panel` management, JSON-only stdout requirement, environment variable caching, and troubleshooting.

### Changed

- **`GEMINI.md`** — Updated Hook Execution section to document automatic hooks (BeforeTool/AfterTool via hooks.json) vs manual fallback. Added `/hooks panel` reference.

## [1.0.0] - 2026-03-24

### Added

- **`stride-claiming-tasks` skill** — Enforces proper task claiming workflow for Gemini CLI: prerequisite verification (`.stride_auth.md` and `.stride.md`), `before_doing` hook execution with timing capture, and immediate transition to implementation. Includes automation notice for continuous claim-implement-complete loop without user prompts. Adapted from Claude Code plugin with Gemini-specific tool name mapping and `activate` terminology.
- **`stride-completing-tasks` skill** — Enforces dual-hook completion workflow: `after_doing` hook (tests, linting, 120s timeout) and `before_review` hook (PR creation, 60s timeout) must both succeed before calling the complete endpoint. Handles `needs_review` gating, auto-continuation, optional `review_report` field, and diagnostician-assisted hook failure debugging via custom agents.
- **`stride-creating-tasks` skill** — Prevents minimal task specifications that cause 3+ hour exploration failures. Enforces comprehensive field population including `key_files`, `acceptance_criteria`, `testing_strategy`, `pitfalls`, `patterns_to_follow`, and `verification_steps` with correct object/array formats.
- **`stride-creating-goals` skill** — Enforces proper goal creation with nested tasks, correct batch format (`"goals"` root key, not `"tasks"`), within-goal dependency management using array indices, and cross-goal dependency workarounds.
- **`stride-enriching-tasks` skill** — 4-phase enrichment workflow that transforms minimal task specifications into full implementation-ready specs. Explores codebase to populate `key_files`, `testing_strategy`, `verification_steps`, `acceptance_criteria`, `patterns_to_follow`, complexity estimates, and other fields. Handles defect tasks, title-only tasks, and ambiguous contexts.
- **`stride-subagent-workflow` skill** — Orchestration skill adapted for Gemini CLI custom agents. Contains the decision matrix for invoking `task-explorer`, `task-reviewer`, `task-decomposer`, and `hook-diagnostician` agents based on task complexity and key_files count. Covers four phases: decomposition for goals, exploration after claim, conditional planning for complex tasks, and code review before completion hooks. Includes fallback guidance for environments without custom agent support.
- **`task-explorer` agent** — Custom Gemini CLI agent for targeted codebase exploration after claiming a task. Reads key_files, finds related tests, searches for patterns_to_follow, navigates where_context, and returns a structured summary for confident implementation.
- **`task-reviewer` agent** — Custom Gemini CLI agent for pre-completion code review. Validates changes against acceptance_criteria, detects pitfall violations, checks pattern compliance, verifies testing strategy alignment, and returns categorized issues (Critical/Important/Minor) with a structured review report for the completion API.
- **`task-decomposer` agent** — Custom Gemini CLI agent that breaks goals and large tasks into dependency-ordered child tasks. Uses 6-step methodology: Scope Analysis, Task Boundary Identification, Dependency Ordering, Complexity Estimation, Full Specification per Task, and Output Assembly.
- **`hook-diagnostician` agent** — Custom Gemini CLI agent that analyzes hook failure output and returns a prioritized fix plan. Parses 6 failure categories (compilation errors, test failures, security warnings, credo issues, format failures, git failures) with structured output and fix prioritization.
- **`GEMINI.md`** — Always-on bridge file providing mandatory skill activation rules, custom agent references, workflow sequence, API authorization statement, hook execution rules, and Gemini-to-Stride tool name mapping table.
- **`README.md`** — Comprehensive installation and usage guide covering `gemini extensions install`, skill chain workflow, all 6 skills and 4 agents with descriptions, configuration file setup, and update instructions.
- **`LICENSE`** — MIT License.

### Notes

This is the initial release of the Stride extension for Google Gemini CLI, ported from the Claude Code plugin (v1.4.0). All 6 skills and 4 custom agents have been adapted for Gemini CLI conventions:

- Frontmatter uses `name` and `description` only (no `skills_version`)
- Agent frontmatter includes `name`, `description`, `tools`, `temperature`, `max_turns`, `timeout_mins`
- Tool references mapped: `Bash`→`run_shell_command`, `Read`→`read_file`, `Grep`→`grep_search`, `Glob`→`glob`, `Edit`→`replace`, `Write`→`write_file`
- Terminology: "invoke"→"activate", "plugin"→"extension", `CLAUDE.md`→`GEMINI.md`/`AGENTS.md`
- Agent references: `stride:task-*`→`task-*` (Gemini uses flat agent names)
- Extension installed via `gemini extensions install <repo-url>` (no plugin.json required)
