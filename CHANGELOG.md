# Changelog

All notable changes to the Stride extension for Gemini CLI will be documented in this file.

## Release record — tags without a GitHub release

*This is a record-keeping note, not a release. It describes no change to this plugin and carries no version.*

A fleet-wide audit found **4 tags** in this repository that are tagged and pushed but have no corresponding GitHub release. **The gap is accepted and will not be backfilled.** It is recorded here so the next release engineer does not rediscover and re-litigate it:

- `v1.3.1` — 2026-04-14
- `v1.5.0` — 2026-04-16
- `v1.8.0` — 2026-05-08
- `v1.9.0` — 2026-05-19

Why accepted rather than backfilled:

- **Nothing resolved through these releases.** A GitHub release is a human-readable record, not a resolution mechanism — nothing installs *through* one. The missing releases cost nothing at the time and cost nothing now.
- **Backfilling would be worse than the gap.** A release created today against a commit from April or May would be dated today, and would manufacture a record for a state no user ever resolved through — misrepresenting the very history it claims to document.
- **The convention itself is unchanged.** These are omissions from a few release cycles, not a policy shift. Every tag still gets a release going forward.

The audit also found **zero** GitHub releases without a matching tag, so the record is incomplete in only this one direction.

## [Unreleased]

## [1.43.0] - 2026-08-01

Discharges the last deferral the `[1.42.0]` Scope block named, completing the exploratory-testing integration. Prompt text only; the companion `stride-gemini-exploratory-testing` extension is untouched.

### Added — an optional `/harden` sub-step (Step 5.6 / Phase 3.6), sequenced so a drafted check cannot redden the gate

A session that finds a bug and stops has closed nothing — the same bug can return unnoticed. `/harden` drafts one regression check per convertible bug, which is the step that turns *Explored* back into *Checked*, and this is the only place the workflow can close that loop automatically.

- **A three-condition gate.** A Step 5.5 session actually ran and returned **convertible** findings — bugs carrying a stated trigger and a stated wrong result, so one whose `minimal_repro` honestly says *"could not establish"* does not qualify; **and** `/harden` is available, detected as Step 5.5 detects the extension and never by reading or evaluating extension content; **and** the runtime can invoke a TOML slash command. Condition 2 is a real gate: `/harden` arrived in the companion extension's **0.2.0** and **0.1.0 shipped without it**, so check for the command rather than for the extension.
- **Condition 3 has no Step 5.5 analog**, and it introduces a failure mode this port has to close explicitly: `/harden` ships **only** as a TOML command, with no `harden` custom agent to fall back on, so a runtime that cannot invoke it has no second route. **Never approximate the dispatch by drafting the checks yourself** — that bypasses every rule in the contract that makes an unattended dispatch safe. Stated in the gate, in the Decision Summary, and in the workflow's ASCII flow.
- **The sequencing rule.** `after_doing` is a blocking gate that typically runs the suite, and a check reproducing an **unfixed** bug is *supposed* to fail — that failure is the evidence it reproduces the bug. Sequenced naively, a session that did exactly the right thing blocks a task that may not even be scoped to fix the bug. **Leaving drafts staged in `.exploratory/checks/` is the default and is always safe**, which is what dispatching without `--output` preserves.
- **Two things must hold before a check enters the suite, and a skip marker gives only one.** The **file must load** — a marker makes a *case* inert, not a *file*, and runners compile the whole tree first, so a draft carrying an unresolved `TODO(harden):` wiring marker fails however it is tagged — and the **case must be green or inert**. Both are established by **running the gate's own command once across the whole suite**, never by expecting; a file-scoped run cannot surface a colliding module or a duplicate name. If it does not come back clean, everything the attempt touched is reverted.
- **Three dispositions, and no others.** Fixed in this task → run the check, see it pass, then keep it and update its expected-to-fail header, never moving an unrun check in on the expectation that it passes. Still open → in only if the file loads clean and the case is marked skipped or pending, **and** a follow-up defect is filed, since a skip line carries no owner or expiry (`xfail` is not a skip — it runs the test, and under `xfail_strict` it fails the run once the bug is fixed). Otherwise → leave it staged and file a follow-up defect. **Never red in the tree**, where the hazard is presence rather than the commit, since `after_doing` runs the working tree.
- **The never-overwrite check is the agent's, not `/harden`'s.** `/harden` never overwrites a path **it** writes, but it never writes into your test tree — so the copy **you** perform there is protected by nothing, and it even prints that line for you, unrun. If the target path exists, do not write it.
- **A check for a security finding asserts the guard, never performs the bypass.** `/harden`'s contract bars a destructive step, a real host and a hard-coded credential — but an auth-bypass request sequence, a cross-tenant read or an IDOR fetch **against the suite's own fixtures** violates none of those and converts cleanly, and the still-open disposition would then commit that check into a suite the gate compiles on every future task. A regression check for a boundary failure is, by construction, a **working exploit for a live vulnerability**. So when the bug matches the rubric's Critical clauses for data crossing a tenant, account, role or permission scope, or for a secret or token exposed, or its High clause for an authorization control demonstrably absent, the draft must assert that the boundary **holds** — the request is rejected, the check fires, the scope filter excludes the other tenant — and never encode the sequence that crosses it. **If the draft reproduces the bug by successfully exploiting it, it may not enter the test tree while the bug is open.** A stored exploit is not made safe by a skip marker: it is read, copied and run by whoever finds it, in a repository usually readable by far more people than the finding was.
- **The content check at the move is the agent's, like the path check.** Deferring the draft-content rules to `/harden`'s contract is right for the drafting, but this step performs the copy into the permanent, gate-run test tree — and the port already argues, for path collisions, that "`/harden` never overwrites a path **it** writes, but it never writes into your test tree, so the copy you perform is protected by nothing." The same reasoning now applies to contents: read the draft first, and refuse the move if it carries a literal credential, token, session identifier, customer record or internal hostname where a fixture value belongs. The source material is application output the agent was told to redact one step earlier, which is exactly why it is not taken on trust at the move.
- **A staged draft is out of the commit only when `.exploratory/` is actually ignored.** Step 0 delivers that advice as a statement the operator may simply not act on, and **this step is the first thing on the sanctioned automated path that writes there at all** — which also falsified a pre-existing sentence claiming nothing writes there on that path, now corrected. If the directory is not ignored, the drafts are untracked files an `after_doing` staging with `git add -A` will commit, so they are named in `actual_files_changed` and the reviewer is re-run on the same terms as a check that entered the test tree: the rule turns on unreviewed executable code reaching the commit, not on which directory it sat in.
- **The verification run is the step's one live action, and it is bounded.** Establishing that a moved check loads clean means running the gate's own command — which in an e2e or browser project drives a running application at whatever host its configuration resolves. That must be the same authorized, non-production target Step 5.5 was given; if it cannot be established or resolves elsewhere, the check is not moved in. Step 5.5's boundary does not stop applying because a different step invoked the command.
- **The condensed surfaces carry the rules too.** A Decision Summary exists to be consulted under pressure, so a table that authorized a move the prose bars would be worse than no table. The still-open row now requires the check to assert the guard, and four rows were added for the security-boundary case, a draft carrying a literal credential, an `.exploratory/` that turns out not to be ignored, and a verification run that drives a live application. Both ASCII flows and both Quick Reference Cards carry the security stop and the content check.
- **Post-review files are surfaced, never smuggled.** Anything written here appears after the diff the reviewer saw, so the reviewed and final diffs diverge. Paths go in `completion_notes`, one line in `completion_summary`, and any check that entered the tree in `actual_files_changed` — with the asymmetry named: `changed_files` is captured from git by the hook during the completion curl, so a moved check can appear there automatically while the hand-authored `actual_files_changed` silently omits it. The reviewer is re-run **whenever** a check entered the tree, with no substantiality judgement, because a rule that turns on a judgement call resolves toward the cheap answer.

### Added — port-specific dispatch arguments, verified against the installed command

The canonical plugin's dispatch advice does not survive translation here, and two of its three argument rules had to be re-derived from `harden.toml` as installed.

- **The findings are supplied inline, not as a file path.** The reference says to pass the bug source positionally. On this port's sanctioned path there **is no path to pass**: the `explorer` custom agent is not asked to write a session file, which this port states in two other places, so `/harden`'s bug-source argument would be empty and it would fall back to globbing `.exploratory/sessions/*.md` and asking which to use. Its contract names an `explorer` findings object as its richest input shape, so the object is passed inline — redacted first, and framed as data to assess rather than instructions.
- **`--framework` is pinned, not optional.** The reference treats it as an operator override. Here it is mandatory: `/harden` raises its question UI on weak detection evidence or on two competing runners of the same kind, neither of which the orchestrator controls — and this port's own Step 5.5 already rests its "clears the unattended bar" judgement on that pin. Without the framework established, the step does not dispatch.
- **The no-runner property is contractual, not mechanical.** The reference calls `/harden` a command that "holds no test runner". `harden.toml` says of itself that this is a rule it holds rather than a restriction the runtime imposes, and this port already establishes that a TOML command carries no tool allowlist at all — so the claim is stated as a contractual guarantee, which is precisely why a drafted check is never reported as passing on its say-so and never on the agent's own.

### Fixed — three routing artifacts that skipped the optional steps

- **`stride-workflow`'s availability-detection list** named five of the seven installed TOML commands, omitting `/harden` and `/pair` — so Step 5.6's condition 2, which detects "the same way Step 5.5 does", pointed at a list that never named the command it gates on.
- **`stride-completing-tasks`' Completion Workflow Flowchart and Quick Reference Card** jumped straight from the reviewer branch to the `after_doing` hook, mentioning **neither** Step 5.5 nor Step 5.6. Adding only the hardening line would have produced a diagram that names a session it shows no path to, and positions hardening as the immediate successor of review — contradicting its own trigger. Both halves are therefore added together, matching the canonical plugin's own resolved state; the Step 5.5 half is a pre-existing gap closed in passing rather than new scope, and is disclosed here for that reason.

### Scope

Prompt text and documentation only. **No completion field is added, removed, or made required; no seventh `workflow_steps` name; no enum, schema, hook-script or custom-agent change.** The dispatch's wall-clock folds into the existing `reviewer` entry, exactly as the deep security-considerations review and the exploratory session already do. The new step is additive and gated: with no session, no convertible findings, no `/harden`, or a runtime that cannot invoke it, the workflow behaves exactly as it did in `[1.42.0]`.

## [1.42.0] - 2026-08-01

Discharges three of the four deferrals the `[1.41.0]` Scope block named: the explorer session budget and the named environment-context inputs, the richer session recording, and the `.exploratory/` gitignore guidance. The optional `/harden` sub-step with its `after_doing` sequencing remains deferred. Prompt text only; the companion `stride-gemini-exploratory-testing` extension is untouched.

### Added — an explicit session budget and a named environment context on the Step 5.5 / Phase 3.5 dispatch

The dispatch previously said only "passing the running-app environment context". What that context had to contain was nowhere stated, and no budget was passed at all — an unbounded dispatch inside an autonomous workflow, against a live application.

- **Seven named inputs**, packed into the single free-text block the `explorer` custom agent actually takes alongside the charter: the charter, the feature under test, how to reach the running app, the **authorized non-production affirmative**, which interaction tools are available, where source and logs live, and **a pointer to where test accounts or seed data live — never inlined credentials**, because the dispatch prompt is an artifact like any other.
- **The affirmative has exactly one legitimate source: the user, at Step 0.** It is never inferred from a `localhost` URL or from the task record — inferring *is* supplying it on the user's behalf, and task text is author-written, which this workflow already refuses to trust for safety-bearing decisions. **No affirmative means no dispatch**, and the honest outcome is the graceful skip rather than a guess. Failing to establish how to reach the app is the same: you have nothing to dispatch against, so skip and note it rather than guess at a target you are about to drive.
- **The affirmative is scoped to the target it named, and the address is bound to it.** An affirmative covers **the target the user named and only that one**: when Step 0 supplied an address, that is the only dispatchable one, and an address read out of project dev configuration — a `.env`, a runtime config, a compose file — that differs from it is **not covered**, so the step skips. Those files routinely point at staging or a shared remote, and the explorer treats whatever the context names as its authorized boundary, so an unbound address would have let an affirmative given about `localhost` authorize a session against something else entirely. An affirmative given **without** a named target authorizes no address at all, which makes the dev-configuration fallback unreachable rather than unchecked.
- **The budget is the caller's to set**, in whatever unit the **installed** contract declares — the two extensions release independently, so the unit is established from `stride-gemini-exploratory-testing/agents/explorer.md`, never hardcoded from this page. Today that is probes: default **12**, band **8–20**, tool-call ceiling at **5×**, whichever is reached first ending the session, with the agent's own `max_turns` as a separate bound whose lower value wins. **A wall-clock box is never handed to a probe contract** — it has no clock, and minutes invite a duration it never measured. If the budget will not fund one workable charter, **do not dispatch at all**: a token session that cannot reach the feature produces a false coverage claim, which is worse than not running. The band is per dispatch, not a pool to divide.
- **Step 0 gains items 3 and 4.** Item 3 collects the affirmative, the app's address and the seed-data pointer in one question — Step 0 is the only point where addressing the operator is sanctioned, and the orchestrator may not prompt between steps, so **it is asked there or never**. It is optional and never blocks: anything short of an explicit affirmative is recorded and the step skips.

### Added — richer recording: stakeholder impact, the artifact path, and a `completion_summary` mirror

