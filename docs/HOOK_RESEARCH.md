# Gemini CLI Hook Research — Skill-Gate Portability

> **Frozen historical record — not live documentation.** This document captured the research that decided whether
> stride 1.10.0's skill gate ports to Gemini CLI, and its "Action plan for downstream tasks" below was executed:
> W301 added the Orchestrator Activation Marker section to `skills/stride-workflow/SKILL.md`, and W302 ported the
> gate as `hooks/stride-skill-gate.sh` with its test harness. It is kept as a record of what was decided and why,
> on the same footing as a CHANGELOG entry, and is deliberately **not** updated as the port evolves.
>
> Read its step numbers against the numbering that was current when it was written, not against this port today.
> The action plan says to clear the marker at "Step 9", and **that was accurate when written**: this document is
> dated 2026-04-29 and mirrors stride 1.10.0, and the canonical `stride` port carried
> `## Step 9: Post-Completion Decision` from 2026-04-13 (`9c2b3e4`) until 2026-07-02, when W1452 (`0109dfb`)
> resolved a missing Step 5 and renumbered it to Step 8. **This port carried `## Step 9` too**, from 2026-04-13
> (`4272c70`) until 2026-07-03, when W1521 (`2021860`) closed its own empty-Step-5 gap — so on the day this document
> was written the citation was accurate against stride-gemini's *own* headings, not merely the canonical port it
> mirrors. Two sibling ports, `stride-codex` and `stride-opencode`, still number it Step 9 today. So the citation
> is a faithful record of a plan made against numbering this port
> has since superseded — correcting it in place would falsify what was actually planned, which is the same reason
> historical CHANGELOG entries citing superseded step numbers are not rewritten. In this port the marker clear now
> lives under `## Step 8: Post-Completion Decision`. For current guidance always read
> `skills/stride-workflow/SKILL.md`, whose own `## Step` headings are the ground truth.
>
> **One later record is appended at the end:** the W2467 measurement of how a custom-agent invocation and the
> `AfterAgent` input behave. It carries its own date and CLI version, and from that date it is frozen on the same
> terms as everything above it.

Research target: decide whether stride 1.10.0's PreToolUse(Skill) gate
(`stride-skill-gate.sh` + matcher `"Skill"`) ports to Gemini CLI.

## Sources consulted

- Gemini CLI extensions reference: <https://geminicli.com/docs/extensions/reference/>
- Gemini CLI hooks reference: <https://geminicli.com/docs/hooks/reference/>
- Gemini CLI built-in tools reference: <https://geminicli.com/docs/reference/tools>
- `activate_skill` tool documentation: <https://geminicli.com/docs/tools/activate-skill/>
- Local: `stride-gemini/hooks/hooks.json`, `stride-gemini/hooks/stride-hook.sh`
- Reference gate: `stride/hooks/stride-skill-gate.sh`, `stride/hooks/hooks.json`

## Findings

### 1. Hook events Gemini CLI supports

- **Tool hooks:** `BeforeTool`, `AfterTool`
- **Agent hooks:** `BeforeAgent`, `AfterAgent`
- **Model hooks:** `BeforeModel`, `BeforeToolSelection`, `AfterModel`
- **Lifecycle / system hooks:** `SessionStart`, `SessionEnd`, `Notification`, `PreCompress`

`BeforeTool` is the equivalent of Claude Code's `PreToolUse` and is the
event we need.

### 2. `matcher` semantics and tool-name vocabulary

- For `BeforeTool` / `AfterTool`, `matcher` is a **regex** tested against the
  `tool_name`. Example from the docs: `"read_.*"` matches every file-reading
  tool.
- The matcher is honored — the long-standing matcher-ignored bug that Copilot
  CLI had on its `preToolUse` does not apply here.
