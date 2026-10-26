# Why stride-completing-tasks reads the way it does

Gemini CLI loads `skills/stride-completing-tasks/SKILL.md` before every completion call, so any passage in it that only explains a rule, or records where a rule came from, is paid for on every task without changing a single payload. The sections below are those passages. Each was lifted out of the skill as it stood, and the skill keeps a one-line pointer naming the section at the place it came from. Passages that merely restated a rule the skill already states elsewhere were deleted rather than kept here.

**No rule lives in this file.** The completion field reference, both result shapes and the five skip reasons, the verification checklist, the mandatory pre-submission self-check, the redaction and untrusted-data rules, and the stdout guard all remain in the skill. If this page and the skill ever seem to disagree, do what the skill says and correct this page. A completion built without opening it is still a correct completion.

## Three Failed Calls From Memory

*Lifted from `skills/stride-completing-tasks/SKILL.md`, THIS SKILL IS MANDATORY.*

**Attempting to complete a task from memory without this skill results in 3+ failed API calls** as you discover each missing field one at a time. This has been observed in practice.

## What the Checklist Guards Against

*Lifted from `skills/stride-completing-tasks/SKILL.md`, BEFORE CALLING COMPLETE: Verification Checklist.*

This checklist exists because agents consistently skipped these steps under pressure to deliver quickly.

## When the Notes Reach Nobody

*Lifted from `skills/stride-completing-tasks/SKILL.md`, Recording Manual & Exploratory Testing Findings, the `completion_summary` carrier.*

Because `completion_notes` is persisted only from D188 onward, a record that lives there alone may reach nobody. This matters most in exactly the case that looks safest: a small task where no reviewer ran, `completion_notes` is the *only* carrier, and a session that surfaced real bugs would otherwise vanish silently on an older server.

## Warnings Before the Strict Flip

*Lifted from `skills/stride-completing-tasks/SKILL.md`, Explorer/Reviewer Result Schema, the former Grace-period rollout subsection.*

Until the server flips `:strict_completion_validation` to true, missing or invalid `explorer_result`/`reviewer_result` produces a structured warning log but the request succeeds. **Emit the fields correctly now** — agents that lag the rollout will start getting 422 rejections on the flip day.

## Where the Severity Collapse Falls

*Lifted from `skills/stride-completing-tasks/SKILL.md`, Recording Manual & Exploratory Testing Findings, Severity mapping.*

**Where the four-into-three collapse falls, and why it falls there.** One boundary has to be lost. The exploratory ladder's sharpest *descriptive* line is High/Moderate — whether wrong state survives — but the reviewer enum is not descriptive: its three values are **dispositions at the completion gate** (`critical` and `important` both mean *fix before proceeding*; `minor` means *optional but recommended*). So the boundary to lose is the one whose two sides share a disposition, and that is High/Moderate. Collapsing Moderate into `minor` instead would file a broken export alongside a truncated label — the deflation `bug-advocacy` warns costs exactly as much credibility as inflation.

The mapping table in the skill once carried a third column giving each row's reason. It shortened the extension's impact ladder for orientation and was never authoritative; `bug-advocacy` is. It read:

| Exploratory severity | Why it lands there |
|---|---|
| **Critical** | A boundary that must hold was crossed, committed data destroyed, money or a legal obligation wrong, a secret exposed, or the product's primary purpose taken away. `critical` is the only reviewer value carrying the same cannot-ship disposition. |
| **High** | Something incorrect survives — valid data persisted wrong or lost but identifiable, a main workflow blocked, success falsely reported. *Fix before proceeding.* |
| **Moderate** | A real workflow degraded, a secondary feature broken, or an error the user cannot act on. Nothing incorrect survives, but it is still *fix before proceeding*, which is what `important` means. |
| **Minor** | Presentation only, or the only casualty was already-invalid input. *Optional but recommended*, which is what `minor` means. |

## Numbers Quoted Without a Source

*Lifted from `skills/stride-completing-tasks/SKILL.md`, the former Rationalization Table and Real-World Impact sections.*

Both passages argued for running the hooks before the completion call by quoting figures, and neither says where or when those figures were measured. They are kept here as they stood rather than restated as fact.

| Excuse | Reality | Consequence |
|--------|---------|-------------|
| "Tests probably pass" | after_doing catches 40% of issues | Task marked done with failing tests |
| "I can fix later" | Task already marked complete | Have to reopen, wastes review cycle |
| "Just this once" | Becomes a habit | Quality standards erode completely |
| "before_review can wait" | API requires both hook results | Request rejected with 422 error |
| "Hooks take too long" | 2-3 minutes prevents 2+ hours rework | Rushing causes failed deployments |

**Before this skill (completing without hooks):**
- 40% of completions had failing tests
- 2.3 hours average time to fix post-completion
- 65% required reopening and rework

**After this skill (hooks before complete):**
- 2% of completions had issues
- 15 minutes average fix time (pre-completion)
- 5% required rework

**Time savings: 2+ hours per task (90% reduction in post-completion rework)**
