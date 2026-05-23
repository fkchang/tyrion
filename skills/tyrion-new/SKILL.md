---
name: tyrion-new
description: Use when initializing a new directory as a Tyrion project. Triggered by "/tyrion-new", "start a tyrion project", "set up tyrion here", "new tyrion project", or when starting fresh in a directory that has no .tyrion/marker. Handles the full init→project→epic setup in one shot so the user lands at a clean tyrion status ready to implement.
---

# /tyrion-new

Bootstrap a new directory as a Tyrion project. One command → oriented and ready.

## When to use

- Fresh directory with no `.tyrion/marker`
- Starting a spike or gate test
- Any time you'd otherwise have to run `tyrion init` + `tyrion project new` + `tyrion project activate` + write a `.feature` + `tyrion import` + `tyrion epic activate` manually

## Protocol

### Step 1: Register this directory

```bash
ruby ~/work/tyrion/bin/tyrion init
ruby ~/work/tyrion/bin/tyrion status
```

If `tyrion status` shows an active project and epic and the user didn't ask to override: stop, report the current state, and ask if they want to proceed anyway.

### Step 2: Ask the user (all at once — one message, not one question at a time)

Ask for:
1. **Project slug** — short-kebab-case identifier (e.g., `crm-intelligence`, `gate-test`)
2. **Project name** — human-readable title (e.g., "Gate Test", "CRM Engagement Intelligence")
3. **One-sentence project description** — what is this app or experiment about?
4. **First epic slug** — short-kebab-case (e.g., `csv-summary`, `phase-3-5-gate`)
5. **First epic name** — human-readable (e.g., "CSV Summary Script")
6. **First epic intent** — one sentence: what slice of the project does this epic represent?
7. **Stories** — list of story titles, one per line. For each, include intent (one sentence) and optionally Given/When/Then. If no G/W/T provided, the skill writes `# TODO: criteria` markers.

Ask for all seven in one shot. The user can answer in a structured dump or conversationally — extract what you need.

### Step 3: Write project ABOUT.md

```
.tyrion/projects/<project-slug>/ABOUT.md
```

Minimal format:
```markdown
# <Project Name>

## What this is
<one-paragraph from the description + any context inferred>

## Vision
<if inferrable from description; else leave blank for user to fill>
```

### Step 4: Register and activate the project

```bash
ruby ~/work/tyrion/bin/tyrion project new <project-slug> "<Project Name>"
ruby ~/work/tyrion/bin/tyrion project activate <project-slug>
```

### Step 5: Write the epic .feature file

```
features/<epic-slug>.feature
```

```gherkin
Feature: <Epic Name>
  <epic intent — one sentence>

  Scenario: <story-slug>
    # Intent: <story intent>
    Given <precondition>
    When <action>
    Then <observable outcome>

  Scenario: <next-story-slug>
    # Intent: <story intent>
    # TODO: criteria — fill during /tyrion-implement step 4
```

Use `# TODO: criteria` for any story where the user provided no G/W/T.

### Step 6: Import and activate

```bash
ruby ~/work/tyrion/bin/tyrion import features/<epic-slug>.feature
ruby ~/work/tyrion/bin/tyrion epic activate <epic-slug>
```

### Step 7: Verify

```bash
ruby ~/work/tyrion/bin/tyrion status
```

Print the status output. The user should see:
- Project name + slug
- Epic name + slug
- Stories listed with pending status

### Step 8: Hand off

Print:
```
Ready. Run /tyrion-implement to claim and implement the first story.
```

---

## What this does NOT do

- Does not write to the DB before Step 4 (ABOUT.md is a draft, but project creation is in Step 4)
- Does not run `/tyrion-implement` — that is the user's next explicit step
- Does not modify an existing active project/epic without asking
