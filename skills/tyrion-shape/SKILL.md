---
name: tyrion-shape
description: Use when converting messy human inputs (PRDs, scored scenario tables, brainstorm transcripts, voice notes) into canonical Tyrion draft files. Triggered by "/tyrion-shape", "shape this", "ingest these docs", "brainstorm an epic", "what's this project about", or when starting a project without a .feature file. Two modes: --from <docs> for ingestion, no args for interactive. Always writes drafts to disk — never writes the DB directly.
---

# /tyrion-shape

Bridge skill: convert human inputs to Tyrion draft files. The user reviews drafts, then runs `tyrion import`.

**This skill never writes to the DB directly.** Drafts go to disk so the user can edit them. `tyrion import` and `tyrion project sync` are the commit boundary.

## Invocation

```
/tyrion-shape [--from <doc1> <doc2>...]
```

- With `--from`: ingestion mode — read existing docs and extract structure
- No args: interactive mode — ask questions to bootstrap or refine

---

## BRANCH A — `--from <docs...>` (Ingestion)

Use when the user has existing documents: PRDs, scored scenario tables, narrative memos, brainstorm transcripts.

### Step 1: Read all docs

Read every file passed via `--from`. Read them fully.

### Step 2: Identify project and epic

Check:
```bash
tyrion init          # idempotent
tyrion status        # see what's already registered
```

Determine project from: `--project` flag, active project, or ask. Determine epic from: `--epic` flag, or ask if ambiguous.

### Step 3: Extract from the docs

Pull out four types of content:

**Project ABOUT material** (for `ABOUT.md`):
- What is this app? What data does it use?
- Who are the users and what are their goals?
- What is the bigger-picture vision and unique value?
- Key algorithms, signals, or domain concepts

**Epic intent** (one paragraph):
- What slice of the project does this epic represent?
- What is the goal of this particular effort?

**Epic context** (long-form narrative):
- Detailed supporting material: algorithms, data shapes, query patterns, deferred work, open questions
- Everything in the source docs that is *not* the story list

**Stories** (one per scenario/case/scored row/acceptance bullet):
- Title: concise, action-oriented
- Intent: one sentence from the source row or scenario description
- Criteria: extract Given/When/Then if explicitly present in the docs
- If no explicit G/W/T, leave a `# TODO: criteria` marker — the implement skill fills them at step 4

### Step 4: Write draft files

Write exactly these files (create dirs as needed):

```bash
# Project ABOUT.md — create or merge
.tyrion/projects/<project-slug>/ABOUT.md

# Epic .feature file — gherkin with TODO criteria where unknown
features/<epic-slug>.feature

# Epic context sidecar — long-form narrative
features/<epic-slug>.context.md
```

**`.feature` format:**
```gherkin
Feature: <epic name>
  <epic intent — one paragraph>

  Background:
    <any shared setup or domain context>

  Scenario: <story title>
    # TODO: criteria — fill during /tyrion-implement step 4
    # Intent: <one sentence from source>

  Scenario: <next story title>
    Given <precondition>
    When <action>
    Then <observable outcome>
```

**If ABOUT.md already exists**, show a brief diff of what changed — don't silently overwrite.

### Step 5: Print handoff

```
Files written:
  .tyrion/projects/<slug>/ABOUT.md
  features/<slug>.feature
  features/<slug>.context.md

Review the drafts. Edit as needed. Then:
  tyrion import features/<slug>.feature
```

---

## BRANCH B — No args (Interactive Bootstrap or Refinement)

Use when starting from scratch or extending an existing project.

### Step 1: Read current state

```bash
tyrion init
tyrion project list
tyrion status
```

### Step 2: Identify mode

**No active project** → bootstrap mode: ask for project name, slug, and a rough one-paragraph vision. Write minimal `ABOUT.md` draft.

**Active project, no active epic** → epic mode: ask for epic name, slug, and scope. Write minimal `.feature` draft with placeholder scenarios.

**Active project + active epic** → refinement mode: ask "What do you want to shape next?" Options:
- Add stories to current epic
- Edit ABOUT.md with new learning
- Split off a new epic
- Refine existing story titles or intent

### Step 3: Write to disk

For each shaping decision:
- If `.feature` was modified: write to `features/<epic-slug>.feature`
- If ABOUT.md was modified: write to `.tyrion/projects/<project-slug>/ABOUT.md`

Never modify the DB.

### Step 4: Print handoff

```
Files written:
  <list of files changed>

If you modified a .feature:
  tyrion import features/<slug>.feature

If you only modified ABOUT.md:
  tyrion project sync
```

---

## What to include in ABOUT.md

ABOUT.md is the long-form "what is this app" document — qualitatively different from epic-scoped intent. It survives across all epics of the project.

Good ABOUT.md sections:
- **What this is**: one paragraph, plain language
- **The data**: what data exists, what it reveals, notable signals
- **The users**: who they are, what they need, their workflow
- **Key algorithms or domain concepts**: any non-obvious logic the reader needs
- **Vision**: where this is heading, bigger-picture direction

Keep it factual and durable — not status updates or sprint notes.

---

## Idempotency

Re-running shape with the same `--from` docs and the same project/epic is safe. If the `.feature` and ABOUT.md are unchanged, no files are rewritten (check content before writing). If changed, show the diff.

---

## What shape does NOT do

- Does not run `tyrion import` — the user reviews drafts first
- Does not write to the DB
- Does not mark any story as done or in-progress
- Does not fill in TODO criteria — that is step 4 of `/tyrion-implement`
