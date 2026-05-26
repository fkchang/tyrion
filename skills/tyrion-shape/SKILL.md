---
name: tyrion-shape
description: Use when converting messy human inputs (PRDs, scored scenario tables, brainstorm transcripts, voice notes) into canonical Tyrion draft files. Triggered by "/tyrion-shape", "shape this", "ingest these docs", "brainstorm an epic", "what's this project about", or when starting a project without a .feature file. Two modes: --from <docs> for ingestion, no args for interactive. Writes drafts, shows for review, imports on approval — no manual shell commands needed.
---

# /tyrion-shape

Bridge skill: convert human inputs to Tyrion draft files. Writes drafts to disk, shows them for review, then imports on approval — no manual shell commands needed.

**This skill never writes to the DB without approval.** Drafts go to disk first so the user can review or edit. On approval, the skill runs `tyrion import` itself — you never need to.

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

### Step 5: Show draft and import on approval

Display the full `.feature` file content inline so the user can review it.

Ask: **"Does this look right? (yes / edit: <what to change> / abort)"**

- **yes** — run:
  ```bash
  tyrion import features/<slug>.feature [--confirm-abandon if in-progress story exists]
  tyrion status
  ```
  Then print: "Epic imported. Run `/tyrion-implement` to start building."

- **edit: <feedback>** — apply the requested changes to the draft file, show updated content, ask again.

- **abort** — leave the draft files on disk unchanged. Print their paths so the user can edit manually and run `tyrion import` themselves if they change their mind.

Never import without a "yes". Never require the user to run import manually when the answer is yes.

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

### Step 4: Show draft and import on approval

Display the changed files inline.

Ask: **"Does this look right? (yes / edit: <what to change> / abort)"**

- **yes** — if a `.feature` was modified, run `tyrion import features/<slug>.feature [--confirm-abandon]` + `tyrion status`. If only ABOUT.md was modified, run `tyrion project sync`. Print "Done. Run `/tyrion-implement` to start building."
- **edit: <feedback>** — apply changes, show updated content, ask again.
- **abort** — leave files on disk, print paths for manual editing.

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

- Does not import without user approval ("yes")
- Does not write to the DB before approval
- Does not mark any story as done or in-progress
- Does not fill in TODO criteria — that is step 4 of `/tyrion-implement`