- Built-in tool names (verified from the tools reference):

  | Category | Tools |
  |---|---|
  | Execution | `run_shell_command` |
  | File system | `glob`, `grep_search`, `list_directory`, `read_file`, `read_many_files`, `replace`, `write_file` |
  | Interaction | `ask_user`, `write_todos` |
  | Task tracker | `tracker_create_task`, `tracker_update_task`, `tracker_get_task`, `tracker_list_tasks`, `tracker_add_dependency`, `tracker_visualize` |
  | MCP | `list_mcp_resources`, `read_mcp_resource` |
  | Memory | `activate_skill`, `get_internal_docs`, `save_memory` |
  | Planning | `enter_plan_mode`, `exit_plan_mode` |
  | System | `complete_task` |
  | Web | `google_web_search`, `web_fetch` |
  | MCP-provided | `mcp_<server>_<tool>` |

- **Crucial:** `activate_skill` is a documented built-in tool that fires
  every time the agent activates a skill (either via auto-discovery from the
  description or via an explicit user request). Quote from the activate_skill
  doc: *"`activate_skill` takes one argument: `name` (enum, required): The
  name of the skill to activate."*
- Therefore a matcher of `"activate_skill"` on `BeforeTool` reliably fires
  exactly once per skill activation. This is the exact event the stride
  1.10.0 gate needs.

### 3. Hook stdin JSON shape

All hooks receive these base fields on stdin:

```json
{
  "session_id": "string",
  "transcript_path": "string",
  "cwd": "string",
  "hook_event_name": "string",
  "timestamp": "string"
}
```

Tool-specific additions for `BeforeTool` / `AfterTool`:

- `tool_name` — string, e.g. `"activate_skill"` or `"run_shell_command"`
- `tool_input` — object with the model-generated arguments
- `tool_response` — `AfterTool` only; `{llmContent, returnDisplay, error?}`
- `mcp_context` — present for MCP tools
- `original_request_name` — populated when a tool is tail-called

For an `activate_skill` invocation, `tool_input` shape is therefore:

```json
{"name": "<skill-name>"}
```

This is the load-bearing detail. Compare to Claude Code's
`tool_input.skill` for the `Skill` tool — the field name differs (`name` vs
`skill`). The gate needs a one-line adapter:

- **Claude Code:** `jq -r '.tool_input.skill'`
- **Gemini CLI:** `jq -r '.tool_input.name'`

Project directory is exposed via the stdin `cwd` field (Gemini does not set
a `GEMINI_PROJECT_DIR` environment variable). The existing
`stride-gemini/hooks/stride-hook.sh` already falls back through
`${GEMINI_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-.}}`; the gate should prefer
the stdin `cwd` value and fall back to that env chain so it works both
in-process and from CLI testing.

### 4. Block / deny semantics

Two equivalent contracts, per the hooks reference:

1. **Exit code 2 + stderr message** (preferred system-block form): *"System
   Block. The action is blocked; `stderr` is used as the rejection reason."*
2. **Stdout JSON** with `{"decision": "deny", "reason": "..."}`.

`BeforeTool` denials surface to the agent as a tool-error message. Stride
1.10.0's gate already exits 2 and writes a structured-JSON-on-stdout +
human-readable-stderr, which fits both Gemini contracts simultaneously
(exit 2 + stderr is the primary signal; the stdout JSON is harmless extra).

### 5. Plugin-namespaced skill names

The stride 1.10.0 gate's protected-name list includes both bare names
(`stride-claiming-tasks`) and Claude-Code-namespaced forms
(`stride:stride-claiming-tasks`). On Gemini, skills are activated by their
`SKILL.md` `name:` value as it appears in `tool_input.name` — that is the
bare name, not a plugin-namespaced one. The gate's bare-name list is
correct; the namespaced variants are harmless extras that simply won't
match on Gemini. No protected-name list change is needed.

## Decision

**PATH A: gate IS portable.**

Three load-bearing facts:

1. `BeforeTool` with regex `matcher` honors tool-name filtering on Gemini CLI.
2. `activate_skill` is a real, documented built-in tool that fires on every
   skill activation — there IS an event the gate can intercept.
