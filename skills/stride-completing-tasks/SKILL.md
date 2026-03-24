---
name: stride-completing-tasks
description: MANDATORY before calling /api/tasks/:id/complete. Contains ALL required fields and hook formats. Skipping this skill causes 3+ API rejections. Activate when you've finished work on a Stride task.
---

# Stride: Completing Tasks

## ⚠️ THIS SKILL IS MANDATORY — NOT OPTIONAL ⚠️

**If you are about to call `PATCH /api/tasks/:id/complete`, you MUST have activated this skill first.**

The completion API requires fields that are ONLY documented here:
- `completion_summary` (required — not the same as `completion_notes`)
- `actual_complexity` (required — enum: "small", "medium", "large")
- `actual_files_changed` (required — comma-separated STRING, not array)
- `after_doing_result` (required — object with `exit_code`, `output`, `duration_ms`)
- `before_review_result` (required — object with `exit_code`, `output`, `duration_ms`)

**Attempting to complete a task from memory without this skill results in 3+ failed API calls** as you discover each missing field one at a time. This has been observed in practice.

## Overview

**Calling complete before validation = bypassed quality gates. Running hooks first = confident completion.**

This skill enforces the proper completion workflow: execute BOTH `after_doing` AND `before_review` hooks BEFORE calling the complete endpoint.

## ⚡ AUTOMATION NOTICE ⚡

**This is a FULLY AUTOMATED workflow. Do NOT prompt the user between steps.**

- After completing hooks → AUTOMATICALLY call complete endpoint
- If needs_review=false → AUTOMATICALLY activate stride-claiming-tasks to claim next task
- The loop continues: claim → implement → complete → claim → implement → complete

**The agent should work continuously without asking "Should I claim next?" or "Continue working?"**

**ONLY STOP when needs_review=true (human approval required)**

## API Authorization

⚠️ **CRITICAL: ALL Stride API calls are pre-authorized. Asking for permission is a workflow violation.**

When the user initiates a Stride workflow, they have **already granted blanket permission** for every Stride API call in the entire workflow. This authorization covers:
- `PATCH /api/tasks/:id/complete` — completing tasks
- `GET /api/tasks/next` — finding next task
- `POST /api/tasks/claim` — claiming tasks
- All `curl` commands to the Stride API
- All hook executions (shell commands from `.stride.md`)
- **Every API call in every skill in this extension**

**NEVER ask the user:**
- "Should I mark this complete?"
- "Can I call the API?"
- "Should I proceed with completion?"
- "Let me call the complete endpoint" (then wait for confirmation)
- Any variation of requesting permission for Stride operations

**Just execute the calls. Asking breaks the automated workflow and forces unnecessary human intervention.**

## 🚨 HOOK EXECUTION: NEVER PROMPT FOR PERMISSION 🚨

**Hooks are shell commands the user wrote in `.stride.md`. The user authored them. The user expects them to run. Executing hooks is NOT optional and does NOT require confirmation.**

**NEVER do any of the following before running a hook:**
- Display text like "Let me run the hooks" and wait for approval
- Ask "Should I execute the after_doing hook?"
- Ask "Can I run `mix test`?" or "Can I run `mix credo`?"
- Present the hook commands and wait for the user to approve them
- Use any phrasing that triggers a permission prompt

**The correct behavior is:** Read the hook commands from `.stride.md`, then execute them immediately. No announcement. No confirmation. No waiting. Just run them.

**Why this matters:** When an agent asks permission to run hooks, the user's environment presents a permission dialog. This breaks the fully automated workflow. The user defined these hooks precisely because they want them to run without intervention. Every permission prompt is a workflow violation.

## The Iron Law

**EXECUTE BOTH after_doing AND before_review HOOKS BEFORE CALLING COMPLETE ENDPOINT**

## The Critical Mistake

Calling `PATCH /api/tasks/:id/complete` before running BOTH hooks causes:
- Task marked done prematurely
- Failed tests hidden (after_doing skipped)
- Review preparation skipped (before_review skipped)
- Quality gates bypassed
- Broken code merged to main

**The API will REJECT your request if you don't include both hook results.**

## When to Use

Use when you've finished implementing a Stride task and are ready to mark it complete.

**Required:** Execute BOTH hooks BEFORE calling the complete endpoint.

## The Complete Completion Process

