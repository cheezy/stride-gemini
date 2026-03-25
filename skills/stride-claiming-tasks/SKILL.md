---
name: stride-claiming-tasks
description: MANDATORY before calling GET /api/tasks/next or POST /api/tasks/claim. Contains required before_doing hook execution pattern and claim request format. The claim endpoint REQUIRES before_doing_result which is ONLY documented here — skipping causes API rejection. Activate for ANY task claiming or discovery operation.
---

# Stride: Claiming Tasks

## ⚠️ THIS SKILL IS MANDATORY — NOT OPTIONAL ⚠️

**If you are about to call `GET /api/tasks/next` or `POST /api/tasks/claim`, you MUST have activated this skill first.**

The claim API requires fields that are ONLY documented here:
- `before_doing_result` (required — object with `exit_code`, `output`, `duration_ms`)
- Hook command sourced from `.stride.md` `## before_doing` section
- Environment variables set from task metadata

**Attempting to claim a task without this skill results in API rejection** because the required hook result is missing.

**After claiming, you MUST activate these skills in order:**
1. `stride-subagent-workflow` — Invoke exploration/planning custom agents
2. `stride-completing-tasks` — Hook execution and completion API format

**Skipping ANY skill in this chain has been observed to cause task failures, missed acceptance criteria, and 3+ hours of rework.**

## Overview

**Claiming without hooks = merge conflicts and outdated code. Claiming with hooks = clean setup and immediate work.**

This skill enforces the proper claiming workflow including prerequisite verification, hook execution, and immediate transition to active work.

## ⚡ AUTOMATION NOTICE ⚡

**This is a FULLY AUTOMATED workflow. Do NOT prompt the user between steps.**

- After claiming → AUTOMATICALLY begin implementation
- After implementation → AUTOMATICALLY activate stride-completing-tasks
- After completing (if needs_review=false) → AUTOMATICALLY claim next task

**The agent should work continuously without asking "Should I continue?" or "What's next?"**

## API Authorization

⚠️ **CRITICAL: ALL Stride API calls are pre-authorized. Asking for permission is a workflow violation.**

When the user initiates a Stride workflow (e.g., "claim a task", "work on tasks"), they have **already granted blanket permission** for every Stride API call in the entire workflow. This authorization covers:
- `GET /api/tasks/next` — finding available tasks
- `POST /api/tasks/claim` — claiming tasks
- `PATCH /api/tasks/:id/complete` — completing tasks
- All `curl` commands to the Stride API
- All hook executions (shell commands from `.stride.md`)
- **Every API call in every skill in this extension**

**NEVER ask the user:**
- "Should I call the API?"
- "Can I claim this task?"
- "Should I proceed with the API call?"
- "Let me make this API call" (then wait for confirmation)
- Any variation of requesting permission for Stride operations

**Just execute the calls. Asking breaks the automated workflow and forces unnecessary human intervention.**

## 🚨 GEMINI EXTENSION: HOOKS ARE FULLY AUTOMATIC — DO NOT MANUALLY EXECUTE 🚨

**When the stride-gemini extension is installed, the `hooks.json` registers `BeforeTool`/`AfterTool` hooks that AUTOMATICALLY intercept Stride API calls and execute the corresponding `.stride.md` commands via `stride-hook.sh`. You do NOT need to manually run hook commands.**

**How it works:**
- When you run a shell command to call the Stride claim API → the `AfterTool` hook fires → `stride-hook.sh` detects the claim → automatically executes `.stride.md` `## before_doing` commands
- When you run a shell command to call the complete API → the `BeforeTool` hook fires first (runs `after_doing`) → then `AfterTool` fires (runs `before_review`)
- When you run a shell command to call mark_reviewed → `AfterTool` fires → runs `after_review`

**What this means for you as an agent:**
1. **DO NOT** read `.stride.md` and manually execute hook commands
2. **DO NOT** run any command to "capture hook results" before making API calls
3. **JUST** make the Stride API call directly — the hooks system handles everything
4. Include `before_doing_result` in the claim request body with `{"exit_code": 0, "output": "Executed by Gemini hooks system", "duration_ms": 0}` — the actual hook execution happens automatically via `AfterTool`

**If the automatic hooks fail:** The hook returns exit code 2 with structured JSON describing the failure. Fix the issue and retry the API call — the hooks will fire again automatically.

