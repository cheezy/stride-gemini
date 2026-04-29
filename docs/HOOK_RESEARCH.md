# Gemini CLI Hook Research — Skill-Gate Portability

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
