---
name: tyrion-shape
description: 'Use when converting messy human inputs (PRDs, scored scenario tables, brainstorm
  transcripts, voice notes) into canonical Tyrion draft files. Triggered by "/tyrion-shape",
  "shape this", "ingest these docs", "brainstorm an epic", "what''s this project about",
  or when starting a project without a .feature file. Two modes: --from <docs> for
  ingestion, no args for interactive. Writes drafts, shows for review, imports on
  approval — no manual shell commands needed.'
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

Use when the user has existing documents: PRDs, scored scenario tables, narrative memos, brainstorm transcripts, Claude-written implementation plans.

### Step 1: Read all docs

Read every file passed via `--from`. Read them fully.

### Step 2: Identify project and epic

Check:
```bash
tyrion init          # idempotent
tyrion status        # see what's already registered
```

Determine project from: `--project` flag, active project, or ask. Determine epic from: `--epic` flag, or ask if ambiguous.

### Step 2b: Discovery recall check (read-only)

**Do this before drafting any scenario.** The project already knows about gaps nobody wrote a
story for — marks filed mid-task, spikes whose findings were never promoted. Shaping a new epic
without reading them is how they get stranded.

```bash
tyrion discovery list --status all
```

Read the whole list. Anything still open — `mark`, `findings_ready`, `active_spike` (i.e. not
`promoted_to_story`, `deferred`, or `invalidated`) — is a candidate. Judge each one on whether its
subject overlaps the epic being drafted. `tyrion discovery search "<term>"` narrows a long list,
but the `--status all` listing is the one that has to be read: the mark filed three months ago is
exactly the one you'd never think to search for.

Every overlapping discovery gets one of exactly two dispositions, and both are visible in the draft
the user reviews:

1. **Folded in** — its subject becomes a drafted scenario, or joins one. Name the `disc-NNN` in
   that scenario's intent line or in the `.context.md` sidecar so the trace survives import.
2. **Called out** — it overlaps but is out of scope for this epic. It goes in the Step 5 draft
   review, verbatim, as:
   `leaving disc-NNN open — consider tyrion discovery defer disc-NNN if out of scope`

Never silently drop an overlapping discovery. "I read it and decided it wasn't worth mentioning"
is not one of the two dispositions.

**This step performs no DB writes.** `discovery list` and `discovery search` are reads.
**Never run `tyrion discovery defer`** — not here, not after import, not anywhere in this skill.
Whether a known gap still matters is a human judgment, and deferring is a DB write; the skill's job
ends at surfacing the choice with the exact command to run. Same boundary as `tyrion import`: this
skill only ever proposes.

### Step 3: Comprehend and extract

**Plans come in many shapes.** A Claude-generated plan might use numbered sections, prose paragraphs, bullet lists, tables, or a mix. Don't pattern-match against a specific format — read and understand the document, then normalize what you find into tyrion's structure.

**What to find (by understanding, not by header name):**

**Project context material** — anything that describes what the app is, who uses it, what data it has, what the architecture is. This becomes ABOUT.md and epic context.

**Cross-cutting concerns** — gotchas, vet results, discoveries, architectural decisions that apply across stories. These go into the epic context sidecar, not story notes.

**Stories** — any unit of work the plan describes as a discrete deliverable. These might appear as:
- Numbered sections (`### S3 — Service Layer`)
- Prose paragraphs ("Next we need a controller that...")
- Bullet lists ("Stories: seed data, migration, service layer...")
- A table of tasks
- Implicit in a file map ("we'll need these new files...")

**Visual/prototype sources — detect before extracting stories:**

Before reading the story list, check whether the docs reference or you can locate any visual source:
- Running prototype app (Sinatra, Rails, etc.) — note its path/port
- Template files from a prototype directory (ERB, Haml, JSX, etc.)
- Figma URLs, exported screenshots, StreamWeaver outputs

If a visual source exists:
1. Add a `PROTOTYPE:` line to the epic context_md:
   ```
   PROTOTYPE: <path or URL>
   All UI stories must match this prototype. Before implementing any view, open the
   prototype, navigate to the relevant page, and use what you see as the visual spec —
   not just the text description in the plan.
   ```
2. For each UI story (views, components, tabs, nav), find the corresponding prototype template and **embed its source verbatim in the story's plan note** — not a pointer, the actual content. An agent implementing `AccountUserRow` needs to see `_user_table_row.erb`, not read "renders a table row." The prototype template IS the visual spec.

For each story, extract:
- **Title** — what it's called, in a few words
- **Slug** — kebab-case from title; use explicit `Tyrion-slug:` if present
- **Intent (Why)** — the reason this story exists; may be labeled `Why:`, `Purpose:`, or embedded in prose
- **Criteria** — Given/When/Then if present; bullet-form acceptance conditions; or derive from the plan's description of what "done" looks like. Leave `# TODO: criteria` only if genuinely absent.
- **Implementation body** — everything the plan says about HOW: file paths, code blocks, patterns, gotchas specific to this story. Capture it verbatim where possible. **For UI stories: include the relevant prototype template source verbatim.**