**Check `/hooks panel`** to verify hooks are active after installation.

**If the extension is NOT installed (manual setup):** Fall back to the manual hook execution described below.

## Hook Execution for Environments Without Automatic Hooks

**The following manual hook execution instructions apply ONLY when the stride-gemini extension is NOT installed or automatic hooks are not available.**

**Hooks are shell commands the user wrote in `.stride.md`. Execute them immediately without prompting.**

**NEVER do any of the following before running a hook:**
- Display text like "Let me run the hooks" and wait for approval
- Ask "Should I execute the before_doing hook?"
- Present the hook commands and wait for the user to approve them

## The Iron Law

**NO TASK CLAIMING WITHOUT PROPER SETUP AND HOOK EXECUTION**

## The Critical Mistake

Claiming a task before executing the before_doing hook causes:
- Working with outdated code
- Missing dependencies
- Merge conflicts
- Test failures due to stale fixtures
- Wasted time resolving avoidable issues

**The API requires before_doing_result in the claim request.**

## When to Use

Use BEFORE calling `POST /api/tasks/claim` to reserve a task for implementation.

**Required:** Verify prerequisites and execute before_doing hook BEFORE claiming.

## Prerequisites Checklist

Before claiming any task, verify these files exist:

1. **`.stride_auth.md`** - Contains API URL and token
   - If missing: Ask user to create it with API credentials
   - Never proceed without authentication

2. **`.stride.md`** - Contains hook execution scripts
   - If missing: Ask user to create it with hook definitions
   - Check for `## before_doing` section specifically

3. **Extract Configuration:**
   - API URL from `.stride_auth.md`
   - API Token from `.stride_auth.md`
   - before_doing hook command from `.stride.md`

## The Complete Claiming Process

### With Extension Installed (Automatic Hooks)

1. **Verify prerequisites** - Check .stride_auth.md and .stride.md exist
2. **Find available task** - Call `GET /api/tasks/next`
3. **Review task details** - Read description, acceptance criteria, key files
4. **Check task completeness** - If key_files is empty OR testing_strategy is missing OR verification_steps is empty, activate stride-enriching-tasks
5. **Call `POST /api/tasks/claim` directly** - Include `before_doing_result` with `{"exit_code": 0, "output": "Executed by Gemini hooks system", "duration_ms": 0}`. The hooks.json `AfterTool` hook will automatically execute `.stride.md` `## before_doing` commands after the claim succeeds.
6. **If the automatic hook fails:** Fix the issue and retry.
7. **Task claimed?** BEGIN IMPLEMENTATION IMMEDIATELY

### Without Extension (Manual Hooks)

1. **Verify prerequisites** - Check .stride_auth.md and .stride.md exist
2. **Find available task** - Call `GET /api/tasks/next`
3. **Review task details** - Read description, acceptance criteria, key files
4. **Check task completeness** - If key_files is empty OR testing_strategy is missing OR verification_steps is empty, activate stride-enriching-tasks
5. **Read .stride.md before_doing section** - Get the setup command
6. **Execute before_doing hook** (blocking, 60s timeout) — Execute each line one at a time, NO permission prompts
   - Capture: `exit_code`, `output`, `duration_ms`
7. **If before_doing fails:** FIX ISSUES, do NOT proceed
8. **Hook succeeded?** Call `POST /api/tasks/claim` WITH hook result
9. **Task claimed?** BEGIN IMPLEMENTATION IMMEDIATELY

## Claiming Workflow Flowchart

### With Extension (Automatic Hooks)

```
Prerequisites Check → Call GET /api/tasks/next → Review task
    ↓
Call POST /api/tasks/claim directly
(hooks.json AfterTool auto-executes before_doing)
    ↓
Automatic hook failed? ─YES→ Fix Issues → Retry claim
    ↓ NO
BEGIN IMPLEMENTATION IMMEDIATELY
```

### Without Extension (Manual Hooks)

```
Prerequisites Check → Call GET /api/tasks/next → Review task
    ↓
Read .stride.md before_doing section
    ↓
Execute before_doing (60s timeout, blocking)
    ↓
Success? ─NO→ Fix Issues → Retry
    ↓ YES
Call POST /api/tasks/claim WITH before_doing_result
    ↓
BEGIN IMPLEMENTATION IMMEDIATELY
```