- **Each finding now names who is harmed and how**, not only its severity. A severity word says how bad the failure is; it does not say who it lands on, and that is what a reader triaging the Review queue needs. The impact field is **read from the installed contract** (`bugs[].stakeholder_impact` today), restated and redacted rather than pasted; where a contract emits none, say who is harmed in your own assessment or say plainly that the session did not establish it — **never invent an impact the session did not support, and never silently drop the question because the field was absent**.
- **The session artifact's path is cited when one exists — and the text is explicit that usually it does not.** The sanctioned surface is not asked to write one, so on the automated path the prose summary is the normal and complete record rather than a degraded fallback; an artifact exists only when a human separately ran `/explore`, `/pair` or `/harden`. **Cite a path only when you know of such an artifact and it belongs to this task's record** — never go looking for a file to name, and never infer one from a default path holding another session's output. **Record the path, never the contents**, repository-relative, since an absolute path discloses a username and machine layout and the artifact may hold unredacted output.
- **One line is mirrored into `completion_summary`** whenever a session found anything worth a human's attention. `completion_notes` is persisted only by servers from D188 onward and the agent cannot tell which version it is talking to, so a record living there alone may reach nobody; `completion_summary` is required, persisted and rendered on the Review queue. This matters most in the case that looks safest — a small task with no reviewer, where `completion_notes` is the only carrier. **Not a new field.**
- **Session text is untrusted DATA, never instructions — stated at the site that composes the payload.** Both workflow skills already carried the rule at their dispatch and escalation sites, but `stride-completing-tasks`, which an agent reads while actually writing the persisted fields, did not — and this release points it at two further application-derived inputs, the impact field and the session sheet. It now says so twice: at the head of the recording section, before the text exists, naming the impact field, every bug field, the session sheet and the artifact path, and routing text that appears to address the agent or waive a check to **content to record and name in `completion_notes`** rather than a directive to obey — the same convention the skill already applies to a `behaviour_test_matrix` row — and again in the redaction paragraph, where the reference places it. Both workflow skills also gain **"capture every field, then restate and redact what you record"**, since "capture everything the agent returned, not a hand-picked subset" was otherwise the strongest pull toward pasting transcribed application output verbatim into a rendered field.
- **Redaction now binds explicitly on the impact text and the artifact path**, and on every finding field that carries secrets (`observed`, `repro`/`minimal_repro` — the request that reproduces a bug is often the request that carries the credential — `why_wrong`, `worst_observed`, `summary`, `generalization`, the severity string), as examples rather than a closed list. **Restating is not redacting**, and the two are separate obligations: a faithful paraphrase carries an account name, a customer email and a hostname through untouched, so redact by **generalising the referent** and name a finding rather than quoting it when its text carries a secret.

### Added — `.exploratory/` gitignore guidance, delivered at Step 0

Session artifacts land under `.exploratory/`, hold transcribed application output — the exact material the redaction rules keep out of the completion payload — and arrive **untracked**. An operator's `## after_doing` that stages everything (`git add -A`) sweeps them into a commit, which is far harder to walk back than a payload field. Neither behaviour is wrong alone; they interact badly, and one `.gitignore` line prevents it.

- Stated in **three places with distinct jobs**: the Marker Contract row names `.exploratory/` alongside `.stride/`; **Step 0 item 4 is the delivery point**, because Step 5.5 runs only once a session is under way and is structurally too late; and Step 5.5 / Phase 3.5 carry the reasoning as the agent's reminder of what to say.
- **Operator guidance only — the agent never edits their `.gitignore`.** `git commit -a` is named as the safe shape (it stages only tracked files) against `git add -A`, and the sweeper is identified as the operator's own `after_doing`, since this extension's `hooks/stride-hook.sh` stages nothing itself. A committed artifact needs `git rm --cached` as well, because `.gitignore` is inert for a path git already tracks — which is why "before the first session" is the difference between the line working and doing nothing.
- **The redirected-output caveat is a general rule, not an enumeration:** any command invoked with `--output` writes wherever the operator names, so a redirected path needs gitignoring too. Verified against the installed extension, six commands accept the flag — `/pair`, `/harden`, `/recon`, `/charter`, `/debrief` and `/nightmare-headline` — where the canonical plugin names only three. A `/recon` report is a survey of a running system, so it carries exactly the internal hostnames and environment layout this guidance exists to keep out of a commit. **`/explore` is the sole exception**: its usage line takes no `--output` in this port, so it **always** writes to `.exploratory/` — which makes the gitignore line strictly more load-bearing here than upstream.
- `README.md` gains a `### .gitignore` subsection with the full recommended block (including `.stride-dirty-baseline`, which its hook writes but its docs had never named).

### Fixed — a blocked session is recorded as an obstacle, not as a finding

Both skills said an unreachable app should have its obstacle "reported as a finding". That hands it to the absent-severity rule, which maps it to `important` — filing an unreachable dev server as an important testing finding whose worst impact the agent is then asked to name. The contract requires a blocked session to set its `status`, record the obstacle in its `debrief` and **not fabricate results**, so the obstacle lives there carrying no exploratory severity. **A blocked session that returns bugs is no contradiction** — those are real observations recorded as findings on their own terms; only the *obstacle* is never one.

- **Coverage is now judged from the session sheet, not from the word.** Blocking is a stopping heuristic reachable at any point, so a `blocked` session at or near zero probes has the same coverage as a zero-probe `tool_call_ceiling` — nothing — and takes the identical disposition: **not a performed test**, handed back as a human responsibility with the unexamined risk filed as a follow-up defect. After meaningful probes both are partial coverage whose findings are recorded. **Two endings with the same coverage must not get opposite dispositions.**
- **Budget exhaustion never fails completion.** What varies is only what may honestly be claimed: `charter_quiet` (and `risk_acceptable`) is the only ending supporting "this manual test was performed"; `probe_budget_exhausted` is valid findings with an incomplete coverage claim. Claiming a spun-out session as a performed manual test is worse than not running the extension at all, because the extension-absent path at least flags the test as still owed. Leftover risk goes to a **filed follow-up with an ID** — "follow-up charter" is not a disposition, since a charter has no identifier and no lifetime past the session.
- Phase 3.5's skip list no longer conflates a pre-dispatch skip with the post-dispatch `blocked` ending, and gains the two new pre-dispatch refusals (no affirmative, budget too small).
- **The stop-reason enum is named verbatim** — `charter_quiet`, `probe_budget_exhausted`, `tool_call_ceiling`, `risk_acceptable`, `blocked` — because in this port it is knowable from the installed contract, where the canonical plugin has to hedge across contract versions. The hedge is kept for a contract reporting only a coarse root `status`, whose `stopped_early` is ambiguous and is resolved from the sheet, conservatively.

### Added — where the exploratory session's wall-clock goes

