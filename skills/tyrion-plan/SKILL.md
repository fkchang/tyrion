---
name: tyrion-plan
description: Augments Claude Code plan mode for Tyrion-tracked projects. Triggered when entering plan mode on a project with a Tyrion ledger, or by "/tyrion-plan". Ensures the plan produces both a human-readable document AND a ledger-ready feature file, and wires plan approval directly to /tyrion-implement so the ledger stays current from the first story onward.
---

# /tyrion-plan

Bridge between Claude Code plan mode and the Tyrion implementation loop.
Solves the "plan approved but ledger not updated" problem — the handoff gap
where a session codes 9 stories in one window and only marks 1 done.

## The problem this skill fixes

Without this skill:
1. Plan approved via `ExitPlanMode`
2. Session codes all stories in one big context window
3. Only marks done whatever it remembers to
4. `/clear` loses the rest — or requires a manual cleanup pass

With this skill:
1. Plan approved → **first action is `/tyrion-implement`**
2. Each story closes before the next opens (Step 9 CLOSE in the implement skill)
3. `/clear` is safe after every story — ledger is authoritative

---

## When to invoke

- You are entering plan mode on a project that has a Tyrion ledger (`tyrion status` works)
- Or the user typed `/tyrion-plan`
- Or you just called `ExitPlanMode` and it was approved

---

## Protocol

### On entering plan mode (before writing the plan)

1. Check ledger state:
   ```bash
   tyrion status
   ```
   If there is already an in_progress story, do NOT start a new plan — invoke
   `/tyrion-implement` to finish what's started first. A new plan on top of
   in-flight work is context rot in disguise.

2. Write the plan as usual (the full plan file approach works well here).

3. **Also produce a feature file.** The plan's stories → Gherkin scenarios:
   - One epic per major initiative
   - One scenario per story, with the narrative (As a / In order to / I want)
     and sharp Given/When/Then criteria
   - The plan's Verification section IS the UAT runbook for each story's Step 7.5
   - Save to `features/<epic-slug>.feature`

4. On `ExitPlanMode` — when the user approves — **the first action is:**
   ```bash
   tyrion import features/<epic-slug>.feature
   tyrion epic activate <epic-slug>
   ```
   Then immediately invoke `/tyrion-implement` for the first story.

### On plan approval (ExitPlanMode just fired)

**Do not write any code yet.** First:

```bash
tyrion import features/<epic-slug>.feature   # ingest the plan into the ledger
tyrion epic activate <epic-slug>             # set it as the active epic
tyrion status                                # confirm all stories are pending
```

Then invoke `/tyrion-implement` — this starts the per-story loop with CLAIM →
IMPLEMENT → CLOSE → (shepherd `/clear`) → repeat.

**This is the handoff.** `/tyrion-implement` owns the implementation discipline
from here. `/tyrion-plan` just ensures the ledger is ready before it starts.

---

## Shepherd mode (default)

After each story's Step 9 CLOSE:
- The ledger marks the story done
- `/clear` is explicitly safe (the implement skill calls this out)
- Re-invoke `/tyrion-implement` for the next story in a fresh context

This means:
- 9 stories = 9 `/tyrion-implement` invocations, each in a clean context
- `/clear` at any point = zero lost work
- Forrest's/Gloria's Law satisfied: zero friction to context-reset

## Adequate mode (future — DTO-driven)

When the autonomy-loop discovery (`disc-003`) resolves:
- DTO spawns a fresh session per story
- Same ledger, same implement skill, same CLOSE step
- Forrest stays out of the loop unless blocked

---

## What the feature file looks like

Minimal correct form — sharp criteria that double as UAT steps:

```gherkin
Feature: My epic name

Scenario: my-story-slug
  As a <who>
  In order to <why>
  I want <what>

  Given <setup state>
  When <action>
  Then <verifiable outcome — exact command or page behavior>
  And <second verifiable outcome>
```

The Then/And lines become criteria. Write them so you could write the UAT
runbook step (tyrion-implement Step 7.5) before writing any code. If you
can't, the criterion is vague — sharpen it before importing.