3. `tool_input.name` carries the skill name, exit 2 + stderr blocks with the
   reason becoming a tool error to the model. Both contracts the stride
   1.10.0 gate uses are honored.

## Action plan for downstream tasks

### W301 — marker lifecycle docs (skip is unnecessary)

Add an "Orchestrator Activation Marker" section to
`stride-gemini/skills/stride-workflow/SKILL.md` mirroring stride 1.10.0:
path `<cwd>/.stride/.orchestrator_active`, JSON shape with
`session_id`/`started_at`/`pid`, 4-hour freshness window,
`STRIDE_ALLOW_DIRECT=1` override. Update Step 0 with the marker write
command and Step 9 with the clear command. The marker contract is byte-
identical to stride 1.10.0 so cross-plugin tooling works.

### W302 — port the gate

Port `stride/hooks/stride-skill-gate.sh` and `.ps1` (and the test
harnesses) to `stride-gemini/hooks/`. Two adapters required:

- **Skill-name extraction:** change `jq -r '.tool_input.skill'` to
  `jq -r '.tool_input.name'`. Also update the pure-bash fallback to look
  for the `"name"` field instead of `"skill"`.
- **Project-dir resolution:** prefer stdin `cwd` over the
  `GEMINI_PROJECT_DIR` / `CLAUDE_PROJECT_DIR` env chain (the existing
  stride-hook.sh keeps the env fallback for compatibility with manual hook
  testing).

Add a new entry to `stride-gemini/hooks/hooks.json` under `BeforeTool`:

```json
{
  "matcher": "activate_skill",
  "hooks": [
    {
      "name": "stride-skill-gate",
      "type": "command",
      "command": "${extensionPath}/hooks/stride-skill-gate.sh",
      "timeout": 10000
    }
  ]
}
```

### W303 — release stride-gemini

Bump version, CHANGELOG entry under "Added": gate scripts + marker
section + STOP preambles + INTERNAL descriptions. Note Layer-1 enforcement
is now active on Gemini.

## What stays in effect regardless

Layers 2 (INTERNAL descriptions, W299) and 3 (STOP preamble, W298) are
runtime-independent and remain the always-available enforcement.

## Custom-agent invocation and the `AfterAgent` input — measured (W2467, 2026-10-25)

stride 1.81.0 shipped two fixes whose value rests on host behaviour: W2254 (read the `key_files` while
the explorer runs) and W2255 (let a held-claim stop through while a subagent is still running, which
reads the running-agent list Claude Code puts on its `Stop` input). Each port has to measure its own
host before porting either. This section is that measurement for Gemini CLI.

### How it was measured

- **CLI version: 0.65.0** — the `latest` npm tag of `@google/gemini-cli` on the day, fetched with
  `npm pack` (no install scripts run) and executed from the package's own `bundle/gemini.js`, whose
  `--version` printed `0.65.0`.
- **Throwaway everything.** A scratch project and a scratch `HOME`, headless (`-p` with `--yolo`). The
  model endpoint was a local mock reached through `GOOGLE_GEMINI_BASE_URL`, with a placeholder API key:
  no real credential existed in the session, and none was needed, because the mock scripted the model.
- **The script.** The main model's first response asked for two calls at once — `invoke_agent` naming a
  throwaway user-level agent, and `read_file`. The agent ran `sleep 6` through `run_shell_command` and
  then called `complete_task`. Project-local hooks on `BeforeAgent`, `BeforeTool`, `AfterTool` and
  `AfterAgent` appended the event name, a millisecond clock and the sorted top-level field names of
  their stdin to a log. **The raw log is not committed**; only the field names and timings below are.
- **Two runs.** The second set `experimental.adk.agentSessionSubagentEnabled: true`, which selects the
  other invocation class in the agent tool's source. Both runs gave the same ordering. Whether that
  setting was honoured in headless mode was not separately confirmed; the source check below covers
  both classes either way.

### What the hooks saw (first run; milliseconds after the `invoke_agent` `BeforeTool`)

