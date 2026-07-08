---
name: tyrion-checkpoint
description: Use before /compact, /clear, or ending a session on an in-progress story. Triggered by "checkpoint", "save state", "handoff", "/tyrion-checkpoint", or when the user signals they are about to leave or clear context. Persists current state so the next agent can resume exactly.
---

# /tyrion-checkpoint

Persist a handoff before `/compact`, `/clear`, or session end. Distinct from the implement loop — this is an interrupt point, not a step.

## When to use

- Before you run `/compact` or `/clear`
- Before ending a session mid-story
- When the user says "save where we are" or "handoff"
- When you realize context is filling up and work isn't done

## Protocol

First, identify the in-progress story:

```bash
tyrion status        # confirm which story is in_progress
```

Then persist everything:

```bash
# 1. Record what is currently done and what is not yet done
tyrion context <slug> "<one-paragraph: what is implemented, what is wired up, what is still TODO>"

# 2. Record the exact next action
tyrion next <slug> "<the single most important thing to do first on resume>"

# 3. Record a handoff note with key details the next agent needs
tyrion note <slug> handoff "<key facts: files changed, approach taken, blockers, what NOT to redo>"
```

## What to include in the handoff note

- Which files were modified and roughly what was changed
- Any gotchas or non-obvious decisions made
- What was tried that didn't work (so the next agent doesn't repeat it)
- Dependencies or assumptions the next agent should know about

## After checkpoint

The next fresh agent runs `/tyrion-implement` with no slug — it will resume exactly from `current_context` and `next_action`.

## Epic close → Timeline update

When an agent closes the last story in an epic (or spawns a corrective epic after review), record the arc in the project ABOUT.md `## Timeline` section:

```
- YYYY-MM-DD | <epic-slug> shipped (N/N) | review: <one-line finding> | spawned: <slug>
```

This is how "why the next epic exists" survives a `/clear`. Without it, the next agent sees only the corrective epic and cannot understand the arc that created it.