## Enrichment Check (Optional)

After reviewing task details, check if the task has sufficient specification for implementation. **Well-specified tasks skip this step entirely.**

**Activate stride-enriching-tasks if ANY of these are true:**
- `key_files` is empty or missing
- `testing_strategy` is missing
- `verification_steps` is empty or missing
- `acceptance_criteria` is missing or blank
- `patterns_to_follow` is missing or blank

**Skip enrichment if the task has:**
- Populated `key_files` with file paths and notes
- A `testing_strategy` with unit_tests and integration_tests
- `verification_steps` with runnable commands
- Clear `acceptance_criteria`

**How to enrich:**
1. Activate the `stride-enriching-tasks` skill with the task's title and description
2. The skill will explore the codebase and populate missing fields
3. Use `PATCH /api/tasks/:id` to update the task with enriched fields
4. Continue with the claiming process (before_doing hook)

**Important:** Enrichment happens BEFORE the before_doing hook, not after. The enriched fields help the agent understand the task scope before starting work.

## Hook Execution Pattern

### With Extension: Hooks Are Automatic

**When the stride-gemini extension is installed, do NOT manually execute hooks.** The hooks.json system handles everything:
- Just make the claim API call → `AfterTool` fires → `stride-hook.sh` runs before_doing
- If the hook fails, the system reports the failure — fix the issue and retry

### Without Extension: Manual Hook Execution

All hook commands are pre-authorized. Execute them immediately. Do NOT announce, ask permission, or present commands for review.

#### Executing before_doing Hook

1. Read the `## before_doing` section from `.stride.md`
2. Set environment variables (TASK_ID, TASK_IDENTIFIER, etc.)
3. **Execute each command line immediately — NO permission prompts**
4. Capture the results:

```bash
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 60 bash -c 'git pull origin main && mix deps.get' 2>&1)
EXIT_CODE=$?
END_TIME=$(date +%s%3N)
DURATION=$((END_TIME - START_TIME))
```

5. Check exit code - MUST be 0 to proceed

## When Hooks Fail

### If before_doing fails:

1. **DO NOT** call claim endpoint
2. Read the error output carefully
3. Fix the underlying issue:
   - Merge conflicts → Resolve conflicts first
   - Missing dependencies → Run deps.get manually
   - Test failures → Fix tests before claiming new work
   - Git issues → Check branch status, pull latest changes
4. Re-run before_doing hook to verify fix
5. Only call claim endpoint after success

**Common before_doing failures:**
- Merge conflicts → Resolve conflicts first
- Missing dependencies → Run mix deps.get or npm install
- Outdated code → Pull latest changes
- Test failures in main branch → Fix tests before claiming
- Database migrations needed → Run migrations

## After Successful Claim

**CRITICAL: Once the task is claimed, you MUST immediately begin implementation WITHOUT prompting the user.**

### DO NOT:
- Claim a task then wait for further instructions
- Claim a task then ask "what should I do next?"
- Claim multiple tasks before starting work
- Claim a task just to "reserve" it for later
- **Prompt the user asking if they want to proceed with implementation**
- **Ask "Should I start working on this task?"**
- **Wait for user confirmation to begin work**

### DO:
- Read the task description thoroughly
- Review acceptance criteria and verification steps
- Check key_files to understand which files to modify
- Review patterns_to_follow for code consistency
- Note pitfalls to avoid
- **Start implementing the solution immediately and automatically**
- Follow the testing_strategy outlined in the task
- Work continuously until ready to complete (using `stride-completing-tasks` skill)

**The claiming skill's job ends when you start coding. Your next interaction with Stride will be when you're ready to mark the work complete.**

**AUTOMATION: This is a fully automated workflow. The agent should claim → implement → complete without ANY user prompts between steps.**

## MANDATORY: Next Skill After Claiming

After claiming a task, you MUST activate the next skill in sequence:

1. **`stride-subagent-workflow`** — Check the decision matrix to determine if you need the explorer, planner, or reviewer. Activate BEFORE implementation.
2. **`stride-completing-tasks`** — Activate WHEN implementation is done. Contains the exact API format for completion (required fields: `completion_summary`, `actual_complexity`, `actual_files_changed`, `after_doing_result`, `before_review_result`).