**File maps** — any list of new/modified files the plan provides. Goes into epic context.

**Deferred items** — things the plan explicitly excludes. Goes into epic context.

**Superpowers plans — recognize and map natively:**

A document produced by `superpowers:writing-plans` is detectable by its mandatory header line:

```
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development ...
```

plus `### Task N:` sections with `- [ ]` checkbox steps. These usually live at
`docs/superpowers/plans/YYYY-MM-DD-<feature>.md`. When you detect one:

- Each `### Task N:` section → one story. The task's **Files:** block and step details are the
  implementation body (capture verbatim in the story's plan note).
- Checkbox steps → criteria. Superpowers steps are TDD micro-steps ("write failing test", "run it",
  "commit") — collapse each red/green/commit cycle into one sharp criterion asserting the behavior
  the test proves, not five criteria for the five mechanical steps.
- Add a `Plan file: <path-to-the-plan>` line to the epic context_md. `/tyrion-implement` Step 1
  reads that line and injects the matching plan section into every subagent prompt — this is the
  handoff that makes the superpowers plan executable under the Tyrion ledger.
- Check for a sibling spec at `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` (written by
  `superpowers:brainstorming`). If present, ingest it as project/epic context material like any
  other design doc — it's the WHY behind the plan.
- Superpowers plans are TDD-first by construction: default these stories to `RIGOR: strict` unless
  the task is genuinely mechanical (Step 3b judgment still applies).

This is the recommended front-end for new work: `superpowers:brainstorming` →
`superpowers:writing-plans` → `/tyrion-shape --from <plan>` → `/tyrion-implement`. Superpowers owns
brainstorm/plan discipline; Tyrion owns the ledger, resumability, and gate traceability.

### Step 3b: Rigor + batching detection

**Do this for every story after extraction, before writing anything.**

This is a judgment call based on understanding the work — not keyword matching. Ask yourself: *what does this story actually require?*

**TRIVIAL** — implement directly, no subagents, no pre-push:

The work is mechanical and fully specified. A careful developer could do it by reading the plan once. Examples: seeding dev data, adding an index, adding a tab to a nav constant, swapping an inline nav for a component, any change where the plan gives you the exact code and there's no logic to invent.

**LOOSE** — tests encouraged, pre-push required:

Framework plumbing: controllers, views, routes, standard CRUD. The plan specifies structure and behavior but the implementation requires knowing Rails/Phlex conventions. Tests make sense but aren't the core value.

**STRICT** — failing test must come first:

Novel logic that could be wrong in subtle ways: business rules, classification algorithms, numeric computations, data transformations. The plan may give you the rules, but the implementation has enough degrees of freedom that tests are the only reliable way to know it's right.

**The test:** could this break silently with a plausible-looking but wrong implementation? If yes → strict. If the only way to be wrong is to not read the plan → trivial. Everything else → loose.

**BATCHING** — how many subagents should implement this story?

One story may contain multiple independent units of work. Identify natural seams: separate classes, separate views, separate behaviors. Each seam is a batch. Record: `"criteria 1-4 (ClassName A), criteria 5-7 (ClassName B)"`. If it's one cohesive unit, one batch.

Record all decisions. They go into the ledger after import (Step 5b) and are shown in the draft review.

### Step 3c: Multi-epic decomposition detection

**Do this once, after story extraction, before writing draft files.** Judge whether the
input describes work larger than one epic — not by story count, but by whether the
extracted stories cluster into two or more distinct arcs, each with its own intent, rather
than one cohesive scenario set. Signals: the source document itself names phases,
milestones, or epics; the extracted stories split into groups that don't share a single
Given/When/Then narrative; or the scope is plainly "build X, then build Y on top of it."

If the work fits one epic, skip this step — nothing changes.

If it doesn't, propose a decomposition:
- One **parent epic** — a container with no scenarios of its own, named for the umbrella
  initiative (`features/<parent-slug>.feature` with just a `Feature:` line, no `Scenario:`
  blocks).
- Two or more **sub-epics**, each its own `.feature` file, holding the story clusters.
- **Prerequisite edges** between sub-epics only when the source's own language orders them
  ("first," "then," "after," "requires," "on top of"). Siblings with no ordering language
  get no edge — don't invent sequencing that isn't in the source.

This is shown as part of the Step 5 draft review and stays gated behind the same "yes"
approval as everything else — never propose a decomposition without the exact
`tyrion epic parent` / `tyrion epic depends add` commands sitting right next to the
`tyrion import` lines that would enact it.

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

**If Step 3c proposed a decomposition**, write one `features/<slug>.feature` per epic in the
tree — the parent (scenario-less) plus every sub-epic — instead of a single file.

**`.feature` format:**
```gherkin
Feature: <epic name>
  <epic intent — one paragraph>

  Background:
    <any shared setup or domain context>

  Scenario: <story-slug>
    # Intent: <one sentence from source>
    # RIGOR: trivial|loose|strict — <one-phrase rationale>
    Given <precondition>
    When <action>
    Then <observable outcome>

  Scenario: <next-story-slug>
    # Intent: <one sentence from source>
    # RIGOR: loose — standard Rails controller
    # TODO: criteria — fill during /tyrion-implement step 4
```

The `# RIGOR:` comment is written into the feature file so it survives re-imports and is visible to any agent reading the file directly.

**If ABOUT.md already exists**, show a brief diff of what changed — don't silently overwrite.

### Step 5: Show draft and import on approval

Display the full `.feature` file content inline so the user can review it. Include the rigor/batching table:

```
Story rigor summary:
  dev-data-seed              trivial   rake task, dev-only
  new-index-migration        trivial   single migration file
  crm-service-layer          strict    pure Ruby, persona classification logic
  crm-navigation-accounts-tab trivial  3 file edits, no logic
  crm-accounts-controller    loose     standard Rails controller
  crm-phlex-subcomponents    loose     Phlex components, render-only
  crm-accounts-views         loose     Phlex views, integration
  crm-engagement-tab         loose     Rails + Phlex, existing file modification
```

Then the discovery recall result from Step 2b — every overlapping discovery, with its disposition:

```
Discovery recall:
  disc-041  folded into crm-service-layer (persona classification was the open question)
  disc-047  folded into crm-accounts-controller
  leaving disc-052 open — consider tyrion discovery defer disc-052 if out of scope
  leaving disc-058 open — consider tyrion discovery defer disc-058 if out of scope
```

Print the section even when nothing overlapped (`Discovery recall: no open discoveries overlap this
epic`) — silence reads as "didn't check". Those `defer` commands are for the user to run, or not,
after the import; never run them yourself.

**If Step 3c proposed a decomposition**, show it too, with the exact commands that would enact
it:

```
Epic tree proposal:
  crm-rollout (parent)
    crm-service-layer   — no prerequisite
    crm-accounts-ui     — requires crm-service-layer

  tyrion epic parent crm-service-layer crm-rollout
  tyrion epic parent crm-accounts-ui crm-rollout
  tyrion epic depends add crm-accounts-ui crm-service-layer
```

Ask: **"Does this look right? (yes / edit: <what to change> / abort)"**

- **yes** — single epic: run:
  ```bash
  tyrion import features/<slug>.feature [--confirm-abandon if in-progress story exists]
  tyrion status
  ```
  Multi-epic (Step 3c fired): import every feature file, parent, then wire the edges the
  source actually ordered:
  ```bash
  tyrion import features/<parent-slug>.feature
  tyrion import features/<sub-epic-1-slug>.feature
  tyrion import features/<sub-epic-2-slug>.feature
  tyrion epic parent <sub-epic-1-slug> <parent-slug>
  tyrion epic parent <sub-epic-2-slug> <parent-slug>
  tyrion epic depends add <sub-epic-2-slug> <sub-epic-1-slug>   # only if the source ordered them
  tyrion status
  ```
  Then proceed to Step 5b.

- **edit: <feedback>** — apply the requested changes to the draft file, show updated content, ask again.

- **abort** — leave the draft files on disk unchanged. Print their paths so the user can edit manually.

Never import without a "yes". Never require the user to run import manually when the answer is yes.

### Step 5b: Bake rigor + batching + plan sections into the ledger

**After import succeeds**, for each story, run:

```bash
tyrion note <slug> plan "RIGOR: <trivial|loose|strict>. <one-phrase rationale>. BATCHING: <grouping if applicable>. PLAN: <implementation body summary — key files, patterns, gotchas specific to this story>"
```

This is the payload that makes `/tyrion-implement` fast. When the implement skill runs `tyrion resume`, it finds RIGOR, BATCHING, and the implementation plan in one note — no file hunting, no re-derivation.

For stories with substantial implementation bodies (code blocks, full file paths), include the full content in the note rather than summarizing — verbatim plan text in the ledger beats a pointer to a file.

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

**Whenever a new epic is being shaped** — epic mode, or "split off a new epic" from refinement mode
— run Branch A's **Step 2b discovery recall check** before drafting scenarios. Same read-only
rules, same two dispositions, same callout lines in the Step 4 review.

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

Re-running shape with the same `--from` docs and the same project/epic is safe. If the `.feature` and ABOUT.md are unchanged, no files are rewritten. If changed, show the diff.

---

## What shape does NOT do

- Does not import without user approval ("yes")
- Does not write to the DB before approval
- Does not run `tyrion discovery defer` — ever. It surfaces overlapping discoveries and prints the
  command; the decision to defer stays with the human, like every other DB write here
- Does not mark any story as done or in-progress
- Does not fill in TODO criteria — that is step 4 of `/tyrion-implement`
