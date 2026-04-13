# Changelog

All notable changes to the Stride extension for Gemini CLI will be documented in this file.

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
