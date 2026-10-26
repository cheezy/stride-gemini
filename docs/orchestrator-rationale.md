# Why the stride-workflow skill says what it says

Gemini CLI reads `skills/stride-workflow/SKILL.md` in full every time the orchestrator runs a task, so the background behind its rules costs context on every task even though no step needs it. Each section below is a passage that explained a rule without stating one; it was lifted out of the skill unchanged, and the skill keeps a pointer naming the section at the spot it came from.

**No rule lives in this file.** The skill is the only authority: if this page and the skill ever seem to disagree, do what the skill says and correct this page. Nothing in a task requires opening it.

## Seventeen Tasks and the Skipped Steps

*Lifted from `skills/stride-workflow/SKILL.md`, Purpose.*

During a 17-task session, an agent consistently skipped mandatory workflow steps despite skills being labeled MANDATORY. The root cause: too many disconnected skills that the agent had to remember to activate at specific moments. Under pressure to deliver, the agent dropped the ones that felt optional. This orchestrator eliminates that failure mode.

## Where the Marker Path Comes From

*Lifted from `skills/stride-workflow/SKILL.md`, Orchestrator Activation Marker, Marker Contract.*

Gemini CLI does not set a dedicated project-directory environment variable (the hooks reference passes `cwd` on stdin to hook scripts; the agent itself runs `run_shell_command` from the project root). The orchestrator therefore writes the marker relative to the active working directory using a fallback chain: `${GEMINI_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$(pwd)}}`. The companion gate script (`stride-skill-gate.sh`) prefers the stdin `cwd` field with the same env-var fallback so the two agree on the marker location regardless of host.

## The Plan Trigger Branch C Once Carried

*Lifted from `skills/stride-workflow/SKILL.md`, Step 3, Branch C item 2.*

This item previously stated its own trigger ("medium+ OR 3+ key_files OR 3+ acceptance criteria lines"), which could fire on a row whose `Plan` column says Skip — the `small, 2+ key_files` row being the collision.

## The Review Trigger Step 5 Once Carried

*Lifted from `skills/stride-workflow/SKILL.md`, Step 5, opening paragraph.*

This line previously restated its own trigger ("medium+ OR 2+ key_files"), which disagreed with the matrix for a `small` defect with 1 `key_file` — the same defect class, in the Review column instead of the Plan column.

## Why a Specialist Checks the Security Considerations

*Lifted from `skills/stride-workflow/SKILL.md`, Step 5, Deep security-considerations review.*

**Why this sub-step exists.** The task-reviewer already records a `security_considerations` section verdict, but as a generalist. When the `stride-gemini-security-review` extension is installed, this sub-step runs the *specialist* `security-reviewer` custom agent against each of the task's `security_considerations`, folds a per-consideration verdict into the completion payload, and routes any un-addressed consideration through the same gate that already blocks on a failed section — so a real, unmitigated security implication cannot reach Done.

## How Manual Tests Became Charters

*Lifted from `skills/stride-workflow/SKILL.md`, Step 5.5, Why this step exists.*

Tasks routinely carry `manual_tests` in their `testing_strategy`, but the workflow has historically had no way to actually perform them — they were left to a human or silently skipped. When the `stride-gemini-exploratory-testing` extension is installed, each manual test becomes a **charter** and the explorer runs a real, budgeted exploratory session, closing the gap between "tests written" and "tests performed."

## How an Untracked Session File Ends Up Committed

*Lifted from `skills/stride-workflow/SKILL.md`, Step 5.5, Gitignore the artifact directory before the first session.*

Those files hold transcribed application output, exactly the material the redaction rules keep out of the completion payload, and they arrive **untracked**. If the project's own `## after_doing` section stages everything before committing — `git add -A` or `git add .`, a common shape for a quality gate that commits its own fixes — it sweeps them into the commit, and a commit is far harder to walk back than a payload field. Neither behaviour is wrong on its own; they interact badly, and one `.gitignore` line prevents it. Note the sweep is the **operator's own** `after_doing`: this extension's `hooks/stride-hook.sh` stages nothing itself. One safe shape, so the check is decidable both ways — `git commit -a` stages only files git already tracks and does not sweep untracked artifacts; `git add -A` and `git add .` do.

## Which Commands Can Write Outside the Default Directory

*Lifted from `skills/stride-workflow/SKILL.md`, Step 5.5, operator guidance on the ignore file.*

It costs nothing when the directory never appears. Note the sanctioned automated path **does** write there now: nothing in the `explorer` contract asks it to write a session file, but **Step 5.6's `/harden` dispatch writes drafts into `.exploratory/checks/`** — which strengthens the case for the line rather than weakening it. It matters for the sessions an operator runs themselves too. Today `/pair`, `/harden`, `/recon`, `/charter`, `/debrief` and `/nightmare-headline` all accept the flag — and a `/recon` report is a survey of a running system, so it carries exactly the internal hostnames and environment layout this paragraph exists to keep out of a commit. That is why "before the first session" is not merely tidier, it is the difference between the line working and the line doing nothing.

