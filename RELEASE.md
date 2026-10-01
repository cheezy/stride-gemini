# Releasing stride-gemini

A release of this extension touches two repositories: this one (manifest,
changelog, tag, GitHub release) and `stride-gemini-marketplace`, the catalog
that records which version is pinned. The facts below come from this
repository's own history; where that history varies, it is stated rather than
smoothed over.

## The three facts

**Where the version lives.** `gemini-extension.json` (`"version"`). It is the
only file in this repository that carries the release version. Nothing tests
it against the changelog — checking that the two agree is part of the steps.

**Changelog shape: more than one shape on the record, and the history does
not settle which is the rule.** For 1.41.0, 1.42.0 and 1.43.0 the work commit
itself opened the dated heading and bumped `gemini-extension.json` in
lockstep (1.42.0 is even tagged on its work commit). Since 1.44.0, work
commits either append an entry under `## [Unreleased]` or leave the changelog
alone, and the release commit does the rest, in one of two forms:

- renaming `[Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` and bumping
  `gemini-extension.json` (the stamp form), or
- writing the whole entry themselves, often a long one, alongside the bump —
  usually when the work commits in that cycle had not written entries.

So before a release, check whether every commit since the last tag has an
entry; write the missing ones in the release commit. At the time this file
was written, `[Unreleased]` holds an entry from after the last release and at
least one later work commit has none.

**Catalog: `stride-gemini-marketplace`.** That repository's `extensions.json`
lists this extension by a bare repository URL plus a `version` field, so a
sync is a catalog commit that moves the `version` field (and the README row)
to the new release. Its README's "Releases and tagging" section is
authoritative for that side. The part most easily got wrong: every sync gets a
catalog tag and GitHub release, and the catalog tag mirrors this extension's
version **only when that number is free and ahead of the catalog's latest
tag** — otherwise it takes the next free number in the catalog's own
sequence. Companion-extension releases keep consuming catalog numbers, so
expect the two sequences to differ. Nothing installs through that pin: the
URL carries no ref, so users get this repository's default branch.

## Before you add to the changelog: is the top heading already tagged?

```bash
git tag -l "v$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -n 1)"
```

This looks at the newest **numbered** heading (it skips `[Unreleased]` and
the "Release record" note). Any output means that heading has shipped and is
closed: new entries belong under `[Unreleased]`, never under it. In the lite
ports a work commit once appended to an already-released heading and the
entry had to be moved to a new one; this check is what catches that.

## Steps

1. Run the gates:

   ```bash
   bash hooks/test-stride-hook.sh
   pwsh -File hooks/test-stride-hook.ps1
   bash hooks/test-stride-skill-gate.sh
   ```

   and the fleet drift check from the `stride` repository
   (`bash scripts/check-port-canon.sh`, run there).

2. Run the top-heading check. Make sure every commit since the last tag
   (`git log --oneline "$(git describe --tags --abbrev=0)"..HEAD`) has an
   entry, then rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` and set
   `"version"` in `gemini-extension.json` to `X.Y.Z`, in one commit on `main`
   (recent ones are titled `Release X.Y.Z - <summary> (Gnnn)`). Push `main`.

3. Tag the release commit (annotated) and push the tag:

   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```

4. Publish the GitHub release from the changelog entry:

   ```bash
   gh release create vX.Y.Z --repo cheezy/stride-gemini --notes-file <notes.md>
   ```

5. Sync `stride-gemini-marketplace` per its README, choosing the catalog tag
   number by its free-and-ahead rule.

## Known gaps on the record

- Four older tags have no GitHub release; that is accepted and recorded at
  the top of `CHANGELOG.md`. Do not backfill.
- Tags are a mix of annotated and lightweight; use annotated.