The port forbade the wrong answer in one skill (`stride-completing-tasks`: manual testing "is **not** a seventh workflow step") and gave the right answer for a sibling dispatch in another (Step 5's deep security review folds into the existing `reviewer` entry), while saying nothing at the site where the question arises. It now says it: fold the session's wall-clock into the existing **`reviewer`** entry, **never a seventh step name**. The wall-clock is **the orchestrator's own measurement**, never a field read out of the session sheet — today's contract states outright that it carries no `duration` and no `tbs`. When no reviewer ran — routine here, since this gate has no review precondition — that entry is the skip form carrying no duration, so the dispatch is recorded in `completion_notes` rather than given an invented one; the entry is still submitted as `dispatched: false` with a reason.

### Fixed — the last flow artifact still naming `/explore` as a dispatch target

`GEMINI.md` said the workflow "dispatches the extension's `/explore` command or `explorer` agent". `[1.41.0]` corrected the four flow artifacts inside the two skills but missed this one, which is the extension's `contextFileName` and so is loaded into **every** session — leaving the most-read document contradicting the policy. Strictly a `[1.41.0]` gap, fixed here rather than left to contradict this release too.

### Scope

Prompt text and documentation only. **No completion field is added, removed, or made required; no seventh `workflow_steps` name; no enum, schema, hook-script or custom-agent change.** No trigger condition moves — the two new refusals (no affirmative, budget too small) are post-gate dispatch decisions, not gate conditions, so every path still skips gracefully when the extension is absent. Deliberately **not** in this release: the optional `/harden` sub-step and its `after_doing` sequencing.

## [1.41.0] - 2026-08-01

Ports two `stride`-side changes into this Gemini CLI port: the exploratory severity ladder is aligned with the reviewer's issue vocabulary and given an escalation policy, and the Step 5.5 / Phase 3.5 dispatch is narrowed to surfaces that can complete without a human. Both are prompt-text changes to the task-lifecycle skills; the companion `stride-gemini-exploratory-testing` extension is untouched.

### Added — the exploratory severity ladder mapped onto the reviewer issue vocabulary

The exploratory extension rates each bug on a four-level ladder (**Critical > High > Moderate > Minor**, owned by its `bug-advocacy` skill); `reviewer_result` has three (`critical` / `important` / `minor`). Nothing said how one became the other, so a finding could reach the completion payload on whichever scale the agent happened to be holding.

- **`skills/stride-completing-tasks/SKILL.md`** gains a `### Severity mapping` subsection under *Recording Manual & Exploratory Testing Findings*: the four-row mapping table, and the reason the four-into-three collapse falls on **High/Moderate** — the reviewer enum's values are *dispositions at the completion gate* rather than descriptions, and `critical` and `important` share one (*fix before proceeding*), so that is the boundary whose loss costs least. Collapsing Moderate into `minor` instead would file a broken export alongside a truncated label. **The section maps; it never re-rates** — the extension's rubric stays the sole source of truth for what level a finding *is*, and a mapped reviewer value is never written back onto `bugs[].severity`.
- **Mapping a severity is not appending an `issues[]` entry.** Only a `critical` the escalation rules find *introduced* becomes one; everything else — including a *discovered* `critical` — goes to `completion_notes` and the `testing_strategy` note only. Appending a non-escalating finding would pair a `category: "testing"` entry with a failed verdict under the existing fail-closed consistency rules, manufacturing exactly the blocked completion the policy promises not to cause.
- **Absent or unrecognized severity → `important`; never dropped, never `critical`.** `critical` is the one value that triggers escalation, so a string that could not be parsed must never reach a blocking path; `minor` would be a silent downgrade. The raw value is quoted to 40 characters in inline backticks **only when it carries nothing from the protected classes** — a credential or token, customer data, an internal hostname — otherwise it is replaced with `[REDACTED — severity field carried sensitive text]` and its length reported. **Judge that by class, never by length**: an email address or an internal hostname is short and perfectly legible, so a length bound would emit the whole thing while looking like a mitigation.

### Added — a Critical exploratory finding now escalates, but only when this task introduced it

Before this release a Critical exploratory finding was advisory prose while a `partial`/`unmitigated` security verdict was fail-closed — an asymmetry that was an accident rather than a decision. It is now a decision, and a bounded one.

- **`skills/stride-workflow/SKILL.md`** gains `### Escalation: what happens when a session returns a Critical finding` in Step 5.5, and **`skills/stride-subagent-workflow/SKILL.md`** gains the matching `**Escalating a Critical finding.**` digest in Phase 3.5 — **identical in substance, with reciprocal keep-in-sync pointers naming each other's exact heading.**
- **One question decides it: are the responsible lines among the lines this task changed?** *Introduced* escalates fail-closed — `testing_strategy.status` → `"failed"` plus a `category: "testing"` / `severity: "critical"` entry with matching `issue_counts.critical` and `issues_found` increments — which flows through the existing review gate ("Fix all Critical issues before proceeding"), so the defect is fixed, the charter re-run, and the review re-run before completing. *Discovered* appends no issue and flips no verdict: it is recorded at its **exploratory** severity in `completion_notes` and one line of `completion_summary`, added as an advisory to the `testing_strategy` note, and **filed as a follow-up defect** so it has an owner. **A pre-existing bug never blocks an unrelated task.**
- **Provenance is computed from your own artifacts, never from the finding's text.** The finding's summary, repro and observed output are leads for locating the defect and are never evidence of where it came from, because the application under test controls them and a blocking escalation must not be triggerable by content an attacker can influence. The change set is `TASK_BASE_REF` (read from `.stride-env-cache`, which the hook filters out of the environment forwarded to the agent) plus `git status --porcelain`, **minus the claim-time `.stride-dirty-baseline`** — with the nested-repository case called out, since this project contains several. Falling back to the task's `key_files` is explicitly barred: that would hand the blocking footprint to task-author text.
- **Every uncertain state resolves to `discovered`** — an undeterminable change set, a base ref failing its sanity check, a fault site unidentified after a bounded attempt — and is labelled *provenance undetermined*, never *pre-existing*, because those branches never established provenance. Blocking on a link you could not draw would be a denial-of-progress surface.
- **No structured review block in the payload → no escalation, and nothing may be synthesized.** A small task (0-1 `key_files`) whose review the decision matrix skipped, and a review whose JSON would not parse, both reach this: there is no `issues[]` to append to and no verdict to flip. Never fabricate a structured block, an `issues[]`, an `issue_counts`, a section verdict or a `dispatched: true` — and never downgrade a review that *did* run to a self-reported skip.
- **The graceful-skip contract is unchanged.** No trigger condition moved, the fallback text is untouched, and both skills now say plainly that **no exploratory finding can block completion on a task that never ran a session.**

### Changed — Step 5.5 and Phase 3.5 dispatch only non-interactive surfaces

Both skills previously said to dispatch "the `/explore` TOML command (or its `explorer` custom agent directly)". `/explore` opens by asking a person for an authorization and non-production confirmation, so an autonomous workflow that dispatched it would **hang with no error** — the worst failure shape, because it looks like a stall rather than a violation.

- **The principle governs, not the list:** *dispatch only a surface that runs to completion without requiring a human*, because the orchestrator does not prompt the user between steps. "Requires a human" is read broadly — a surface that waits on an out-of-band approval fails identically to one that prompts. A surface the extension gains later qualifies by satisfying the principle, **never by being added to a list**, and the entries below record reasoning rather than a standing guarantee: the exploratory extension versions separately, so re-establish a surface from its own front matter whenever its version changes.
- **The sanctioned surface is the `explorer` custom agent, and it is the only one.** A Gemini CLI custom agent declares a `tools:` list the runtime enforces, and `explorer`'s holds no way to put a question to a person. A **TOML command carries no tool allowlist at all** — `pair.toml` and `harden.toml` each say so of themselves — so a command's unattended-safety rests on its prose alone and can rarely be *established* the way an agent's can. This is the port's own argument, not a translation of the canonical port's (which reasons from a Claude Code questioning tool that does not exist here).
- **Never auto-dispatched:** `/explore` and `/recon` (each requires an explicit authorization + non-production confirmation — a **safety control**, which disqualifies outright, because satisfying it on the user's behalf is never the orchestrator's call), `/pair` (human-at-the-keyboard by construction), `/nightmare-headline` (looping elicitation rounds with a person), and the extension's **`stride-exploratory-testing` routing skill** — which can route to any of them, and which is what the bare extension name resolves to, so "dispatch the extension" lands on it. `/charter`, `/debrief` and `/harden` clear the bar but run no session, so none is what this step dispatches.
- **Disqualification turns on prompts a surface *can* raise, by a stated test:** a prompt you pre-empt with an input you control does not disqualify; one fired by a condition you do not control does; a safety-control prompt disqualifies regardless.
- **This narrows what may be *run*, never what counts as *installed*.** Detection is unchanged and still availability-only, with the never-execute rule intact — it now says explicitly that detection **confers no dispatch licence**. All four flow artifacts that named `/explore` as a dispatch target are corrected (both skills' ASCII workflow and Quick Reference Card), so no diagram routes around the policy.
- **`README.md`** describes both changes for operators, and notes that the restriction is on automated dispatch only — running any of these commands yourself is unaffected.

### Scope

Prompt text and documentation only. **No completion field is added, removed, or made required; no seventh `workflow_steps` name; no enum, schema, or hook-script change.** The escalation writes only into fields that already exist (`reviewer_result.issues[]`, `issue_counts`, `testing_strategy.status` and `.note`, `completion_notes`, `completion_summary`), as a named bounded exception to the whole-object-copy rule on the same terms the `security_considerations` escalation already is. Deliberately **not** in this release, and left to follow-up tasks: the explorer session budget and the named environment-context inputs, the richer session recording (stakeholder impact, artifact citation), the `.exploratory/` gitignore guidance, and the optional `/harden` sub-step with its `after_doing` sequencing.

## [1.40.2] - 2026-07-29

### Fixed — the two remaining stale step cross-references, and a live-or-frozen decision (D192)

`[1.40.1]` corrected ten references of this class and explicitly left two for follow-up: a `Step 7 env matrix` comment in the hook script, and a `Step 9` citation in a document whose status was unclear. Both are resolved here, each checked against this port's own `## Step` headings rather than replaced in bulk.

- **`hooks/stride-hook.sh` and `hooks/stride-hook.ps1`** — the server-env-forwarding comment cited "The Step 7 env matrix"; the matrix is `### Hook Environment Variables`, which sits inside `## Step 6: Execute Hooks`. Step 7 is Complete the Task. The workflow skill's own back-references already said Step 6, so the port disagreed with itself about the same section. The PowerShell mirror carried the identical reference plus a second at its empty-key re-add ("per the Step 7 env matrix contract"); its own header states both scripts must agree on behaviour, so fixing only the bash side would have left the pair inconsistent. All three are corrected. **Comment-only** — every hunk is a `#` line, and no hook command, credential path, env-var handling, or control flow changes in either script.
- **`docs/HOOK_RESEARCH.md` is recorded as a frozen historical record**, and its `Step 9` citation is deliberately left as written. The file captured the research deciding whether stride 1.10.0's skill gate ports to Gemini CLI, and its "Action plan for downstream tasks" has been executed — W301 added the Orchestrator Activation Marker section to `skills/stride-workflow/SKILL.md`, and W302 ported the gate as `hooks/stride-skill-gate.sh` with its test harness. Nothing live references the document. A frozen-record note at the top now says so, and explains that its step numbers are the plan's contemporaneous expectations rather than current navigation: the plan says to clear the marker at "Step 9", and **that was accurate when written** — the document is dated 2026-04-29 and mirrors stride 1.10.0, and the canonical `stride` port carried `## Step 9: Post-Completion Decision` from 2026-04-13 (`9c2b3e4`) until 2026-07-02, when W1452 (`0109dfb`) resolved a missing Step 5 and renumbered it to Step 8. `stride-codex` and `stride-opencode` still number it Step 9 today. **This port carried `## Step 9` too**, from 2026-04-13 (`4272c70`) until 2026-07-03, when W1521 (`2021860`) closed its own empty-Step-5 gap — so the citation was accurate against stride-gemini's own headings on the day it was written, not merely the canonical port it mirrors. In this port the clear now lives under `## Step 8: Post-Completion Decision`.

**Why freeze rather than renumber.** The citation is a faithful record of a plan made against numbering this port has since superseded, so correcting it in place would falsify what was actually planned — the same reason this changelog's historical entries citing superseded step numbers are not rewritten. The decision is written down in the document itself so the question is not reopened a third time.

### Scope

**Gemini-only — deliberately not a fleet fix**, on the same reasoning `[1.40.1]` recorded. `stride-codex` numbers Code Review as Step 6 to preserve an intentionally-blank Step 5 slot, and `stride-opencode` also numbers it Step 6; every Step 6 citation in those two ports is *correct*. Neither repo is touched by this release, and both working trees were verified clean. Historical CHANGELOG entries citing an older step number are likewise left unchanged.

### Backward compatibility

Fully backward compatible. A comment and a documentation note only — no skill logic, hook behaviour, credential path, authorization instruction, API payload, or schema is changed.

## [1.40.1] - 2026-07-28

### Fixed — nine stale workflow step cross-references (D175)

"Extracting the structured review block" lives in **Step 5 (Code Review)** of this port's `stride-workflow` skill; Step 6 is Execute Hooks. Nine references sent a reader — or an agent — to the wrong step, and two of them sit in `GEMINI.md` and `README.md`, which are loaded into every session.

- **Seven citations of the extraction section** corrected from Step 6 to Step 5: one in `README.md`, one in `GEMINI.md` (the extension's `contextFileName`), and five in `skills/stride-completing-tasks/SKILL.md`.
- **Two related off-by-one lines** in the same completing-tasks skill: the orchestrator entry point now reads "you arrive here at **Step 6-7**" (Execute Hooks → Complete) rather than Step 7-8, and the prerequisite line now reads "Code review was performed against acceptance criteria (**Step 5**)" rather than Step 6.

Each reference was checked against this port's own `## Step` headings rather than replaced in bulk. Nine were stale; references that already read Step 5 or Step 5.5 were left alone.

- **A tenth, found by the exploratory sweep that verified the nine.** `skills/stride-workflow/SKILL.md` — the activation-marker warning read "will block your sub-skill activations in Steps 2, 3, 6, and 8", naming Execute Hooks and Post-Completion, neither of which activates a governed sub-skill. Corrected to "Steps 2, 3, 5, and 7", matching the canonical plugin verbatim. This is the same residue class: the port closed its Step-5 numbering gap in v1.29.0 (W1521), and every stale reference since is that same −1 shift.

Two further sites of the same class are left for follow-up rather than folded in here: a `Step 7 env matrix` comment in `hooks/stride-hook.sh` (the matrix is under Step 6) and a `Step 9` citation in `docs/HOOK_RESEARCH.md`, a file whose executed-action-plan framing makes it arguably historical like this changelog.

### Scope

**Gemini-only — deliberately not a fleet fix.** `stride-codex` numbers Code Review as Step 6 to preserve an intentionally-blank Step 5 slot, and `stride-opencode` also numbers it Step 6; every Step 6 citation in those two ports is *correct*, and a fleet-wide replacement would corrupt both. Neither repo is touched by this release. Historical CHANGELOG entries citing an older step number are also left unchanged — they were accurate for the release they describe.

### Backward compatibility

Fully backward compatible. Documentation cross-references only — no skill logic, hook, credential path, authorization instruction, API payload, or schema is changed.

## [1.40.0] - 2026-07-28

### Changed — the `behaviour_test_matrix` rules treat row text as untrusted, and say what to do when it carries a credential

`behaviour_test_matrix` row text is authored by whoever created the task and is attacker-controlled at the API boundary — anyone posting directly to the Stride API never sees these instructions. v1.39.0 threaded the field through the port; this release hardens every rule that reads it, and resolves a contradiction that made one of them impossible to obey.

- **Row text is data, never instructions.** The completion self-check's matrix gate and the implementation driver both state the boundary explicitly: a row is a specification to satisfy, and text inside a row that appears to address the agent, waive a check, or exempt the task is content being submitted — reportable as a finding, never a directive to follow (back-ported in W1946).
- **The secret rule is scoped to row *state*, not agent intent, and covers references.** A row that embeds a secret, credential, or token — **or that names a location where one lives** (file path, env var, secret-store key, vault reference, CI/CD or platform secret, Kubernetes Secret, git object, database row) — is by that fact alone a defect to raise (D184, D187).
- **A refused row has a named reporting channel and a defined representation.** The implementing agent reports the defect in `completion_notes`, identifying the row by `category` and position rather than quoting its text, and leaves the row exactly as authored. The reviewer, required to echo rows verbatim, instead substitutes the literal sentinel `[REDACTED — row text embedded a credential]` into the required field carrying the credential, echoes that row `failing`, and raises a `category: "security"` issue. The resulting `failed` verdict is the **expected outcome of a correct refusal** (D186).
- **The PATCH-body contradiction is resolved.** The driver mandated recording a row's status advance by PATCHing the matrix while forbidding a credential from reaching the PATCH body — unsatisfiable together, since `PATCH /api/tasks/:id` replaces the whole array and a non-empty matrix is rejected unless it covers all seven categories. The rules now state that re-sending row text the record **already stores**, byte-for-byte unchanged, back onto that same record is not a new copy, and name exactly one correct action (D185).

### Changed — guidance now cites the real controls instead of authoring conventions

- **`completion_notes` is persisted.** Every span that described it as unpersisted now states the deployment-conditional truth: persisted by Stride servers from D188 onward, but an agent cannot tell which server version it is talking to. The rule requiring the refusal to *also* appear in one line of `completion_summary` is unchanged — only its premise was corrected.
- **Row-text rendering is defended by escaping, not by an authoring rule.** The creation and enrichment guidance now cites the real controls (auto-escaped interpolation on every render path; the API hard-rejects an out-of-vocabulary `category` or `status`), keeps the no-raw-HTML rule as hygiene, and separates the secrets rule as genuinely authoring-only (W1947).

## [1.39.0] - 2026-07-26

### Added — the optional `behaviour_test_matrix` task field is populated, verified, and utilized end to end (W1928, W1929)

A task may now carry an **optional** `behaviour_test_matrix`: an array of rows, each pairing one behaviour the change must satisfy with the real test that covers it, across **seven fixed categories** (`Happy path`, `Boundary`, `Error / exception`, `Null / empty`, `Concurrency`, `Lifecycle / wiring`, `Contract / serialization`). The field is **never** one of the five review_queue-scored fields, so a task without one is entirely normal and never produces an empty pill. This is the Gemini port of the canonical [`stride`](https://github.com/cheezy/stride) plugin's v1.40.0 work, against the same Kanban server field.

- **`stride-creating-tasks`** (`skills/stride-creating-tasks/SKILL.md`) documents the field: a recommended-field checklist entry marked **OPTIONAL**, a full seven-row Complete Task Object example, a Field Quick Reference row, and a new `### behaviour_test_matrix` Embedded Object Formats section carrying four ❌ WRONG cases and a labelled ✅ RIGHT excerpt. It specifies the seven exact category strings, the `type` tokens (`unit`/`integration`/`manual` or a `/`-joined combination), the `status` enum (`planned`/`passing`/`failing`/`not_applicable`, default `planned`), `position` (integer >= 0), and the rule that every row names a **real test** or is waived with an `na_reason` — never neither. A **non-empty** matrix must cover all seven categories; absent and empty both pass, partial is rejected.
- **`stride-creating-goals`** (`skills/stride-creating-goals/SKILL.md`) documents the identical shape for nested tasks in a batch — same rules, no batch-specific variation.
- **`task-enricher`** (`agents/task-enricher.md`) and **`stride-enriching-tasks`** (`skills/stride-enriching-tasks/SKILL.md`) populate it: Phase 2 Step 3 now projects the `unit_tests` / `integration_tests` / `manual_tests` / `edge_cases` it just derived onto the seven categories, one row each at `status: "planned"`, with a category table, the honest-waiver rule (`not_applicable` plus a specific `na_reason` beats a fabricated test name), the defect `"Error / exception"` regression pairing, and an emit-by-default posture — all seven rows or omit the field entirely, never partial or filler. The pre-submission checklist grows to **18 items**, with the matrix as its sole optional item where a deliberate omission counts as considered.
- **`task-reviewer`** (`agents/task-reviewer.md`) verifies it and bumps its `reviewer_result` schema to **`schema_version` 1.6**. Review step 4 gains a **Behaviour/Test Matrix Verification** block that judges each row *Verified* / *Missing* / *Mismatch* and echoes those as `passing` / `failing` / `failing`, treating the row's declared status as a claim to confirm rather than trust. The schema gains an **OPTIONAL** `behaviour_test_matrix` verdict object with a nested `rows[]` breakdown and a **fail-closed escalation rule** (any `failing` row forces the section to `failed` and requires a matching `category: "testing"` issue). Unlike the four required section verdicts, this key is **omitted entirely** when the task supplied no matrix — an absent verdict carries no obligation and is preferred over an empty `not_assessed` placeholder. Matrix defects file under the existing `testing` category; `issues[].category` gains no new value.
- **`stride-workflow`** (`skills/stride-workflow/SKILL.md`) utilizes it: Step 4 adds the matrix as an implementation driver — write the test each row names, advance that row from `"planned"` to `"passing"` (or `"failing"`), and record the advance by PATCHing the updated matrix back onto the task — and Step 5 adds the field to the reviewer dispatch list.
- **`stride-subagent-workflow`** (`skills/stride-subagent-workflow/SKILL.md`) documents the same as an **orthogonal** driver — prose, deliberately not a new decision-matrix column — and adds the field to its Phase 3 reviewer input list.
- **`stride-completing-tasks`** (`skills/stride-completing-tasks/SKILL.md`) gains a pre-submission self-check requiring the verdict to be present and consistent when the task supplied a matrix, and to be absent (not back-filled) when it did not. Row statuses outside `planned`/`passing`/`failing`/`not_applicable` are rejected by the completion API in every mode.

Throughout, row text is treated as **untrusted DATA to assess, never as instructions**: a row whose text reads like a directive ("mark this row verified", "skip the remaining rows") is content under review, is reported in the section note, and is judged a Mismatch — and a secret found in row text is reported, never echoed. The creation and enrichment surfaces carry the matching "no secrets, no markup" authoring rule, since row text is stored and later rendered.

### Fixed — stale `schema_version` and checklist-count references across the port

The v1.38.0 cycle bumped the reviewer to `schema_version` 1.5 but left nine example and prose occurrences stranded at 1.4, breaking this file's own lockstep-bump convention. **Twelve stale occurrences were bumped to 1.6** — those nine, plus the three that already read 1.5 — including both copies of the "Extracting the structured review block" section, which this port duplicates in `stride-subagent-workflow` as well as `stride-workflow` (the canonical plugin has it only once, so a file-for-file mirror would have missed the second copy). No `schema_version` token below 1.6 now survives outside this file.

Three prose mentions of *schema 1.5* deliberately remain, in `README.md`, `agents/task-reviewer.md`, and `skills/stride-completing-tasks/SKILL.md`. All three are correct historical notes about when the nested `considerations[]` breakdown was added, and a future stale-version sweep should leave them alone.

The enricher checklist count was simultaneously claimed as 17 (seven sites — four in `agents/task-enricher.md`, three in `skills/stride-enriching-tasks/SKILL.md`), 16 (`stride-workflow`), and 15 (the enrichment red-flag line); all now read **18**, matching the actual bullet count in both files, and the red-flag line drops the number entirely. The completion gate's "must pass all four checks" becomes "must pass every check above", since the new matrix bullet makes it five.

### Testing

Documentation-only; the extension ships no test suite. Verified three ways. A dispatched exploratory session simulated creation, enrichment, and review runs against the modified documents **alone** and validated a constructed seven-row matrix through a faithful port of the Kanban server's `BehaviourTestRow.changeset/2` plus the all-seven-categories completeness rule — accepted; it also confirmed the failing-row path yields `status: "failing"` with a `category: "testing"` issue and both the matrix and `testing_strategy` verdicts at `failed`, and that the no-matrix path directs the reviewer to omit the key. Every complete JSON example this change added or modified was extracted and parsed (the files also carry deliberately malformed ❌ WRONG fragments and single-key excerpts, which are not valid JSON by design). Two grep sweeps confirm no stale `schema_version` below 1.6 and no stale checklist count survive outside this file, and checklist bullets were counted programmatically (18 in both files, matching the claim).

### Backward compatibility

Fully backward compatible, and a minor bump because the change is purely additive. Documentation and skill-text only — no hook logic, `.stride.md`, env-var, or `.stride_auth.md` change. The field is optional at the API (absent, `null`, and `[]` all pass), is never added to the five review_queue-scored fields, and the reviewer verdict is omitted rather than emitted empty when a task carries no matrix — so tasks created before this release, and agents that never emit a matrix, behave exactly as they did on 1.38.0.

### Source

W1928 (locate and map the port) and W1929 (mirror populate/verify/utilize), under goal G382. Mirrors the canonical `stride` plugin's v1.40.0 release (goal G381, commit range `5514c99~1..bd37d05` — note the `~1`, as `5514c99` is itself the first commit of the range and an exclusive `5514c99..` omits two of the mirrored files). Per-file insertion counts match that original exactly on eight of the nine shared files. The ninth, `skills/stride-subagent-workflow/SKILL.md`, is deliberately +2: this port duplicates the "Extracting the structured review block" section that the canonical plugin carries only once, so its two extra `schema_version` bumps have no counterpart upstream. Every other delta is a Gemini-runtime token translation. The `reviewer_result` schema is **not** redefined here — [`stride/agents/task-reviewer.md`](https://github.com/cheezy/stride/blob/main/agents/task-reviewer.md) remains the schema of record for all six reviewer variants. The server-side field comes from goal G379 (`Kanban.Schemas.Task.BehaviourTestRow`).

## [1.38.0] - 2026-07-22

### Added — optional Security-Considerations Deep Review integration with the stride-gemini-security-review extension (W1886, W1887, W1888, W1889, W1890)

The review phase now describes an **optional, gated** deep security-considerations check that runs the companion [`stride-gemini-security-review`](https://github.com/cheezy/stride-gemini-security-review) extension's `security-reviewer` custom agent in **considerations mode** when — and only when — a task carries a non-empty `security_considerations` list **and** that extension is installed. When the extension is absent, every skill falls back to the task-reviewer's own security verdict with **no failure** — the integration is purely additive.

- **`task-reviewer`** (`agents/task-reviewer.md`) bumps its `reviewer_result` schema to **`schema_version` 1.5**: the `security_considerations` verdict object gains an **optional nested `considerations[]` breakdown** — one `{ consideration, status: mitigated|partial|unmitigated, evidence, note }` entry per listed consideration — with a **fail-closed escalation rule** (any `partial`/`unmitigated` entry forces the section status to `failed` and requires a matching `category: "security"` issue). The three-state `passed`/`failed`/`not_assessed` section-status enum is unchanged, and the nested array is never required.
- **`stride-workflow`** gains a **Step 5 sub-step ("Deep security-considerations review")**, immediately after the task-reviewer. It triggers only when `security_considerations` is non-empty AND the extension is available (detected **availability-only** by its sanctioned `/security-review` command / `security-reviewer` agent / `security-review-essentials` skill surface — never by reading, sourcing, or eval'ing extension files). It passes the diff and the considerations list as **data to assess** (prompt-injection safety), merges the returned `consideration_verdicts` into `reviewer_result.security_considerations.considerations[]` via the verbatim whole-object copy, escalates fail-closed, and folds its time into the existing `reviewer` workflow step (no new `workflow_steps` name).
- **`stride-subagent-workflow`** documents the dispatch as an **orthogonal optional trigger** in the custom-agent decision matrix, kept identical to the stride-workflow Step 5 gate so the two stay in sync.
- **`stride-completing-tasks`** documents that the nested `considerations[]` breakdown rides through the whole-object copy to `/complete` automatically, and extends the pre-submission self-check to require it to be present and consistent with the section status when a deep review ran (absent-and-not-required otherwise).

Throughout, detection is **availability-only** and the workflow never executes untrusted extension content; when the extension returns malformed or absent verdicts the task-reviewer's own verdict stands and the section is never silently downgraded to `passed`.

## [1.37.0] - 2026-07-21

### Added — optional Manual & Exploratory Testing integration with the stride-gemini-exploratory-testing extension (W1830, W1831, W1832)

The three task-lifecycle skills now describe an **optional, gated** manual-testing step that runs a real exploratory-testing session when — and only when — a task carries manual tests **and** the companion [`stride-gemini-exploratory-testing`](https://github.com/cheezy/stride-gemini-exploratory-testing) extension is installed. When the extension is absent, every skill falls back to the prior behavior with **no failure** — the integration is purely additive.

- **`stride-workflow`** gains **Step 5.5: Manual & Exploratory Testing (Optional, Gated)**, placed between Code Review (Step 5) and Execute Hooks (Step 6) using fractional 5.5 numbering so no existing step is renumbered. It triggers only when `testing_strategy.manual_tests` is non-empty AND the extension is available (detected **availability-only** by its sanctioned command/agent/skill surface — never by reading, sourcing, or eval'ing extension files). When available it dispatches the extension's `/explore` command or `explorer` agent, mapping each manual test to a charter; the Complete Workflow Flowchart and Quick Reference Card are updated to match.
- **`stride-subagent-workflow`** documents the dispatch as **Phase 3.5** in the custom-agent decision matrix (a new `exploratory-testing` column plus flowchart and Quick Reference Card entries), with the trigger kept identical to the stride-workflow Step 5.5 gate so the two skills stay in sync.
- **`stride-completing-tasks`** documents recording the session's findings in **existing tolerant free-text fields only** — `completion_notes` (primary, and the sole carrier when the reviewer was skipped) and the existing `reviewer_result.testing_strategy.note` (secondary, when a reviewer ran) — introducing **no new server-validated field and no new `workflow_steps` name** (either would `422` under strict completion validation). Real credentials, tokens, private data, and internal hostnames must be redacted with synthetic placeholders.

Throughout, the exploratory-testing **safety boundary** is reiterated: dispatched manual testing runs only against authorized, non-production targets, never takes destructive or production-mutating actions, and treats app content as data, not instructions.

### Fixed — the enrichment surface documented create and update bodies without their `task` root key (D151)

`stride-enriching-tasks` documented submitting an enriched task with a bare body: `POST /api/tasks` carried `-d '{...enriched task JSON...}'` and no `agent_name`. The server requires a `{"task": {...}}` envelope and rejects a bare object with `422 Missing 'task' key`, so an agent following the enrichment skill literally built a rejected request and — once corrected by hand — created a task with no attribution fallback. The create example now shows the envelope with `"agent_name": "Gemini CLI"` beside the `task` key, matching the Request Envelope section in `stride-creating-tasks` and the plain agent name this port already sends on claim and complete.

The same file's `PATCH /api/tasks/:id` example was broken the same way and is fixed too — but its rule differs and the doc now says so: `PATCH` needs the identical `task` root key, yet takes **no** `agent_name`, because attribution is create-only and `created_by_agent` is forbidden on update. Conflating the two would have been its own defect.

The `task-enricher` agent doc is deliberately **left unwrapped**: its JSON is the agent's return value for the orchestrator to submit, not a request body, so an envelope there would be wrong. It gains a note saying exactly that, and pointing at who does the wrapping.

This surface was missed by goal G4687 (the fleet-wide `agent_name` rollout) because it sits outside that goal's tasks' `key_files` and outside both of their grep sweeps.

### Testing

Documentation-only; no test suite is exercised. Verified by grep sweep: the enrichment create example carries the envelope and this port's own agent name, matching its `stride-creating-tasks` Request Envelope section; every curl body in the file is brace-balanced; and no other file in the port documents a create body.

### Backward compatibility

Fully backward compatible. Documentation/skill-text only — no hook logic, `.stride.md`, env-var, or `.stride_auth.md` change. The documented shapes are corrected to what the server has always required; nothing that previously worked stops working.

### Source

D151 — follow-up to goal G4687; the gap was recorded by the W1684 reviewer as out of scope at the time. Kanban `task_controller.ex` is the contract of record: `create/2` reads `agent_name` beside the `task` key, `update/2` requires `task` and reads no `agent_name`.

## [1.36.0] - 2026-07-16

### Added — every documented create payload carries a top-level `agent_name` (W1690)

Mirrors the canonical `stride` plugin's W1684 change (released as `stride` v1.37.0) into the Gemini CLI extension. `stride-creating-tasks`, `stride-creating-goals`, and `agents/task-decomposer.md` now document a top-level `agent_name` on every create request — beside the `task` root key for `POST /api/tasks` and beside the `goals` root key for `POST /api/tasks/batch` — set to the exact same plain agent name the extension already sends as `agent_name` on claim and complete (`"Gemini CLI"`, never the `ai_agent:<model>` token form).

Per-task `created_by_agent` is forgotten in practice and cannot be backfilled (`PATCH` rejects it), so tasks lost their attribution permanently and the `/agents` feed rendered them with a `?` avatar. The root-level param is the always-sent fallback that kanban D137 teaches the server to read. Both creation skills gain the full five-step server resolution order (explicit `created_by_agent` → token `ai_agent:<model>` → top-level `agent_name` → token's last agent name → unset), an `agent_name` row in their field tables, and an explicit note that `agent_name` is display metadata only — never an authorization signal.

### Fixed — `stride-creating-tasks` documented the single-create body without its `task` root key

The skill's complete example was a bare task object, but `POST /api/tasks` requires a `{"task": {...}}` envelope and returns `422 Missing 'task' key` without it. Surfaced while placing `agent_name` "beside the task root key" — the key it had to sit beside was never documented. A new Request Envelope section shows the wrapper with `agent_name` as its top-level sibling, and the Quick Reference heading now names the block as the value of the `task` key rather than the request body; the single-goal format in `agents/task-decomposer.md` is corrected the same way. The extension inherited this defect from the canonical plugin, where W1684 fixed it.

### Testing

Documentation-only; no test suite is exercised. Verified by the task's grep sweeps: both creation skills document the top-level `agent_name`, every literal create and batch payload in the repo carries it, and every non-illustrative `json` fence in the two creation skills and the decomposer parses as valid JSON.

### Backward compatibility

Fully backward compatible, and safe to ship ahead of the server. Documentation/skill-text only — no hook logic, `.stride.md` wire shape, env-var, or `.stride_auth.md` change. Unknown top-level keys are ignored by older servers, so sending `agent_name` before kanban D137 reaches production is a no-op. `created_by_agent` guidance is unchanged and still highest precedence — the new param is a fallback, never a replacement.

### Source

W1690 — mirrors the canonical `stride` plugin's W1684 (`stride` v1.37.0), the `stride-codex` port W1686 (`stride-codex` v1.25.0), and the `stride-copilot` port W1688 (`stride-copilot` v2.26.0). Kanban D137 ships the server half. Released by W1691 as `stride-gemini` v1.36.0, with the URL-pinned `stride-gemini-marketplace` updated to match.

## [1.35.0] - 2026-07-14

### Fixed — Ported all three D142 base-ref / snapshot fixes from the canonical stride plugin (D144)

Mirrors the canonical `stride` plugin's D142 fixes (released as `stride` v1.36.0) into the Gemini port. Two production incidents silently corrupted the review diff surface. Because Gemini already uses the newer W1457 file-based `.stride-dirty-baseline` design, this port maps nearly 1:1 onto the reference. All changes are backward-compatible — no wire-shape or `.stride.md` contract change — but this ships as a **minor** bump (1.34.1 → 1.35.0) because the base-ref lifecycle and the new trust guard are behavioral additions.

- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1` (D132)** — `TASK_BASE_REF` was captured at claim time, **before** the `## before_doing` section's `git pull` moved `HEAD`, so the `after_doing` diff spanned commits pulled from another clone (a reviewer saw another machine's task inside an unrelated defect's Review diff). The claim interception now writes task **identity only** and strips any inherited `TASK_BASE_REF` (and its trust marker); a new `finalize_before_doing` (bash) / `Invoke-FinalizeBeforeDoing` (PowerShell) rewrites the base and re-records the dirty baseline **after** the section finishes — jq-free, regardless of the section's exit code — stamping a `TASK_BASE_REF_TRUSTED` marker.
- **`hooks/stride-hook.sh` (D132)** — Added `resolve_snapshot_base`, a trust guard wired into `finalize_after_doing` and the `before_review` self-heal: empty/unresolvable and non-ancestor-of-`HEAD` bases always recompute from the task branch point (merge-base with the origin default branch) with a loud stderr notice; the strict-ancestor-of-branch-point rule applies only to **unmarked inherited** bases. The judgment resolves **once per task window** (memoized against the after_doing section's own `git push`) and is persisted as a `base=` line in `.stride-diff-upload-state` (`record_diff_upload_state` gains a third argument) for the self-heal to reuse.
- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1` (D137)** — `capture_changed_files` (bash) and the `Invoke-ChangedFilesUpload` filter (PowerShell) now override the dirty-baseline exclusion for any path in the `base..HEAD` committed range — committed range = task work, by definition.

### Testing

`hooks/test-stride-hook.sh` (246 assertions) and `hooks/test-stride-hook.ps1` (189 assertions) both pass, with a new **Test Group 17** (bash) / **Test Group 13** (PowerShell) covering the two-clone bare-origin cross-pull scenario, the `resolve_snapshot_base` trust-guard units, the D137 committed-range override, the push-in-`after_doing` once-per-window memoization with persisted `base=`, the trusted pre-pushed base, and the jq-free `finalize_before_doing` rewrite. Both groups were verified failing against the pre-fix hooks (16 bash / 2 PowerShell failures) and passing after.

### Backward compatibility

Backward-compatible and additive. The `TASK_BASE_REF_TRUSTED` marker and the `base=` state line are new but tolerated when absent (an inherited cache simply gets the full trust guard); the committed-range override only ever **includes** more task work; the file-based `.stride-dirty-baseline` transport is unchanged; `after_goal` detection, the canonical response fallback, and the non-fatal upload semantics are untouched.

## [1.34.1] - 2026-07-10

### Fixed — Ported the changed_files upload targeting + fail-loud fixes from the canonical stride plugin (G323)

Two `G323` parity fixes make the Gemini port's `changed_files` diff upload target the right task and stop swallowing terminal upload failures. Both are bug fixes to existing hook behavior with no wire-shape or `.stride.md` contract change, so this ships as a patch bump (1.34.0 → 1.34.1).

- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1`** — **Target the changed_files upload by the `/complete` URL id (D127).** New `task_id_from_command` (bash) / `Get-TaskIdFromCommand` (PowerShell) helpers derive the authoritative task id from the `/complete` or `/mark_reviewed` URL in the intercepted command, and both the `after_doing` finalize and the `before_review` self-heal now use that id as the PUT target, falling back to the env-cache `TASK_ID` only when the URL carries no id (the claim path). This fixes the confirmed empty-`changed_files` root cause (G321/D126) where a hidden claim response left a stale `TASK_ID` in the env cache and routed the diff to the previous task. The parse is gated to the completion path, adds no network call, and preserves the re-PUT's idempotency.
- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1`** — **Fail loud on a terminal changed_files upload failure (W1658).** When the `before_review` self-heal PUT — the last retry — returns a non-2xx, the hook now prints a distinct `CHANGED_FILES UPLOAD UNRESOLVED for task <id> (HTTP <code>)` warning to stderr and appends `unresolved=yes` to `.stride-diff-upload-state`, so a definitively-lost diff is never silently swallowed. The hook exit code is unchanged (the marker append is best-effort), and because the state writer overwrites the whole file, a later successful 2xx PUT self-clears the mark. Only the task id and HTTP code appear in the message and marker — never the bearer token.

### Backward compatibility

Both changes are behavioral bug fixes with no wire-shape change: the changed-files transport envelope, the `before_review` self-heal cadence, and the JSON-only-stdout contract are unchanged, and existing `.stride.md` hooks keep working. The URL→id resolution simply corrects the upload target, and the fail-loud path only adds stderr output plus a best-effort state marker.

### Release

**No marketplace pin update is required.** `stride-gemini` is **not** distributed on `stride-marketplace`; its release is a git tag + GitHub release on the `stride-gemini` repository only, handled by the maintainer.

### Source

G323 — W1665 (D127 targeting), W1666 (W1658 fail-loud), W1667 (this version bump).

## [1.34.0] - 2026-07-04

### Fixed — Ported five unported hook-executor / documentation gaps from the canonical stride plugin (G289)

A batch of `G289` parity fixes brings the Gemini port in line with the canonical stride plugin. Two of them change the hook wire shape / behavior (server env forwarding and millisecond durations), so this ships as a minor bump (1.33.0 → 1.34.0) rather than a patch.

- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1`** — **Server hook.env forwarding (W1519).** Both hook scripts now source the server-supplied `hook.env` verbatim instead of reconstructing only a six-field `TASK_*` subset: after a claim the env cache carries `TASK_DESCRIPTION`, `TASK_NEEDS_REVIEW`, and `BOARD_*` / `COLUMN_*` / `AGENT_NAME` when the server supplies them, and on the `after_goal` path the section receives `GOAL_ID` / `GOAL_IDENTIFIER` / `GOAL_TITLE` / `GOAL_DESCRIPTION` (with a `parent_id` fallback for `GOAL_ID`). Keys are shell-identifier-filtered and safely quoted; server-omitted keys export as empty strings; `HOOK_NAME` and `TASK_BASE_REF` stay script-owned.
- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1`** — **Hook-executor correctness fixes (W1520).** (1) The success JSON now reports a real `duration_ms` at sub-second resolution (`duration_seconds` kept as a deprecated alias). (2) `.stride.md` commands split across lines with a trailing backslash are joined into one logical command before execution. (3) A claim-time dirty baseline (`.stride-dirty-baseline`) now excludes working-tree edits that predate the claim from the changed-files snapshot — a path is dropped only when it is in the baseline AND hash-identical now (task-introduced changes still surface); `.stride.md` / `.stride_auth.md` are also hard-excluded from uploads.
- **`skills/stride-workflow/SKILL.md`** — **Step-numbering gap closed (W1521).** The empty Step 5 slot left by v1.8.0 is gone; the lifecycle steps now run contiguously 0..8 (Code Review is Step 5, Execute Hooks Step 6, Complete Step 7, Post-Completion Step 8), with every in-file cross-reference, marker heading, flowchart, and quick-reference updated. The six `workflow_steps` completion names are unchanged.
- **`README.md`** — **Required-completion-fields corrected (W1522).** The stale "5 required completion fields" claim now names the current set — `completion_summary`, `actual_complexity`, `actual_files_changed`, `after_doing_result`, `before_review_result`, `explorer_result`, `reviewer_result`, plus the required `workflow_steps` array — matching `skills/stride-completing-tasks/SKILL.md`.
- **`agents/hook-diagnostician.md`** — **after_goal awareness + timeout accuracy (W1523).** The diagnostician now recognizes `after_goal` failures (frontmatter + body), and its Hook Timeout Handling section reflects the actual single 300,000 ms `run_shell_command` ceiling that all five hooks share under Gemini's `hooks.json`, instead of the canonical 60k/120k per-hook thresholds this port never enforced.

### Backward compatibility

The env-forwarding and `duration_ms` changes are additive: existing `.stride.md` hooks keep working, `duration_seconds` is still emitted, and the changed-files transport envelope, `before_review` self-heal, and JSON-only-stdout contract are unchanged. The remaining changes are documentation/skill-text only.

### Release

**No marketplace pin update is required.** `stride-gemini` is **not** distributed on `stride-marketplace`; its release is a git tag + GitHub release on the `stride-gemini` repository only.

### Source

G289 — W1519, W1520, W1521, W1522, W1523, W1524.

## [1.33.0] - 2026-07-01

### Added — `API Notes & Limitations` section in the workflow orchestrator skill (G286 / W1419)

Two recurring API gotchas were undocumented, and agents kept rediscovering them the hard way: attempting to move a task to a different goal via `PATCH` (impossible — `parent_id` is creation-only and there is no DELETE endpoint), and calling the hosted API from an HTTP library whose default User-Agent the edge rejects.

- **`skills/stride-workflow/SKILL.md`** — Added an **API Notes & Limitations** section directly after **API Authorization**, mirroring the canonical stride wording: (a) tasks cannot be reparented and there is no DELETE endpoint — moving a task between goals or removing it is a human board-UI action, never to be worked around by recreating the task as a supersede; (b) raw HTTP calls must use curl or a curl/browser-like `User-Agent`, because the hosted API edge returns `403` with `error code: 1010` to default library User-Agents (e.g. `python-urllib`).

### Backward compatibility

Documentation/skill-text only. No skill logic, hook, or wire-shape changes.

### Source

G286 — W1419 (mirrors the canonical stride W1416 wording).

## [1.32.0] - 2026-06-29

### Added — `create-tasks`/`create-goals` now have an explicit terminal state, plus a Backlog claim-fail guard (G284 / W1403)

In an autonomous/build context the create-tasks/create-goals flow could create a task and then fall straight through the `stride-workflow` orchestrator's build loop — auto-claiming and building the just-created task. The claim fails because newly created tasks sit in the Backlog (not Ready), and the agent would then build the work outside the Stride lifecycle (no claim, no hooks, no completion record). The orchestrator had no terminal state for the create intent, unlike `stride-ideation` which stops at the written document.

- **`skills/stride-workflow/SKILL.md`** — Added a **Creation Terminal State** section: on a create-tasks/create-goals intent the orchestrator now reports the created identifiers, clears the activation marker (`$PROJECT_DIR/.stride/.orchestrator_active`, with the `GEMINI_PROJECT_DIR` fallback chain), and STOPS without entering Task Discovery, claiming, or implementation. Added a **Backlog Claim-Fail Guard**: a failed claim is a terminal stop, never a fallback to building outside the lifecycle. The build loop (Steps 1–9) is unchanged.
- **`skills/stride-creating-tasks/SKILL.md`**, **`skills/stride-creating-goals/SKILL.md`** — Added a `## Terminal state` note: creation ends the turn; building is a separate, explicitly-invoked action.

### Backward compatibility

Documentation/skill-text only. No hook, `.stride.md`, or wire-shape change. The build loop is unchanged; only the create-intent path gains an explicit stop.

## [1.31.0] - 2026-06-24

Adds the `gemini-extension.json` manifest at the repo root, making stride-gemini a first-class installable Gemini CLI extension. Previously the repo carried only `GEMINI.md` and had no extension manifest, so `gemini extensions install https://github.com/cheezy/stride-gemini` had nothing to read.

- **`gemini-extension.json`** (new) — declares `name` (`stride-gemini`), `version` (`1.31.0`), `description`, and `contextFileName` (`GEMINI.md`). No `mcpServers` are declared — the extension drives its workflow through `hooks/hooks.json` and skills, not an MCP server.
- **`README.md`** — Installation section notes the manifest so the `gemini extensions install` flow is documented as first-class.

No skill, agent, hook, or workflow behavior changed. Delivered under task W1342.

## [1.30.0] - 2026-06-20

Documentation parity release: brings the Gemini variant to **canonical stride v1.30.0** (G254), porting the `created_by_agent` creation-skill documentation into the Gemini skills. The version tracks the canonical release it now matches.

Agent-created tasks previously landed with `created_by_agent` nil, so the `/agents` activity feed rendered an uninformative `?` avatar on every `created` row. The creation skills now document the field on the create request bodies:

- **`skills/stride-creating-tasks/SKILL.md`** — `created_by_agent` added to the complete-task example, the Field Quick Reference table (string, create-only, forbidden on `PATCH`), and an explanatory note: set it to the plugin's own agent name (`"Gemini CLI"` — the exact value sent as `agent_name` on claim/complete), never the `ai_agent:<model>` token form, so one agent stays one roster identity.
- **`skills/stride-creating-goals/SKILL.md`** — `created_by_agent` added to the batch goal example with a note that the server propagates the goal's value to every nested child task.

Documentation-only: no wire-shape, hook, or auth change; `created_by_agent` is optional on create, was already accepted by the API, and is forbidden on `PATCH`. stride-gemini is not distributed through a marketplace, so there is no marketplace pin to update. Delivered under task W1230.

## [1.29.0] - 2026-06-19

Documentation parity release: brings the Gemini variant to **canonical stride v1.29.0** (G225), porting the `technical_details` task-field documentation rollout into the Gemini skills and agents. The version tracks the canonical release it now matches. Delivered under tasks W1193, W1194, W1195, W1196. stride-gemini is not distributed through a marketplace, so there is no marketplace pin to update.

### Added — the `technical_details` task field is now documented across the plugin

`technical_details` is an **optional, free-form JSON object** a task may carry to hold any additional technical context that does not fit the structured fields — data shapes, gotchas, key decisions, reference links. Unlike `testing_strategy`, it has **no fixed keys**: a task author or enricher uses whatever keys best describe the work, and leaves it as `{}` when there is nothing substantive to record. It is **not** one of the five review_queue-scored fields (`acceptance_criteria`, `testing_strategy`, `security_considerations`, `pitfalls`, `patterns_to_follow`), so a blank value is never a scoring gap. The plugin previously had no documentation for this field; agents now have one consistent definition to follow.

- **`skills/stride-creating-tasks/SKILL.md`** (W1193) — documents `technical_details` in the Field Quick Reference table, the complete-task example, and the Embedded Object Formats section (as a free-form object, explicitly contrasted with `testing_strategy`, which has fixed `valid_keys`).
- **`skills/stride-creating-goals/SKILL.md`** (W1193) — notes that nested tasks MAY carry an optional free-form `technical_details` object and that it is not a review_queue-scored field.
- **`agents/task-enricher.md` + `skills/stride-enriching-tasks/SKILL.md`** (W1194) — add `technical_details` to the enrichment guidance as an optional field the enricher MAY populate from discovered context — never fabricated, left as `{}` otherwise — with a no-secrets reminder since the object is free-form.
- **`agents/task-decomposer.md`** (W1194) — notes that a decomposed task MAY include an optional `technical_details` object.
- **`skills/stride-workflow/SKILL.md`** (W1195) — adds `technical_details` to the Step 1 task-field review list (optional free-form context; not a scored field).
- **`agents/task-explorer.md`** (W1195) — the explorer folds any recorded `technical_details` into its summary so implementation benefits from it.

### Backward compatibility

Documentation-only. No hook (`stride-hook.sh` / `.ps1` / `hooks.json`), wire-shape, `.stride.md`, or `.stride_auth.md` changes; `technical_details` is optional everywhere it appears and is never added to any scored-field set. Tasks that omit it behave exactly as before.

### Source

Goal G246 — the Gemini port of canonical stride v1.29.0 (G225 / G243, W1179–W1182), across child tasks W1193 (creation contracts), W1194 (enrichment + decomposition), W1195 (workflow + exploration surfacing), and W1196 (this release-notes/version task). stride-gemini is not distributed through a marketplace, so no marketplace pin update.

## [1.28.0] - 2026-06-14

Parity release: brings the Gemini variant up from canonical stride v1.23.0 (its own v1.16.0) to **canonical v1.28.0**, porting all five intervening canonical releases (v1.24.0–v1.28.0) into the Gemini hooks, skills, and reviewer prompt. The version jumps `1.16.0 → 1.28.0` to align the Gemini variant's number with the canonical release it now matches. Both hook test suites pass (bash 184/0, PowerShell 145/0). stride-gemini is not distributed through a marketplace, so there is no marketplace pin to update (goal G231).

### Changed — complete-delivery review reports (canonical v1.24.0 / G222, W1120)

- **`skills/stride-workflow/SKILL.md` + `skills/stride-subagent-workflow/SKILL.md`** — the reviewer-dispatch step now passes **every** review field the task supplies (`acceptance_criteria`, `pitfalls`, `patterns_to_follow`, `testing_strategy`, `security_considerations`, `description`, `what`, `why`) with emphatic no-exceptions wording, so a task-supplied section can never come back `not_assessed` because it was withheld from the reviewer.
- **`agents/task-reviewer.md`** — `not_assessed` is reserved STRICTLY for a section the task itself left empty (per-section verdict clauses + a combined four-tile override rule), and the input contract is declared authoritative across variants.
- **`skills/stride-workflow/SKILL.md` + `skills/stride-completing-tasks/SKILL.md`** — `reviewer_result` is built by a whole-object copy of the reviewer's JSON plus a mandatory self-check (every section present; `project_checks` count matches), backed by a hard pre-submission gate in `stride-completing-tasks`.

### Fixed — the changed-files diff upload survives the after_doing timeout (canonical v1.25.0, W1093–W1096; D72)

- **`hooks/stride-hook.sh` + `hooks/stride-hook.ps1`** — the per-file diff snapshot is captured and PUT **before** the `after_doing` gate commands run (with the post-loop call kept as a refresh), so a hook-timeout no longer loses the diffs. A new `.stride-diff-upload-state` file records the last upload's task id + HTTP code (no URL/token), and the `before_review` hook — running on a fresh timeout budget — re-uploads when no healthy upload is on record. The PowerShell hook gains the net-new `Invoke-ChangedFilesUpload`, `Write-DiffUploadState`, and `Invoke-SelfHealChangedFilesUpload` functions.
- **`hooks/hooks.json`** — the two `run_shell_command` hook timeouts are raised `120000 → 300000` ms (5 minutes); the `activate_skill` gate stays at 10000 ms.

### Fixed — a passing after_doing gate no longer renders as a red hook error (canonical v1.26.0 / D65; D73)

- **`hooks/stride-hook.sh` + `hooks/stride-hook.ps1`** — the success branch no longer writes passing-command output to fd 2 / `Console.Error` (which the host mislabels as a hook error even on exit 0). Each passing command's tail-truncated stdout/stderr is folded into a new `commands_output` array on the success JSON, encoded via `jq --arg` / `ConvertTo-Json` so command output cannot inject JSON fields. The failure branch is unchanged; the no-jq path still emits no success JSON.

### Changed — the task-reviewer restates acceptance criteria verbatim, including on re-review (canonical v1.26.0 / D66; W1121)

- **`agents/task-reviewer.md`** — the `acceptance_criteria` array is governed by a hard 1:1 rule: exactly one entry per criterion line of the task's `acceptance_criteria`, verbatim and in order, never split/merged/reworded/added/dropped.
- **`skills/stride-workflow/SKILL.md`** — Step 6 gains a re-review/follow-up dispatch rule and a self-check asserting the reviewer's `acceptance_criteria` count equals the task's own criterion-line count.

### Fixed — the hook's own state artifacts are excluded from changed_files (canonical v1.27.0 / D67; part of D74)

- **`hooks/stride-hook.sh`** — `capture_changed_files` excludes the repo-root `.stride-diff-upload-state` and `.stride-changed-files.json` (exact whole-line match; a same-named file in a subdirectory is still captured).
- **`hooks/stride-hook.ps1`** — `Invoke-ChangedFilesUpload` strips the same root artifacts from the snapshot before PUT (the PowerShell hook has no capture step).

### Fixed — claim-time TASK_BASE_REF is always refreshed (canonical v1.28.0 / G224, W1086/W1087; part of D74)

- **`hooks/stride-hook.sh` + `hooks/stride-hook.ps1`** — the `before_doing` claim path adds a persisted-output-file fallback (read the "Full output saved to: &lt;path&gt;" file, validated as a regular file and parsed with jq / `ConvertFrom-Json` only — never sourced/eval'd; space/quote-tolerant) and refreshes `TASK_BASE_REF` to current HEAD **unconditionally**: even when no task JSON is obtainable it rewrites `TASK_BASE_REF`, clears the stale snapshot/upload-state, and preserves existing `TASK_` identity lines (skipping silently in a non-git dir). The PowerShell hook now **writes `TASK_BASE_REF` for the first time**, with `PSObject.Properties.Name` StrictMode guards on the response-parse cascade.

### Backward compatibility

D65 changes the success-path output shape only (stderr empty on a passing gate; the success JSON gains an additive `commands_output` array). D66, G222 are documentation/agent-contract changes with no wire-shape change. D72 (v1.25.0) raises hook timeouts and adds `.stride-diff-upload-state`; D67/G224 change capture and claim-time cache behavior. Add `.stride-env-cache`, `.stride-changed-files.json`, and `.stride-diff-upload-state` to your `.gitignore` (all are temp files cleaned up after `after_review`).

### Source

Goal G231 — the Gemini port of canonical stride v1.24.0 (G222), v1.25.0 (W1093–W1096), v1.26.0 (D65 + D66), v1.27.0 (D67), and v1.28.0 (G224), across child tasks W1120, D72, D73, W1121, and D74. stride-gemini is not distributed through a marketplace, so no marketplace pin update.

## [1.16.0] - 2026-06-08

Parity release: brings the Gemini variant to G220/G219 parity for the reviewer `project_checks` `not_applicable` status and full-checklist emission (canonical: stride v1.23.0, commit a4e7e6f, W1057). Feature minor (1.15.0 → 1.16.0).

### Updated

- **`agents/task-reviewer.md`** — The `project_checks[]` per-entry `status` enum gains a third value, **`not_applicable`**, alongside `met` / `not_met`, and the reviewer is now required to **emit one entry for every top-level `CODE-REVIEW.md` bullet — never omit one**. Previously, with only `met` / `not_met` available, the reviewer silently dropped bullets that had no bearing on the diff under review (a small one-line fix surfaced only 2 of ~9 checks), so the Kanban review queue's "Code review" panel rendered a partial, ambiguous checklist. Now bullets that do not apply are marked `not_applicable` with a one-line reason in `evidence`; `not_applicable` is **approval-neutral** — it produces no paired `issues[]` entry and never contributes to `changes_requested` (only `not_met` does). `schema_version` bumps `"1.3"` → `"1.4"`, and the worked example demonstrates a `not_applicable` row.
- **`GEMINI.md`, `README.md`, `skills/stride-completing-tasks/SKILL.md`, `skills/stride-workflow/SKILL.md`, `skills/stride-subagent-workflow/SKILL.md`** — All example/prose `schema_version` strings bumped `"1.3"` → `"1.4"` in lockstep so no stale `"1.3"` remains; the GEMINI.md and README.md reviewer summaries now note the `met`/`not_met`/`not_applicable` enum and full-checklist emission.

### Backward compatibility

Documentation/agent-prompt change only — no wire-shape, hook, `.stride.md`, `.stride_auth.md`, or `.gitignore` changes. The change is additive: `reviewer_result` is stored as `:jsonb` by the Kanban server and persisted verbatim (the v1.15.0 passthrough change), so the new `not_applicable` status value flows through with no consumer edit. Payloads from reviewers on the prior `"1.3"` schema (emitting only `met` / `not_met`) remain valid. The Kanban review-queue panel renders `not_applicable` as a neutral "N/A" pill (kanban-side, ships independently).

### Source

W1062 under goal G220 — the Gemini port of W1057 (reviewer `not_applicable` status + full-checklist emission) from goal G219. The canonical implementation is stride v1.23.0 (commit a4e7e6f). stride-gemini is not distributed through a marketplace, so no marketplace pin update.

## [1.15.0] - 2026-06-08

Bundled release covering two ports from the main `stride` plugin (G217 + G218 parity).

### Added

- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1`** (W1045 / D61) — The `after_doing` hook now uploads the per-file diff snapshot to `/api/tasks/:id/changed_files` as a **transport-encoded envelope** — `{"changed_files":{"encoding":"base64","data":"<single-line-base64>"}}` — instead of the raw `{"changed_files":[...]}` array. An edge request filter (WAF) in front of the Stride server can misread a dense code diff as an attack payload and silently drop the upload, leaving `changed_files` empty in the review queue; base64-wrapping the body neutralizes that false positive while the server decodes it back to the identical list. Falls back to the raw `{"changed_files":[...]}` object when `base64` is unavailable (never a bare top-level array). A non-2xx upload response is now surfaced as a stderr warning rather than discarded (non-fatal to completion; the bearer token is never logged). The PowerShell mirror uses `[System.Convert]::ToBase64String` and `[Console]::Error.WriteLine`. The `.sh` D61 block is byte-identical to the main plugin's; hook test suites assert the encoded envelope, raw-text absence, and base64 round-trip (`test-stride-hook.sh` 140/0).

### Fixed

- **`skills/stride-workflow/SKILL.md`, `skills/stride-subagent-workflow/SKILL.md`** (W1053 / D63) — Both skills' "Extracting the structured review block" guidance built `reviewer_result` from a hand-maintained enumerated copy-list of structured keys that omitted `project_checks`, so the reviewer's CODE-REVIEW.md per-bullet audit was silently dropped on completion and the Kanban review queue's **Code review** panel rendered nothing. The guidance is now a **verbatim passthrough**: copy the reviewer's entire parsed JSON object into `reviewer_result` and overlay only the legacy summary fields. The fallback (no parseable JSON block) was inverted to a legacy-only send list so it no longer enumerates structured keys either.

### Updated

- **`agents/task-reviewer.md`** (W1053 / W1049) — Added an explicit **consumption invariant**: the canonical schema is the only place the structured key-set is enumerated, and the completion path MUST persist the reviewer's emitted JSON verbatim and MUST NOT maintain its own allow-list of keys to copy.

### Backward compatibility

Wire-shape: the `changed_files` envelope requires a Stride server that accepts the `base64` / `gzip+base64` encodings on `/changed_files` (ships in the kanban repo); the raw-array fallback path remains byte-compatible with the prior hook. The `reviewer_result` change is documentation/skill-instruction only — `project_checks[]` already existed and is already rendered by the review queue; this release simply stops dropping it. No `.stride.md` / `.stride_auth.md` / `.gitignore` changes required. Not distributed through a marketplace.

### Source

W1045 (D61 base64 changed_files transport port), W1053 (D63 reviewer_result verbatim passthrough + W1049 consumption invariant). Mirrors the main `stride` plugin's 1.22.0 (D61) and 1.22.1 (project_checks) releases.

## [1.14.0] - 2026-06-07

Parity release: brings the Gemini variant to G210 parity by adding `security_considerations` as the **fifth** review_queue-scored field across the creation, enrichment, decomposition, review, completion, and extraction skills/agents. Feature minor (1.13.0 → 1.14.0).

### Added

- **`skills/stride-creating-goals/SKILL.md` + `skills/stride-creating-tasks/SKILL.md` — `security_considerations` as the 5th scored field (mirrors canonical G210).** Adds `security_considerations` everywhere the four-field scored set appears: the review_queue scoring banner, the required/nesting field lists, the minimum-bar list, the Red Flags - STOP list, the Rationalization Table, and the example JSON. `creating-tasks` also gains the `### security_considerations` Embedded-Object-Formats WRONG-vs-RIGHT subsection (array-of-strings shape + the `"None — …"` escape hatch for tasks with no security surface).
- **`skills/stride-enriching-tasks/SKILL.md` + `agents/task-enricher.md` — Step 5 security pass + 17-item checklist.** Expands enrichment Step 5 from "Identify Risks" to "Identify Risks **and Security**" → `pitfalls`, `security_considerations` (input validation/sanitization, authorization boundaries, secret/credential handling, injection surfaces, data exposure). Grows the pre-submission checklist from 16 to **17** items, and threads `security_considerations` through the PATCH/output example JSON, the field-type reminders, and the Red Flags list.
- **`agents/task-decomposer.md` — `security_considerations` Required.** Marks `security_considerations` a Required field in the per-task field table, the single-goal output template, and every one of the four worked-example tasks (array-of-strings with concrete, context-appropriate considerations).
- **`agents/task-reviewer.md` — Step 5 Security Considerations review + schema 1.3.** Adds the "Security Considerations Alignment" review step (gating that the listed considerations were actually implemented), extends the `issues[]` category enum with `"security"`, adds the `security_considerations` per-section verdict object (`passed` | `failed` | `not_assessed`), and extends the consistency rule + review-queue tile list to cover it. Bumps the reviewer `schema_version` **1.2 → 1.3**.
- **`skills/stride-completing-tasks/SKILL.md` + `skills/stride-workflow/SKILL.md` + `skills/stride-subagent-workflow/SKILL.md` — `security_considerations` persistence + extraction.** The structured `reviewer_result` block now carries the `security_considerations` section verdict alongside `testing_strategy` / `patterns` / `pitfalls` (all examples + prose verdict-chains + Shape-1 schema + quick-reference cheat-sheet), at `schema_version` **1.3**. The "Extracting the structured review block" section — present in BOTH `stride-workflow` and `stride-subagent-workflow` in the Gemini variant — adds `security_considerations` to the verbatim-copy field map, the worked examples (schema 1.3), and the JSON-parse-failure omit-list.
- **`GEMINI.md` — top-level manifest.** Updates the `task-reviewer` description to `schema_version` 1.3 and adds `security_considerations` to the listed per-section verdicts.

### Backward compatibility

Documentation/contract-only release. No hook script, parser contract, env-var matrix, or workflow step changed — every `.stride.md` hook behavior is byte-identical to 1.13.0. The `security_considerations` additions are contract additions: older completions that omit the field continue to validate (the server tolerates the structured keys as `:jsonb`, and an absent section renders nothing). All intentional Gemini adaptations are preserved (tool-name vocabulary `read_file`/`grep_search`/`glob`/`list_directory`, the `tools:`/`temperature:`/`max_turns:`/`timeout_mins:` agent frontmatter, the `GEMINI.md`-prefixed project-rules references, and the extraction-in-both-workflow-files structure).

### Source

G210 parity (W1034 creating-goals/creating-tasks, W1035 enriching-tasks/task-enricher, W1036 task-decomposer/task-reviewer, W1037 completing-tasks/workflow/subagent-workflow, W1038 release). Mirrors the canonical stride/ G210 `security_considerations` fifth-scored-field release into the Gemini variant. No marketplace pin update — stride-gemini is not distributed through a marketplace.

## [1.13.0] - 2026-06-05

Parity release: brings the Gemini variant up to the canonical stride 1.18.0–1.20.0 reviewer/creation feature set, plus the D54 credential-resolution fix and an adapter-quality uplift. Feature minor (1.12.1 → 1.13.0).

### Added

- **`agents/task-reviewer.md` — project-level checks (mirrors stride 1.18.0).** Adds a step 6 "Project-Level Checks": read `CODE-REVIEW.md` from the project root (via `read_file`), parse each top-level Markdown bullet as a standing check (nested sub-bullets are context, not separate checks), map a case-sensitive `CRITICAL:` prefix to severity `critical` (default `important`, prefix stripped), and emit `project_checks[]` (`check` / `source` / `status` / `evidence`). Every `not_met` check requires a paired `issues[]` entry with `category: "project_check"`. When `CODE-REVIEW.md` is absent, `project_checks` renders as `[]`. Bumps the reviewer `schema_version` 1.0 → 1.1 and extends the `issues[]` category enum + the `changes_requested` status rule.
- **`agents/task-reviewer.md` — per-section verdicts + schema 1.2 (mirrors stride 1.19.0 / D58).** Adds the `testing_strategy` / `patterns` / `pitfalls` verdict objects (`passed` | `failed` | `not_assessed` + one-line `note`), the consistency rule (a `failed` verdict must be backed by a matching-category `issues[]` entry and vice-versa), and the three step verdict-recording lines (Pitfall Detection / Pattern Compliance / Testing Strategy Alignment). Bumps the reviewer `schema_version` 1.1 → **1.2**.
- **`skills/stride-completing-tasks/SKILL.md` + `skills/stride-workflow/SKILL.md` — structured `reviewer_result` persistence (mirrors stride 1.19.0 / D57).** Documents persisting the reviewer's full structured block verbatim as `reviewer_result` (the rich `schema_version` / `status` / `issue_counts` / `issues[]` / `acceptance_criteria[]` / `project_checks[]` / `testing_strategy` / `patterns` / `pitfalls` keys merged with the legacy `dispatched` / `duration_ms` / `issues_found` / `acceptance_criteria_checked` envelope) rather than the thin envelope. Adds the "Extracting the structured review block" subsection to stride-workflow Step 6 (conceptual fenced-block extraction adapted for Gemini — no Python), the legacy↔structured field mapping, the omit-unemitted-keys rule, and the JSON-parse-failure fallback. The schema is cited (`agents/task-reviewer.md`), not redefined.
- **`skills/stride-workflow/SKILL.md` + `skills/stride-creating-tasks/SKILL.md` + `skills/stride-creating-goals/SKILL.md` — context-informed creation docs (mirrors stride 1.20.0).** Adds a "Context-Informed Creation" section to the orchestrator and "Consuming Provided Context" sections to the two creation skills (context→field mapping, augment-never-override rule, still-required four review_queue fields, and the unchanged `"goals"` root-key / index-dependency rules). Reframed for Gemini's no-slash-command reality: invocation is activating `stride-workflow` with a creation intent + optional directory path (the orchestrator reads the `.md` bundle via `glob`/`read_file`), **not** `/stride:create-*` commands — no `commands/` directory is added.

### Changed / Fixed

- **`hooks/stride-hook.sh` + `hooks/stride-hook.ps1` — D54 `changed_files` credential resolution.** `finalize_after_doing` / `Invoke-FinalizeAfterDoing` now resolve the upload URL + Bearer token via new `resolve_stride_api_url` / `resolve_stride_api_token` (bash) and `Resolve-StrideApiUrl` / `Resolve-StrideApiToken` (PowerShell) helpers that read `$PROJECT_DIR/.stride_auth.md` as the **primary** source — matching the production `**API Token:**` line, deliberately NOT `**Local API Token:**` — and fall back to the `$COMMAND` literal extraction. This makes the snapshot PUT work when the agent's completion curl uses `$STRIDE_API_URL` / `$STRIDE_API_TOKEN` shell variables (previously the PUT silently no-opped). Fire-and-forget / non-fatal semantics preserved; the token is never logged. New `test-stride-hook.sh` Group 10 (10a–10g) covers auth-file primary, the API-Token-vs-Local discrimination, the `$COMMAND` fallback, the shell-variable skip, and no-token-logging. Bash suite: 140 passed / 0 failed.
- **Adapter uplift + accuracy reconciliation.** Hardened the bash + PowerShell hook scripts and skill-gate (`local`-scoped `emit_block` reason, `cd "$PROJECT_DIR"` before the base-ref `git rev-parse`, `$RawInput` rename to avoid shadowing PowerShell's automatic `$input`, after_review cleanup parity for `.stride-changed-files.json`), clarified GEMINI.md (corrected the agent count to five incl. `task-enricher`, em-dash + hooks-panel prose), and reconciled all 7 skills + 5 agents + GEMINI.md against canonical — fixing residual drift (stale `schema_version "1.0"` in the subagent-workflow worked example, the hook-diagnostician structured-JSON input/output handling, `skills_version` documentation, and the `/hooks panel` Claude-Code artifact) while preserving the intentional Gemini adaptations (tool-name mapping, `activate_skill`, `BeforeTool`/`AfterTool` hook mechanism, bash + PowerShell scripts).

### Backward compatibility

The reviewer-schema, structured-`reviewer_result`, and context-creation changes are documentation/contract additions — older completions that still send the thin `reviewer_result` envelope continue to validate (the server tolerates the structured keys as `:jsonb`). The D54 credential-resolution change is the only behavioral change: the `changed_files` PUT now succeeds in the shell-variable-completion-curl case it previously skipped; it remains fire-and-forget and no-ops when neither `.stride_auth.md` nor a `$COMMAND` literal yields a URL+token. All five `.stride.md` hooks produce byte-identical output; the bash test suite is green (140/0).

### Source

G167 (W983 adapter uplift, W984 1.18.0 project_checks, W985 1.19.0/D58 section verdicts, W986 1.19.0/D57 structured reviewer_result persistence, W987 1.19.0/D54 credential resolution, W988 1.20.0 context-threading docs, W989 accuracy reconciliation, W990 release). Mirrors the stride/ **1.18.0** (project_checks), **1.19.0** (section verdicts + structured persistence + D54), and **1.20.0** (context-informed creation) releases into the Gemini variant. No marketplace pin update — stride-gemini is not distributed through a marketplace. No gh release is cut here — that step is human-triggered.

## [1.12.1] - 2026-05-25

### Updated

- **`skills/stride-creating-tasks/SKILL.md`** (W857) — Adds a top-of-file "⚠️ REVIEW QUEUE SCORING" callout that names the four fields the review_queue dashboard scores on every completion (`acceptance_criteria`, `testing_strategy`, `pitfalls`, `patterns_to_follow`) and frames the consequence of omitting any of them: a visible, public, persistent **empty pill** on the dashboard that does not get back-filled later. Reinforces with four new bullets in the existing **Red Flags - STOP** list and four new rows in the existing **Rationalization Table**. Wording matches the stride/ Claude Code variant for cross-plugin consistency.
- **`skills/stride-enriching-tasks/SKILL.md`** (W858) — Adds a top-of-file "⚠️ REVIEW QUEUE SCORING — ENRICHMENT IS THE LAST CHANCE" callout. Promotes the four scored fields to individual mandatory-for-review items in the Phase 4 16-item pre-submission checklist (replacing prior single-line bundling), each with its specific empty-pill condition. Adds four new Red Flags - STOP bullets.
- **`skills/stride-creating-goals/SKILL.md`** (W859) — Adds a top-of-file "⚠️ REVIEW QUEUE SCORING — NESTED TASKS ARE NOT EXEMPT" callout stressing the four-field minimum bar applies to every nested task individually — no "it's just a subtask" discount. Strengthens Task Nesting Rules with a per-field block enumerating each scored field with its empty-pill condition. Adds four new Red Flags - STOP bullets and four new Rationalization Table rows.

### Backward compatibility

Content-only release. No hook script, parser contract, env-var matrix, API field shape, or workflow step changed — every behavior is byte-identical to 1.12.0. The three SKILL.md edits strengthen guidance only; existing task-creation, enrichment, and goal-creation calls continue to validate without modification. No `.stride.md`, `.stride_auth.md`, or `.gitignore` changes are required.

### Source

G166 / W857 / W858 / W859 / W860. Patch release — documentation-only emphasis updates across three SKILL.md files. The change set mirrors the stride/ plugin's 1.17.3 release (Claude Code variant) and the goal is to raise the floor on the four fields the review_queue dashboard scores at completion, so empty pills become rare rather than common.

## [1.12.0] - 2026-05-25

### Critical fix

- **`hooks/stride-hook.sh`** and **`hooks/stride-hook.ps1`** — `finalize_after_doing` / `Invoke-FinalizeAfterDoing` now PUT the per-file diff snapshot to Stride immediately after writing `.stride-changed-files.json` to disk, with the body shaped as `{"changed_files": [...]}` (G162 + G174 ports from main stride 1.16.0 + 1.17.2 shipped together). URL and Bearer token are extracted from the intercepted agent completion command in `$COMMAND` / `$Command` (superseded in 1.13.0, which adds `.stride_auth.md` as the primary credential source — see the D54 fix). The PUT is fire-and-forget (`-s ... > /dev/null 2>&1 || true` on bash; `try`/`catch` + `-ErrorAction SilentlyContinue` on PS) and silently no-ops when any prerequisite is missing (`HAS_JQ=false`, no `curl`, no `TASK_ID`, no URL/token in the command, no snapshot file on disk). The on-disk snapshot is preserved unchanged for legacy `--argjson cf` consumers on older deployments. **G162 and G174 ship together because the wrap is required for the PUT to work at all** — a bare top-level array lands at `params['_json']` under Plug.Parsers, validates as `{:ok, nil}`, and is persisted as NULL, silently clearing `changed_files`.

### Added

- **`hooks/test-stride-hook.sh`** — New Test Group 9 (W844) — 6 sub-cases covering PUT-success+round-trip (curl stub records the body), no-Bearer-token (PUT skipped, snapshot still written), no-`TASK_ID` (PUT skipped), empty-snapshot (`[]` still PUTs as wrapped `{"changed_files": []}`), PUT-failure (stub exits 1, hook still exits 0, snapshot persists), and `HAS_JQ=false` (PUT skipped via the sourced unit-test path). Bash suite total: 131 passed / 0 failed (117 prior + 14 new).
- **`hooks/test-stride-hook.ps1`** — New Test Group 8 (W844) — HttpListener-backed PUT-success test (asserts method, path, Authorization header, body content, wrapped-object shape, snapshot round-trip) plus 4 wrapper-resilience cases (unreachable port doesn't propagate, no snapshot file no-ops, no Bearer token no-ops, no `TASK_ID` no-ops).

### Gemini-specific adaptations preserved

The PUT block sits inside the gemini-style `finalize_after_doing` shape — the outer guard remains `TASK_BASE_REF`, and the HOOK_NAME gating happens at the routing layer (`[ "$_section" = "after_doing" ] && finalize_after_doing` at the three after_doing exit paths). The PowerShell mirror gates on `$HookName -eq 'after_doing'` at function entry, matching the main stride contract. URL+token come from the intercepted agent completion command (1.13.0 adds `.stride_auth.md` as the primary source via the D54 fix).

### Backward compatibility

The wire-shape fix is fully backward-compatible at the server boundary. The four existing `.stride.md` hooks produce byte-identical output to v1.11.0, empirically confirmed by all 117 prior bash tests passing unchanged. The on-disk `.stride-changed-files.json` snapshot is preserved unchanged so legacy `--argjson cf` consumers on older deployments still read it.

### Migration

Install or update via your normal stride-gemini install flow. No `.stride.md`, `.stride_auth.md`, or `.gitignore` changes are required. No marketplace pin update — stride-gemini is not distributed through stride-marketplace. Against pre-1.16.0 Stride servers without the `PUT /api/tasks/:id/changed_files` endpoint, the hook PUT 404s harmlessly (fire-and-forget) and the inline-cat pattern in `stride-completing-tasks/SKILL.md` remains the path that carries the snapshot.

### Source

G162 (auto-PUT — bash port W842, PS port W843, test groups W844) + G174 (wrapped body — folded into W842/W843 since shipping the PUT without the wrap is the broken state that made stride 1.17.2 a critical fix). Mirrors the stride/ 1.16.0 + 1.17.2 releases into the Gemini variant.

## [1.11.0] - 2026-05-22

### Added

- **`## after_goal` hook section** — fifth `.stride.md` hook, fires after the parent goal's final child task completes. Blocking, 60s timeout, same single-bash-fence parsing rule as the four existing hooks. The plugin's `hooks/stride-hook.sh` and `hooks/stride-hook.ps1` now inspect the response payload of `/complete` and `/mark_reviewed` for an `after_goal` entry and execute the local `## after_goal` section as a blocking hook when present. Missing section is a clean no-op (back-compat). Structured failure JSON surfaces on stdout for the agent to forward via `PATCH /api/tasks/:goal_id/after_goal` per the Stride server contract. Implemented as W783 / W784.
- **`GOAL_*` env vars** — `GOAL_ID`, `GOAL_IDENTIFIER`, `GOAL_TITLE`, `GOAL_DESCRIPTION` forwarded by the hook bridge into the `## after_goal` child process environment, sourced verbatim from the server-supplied `hook.env`. `BOARD_*`, `COLUMN_*`, `AGENT_NAME`, and `HOOK_NAME` remain present across all five hooks.
- **`skills/stride-workflow/SKILL.md`** (W786) — Step 7 (Execute Hooks) opens with a Hooks Reference table listing all five hooks (timing/blocking/timeout/purpose), followed by a Hook Environment Variables matrix (`TASK_*` vs `GOAL_*` per hook) and a Canonical Hook Examples block. Step 9 (Post-Completion Decision) gains a subsection describing the goal-Done transition triggered by `after_goal` success and the agent's `PATCH /api/tasks/:goal_id/after_goal` POST contract. Examples explicitly note the hook is general-purpose (Slack notifications, artifact archival, release pipelines, project-level smoke tests are all valid uses).
- **`hooks/test-stride-hook.sh`** and **`hooks/test-stride-hook.ps1`** (W785) — End-to-end test coverage for the new routing. Each harness adds five cases (four required scenarios + mark_reviewed parity). Bash suite now reports 117/0 (100 prior + 17 new in Group 8). PowerShell suite mirrored in Group 7.

### Gemini-specific adaptations preserved

The `run_stride_section` helper introduced for after_goal routing keeps two pre-existing gemini conventions intact: (1) `finalize_after_doing` is gated explicitly on the section being `after_doing` (gemini gates at every call site rather than inside the function), and (2) the plain-text JSON fallback when `$HAS_JQ=false` is routed to stderr (not stdout) per gemini's "JSON-only stdout" contract.

### Backward compatibility

A `.stride.md` without a `## after_goal` section continues to work unchanged — the new routing code is a clean no-op for that case. The four existing hook routes produce byte-identical output (empirically confirmed by all 100 pre-existing tests passing unchanged after the parse-and-exec refactor). Older agent runtimes that don't speak the after_goal protocol — including those that don't make the PATCH POST — are covered by the server-side grace-window worker.

### Migration

Install or update via your normal stride-gemini install flow. No `.stride.md`, `.stride_auth.md`, or `.gitignore` changes are required. To opt into the new hook, add a `## after_goal` section to `.stride.md`. The receiving Stride server must include the `PATCH /api/tasks/:id/after_goal` endpoint for agent reports to land.

### Note on the v1.10.0 gap

Commit `c3da0d8 Release 1.10.0` (per-file diff capture, W732) was committed but never tagged on origin. This v1.11.0 release captures both the v1.10.0 prepared work AND the new after_goal feature, so installing v1.11.0 picks up both.

### Source

G163 / W783 (bash routing), W784 (PowerShell mirror), W785 (end-to-end tests), W786 (SKILL.md), W787 (this release). Pattern mirrors the Claude plugin's v1.17.1 release (https://github.com/cheezy/stride/releases/tag/v1.17.1) — the after_goal feature shipped first on the Claude plugin and is being ported to the other Stride agent plugins.

## [1.10.0] - 2026-05-20

### Added

- **`hooks/stride-hook.sh`** — Added `capture_changed_files()` per the G148/W719 contract with the Option D working-tree semantic landed under G157/W758. The function emits a JSON array of `{path, diff}` entries for every file that differs between `$TASK_BASE_REF` and the agent's working tree at completion time — committed-since-base, staged-but-uncommitted, modified-but-unstaged, and untracked-not-gitignored changes all surface in a single pass. Untracked text files appear as synthesized new-file unified patches (diffed against `/dev/null`); untracked binaries are detected via the `Binary files ... differ` sentinel and use the existing binary placeholder string. A path that is both committed-since-base AND further modified in the working tree appears exactly once with a diff that reflects the final working-tree state. Truncates diffs over 500 lines with the contract marker `[diff truncated at 500 lines]`; emits `[binary file — no diff captured]` for binaries. Falls back to `HEAD~1` when the base ref is empty or unresolvable; returns `[]` for any degraded path (jq missing, git missing, not in a repo, no commits to diff). The function is defined above the early-exit guards so the test suite can `source` the script to call it in isolation.
- **`hooks/stride-hook.sh`** — Added `TASK_BASE_REF` (captured via `git rev-parse HEAD` at `before_doing` time) to the `.stride-env-cache` writer so `capture_changed_files` has an anchor when `after_doing` fires.
- **`hooks/stride-hook.sh`** — Added `finalize_after_doing()` helper and wired it to all three `after_doing` exit points (no-commands branch, all-comments-filtered branch, and post-command-loop). The helper writes the JSON array to `$PROJECT_DIR/.stride-changed-files.json` where `$PROJECT_DIR` resolves to `${GEMINI_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-.}}`.
- **`hooks/stride-hook.sh`** — Added stale-snapshot cleanup on `before_doing` (`rm -f .stride-changed-files.json`) and lifecycle cleanup on `after_review` (removes both `.stride-env-cache` and `.stride-changed-files.json`).
- **`hooks/test-stride-hook.sh`** — Added Test Group 7 (19 cases, 7a-7s) covering truncation thresholds (7a 500-line preserved, 7b 750-line truncated with marker as last line, 7c empty stays empty), binary detection (7d numstat `- -` row, 7e text row not flagged, 7f missing file not flagged), real-git integration against a temp repo with text + binary + deleted entries (7g), non-repo fallback (7h), empty-base fallback to `HEAD~1` (7i), end-to-end `after_doing` snapshot write via `GEMINI_PROJECT_DIR` (7j), all-commented `after_doing` path (7k), legacy-bypass guarantee — `before_review` preserves a pre-seeded stale snapshot (7l), empty changed-files list (7m), null-byte binary file detection (7n), and the five Option D cases (7o modified-uncommitted, 7p staged-uncommitted, 7q untracked text, 7r untracked binary, 7s dedupe when committed-and-further-modified). Suite reports 100 passed / 0 failed.
- **`skills/stride-completing-tasks/SKILL.md`** — Added a new pre-completion checklist item that explicitly tests for the inline `--argjson cf` pattern with absolute `$GEMINI_PROJECT_DIR` path. Rewrote the `## API Request Format` section to lead with a `bash`/`curl` example that inlines the snapshot read via `--argjson cf "$(cat \"$GEMINI_PROJECT_DIR/.stride-changed-files.json\" 2>/dev/null || echo '[]')"` INSIDE the `jq -n` invocation that builds the curl's `-d` payload; the JSON body shape is kept below as an illustrative supplement. Added a new `## Per-File Diff Capture (Optional)` section citing the canonical [`docs/diff-contract.md`](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/diff-contract.md) for the field shape, truncation marker, binary placeholder, and 500-line cap. The section contains a "Why inline?" paragraph explaining the BeforeTool-on-complete trigger and a "Working-tree semantic (v1.10.0+)" paragraph documenting the broadened capture.

### Source

Mirrors stride 1.15.0 (G157/W758) into stride-gemini. Delivered in gemini as W732 (combined hook implementation + tests + SKILL.md docs). The `capture_changed_files()` function body is byte-identical to the canonical stride/ implementation; the SKILL.md prose adapts the canonical pattern to use `$GEMINI_PROJECT_DIR` (with `$CLAUDE_PROJECT_DIR` fallback) and "BeforeTool" instead of "PreToolUse" to match Gemini CLI's hook naming. Test Group 7's e2e cases (7j/7k/7l) use `GEMINI_PROJECT_DIR` to match the hook's primary env-var convention. No marketplace coordination — stride-gemini ships by tag directly.

## [1.9.0] - 2026-05-19

### Changed

- **`agents/task-reviewer.md`** — Rewrote Step 6 ("Return Structured Review") and the Output persistence paragraph to require an unconditional fenced ```json block alongside the existing markdown prose. The block matches the canonical `reviewer_result` schema documented in [`stride/agents/task-reviewer.md`](https://github.com/cheezy/stride/blob/main/agents/task-reviewer.md) — `schema_version`, `summary`, `status`, `issue_counts`, `issues[]` (with `severity`/`category` enums), and `acceptance_criteria[]` (with `met`/`not_met` enum). Includes a verbatim worked `changes_requested` example. The prose summary line is preserved above the JSON block so orchestrator fallback paths that grep substring summaries continue to work when JSON parsing fails. No gemini-specific schema variant introduced — the canonical schema is cited by path.
- **`skills/stride-subagent-workflow/SKILL.md`** — Added an "Extracting the structured review block" subsection to Phase 3 (Code Review). The orchestrator now extracts the first fenced ```json fence from the reviewer's response and populates `reviewer_result` in the completion PATCH payload with both (a) the legacy summary fields (`summary`, `issues_found` from `sum(issue_counts.values())`, `acceptance_criteria_checked` from the length of the structured array) and (b) the structured fields verbatim (`status`, `issue_counts`, `issues`, `acceptance_criteria`, `schema_version`). Includes a worked example and a documented fallback path that keeps older agent versions and parse failures working: substring-match the prose summary, omit structured fields from the PATCH (never empty placeholders), do not abort the completion.

### Source

Ported from stride 1.13.0 (commits 9c19359 "Define structured JSON review-report schema in task-reviewer agent" and 8e94eca "Extract structured review block into reviewer_result PATCH payload"). Cross-plugin parity for Stride W685/W686 (implemented in stride-gemini as W697).

### Notes

Sandbox-scenario verification against the running Gemini agent (zero issues / multiple severities / no acceptance criteria) is deferred to post-release manual testing. The prompt is contract-shaped, but Gemini's empirical adherence to the JSON-block emission contract should be observed before relying on the structured payload from Gemini-driven completions.

## [1.8.0] - 2026-05-08

### Removed

- **`skills/stride-workflow/SKILL.md`** — Removed all three references to the user-private `stride-development-guidelines` skill: the Step 5 ("Activate Development Guidelines") section, the corresponding flowchart node, and the Quick Reference Card line. That skill is project-local to the plugin author's machine and is not distributed with this extension, so end users would have seen Step 5 instructing them to activate a skill that does not exist for them. The Step 5 slot is left empty rather than renumbered to avoid breaking step-number cross-references elsewhere in the file.

### Why this release

Cross-skill references to non-plugin skills break the workflow for end users. This guard rail is being applied to all five Stride plugins (`stride`, `stride-codex`, `stride-gemini`, `stride-opencode`, `stride-pi`) in a coordinated release.

## [1.7.0] - 2026-05-06

### Added

- **`agents/task-enricher.md`** — New custom agent that owns the four-phase enrichment procedure (intent parse, codebase exploration, complexity heuristic, 16-item validation checklist). Receives sparse task fields from the orchestrator and returns a single enriched-task JSON object ready for `PATCH /api/tasks/:id`. Ported from stride 1.11.0 (`stride/agents/task-enricher.md`) with Gemini-specific frontmatter (`tools:` as a YAML list of `read_file`, `grep_search`, `glob`, `list_directory`; plus `temperature: 0.2`, `max_turns: 15`, `timeout_mins: 5`; no `model` or `skills_version` fields). The body is platform-neutral with grep/glob/read invocation syntax adapted to Gemini tool names.

### Changed

- **`skills/stride-enriching-tasks/SKILL.md`** — Slimmed from 779 lines to 264 lines. The four-phase manual enrichment procedure now lives in `agents/task-enricher.md`. The skill retains the STOP preamble, MANDATORY warning, API Authorization block, Iron Law, API integration curl examples, and output example, but the Gemini CLI path now invokes `task-enricher` instead of walking the procedure inline. Other environments still follow the condensed manual walkthrough phases (Phases 1-4 retained in summary form, with the 16-item Phase 4 checklist preserved verbatim).
- **`skills/stride-subagent-workflow/SKILL.md`** — Added `task-enricher` to the agent inventory in the MANDATORY teaser block. Added a new `## Pre-Claim: Enrichment (Sparse Tasks)` section documenting when and how to invoke the enricher before claiming a task. Added `task-enricher` to the Quick Reference Card and References section. Updated the frontmatter `description:` to enumerate `task-enricher` alongside the other custom agents.
- **`skills/stride-workflow/SKILL.md`** — Step 1 enrichment check expanded into two platform subsections: `#### Gemini CLI: Invoke the Enricher Agent` (3-step invoke + PATCH flow) and `#### Other Environments: Activate the Enrichment Skill` (manual-phase fallback). Matches the stride 1.11.0 platform-split pattern.

### Source

Ported from stride 1.11.0 (commit 92b72ea). Cross-plugin parity goal G86 / W349.

## [1.6.0] - 2026-04-29

### Added

- **`hooks/stride-skill-gate.sh` and `hooks/stride-skill-gate.ps1`** — Layer-1 enforcement gate ported from stride 1.10.0 (commit 5c30036). Registered as a new `BeforeTool` hook with `matcher: "activate_skill"` in `hooks/hooks.json`, alongside the existing `run_shell_command` matcher. When the agent attempts to activate any internal Stride sub-skill (`stride-claiming-tasks`, `stride-completing-tasks`, `stride-creating-tasks`, `stride-creating-goals`, `stride-enriching-tasks`, `stride-subagent-workflow`) directly from a user prompt, the gate blocks the activation with exit 2 + a structured `{"decision":"block","reason":"..."}` JSON payload and a human-readable stderr message instructing the agent to activate `stride:stride-workflow` instead. The orchestrator skill writes a marker file at `<project-root>/.stride/.orchestrator_active` on entry and clears it on exit; the gate allows protected sub-skill activations only while the marker is present and fresh (within 4 hours). `STRIDE_ALLOW_DIRECT=1` bypasses the gate entirely for plugin debugging or scripted CI.
- **Gemini-specific gate adapters.** Compared to the Claude Code reference: (1) the gate extracts the skill name from `tool_input.name` (Gemini's `activate_skill` argument shape) instead of `tool_input.skill`; (2) the project root is resolved from the BeforeTool stdin `cwd` field, falling back through `${GEMINI_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-.}}` because Gemini CLI does not set a dedicated project-dir env var; (3) the pure-bash JSON-extraction fallback anchors on `"tool_input"` before searching for `"name"` so it never mismatches against `"tool_name"` or `"hook_event_name"` at the top level of the payload.
- **`hooks/test-stride-skill-gate.sh` and `hooks/test-stride-skill-gate.ps1`** — Test harnesses with 7 scenarios covering: marker missing → block, marker fresh → allow, marker stale (5h) → block, `stride-workflow` always allowed, non-Stride skills always allowed, `STRIDE_ALLOW_DIRECT=1` bypasses, plugin-namespaced names recognized. The bash suite runs 16 assertions and exits 0 on success.
- **`skills/stride-workflow` Orchestrator Activation Marker section.** New section between API Authorization and When to Activate documents the marker contract (path, JSON shape, 4h freshness window, `.gitignore` note, `STRIDE_ALLOW_DIRECT=1` override). Step 0 (Prerequisites) gained a marker-write block; Step 9 (Post-Completion) gained a "Clearing the Orchestrator Activation Marker" subsection. The marker contract is byte-identical to stride 1.10.0 so cross-plugin tooling can rely on the same path and JSON fields.
- **`## STOP — orchestrator check` preamble** — Inserted as the first H2 of every sub-skill body (6 files). The 5-line block instructs an agent that arrived at a sub-skill directly to back out and activate `stride:stride-workflow` instead. Wording is byte-identical to stride 1.10.0 so cross-plugin grep tooling stays consistent.
- **`docs/HOOK_RESEARCH.md`** — Captures the research that decided Layer 1 is portable to Gemini CLI. Confirms `activate_skill` is a documented built-in tool, `BeforeTool` honors regex matchers on `tool_name`, the `tool_input.name` field carries the skill name, and exit 2 + stderr is the preferred block contract — all aligning with stride 1.10.0's gate design with only the three adapters listed above.

### Changed

- **All 6 sub-skill `description:` fields** (`stride-claiming-tasks`, `stride-completing-tasks`, `stride-creating-tasks`, `stride-creating-goals`, `stride-enriching-tasks`, `stride-subagent-workflow`) — Reframed as `INTERNAL — invoked only by stride:stride-workflow. Do NOT invoke from a user prompt.` Removed user-intent verbs (`claim a task`, `complete a task`, etc.) so Gemini's auto-activation matcher no longer routes user prompts to the sub-skills. Wording is byte-identical to stride 1.10.0 for cross-plugin consistency. Frontmatter shape preserved — no `skills_version` field added (the stride-gemini convention is `name` + `description` only).
- **`stride-workflow` `description:`** — Amplified to enumerate the explicit user-intent phrases that should match the orchestrator: "claim a task", "work on the next stride task", "complete a stride task", "enrich a stride task", "decompose a goal", "create a goal or stride tasks". The phrase list is load-bearing for Gemini's matcher and should not be diluted.

### Source

Motivated by the three-layer defense designed in `docs/plans/stride-plugin-feedback.md` (kanban repo) and ported from stride 1.10.0 (commit 5c30036). Layer 1 (the runtime `BeforeTool(activate_skill)` gate) is now active on Gemini CLI; Layers 2 (description reframing) and 3 (STOP preamble) have always been runtime-independent and are also in place.

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