## Why an Obstacle Is Not a Finding

*Lifted from `skills/stride-workflow/SKILL.md`, Step 5.5, Safety boundary.*

The distinction is not pedantry: the contract requires a blocked session to set its `status`, record the obstacle in its `debrief`, and **not fabricate results** — so the obstacle lives there and carries no exploratory severity, and where the app was unreachable from the start the bug list is empty too. Treating the obstacle as a finding hands it to the absent-severity rule, which maps it to `important` — filing an unreachable dev server as an important testing finding whose worst impact you are then asked to name.

## Why Doubt Resolves to Discovered

*Lifted from `skills/stride-workflow/SKILL.md`, Step 5.5, Escalation.*

Every uncertain case therefore resolves to **discovered**, and that is deliberate. The blocking path is scoped to lines you demonstrably wrote, so nothing the application prints — and nothing a task author wrote — can move a finding into it. Blocking on a link you could not draw would be a denial-of-progress surface, and it would reward investigating less.

## Turning a Found Bug Into a Lasting Check

*Lifted from `skills/stride-workflow/SKILL.md`, Step 5.6, Why this step exists.*

A session that finds a bug and stops has closed nothing — the same bug can return unnoticed. `/harden` reads the bugs a session confirmed and drafts one regression check per convertible bug, which is the step that turns *Explored* back into *Checked*. It is the only place this workflow can close that loop automatically.

## The Clash Between a Failing Check and a Blocking Gate

*Lifted from `skills/stride-workflow/SKILL.md`, Step 5.6, The sequencing rule.*

`after_doing` is a **blocking** hook that typically runs the project's test suite, and a non-zero exit aborts completion. A regression check for an **unfixed** bug is *supposed* to fail — that failure is the evidence it reproduces the bug. Put those two facts together naively and a session that did exactly the right thing blocks the completion of a task that may not even be scoped to fix the bug.

## Why Post-Review Files Must Be Named

*Lifted from `skills/stride-workflow/SKILL.md`, Step 5.6, Files written after review.*

When a review did run, anything written here appears **after** the diff that was reviewed, so the reviewed diff and the final diff diverge — and unreviewed executable code entering a commit unannounced is exactly what review exists to prevent.

## How Older Runtimes Still Close a Goal

*Lifted from `skills/stride-workflow/SKILL.md`, Step 8, If this completion finishes the parent goal's last child task.*

**Back-compat (for older agent runtimes):**

- If `.stride.md` has no `## after_goal` section, the hook bridge silently no-ops. The server's grace-window worker promotes the goal to Done automatically after the configured wait.
- If the agent doesn't POST the result at all (older plugin versions), the same grace-window worker covers the gap. The goal transitions to Done after the wait expires with a synthetic attempt tagged `source: "after_goal_grace_worker"`.

## The Case for Tokens, and Why It Waits

*Lifted from `skills/stride-workflow/SKILL.md`, Workflow Telemetry, What dispatch_count and duration_ms do and do not tell you.*

**Why not simply record tokens.** Tokens are the only figure observed to rank correctly, so it is the obvious answer to limit (1) — and the usual justification for refusing is wrong: some runtimes do measure a per-dispatch token cost, so recording it would not be inventing one. The real objection is **portability**, whether every runtime this schema serves can produce one, and that is unsettled. Until it is, this pair is what there is, read within the limits above.

## The Strict-Validation Rollout

*Lifted from `skills/stride-workflow/SKILL.md`, Explorer and Reviewer Result Rollout.*

The server is rolling out hard enforcement behind a feature flag `:strict_completion_validation`:

| Phase | Server behavior | Agent impact |
|---|---|---|
| **Grace (current)** | Missing or invalid results log a structured warning and the request succeeds | Emit the fields correctly now; the warning volume is a preview of the strict-mode rejection volume |
| **Strict (after all 5 plugins release)** | Missing or invalid results return `422` with a `failures` list | Any agent not emitting valid fields is locked out of completion |

## The Failures This Skill Was Written Against

*Lifted from `skills/stride-workflow/SKILL.md`, Failure Modes This Skill Prevents.*

| Failure Mode | Old Pattern | This Skill |
|---|---|---|
| Forgot to explore | Agent skipped stride-subagent-workflow | Step 3 is inline -- can't be missed |
| Forgot to review | Agent jumped to completion | Step 5 is inline -- can't be missed |
| Wrong API fields | Agent guessed from memory | Step 7 has the exact format |
| Skipped hooks | Agent called complete directly | Step 6 blocks Step 7 |
| Asked user permission | Agent prompted between steps | Automation notice says don't |
| Speed over process | Agent optimized for throughput | Every step is framed as mandatory |
