---
name: tyrion-import
description: Use when loading a reviewed .feature file (and optional companion .context.md) into the Tyrion DB. Triggered by "/tyrion-import", "import feature", "load scenarios", "seed tyrion", or after /tyrion-shape writes drafts that the user has reviewed. Deterministic — always safe to re-run on the same file.
---

# /tyrion-import

Deterministic loader: parse a reviewed `.feature` file into the Tyrion DB. Run after `/tyrion-shape` produces drafts and the user has reviewed them.

## Protocol

```bash
# 1. Ensure this repo is registered
tyrion init

# 2. Import the .feature file
tyrion import features/<epic-slug>.feature

# 3. Activate the newly imported epic
tyrion epic activate <epic-slug>

# 4. Verify
tyrion status
```

## What `tyrion import` does

- Parses the `.feature` file line by line
- Creates or updates the project (if `--project` flag was used)
- Creates or refreshes the epic (name + intent from `Feature:` block)
- If `features/<epic-slug>.context.md` exists alongside the `.feature`, reads it → `epics.context_md`
- Creates stories from each `Scenario:` block
- Creates criteria from `Given/When/Then/And/But` lines
- Stories with `# TODO: criteria` markers get no criteria rows — step 4 of `/tyrion-implement` fills them

## Idempotency

`tyrion import` is always safe to re-run:
- Same file → same `feature_source_hash` → no-op
- Changed file → updates stories matched by slug; new stories appended; missing stories marked `abandoned` (not deleted — notes are preserved)

## After import

```bash
tyrion status        # plan view: check story count, epic intent
tyrion list          # verify stories imported correctly
tyrion show <slug>   # inspect any story: criteria, intent
```

If you need to mark pre-Tyrion work as done:
```bash
tyrion backfill <slug> done "<one-sentence summary of what was built>"
```

## Next step

Once the DB reflects the correct state:

```bash
/tyrion-implement    # claim and implement the next pending story
```