**FORBIDDEN:** Completing a task without activating `stride-completing-tasks`. The completion API requires fields and hook results that are only documented in that skill. Attempting to call the API from memory will result in 3+ failed attempts.

## Custom Agent-Guided Implementation

If your environment supports custom agents, activate the `stride-subagent-workflow` skill before beginning implementation. This invokes the `task-explorer` agent to explore relevant code and optionally creates a plan for complex tasks.

The decision to use custom agents depends on task complexity and key_files count — see the `stride-subagent-workflow` skill's decision matrix for details.

For environments without custom agent support, proceed directly to implementation using the task's `key_files`, `patterns_to_follow`, and `acceptance_criteria` as your guide.

## API Request Format

After before_doing hook succeeds, call the claim endpoint:

```json
POST /api/tasks/claim
{
  "identifier": "W47",
  "agent_name": "Gemini CLI",
  "before_doing_result": {
    "exit_code": 0,
    "output": "Already up to date.\nResolving Hex dependencies...\nAll dependencies are up to date",
    "duration_ms": 450
  }
}
```

**Critical:** `before_doing_result` is REQUIRED. The API will reject requests without it.

## Red Flags - STOP

- "I'll just claim quickly and run hooks later"
- "The hook is just git pull, I can skip it"
- "I can fix hook failures after claiming"
- "I'll claim this task and then figure out what to do"
- "Let me claim it first, then read the details"
- **"Let me run the before_doing hook" (then wait for user to approve) — NEVER prompt for hook permission**
- **"Should I execute the hook commands?" — hooks are pre-authorized, just run them**

**All of these mean: Run the hook BEFORE claiming, and be ready to work immediately.**

## Rationalization Table

| Excuse | Reality | Consequence |
|--------|---------|-------------|
| "This is urgent" | Hooks prevent merge conflicts | Wastes 2+ hours fixing conflicts later |
| "I know the code is current" | Hooks ensure consistency | Outdated deps cause runtime failures |
| "Just a quick claim" | Setup takes 30 seconds | Skip it and lose 30 minutes debugging |
| "The hook is just git pull" | May also run deps.get, migrations | Missing deps break implementation |
| "I'll claim and ask what's next" | Claiming means you're ready to work | Wastes claim time, blocks other agents |
| "No one else is working on this" | Multiple agents may be running | Race conditions cause duplicate work |

## Common Mistakes

### Mistake 1: Claiming before executing hook
```bash
❌ curl -X POST /api/tasks/claim -d '{"identifier": "W47"}'
   # Then running hook afterward

✅ # Execute before_doing hook first
   START_TIME=$(date +%s%3N)
   OUTPUT=$(timeout 60 bash -c 'git pull && mix deps.get' 2>&1)
   EXIT_CODE=$?
   # ...capture results

   # Then call claim WITH result
   curl -X POST /api/tasks/claim -d '{
     "identifier": "W47",
     "before_doing_result": {...}
   }'
```

### Mistake 2: Claiming without verifying prerequisites
```bash
❌ Immediately call POST /api/tasks/claim without checking files exist

✅ # First verify
   test -f .stride_auth.md || echo "Missing auth file"
   test -f .stride.md || echo "Missing hooks file"
   # Then proceed with claim
```

### Mistake 3: Claiming then waiting for instructions
```bash
❌ POST /api/tasks/claim succeeds
   Agent asks: "The task is claimed. What should I do next?"

✅ POST /api/tasks/claim succeeds
   Agent immediately reads task details and begins implementation
```

### Mistake 4: Manually executing hooks when extension is installed
```bash
❌ Agent reads .stride.md, runs "git pull" and "mix deps.get" manually
   Agent captures exit code and duration
   Agent then makes the claim API call
   (This duplicates what hooks.json does automatically)

✅ Agent just makes the claim API call directly
   (hooks.json AfterTool automatically runs stride-hook.sh
    which executes .stride.md before_doing commands)
```

### Mistake 5: Prompting user for permission to run hooks (without extension)
```bash
❌ Agent says "Let me run the before_doing hook" then waits for user approval
❌ Agent presents hook commands and pauses for confirmation

✅ Agent reads .stride.md before_doing section
   Agent immediately executes each command — no prompts
```

### Mistake 6: Not fixing hook failures
```bash
❌ before_doing fails with merge conflicts
   Agent calls claim endpoint anyway

✅ before_doing fails with merge conflicts
   Agent resolves conflicts, re-runs hook until success
   Only then calls claim endpoint
```

