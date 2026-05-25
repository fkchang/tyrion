---
name: tyrion-add-story
description: Add a new story to the active epic without manually editing .feature files. Triggered by "/tyrion-add-story", "add a story", "add scenario", "new story", or when the user wants to extend the current epic with a new scenario. Proposes Gherkin, waits for approval, appends to .feature, and imports — all in one shot.
---

# /tyrion-add-story

Add a story to the active epic. One command: describe → approve → imported.

## Invocation

```
/tyrion-add-story [story title or natural language description]
```

- With args: treat as the story description, propose Gherkin immediately
- No args: ask for title + intent + what it should do

---

## Protocol

### Step 1: Orient

```bash
tyrion status        # confirm active project + epic
tyrion epic show     # get epic slug (needed for .feature path)
```

Derive the .feature path: `features/<epic-slug>.feature`. Confirm it exists.

### Step 2: Gather story shape

If invocation args provided, extract from them:
- **Title** — concise, action-oriented (used as `Scenario:` label and DB slug)
- **Intent** — one sentence: what does this story accomplish?
- **Criteria** — Given/When/Then

If no args or info is missing, ask the user in one message. Natural language is fine — the skill converts it to Gherkin.

### Step 3: Apply sharpness check

Every `Then` line must be a verifiable assertion — observable output, status code, file content, exact string. Vague `Then` lines must be rewritten before proposing.

- VAGUE: `Then the user sees a result`
- SHARP: `Then stdout includes "MD5: <hex>" where hex is 32 lowercase hex characters`

### Step 4: Propose and wait

Present the proposed Gherkin block:

```gherkin
  Scenario: <slug>
    # Intent: <intent>
    Given <precondition>
    When <action>
    Then <sharp observable outcome>
```

**Wait for the user to approve, modify, or reject.** Do not append to the file until approved. Criterion sharpness is a requirements decision.

### Step 5: Append and import

On approval:

```bash
# Append to the .feature file
cat >> features/<epic-slug>.feature << 'SCENARIO'

  Scenario: <slug>
    # Intent: <intent>
    Given <precondition>
    When <action>
    Then <sharp observable outcome>
SCENARIO

# Import to update the DB
tyrion import features/<epic-slug>.feature
```

If import fails with "in-progress story" error, add `--confirm-abandon` — re-importing only refreshes pending stories; in-progress and done stories are preserved.

### Step 6: Confirm

```bash
tyrion status
```

Show the output. The new story should appear as `pending`.

---

## What this does NOT do

- Does not claim or start the new story — run `/tyrion-implement` for that
- Does not reorder existing stories — sequence is set by position in the .feature file
- Does not create a new epic — use `/tyrion-new` for that