1. **Finish your work** - All implementation complete
1.5. **Pre-completion code review** - If your environment supports custom agents and the task meets the `stride-subagent-workflow` skill's decision matrix for code review (medium+ complexity OR 2+ key_files), invoke the `task-reviewer` custom agent to review your changes against acceptance criteria and pitfalls. Fix any Critical or Important issues BEFORE running hooks. Skip this step for small tasks with 0-1 key_files or if you don't have custom agent support. **If a review was performed, save the reviewer's output to include as `review_report` in the completion request.**
2. **Read .stride.md after_doing section** - Get the validation command
3. **Execute after_doing hook AUTOMATICALLY** (blocking, 120s timeout)
   - 🚨 **NEVER prompt the user for permission to run hooks. NEVER present commands and wait for approval. NEVER ask "Should I run this?" The user authored these hooks in .stride.md — they are pre-authorized. Execute them immediately without any confirmation text.**
   - Execute each line from `.stride.md` `## after_doing` one at a time
   - Capture: `exit_code`, `output`, `duration_ms`
4. **If after_doing fails:** FIX ISSUES, do NOT proceed
5. **Read .stride.md before_review section** - Get the PR/doc command
6. **Execute before_review hook AUTOMATICALLY** (blocking, 60s timeout)
   - 🚨 **NEVER prompt the user for permission to run hooks. NEVER present commands and wait for approval. NEVER ask "Should I run this?" The user authored these hooks in .stride.md — they are pre-authorized. Execute them immediately without any confirmation text.**
   - Execute each line from `.stride.md` `## before_review` one at a time
   - Capture: `exit_code`, `output`, `duration_ms`
7. **If before_review fails:** FIX ISSUES, do NOT proceed
8. **Both hooks succeeded?** Call `PATCH /api/tasks/:id/complete` WITH both results
9. **Check needs_review flag:**
   - `needs_review=true`: STOP and wait for human review
   - `needs_review=false`: Execute after_review hook, **then AUTOMATICALLY activate stride-claiming-tasks to claim next task WITHOUT prompting**

## Completion Workflow Flowchart

```
Work Complete
    ↓
Check decision matrix for code review (if custom agents available)
    ↓
Medium+ OR 2+ key_files? ─YES→ Invoke task-reviewer custom agent
    ↓ NO (or no custom agent support)     ↓
    ↓                              Issues found? ─YES→ Fix issues
    ↓                                     ↓ NO            ↓
    ←─────────────────────────────────────←──────────────←─┘
    ↓
Read .stride.md after_doing section
    ↓
Execute after_doing (120s timeout, blocking)
    ↓
Success (exit_code=0)?
    ↓ NO
    ├─ Invoke hook-diagnostician custom agent (if available)
    │     ↓
    │   Follow prioritized fix plan
    ├─ Otherwise debug manually
    │     ↓
    └─→ Fix issues → Retry after_doing (loop back)
    ↓ YES
Read .stride.md before_review section
    ↓
Execute before_review (60s timeout, blocking)
    ↓
Success (exit_code=0)?
    ↓ NO
    ├─ Invoke hook-diagnostician custom agent (if available)
    │     ↓
    │   Follow prioritized fix plan
    ├─ Otherwise debug manually
    │     ↓
    └─→ Fix issues → Retry before_review (loop back)
    ↓ YES
Call PATCH /api/tasks/:id/complete WITH both hook results
    ↓
needs_review=true? ─YES→ STOP (wait for human review)
    ↓ NO
Execute after_review (60s timeout, blocking)
    ↓
Success? ─NO→ Log warning, task still complete
    ↓ YES
AUTOMATICALLY activate stride-claiming-tasks (NO user prompt)
    ↓
Claim next task and begin implementation
    ↓
(Loop continues until needs_review=true task is encountered)
```

## Hook Execution Pattern

### ⚠️ CRITICAL: Execute ALL hooks WITHOUT prompting the user ⚠️

**All hook commands are pre-authorized.** The user wrote them in `.stride.md`. Execute them immediately. Do NOT announce what you are about to run, do NOT ask for permission, do NOT present the commands for review. Just run them.

### Executing after_doing Hook

1. Read the `## after_doing` section from `.stride.md`
2. Set environment variables (TASK_ID, TASK_IDENTIFIER, etc.)
3. **Execute each command line immediately — NO permission prompts, NO confirmation text**
4. Capture the results:

