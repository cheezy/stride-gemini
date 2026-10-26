# Why the task-reviewer agent reads the way it does

`agents/task-reviewer.md` is the whole prompt of the `task-reviewer` custom agent, so every sentence in it is paid for on every review the orchestrator dispatches. A dispatched reviewer never opens this page. The sections below are passages from that prompt which recorded where a rule came from rather than telling the reviewer what to do; each was lifted out as it stood, and the prompt keeps a one-line pointer at the place it came from. This page sits under `docs/` and not beside the agent, because Gemini CLI treats every `.md` file in `agents/` as a custom agent.

**No rule lives in this file.** The reviewer's block schema, every verdict, consistency and escalation rule, the opening summary line and the 40-character summary floor, the untrusted-data framing for matrix rows and `fixes[]`, every redaction rule, and both canon-governed blocks remain in the prompt. Where a lifted passage still reads as an instruction, the prompt states that instruction too, and the prompt's statement is the one that binds. If this page and the prompt ever seem to disagree, do what the prompt says and correct this page.

## A Security Section Reported as Not Assessed

*Lifted from `agents/task-reviewer.md`, review step 5, the verdict rule for the four section tiles.*

It is the exact D60 bug where a task's `security_considerations` came back "not assessed".

## How project_checks Vanished From the Review Panel

*Lifted from `agents/task-reviewer.md`, review step 8, the consumption invariant.*

An enumerated copy-list in a consumer is exactly what silently dropped `project_checks` from the Review queue's Code review panel — do not reintroduce one.

## What Moved the Schema Version Last

*Lifted from `agents/task-reviewer.md`, review step 8, the `schema_version` field.*

(Bumped from `"1.6"` by the addition of the `cosmetic` key to `issues[]` entries; the two changes before it held at `"1.6"` precisely because they added no field. Nothing gates on the value — the server validates it as a semver-shaped string only.)

## A Criteria Count Larger Than the Task's

*Lifted from `agents/task-reviewer.md`, review step 8, the `acceptance_criteria` array hard rule.*

(re-enumerating the list is exactly how a 5-criterion task produced a nonsensical `6/5` review display)

## Who Reads the Review Once It Is Filed

*Lifted from `agents/task-reviewer.md`, the Output persistence paragraph after the worked example.*

**Output persistence:** Your full response — the human-readable prose summary line, the per-severity issue list, the acceptance-criteria table, the project-checks table (when non-empty), and the fenced ```json block — is stored as the `review_report` field on the Stride task record when the agent calls the completion API. Human reviewers and stakeholders read the prose in the task detail view; downstream tooling parses the JSON block by extracting the first ```json ... ``` fence in your response. Always emit both the prose sections and the JSON block — including for `"approved"` results — so both reader paths work and per-severity telemetry stays consistent across dispatches.
