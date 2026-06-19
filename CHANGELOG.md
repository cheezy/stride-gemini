# Changelog

All notable changes to the Stride extension for Gemini CLI will be documented in this file.

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
