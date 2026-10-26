# Break it before you trust it

Step 4 of `stride-workflow` sends you here whenever the diff you are about to
send for review touches a test. For every test this diff adds or changes, break the code
it protects, watch the test fail, undo exactly that edit, and watch it pass
again. When the diff adds or changes no test at all, there are no entries, Step
5 has no `break_it` to send, and nothing is missing.

The evidence has to come from you because the `task-reviewer` custom agent
never runs code: it can read a test, but it cannot learn whether that test was
ever able to go red. Assertions that stayed green with their code broken kept
landing in this fleet — prose elsewhere in the file satisfied every pin
(W2035), an `ok()` fired outside its loop (W2036), a cap raised from 8 to 1000
broke nothing (W2034), an unclosed quote swallowed two assertions (W2171) — and
fix rounds regressed the same way (W2181, D337). Each was found only because a
reviewer happened to mutate the test by hand.

## Which tests need an entry

- A test is the smallest unit its runner reports on. In this repository that is
  one `assert_*` call in `hooks/test-stride-hook.sh`, or one `Assert-*` call in
  its `.ps1` twin; in a project you work on, it is that framework's own unit
  (an ExUnit `test`, a JavaScript `it`, and so on).
- It is new when the diff introduces it. It has changed when the diff touches
  what it asserts, what it sets up, or the text it reads.
- A change of only whitespace, wrapping or comments, where no assertion or
  setup now means something different, needs no entry. If in doubt, count
  it as changed.
- A test the diff leaves alone needs no entry, even when its file changed
  somewhere else.
- Write one entry per new or changed assertion, and let `test` point at the
  line it sits on.

## The procedure

Do all of this inside the repository the change lives in. On a plugin task
that means the nested plugin repo, never the outer project around it.

1. **Take a snapshot before the first break.** Porcelain status on its own is
   not enough here: your files already carry edits by Step 4, so
   it misses a break inside a file you had already modified. Hash content too:

   ```bash
   { git status --porcelain --untracked-files=all; git diff HEAD --binary; git diff --cached --binary; git ls-files --others --exclude-standard -z | xargs -0 shasum; } | shasum
   ```

   Keep the hash in your notes. A shell variable does not survive from one tool
   call to the next, and a snapshot file would change the very tree it
   describes. A host without `shasum` can use any other hash tool, as long as
   both runs use the same one. A permission-bit-only change can slip past the
   hash, so confirm with `ls -l` if you touched a mode.
2. **Make one minimal edit** where the asserted behaviour actually lives: flip
   the condition, change the constant, alter the pinned phrase. Editing a spot
   the test never looks at tells you nothing. Removing a file is never how you
   break a test.
3. **Run the test; it must go red.** Record what you saw as
   `failed_when_broken`.
4. **Restore by reversing that one edit by hand**,
   not by `git checkout`, `git reset`, `git stash` or `git restore` — each of
   those would also wipe whatever else you have not yet committed there.
5. **Run it once more; it must go green.** Record that as
   `passes_when_restored`.

Once the last test is done, snapshot again:
the two hashes must match before you invoke the `task-reviewer` custom agent,
and before any commit or hook runs. If they differ, `git diff` shows what was
left behind; reverse it by hand and take the snapshot again.

A test that stays green with its code broken is vacuous. Repair it — tighten
the text it reads, make its phrase unique, pull the assertion inside its loop,
close the stray quote — and then break it a second time. Report `false` only
for a test you could not repair,
and never report an observed `false` as `true`.

### Counting a pinned phrase

When a test pins a phrase in a document, you break it by altering that phrase
where the rule lives. Count it first, within the slice the test actually reads:
`sed -n '<range>p' <file> | grep -oF -- '<phrase>' | wc -l`. That tallies each
occurrence; `grep -c` tallies matching lines instead, and reports 1 for a line
holding the phrase twice — a markdown link such as `[a.md](a.md)` does exactly
that. With a count above 1, a break at one site leaves the test green, so
narrow the slice or lengthen the phrase until it counts exactly 1.

You may break several text pins in a single run only when every pinned phrase
is unique in its slice and none of them overlaps another. Each pin broken that
way must then go red, and every other assertion must stay as it was. Overlap
means two pinned phrases sharing text; merely sitting on the same line is not
overlap.

A short example: a test checks that a skill mentions `a.md`, reading the whole
file, and the only mention is the link `[a.md](a.md)`. Breaking the link text
to `[b.md]` leaves the test green, because `a.md` survives in the link target.
The occurrence count says 2 before you even try. Pin the whole link or the
sentence around it instead, then break it again and watch it fail.

## Keeping the break inside the repository

- Only the working tree of the repository under change is edited. Nothing
  outside it is created, changed or removed.
- No `rm -rf`, no history rewrite, and nothing that reaches the network — no
  remote, registry, API or Stride server.
- Leave shared things alone: a test's own sandbox database is fine, but a
  shared database, global settings, hook cache files and other running
  processes are off limits.
- Keep every break out of gitignored files; the snapshot cannot see them, so
  it could not prove the restore.
- Never commit while a break is in place. Break one test at a time unless the
  batching rule above allows more.
- A test that needs side effects outside the repository to break gets a
  one-line `not_broken_reason` instead of a break, and its `break` and both
  booleans are `null`. An explanation that points at no such outside effect —
  "slow", "obvious", "too simple to fail" — is no excuse; break the test.

## The entries

Each entry has four fields — `test`, `break`, `failed_when_broken` and
`passes_when_restored` — plus `not_broken_reason` on the unbreakable kind:

```json
[
  { "test": "hooks/test-stride-hook.sh:7650", "break": "altered the pinned phrase at skills/stride-workflow/SKILL.md:318", "failed_when_broken": true, "passes_when_restored": true },
  { "test": "test/app/mailer_test.exs:41", "break": null, "failed_when_broken": null, "passes_when_restored": null, "not_broken_reason": "only a live SMTP server can exercise this handshake" }
]
```

- `test` is a repository-relative path plus either a line number or the test's
  name.
- `break` is a single line saying what you edited, with its `file:line`.
- The two booleans hold what actually happened, not what you predicted.
- No entry quotes a test body, a diff or any command output. A
  credential-shaped string becomes `[REDACTED — break text embedded a credential]`
  and you cite its `file:line` instead, in the reviewer prompt, `completion_notes`
  and `completion_summary` alike.

Step 5 hands these entries to the reviewer as `break_it`. If the decision
matrix skips review for this task, still do the breaking, and send no
`break_it` since there is no reviewer to send it to.

## Later review rounds

A fix touches a test if it edits that test or the code its entry broke. Every
touched test gets broken again; send its new entry under a label saying it is
fresh, and send round one's entries for the others as they were. The label is
prose, never a fifth key. When no fix touched any test, just resend round
one's entries. Even when no second round will run under Step 5's grounds,
break every touched test again before you complete — fix rounds are exactly
where W2181 and D337 regressed. This record is not
`review_round.fixes[]`: that list says what changed, while `break_it` says what
was proven.

These entries are your own report. The reviewer can judge whether each is
plausible against the diff, but it cannot replay a break; what you gain is that
a new test no one ever watched fail can no longer pass unnoticed.