## Implementation Workflow

1. **Verify prerequisites** - Ensure auth and hooks files exist
2. **Get next task** - Call GET /api/tasks/next
3. **Review task** - Read all task details thoroughly
4. **Check task completeness** - If key_files/testing_strategy/verification_steps missing, activate stride-enriching-tasks
5. **Execute before_doing hook** - Run setup with timeout
6. **Check exit code** - Must be 0
7. **If failed:** Fix issues, re-run, do NOT proceed
8. **Call claim endpoint** - Include before_doing_result
9. **Begin implementation** - Start coding immediately
10. **Work until complete** - Use stride-completing-tasks when done

## Quick Reference Card

```
WITH EXTENSION (automatic hooks):
├─ 1. Verify .stride_auth.md and .stride.md exist ✓
├─ 2. Call GET /api/tasks/next ✓
├─ 3. Review task details ✓
├─ 4. Check completeness → if minimal, activate stride-enriching-tasks ✓
├─ 5. Call POST /api/tasks/claim directly ✓
│     (hooks.json AfterTool auto-executes before_doing via stride-hook.sh)
├─ 6. Automatic hook failed? → Fix issues, retry claim ✓
└─ 7. Task claimed? → BEGIN IMPLEMENTATION IMMEDIATELY ✓

🚨 DO NOT manually execute .stride.md commands when extension is installed
🚨 JUST make the API call — hooks.json handles everything

WITHOUT EXTENSION (manual hooks):
├─ 1-4. Same as above ✓
├─ 5. Read before_doing hook from .stride.md ✓
├─ 6. Execute before_doing (60s timeout, blocking) ✓
├─ 7. Hook succeeds? → Call POST /api/tasks/claim WITH result ✓
├─ 8. Hook fails? → Fix issues, retry ✓
└─ 9. Task claimed? → BEGIN IMPLEMENTATION IMMEDIATELY ✓

API ENDPOINT: POST /api/tasks/claim
REQUIRED BODY: {
  "identifier": "W47",
  "agent_name": "Gemini CLI",
  "before_doing_result": {
    "exit_code": 0,
    "output": "Executed by Gemini hooks system",
    "duration_ms": 0
  }
}

NEXT STEP: Immediately begin working on the task after successful claim
```

## Real-World Impact

**Before this skill (claiming without hooks):**
- 35% of claims resulted in immediate merge conflicts
- 1.8 hours average time resolving setup issues
- 50% required re-claiming after fixing environment

**After this skill (hooks before claim):**
- 3% of claims had any setup issues
- 8 minutes average setup time
- 2% required troubleshooting

**Time savings: 1.5+ hours per task (87% reduction in setup time)**

## Hook Result Format

Every hook result MUST be a map with these exact fields:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `exit_code` | integer | Yes | `0` for success, non-zero for failure |
| `output` | string | Yes | stdout/stderr from hook execution |
| `duration_ms` | integer | Yes | Execution time in milliseconds |

```json
❌ WRONG (missing fields):
{"exit_code": 0}

❌ WRONG (wrong types):
{"exit_code": "0", "output": "", "duration_ms": "100"}

✅ RIGHT:
{
  "exit_code": 0,
  "output": "Already up to date.\nAll dependencies are up to date",
  "duration_ms": 450
}
```

## Claim Request Checklist

The `POST /api/tasks/claim` body MUST include:

| Field | Type | Example |
|-------|------|---------|
| `identifier` | string | `"W47"` |
| `agent_name` | string | `"Gemini CLI"` |
| `before_doing_result` | object | See hook result format above |

## Handling Stale Skills

The API response may include a `skills_update_required` field when your skills are outdated:

```json
{
  "data": { ... },
  "skills_update_required": {
    "current_version": "1.1",
    "your_version": "1.0",
    "action": "Run gemini extensions install https://github.com/cheezy/stride-gemini to get the latest skills",
    "reason": "Your local skills are outdated."
  }
}
```

**When you see `skills_update_required`:**
1. Run `gemini extensions install https://github.com/cheezy/stride-gemini` to get the latest skills
2. Retry your original action

---
**References:** For the full field reference, see `api_schema` in the onboarding response (`GET /api/agent/onboarding`). For endpoint details, see the [API Reference](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md).