| Event | Tool | ms |
|---|---|---:|
| `BeforeTool` | `read_file` | 0 |
| `BeforeTool` | `invoke_agent` | 0 |
| `AfterTool` | `read_file` | 69 |
| `BeforeTool` | `run_shell_command` (inside the agent) | 70 |
| `AfterTool` | `run_shell_command` | 6,186 |
| `BeforeTool` / `AfterTool` | `complete_task` | 6,234 / 6,275 |
| `AfterTool` | `invoke_agent` | 6,321 |
| `AfterAgent` | — | 6,373 |

The mock recorded the main model's second request at 6,327 ms — after the invocation's `AfterTool`,
never during the sleep.

Field names on stdin:

- `BeforeAgent`: `cwd`, `hook_event_name`, `prompt`, `session_id`, `timestamp`, `transcript_path`
- `BeforeTool`: those base fields without `prompt`, plus `tool_name` and `tool_input`
- `AfterTool`: the `BeforeTool` set plus `tool_response`
- `AfterAgent`: `cwd`, `hook_event_name`, `prompt`, `prompt_response`, `session_id`,
  `stop_hook_active`, `timestamp`, `transcript_path`

Two side observations: the agent's own tool calls fired the session's `BeforeTool` / `AfterTool` hooks
like any other call, and `AfterAgent` fired exactly once per run — for the main turn, after the agent had
already returned. The agent's own turns did not fire it.

### Source cross-check (0.65.0 `@google/gemini-cli-core`, `dist/src`)

- `hooks/types.d.ts`: `AfterAgentInput` declares exactly `prompt`, `prompt_response` and
  `stop_hook_active` over the base fields. No agent or task list.
- `agents/agent-tool.js`: the invocation's `execute` awaits the child invocation. Both child classes
  await the finished result — `agents/local-invocation.js` awaits `executor.run`, and
  `agents/local-session-invocation.js` awaits `session.getResult()`.
- `scheduler/scheduler.js` with `utils/tool-utils.js` (`isParallelizable`): contiguous calls from one
  model response run as one batch, unless they are edits or set `wait_for_previous`. That is why
  `read_file` finished beside the invocation. Each result goes back to the model only when the batch
  is done.
- `docs/core/subagents.md`, bundled with the package, describes no background or asynchronous mode for
  subagents, so this version's own docs promise no background mode that its code then lacks.

### Answers

1. **Does the invocation block? Yes.** The main model takes no turn until the agent returns. Read-only
   calls in the same response can run beside it (an edit, or a call that sets `wait_for_previous`,
   waits for the calls ahead of it instead), but the model chose them before seeing anything, and their
   results arrive with the agent's.
2. **Does the `AfterAgent` input list running agents? No.** None of its eight fields is an agent or task
   list. `prompt_response` is the model's final text, not a list. And because the invocation holds the
   turn, `AfterAgent` cannot fire while an agent is running on this version.

### Decisions

- **W2254 — disclosed rather than ported.** `skills/stride-workflow/SKILL.md` Step 3 Branch C item 1 now
  says there is nothing to overlap. It gives no instruction to read files during the wait, which the
  host does not allow. It also gives no instruction to batch reads beside the invocation: the saving
  would be the reads' own milliseconds.
- **W2255 — not applicable.** `hooks/stride-stop-gate.sh` and `.ps1` are unchanged, and no
  running-agent marker was invented to stand in for a list the host does not provide.

Not applicable on this port, for the release entry:

- the W2255 running-agent permit at the stop gate and its 30-minute `since_epoch` bound — `AfterAgent`
  carries no running-agent list, and the gate never runs while an agent does;
- the W2254 instruction to read `key_files` while the explorer runs — the invocation holds the turn.

**Re-measure** when a Gemini CLI release documents a background subagent mode or adds an agent list to
the `AfterAgent` input. Test Group 37 in `hooks/test-stride-hook.sh` pins this record, the Branch C
wording and the unchanged gates, so a change to any of them shows up as a failing group.
