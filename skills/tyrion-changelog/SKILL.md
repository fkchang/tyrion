---
name: tyrion-changelog
description: Use when generating a changelog section for a Tyrion epic and appending it to the target repo's CHANGELOG.md. Triggered by "/tyrion-changelog [epic-slug]", "changelog for this epic", "add changelog entry", or "after sealing an epic". Works on any epic (sealed or not) — deterministic data pull, judgment-driven curation.
---

# /tyrion-changelog

Generate a Keep-a-Changelog-style section for a Tyrion epic and append it to the repo's `CHANGELOG.md`. Typically run right after sealing an epic, but works on any epic.

## Invocation

```
/tyrion-changelog [epic-slug]
```

## Protocol

### Step 1: Resolve the epic

1. If an epic slug was given as an argument, use it.
2. Otherwise, use the repo's active epic (`tyrion status` or `tyrion epic show`).
3. Otherwise, use the most recently sealed epic in the active project (`tyrion epic list` — look for the newest `done`).

State which epic and which resolution rule was used before continuing.

### Step 2: Pull data — deterministic, read-only

Never invent or guess entry content. Every bullet must trace to a real story. Use `tyrion` CLI reads and/or read-only SQLite `SELECT`s against the ledger:

```bash
tyrion epic list                       # confirm epic status, find the sealed date
tyrion status                          # active project/epic context
tyrion show <story-slug>               # per-story intent, status, notes, commit SHAs
```

For a direct pull, query the ledger read-only (default DB at `~/.tyrion/tyrion.db`, or `$TYRION_DB_PATH` if set):

```bash
sqlite3 -readonly ~/.tyrion/tyrion.db <<'SQL'
SELECT slug, title, intent, status, completed_at
FROM stories
WHERE epic_id = (SELECT id FROM epics WHERE slug = '<epic-slug>')
ORDER BY sequence;
SQL

sqlite3 -readonly ~/.tyrion/tyrion.db <<'SQL'
SELECT story_id, body, created_at
FROM story_notes
WHERE kind = 'commit'
  AND story_id IN (SELECT id FROM stories WHERE epic_id = (SELECT id FROM epics WHERE slug = '<epic-slug>'));
SQL
```

Also pull the epic's `intent`/Feature description (from `epics.context_md` or `epics.intent`) for the epic-level one-liner.

**Never write to the DB in this skill** — read-only queries only.

### Step 3: Curate (the judgment layer)

This is why the skill exists rather than a plain script — deterministic extraction feeds it, but turning that into a good changelog entry takes judgment:

- One bullet per **done** story. Skip `abandoned` and `blocked` stories entirely.
- The bullet text derives from the story's **intent**, not its slug — "I want X" becomes "X" in active voice, user-facing language. Don't just retitle the slug.
- Bucket bullets Keep-a-Changelog style: **Added / Changed / Fixed** (infer from the story's intent wording and any commit-message prefixes like `feat`/`fix`/`refactor`; default to **Added** when unclear).
- Include commit SHAs (short form) from `commit`-kind story notes when present, e.g. `(a1b2c3d)`.
- Draft an epic-level one-line summary from the epic's Feature description / intent, if available.

### Step 4: Format the section

```markdown
## [<epic-slug>] - <seal-or-generation date>

<epic one-liner, if available>

### Added
- <bullet> (`<sha>`)

### Changed
- <bullet> (`<sha>`)

### Fixed
- <bullet> (`<sha>`)
```

Omit any bucket with no entries. Use the epic's `updated_at` (seal time) as the date if the epic is `done`; otherwise use today's date and say so.

### Step 5: Show for approval — ALWAYS

Present the drafted section to the user before touching any file. Wait for approval, edits, or rejection. Do not write `CHANGELOG.md` until approved.

### Step 6: Write

- If `CHANGELOG.md` exists in the target repo root: insert the new section directly below the title / `[Unreleased]` header, above the most recent existing version section.
- If it doesn't exist: create it with a standard Keep-a-Changelog header:

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
```

then the new section below it.

### Step 7: Confirm

Show the diff or the new file content. Done.

---

## Future direction

This is the interactive-first phase. Once the format stabilizes across real use, the extraction target is a deterministic `tyrion changelog` command (IoC inversion) — code does the deterministic pull and formatting, this skill's judgment step shrinks to just curation review.