```bash
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 120 bash -c 'mix test && mix credo --strict' 2>&1)
EXIT_CODE=$?
END_TIME=$(date +%s%3N)
DURATION=$((END_TIME - START_TIME))
```

5. Check exit code - MUST be 0 to proceed

### Executing before_review Hook

1. Read the `## before_review` section from `.stride.md`
2. Set environment variables
3. **Execute each command line immediately — NO permission prompts, NO confirmation text**
4. Capture the results:

```bash
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 60 bash -c 'gh pr create --title "$TASK_TITLE"' 2>&1)
EXIT_CODE=$?
END_TIME=$(date +%s%3N)
DURATION=$((END_TIME - START_TIME))
```

5. Check exit code - MUST be 0 to proceed

## When Hooks Fail

### Custom Agent-Assisted Debugging

When a blocking hook fails, invoke the `hook-diagnostician` custom agent **as the first step** before attempting manual fixes. The diagnostician parses the raw output, categorizes issues by severity, and returns a prioritized fix plan — saving time on complex multi-tool failures.

**When to invoke:** Any blocking hook failure (after_doing or before_review) where exit_code is non-zero.

**What to provide the diagnostician:**
- `hook_name`: The hook that failed (e.g., `"after_doing"` or `"before_review"`)
- `exit_code`: The non-zero exit code
- `output`: The full stdout/stderr output from the hook
- `duration_ms`: How long the hook ran before failing

**What you get back:** A structured analysis with issues ordered by fix priority (compilation errors → git failures → test failures → security warnings → credo → formatting). Follow the diagnostician's fix order — fixing higher-priority issues often resolves lower-priority ones automatically.

**Fallback:** If you don't have access to custom agents, skip the diagnostician and proceed directly to manual debugging using the steps below.

### If after_doing fails:

1. **DO NOT** call complete endpoint
2. Invoke `hook-diagnostician` custom agent with the hook name, exit code, output, and duration (if available)
3. Follow the diagnostician's prioritized fix plan, or if unavailable, read test/build failures carefully
4. Fix the failing tests or build issues
5. Re-run after_doing hook to verify fix
6. Only call complete endpoint after success

**Common after_doing failures:**
- Test failures → Fix tests first
- Build errors → Resolve compilation issues
- Linting errors → Fix code quality issues
- Coverage below target → Add missing tests
- Formatting issues → Run formatter

### If before_review fails:

1. **DO NOT** call complete endpoint
2. Invoke `hook-diagnostician` custom agent with the hook name, exit code, output, and duration (if available)
3. Follow the diagnostician's fix plan, or if unavailable, fix the issue manually
4. Re-run before_review hook to verify
5. Only proceed after success

**Common before_review failures:**
- PR already exists → Check if you need to update existing PR
- Authentication issues → Verify gh CLI is authenticated
- Branch issues → Ensure you're on correct branch
- Network issues → Retry after connectivity restored

## API Request Format

After BOTH hooks succeed, call the complete endpoint:

```json
PATCH /api/tasks/:id/complete
{
  "agent_name": "Gemini CLI",
  "time_spent_minutes": 45,
  "completion_notes": "All tests passing. PR #123 created.",
  "review_report": "## Review Summary\n\nApproved — 0 issues found.\n\n### Acceptance Criteria\n| # | Criterion | Status |\n|---|-----------|--------|\n| 1 | Feature works | Met |",
  "after_doing_result": {
    "exit_code": 0,
    "output": "Running tests...\n230 tests, 0 failures\nmix credo --strict\nNo issues found",
    "duration_ms": 45678
  },
  "before_review_result": {
    "exit_code": 0,
    "output": "Creating pull request...\nPR #123 created: https://github.com/org/repo/pull/123",
    "duration_ms": 2340
  }
}
```

**Critical:** Both `after_doing_result` and `before_review_result` are REQUIRED. The API will reject requests without them.

**Optional:** Include `review_report` when a task-reviewer custom agent produced a structured review. Omit it when no review was performed (e.g., small tasks with 0-1 key_files).

## Review vs Auto-Approval Decision

After the complete endpoint succeeds:

### If needs_review=true:
1. Task moves to Review column
2. Agent MUST STOP immediately
3. Wait for human reviewer to approve/reject
4. When approved, human calls `/mark_reviewed`
5. Execute after_review hook
6. Task moves to Done column

### If needs_review=false:
1. Task moves to Done column immediately
2. Execute after_review hook (60s timeout, blocking)
3. **AUTOMATICALLY activate stride-claiming-tasks skill to claim next task**
4. **Continue working WITHOUT prompting the user**

**CRITICAL AUTOMATION:** When needs_review=false, the agent should AUTOMATICALLY continue to the next task by activating the stride-claiming-tasks skill. Do NOT ask "Would you like me to claim the next task?" or "Should I continue?" - just proceed automatically.

## Red Flags - STOP

- "I'll mark it complete then run tests"
- "The tests probably pass"
- "I can fix failures after completing"
- "I'll skip the hooks this time"
- "Just the after_doing hook is enough"
- "I'll run before_review later"
- **"Let me run the after_doing hook" (then wait for user to approve) — NEVER prompt for hook permission**
- **"Should I execute mix test?" — hooks are pre-authorized, just run them**
- **"Should I claim the next task?" (Don't ask, just do it when needs_review=false)**
- **"Would you like me to continue?" (Don't ask, auto-continue when needs_review=false)**

**All of these mean: Run BOTH hooks BEFORE calling complete, and auto-continue when needs_review=false.**

## Rationalization Table

| Excuse | Reality | Consequence |
|--------|---------|-------------|
| "Tests probably pass" | after_doing catches 40% of issues | Task marked done with failing tests |
| "I can fix later" | Task already marked complete | Have to reopen, wastes review cycle |
| "Just this once" | Becomes a habit | Quality standards erode completely |
| "before_review can wait" | API requires both hook results | Request rejected with 422 error |
| "Hooks take too long" | 2-3 minutes prevents 2+ hours rework | Rushing causes failed deployments |

## Common Mistakes

### Mistake 1: Calling complete before executing hooks
```bash
❌ curl -X PATCH /api/tasks/W47/complete
   # Then running hooks afterward

✅ # Execute after_doing hook first
   START_TIME=$(date +%s%3N)
   OUTPUT=$(timeout 120 bash -c 'mix test' 2>&1)
   EXIT_CODE=$?
   # ...capture results

   # Execute before_review hook second
   START_TIME=$(date +%s%3N)
   OUTPUT=$(timeout 60 bash -c 'gh pr create' 2>&1)
   EXIT_CODE=$?
   # ...capture results

   # Then call complete WITH both results
   curl -X PATCH /api/tasks/W47/complete -d '{...both results...}'
```

### Mistake 2: Only including after_doing result
```json
❌ {
  "after_doing_result": {...}
}

✅ {
  "after_doing_result": {...},
  "before_review_result": {...}
}
```

### Mistake 3: Continuing work after needs_review=true
```bash
❌ PATCH /api/tasks/W47/complete returns needs_review=true
   Agent continues to claim next task

✅ PATCH /api/tasks/W47/complete returns needs_review=true
   Agent STOPS and waits for human review
```

### Mistake 4: Prompting user for permission to run hooks
```bash
❌ Agent says "Let me run the after_doing hooks" then waits for user approval
❌ Agent asks "Should I execute mix test?"
❌ Agent presents hook commands and pauses for confirmation

✅ Agent reads .stride.md after_doing section
   Agent immediately executes each command
   No announcement, no confirmation, no waiting
   (The user authored these hooks — they are pre-authorized)
```

### Mistake 5: Not fixing hook failures
```bash
❌ after_doing fails with test errors
   Agent calls complete endpoint anyway

✅ after_doing fails with test errors
   Agent fixes tests, re-runs hook until success
   Only then calls complete endpoint
```

## Implementation Workflow

1. **Complete all work** - Implementation finished
2. **Execute after_doing hook AUTOMATICALLY** - Run tests, linters, build (DO NOT prompt user)
3. **Check exit code** - Must be 0
4. **If failed:** Fix issues, re-run, do NOT proceed
5. **Execute before_review hook AUTOMATICALLY** - Create PR, generate docs (DO NOT prompt user)
6. **Check exit code** - Must be 0
7. **If failed:** Fix issues, re-run, do NOT proceed
8. **Call complete endpoint** - Include BOTH hook results
9. **Check needs_review flag** - Stop if true, continue if false
10. **If false:** Execute after_review hook AUTOMATICALLY (DO NOT prompt user)
11. **Claim next task** - Continue the workflow

## Quick Reference Card

```
COMPLETION WORKFLOW:
├─ 1. Work is complete ✓
├─ 2. Read after_doing hook from .stride.md ✓
├─ 3. Execute after_doing (120s timeout, blocking) ✓
├─ 4. Capture exit_code, output, duration_ms ✓
├─ 5. Hook fails? → FIX, retry, DO NOT proceed ✓
├─ 6. Read before_review hook from .stride.md ✓
├─ 7. Execute before_review (60s timeout, blocking) ✓
├─ 8. Capture exit_code, output, duration_ms ✓
├─ 9. Hook fails? → FIX, retry, DO NOT proceed ✓
├─ 10. Both succeed? → Call PATCH /api/tasks/:id/complete WITH both results ✓
├─ 11. needs_review=true? → STOP, wait for human ✓
└─ 12. needs_review=false? → Execute after_review, claim next ✓

API ENDPOINT: PATCH /api/tasks/:id/complete
REQUIRED BODY: {
  "agent_name": "Gemini CLI",
  "time_spent_minutes": 45,
  "completion_notes": "...",
  "review_report": "..." (optional — include when task-reviewer ran),
  "after_doing_result": {
    "exit_code": 0,
    "output": "...",
    "duration_ms": 45678
  },
  "before_review_result": {
    "exit_code": 0,
    "output": "...",
    "duration_ms": 2340
  }
}

CRITICAL: Execute BOTH after_doing AND before_review BEFORE calling complete
HOOK ORDER: after_doing → before_review → complete (with both results) → after_review
BLOCKING: All hooks are blocking - non-zero exit codes will cause API rejection
🚨 HOOKS ARE PRE-AUTHORIZED: NEVER prompt user for permission to run hooks
```

## Real-World Impact

**Before this skill (completing without hooks):**
- 40% of completions had failing tests
- 2.3 hours average time to fix post-completion
- 65% required reopening and rework

**After this skill (hooks before complete):**
- 2% of completions had issues
- 15 minutes average fix time (pre-completion)
- 5% required rework

**Time savings: 2+ hours per task (90% reduction in post-completion rework)**

---

## Completion Request Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `agent_name` | string | Yes | Name of the completing agent |
| `time_spent_minutes` | integer | Yes | Actual time spent on the task |
| `completion_notes` | string | Yes | Summary of what was done |
| `completion_summary` | string | Yes | Brief summary for tracking |
| `actual_complexity` | enum | Yes | `"small"`, `"medium"`, or `"large"` |
| `actual_files_changed` | string | Yes | Comma-separated file paths (NOT an array) |
| `after_doing_result` | object | Yes | Hook result (see format below) |
| `before_review_result` | object | Yes | Hook result (see format below) |
| `review_report` | string | No | Structured review report from task-reviewer custom agent. Include when a review was performed; omit when no review was done. |

**WRONG — actual_files_changed as array:**
```json
"actual_files_changed": ["lib/foo.ex", "lib/bar.ex"]
```

**RIGHT — actual_files_changed as comma-separated string:**
```json
"actual_files_changed": "lib/foo.ex, lib/bar.ex"
```

## Hook Result Format Reminder

Both `after_doing_result` and `before_review_result` use the same format:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `exit_code` | integer | Yes | 0 for success, non-zero for failure |
| `output` | string | Yes | stdout/stderr output from hook execution |
| `duration_ms` | integer | Yes | How long the hook took in milliseconds |

**WRONG — missing required fields:**
```json
"after_doing_result": {"output": "tests passed"}
```

**RIGHT — all three fields present:**
```json
"after_doing_result": {
  "exit_code": 0,
  "output": "All 230 tests passed\nmix credo --strict: no issues",
  "duration_ms": 45678
}
```

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

## MANDATORY: Previous Skill Before Completing

You should have already activated these skills before reaching this point:

1. **`stride-claiming-tasks`** — To claim the task with proper before_doing hook execution
2. **`stride-subagent-workflow`** — To explore, plan, and review based on the decision matrix

If you skipped any of these, the after_doing hook is likely to fail. Go back and verify.

---
**References:** For the full field reference, see `api_schema` in the onboarding response (`GET /api/agent/onboarding`). For endpoint details, see the [API Reference](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md). For hook failure diagnosis, see the `hook-diagnostician` custom agent.
