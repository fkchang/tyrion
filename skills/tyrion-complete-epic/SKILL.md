---
name: tyrion-complete-epic
description: Use to seal the active (or a named) epic as done once all its stories are complete. Triggered by "complete the epic", "seal the epic", "mark epic done", or "/tyrion-complete-epic". Thin wrapper over `tyrion epic complete`.
---

# /tyrion-complete-epic

Seal a completed epic so it reads as DONE on every surface (web roadmap seal, CLI `project show`, statusline). An epic's status is never auto-flipped to `done`; this is the manual seal gesture.

## When to use

- You just closed the last story in an epic and want to record the win
- `tyrion status` shows N/N done but the epic still reads `[active]`
- The user says "seal the epic" / "mark the epic complete"

Note: `tyrion done` already prompts to seal when the last story closes in an interactive session. Use this skill when that prompt was declined, the close was non-interactive, or you want to seal a different epic.

## Protocol

```bash
# Seal the active epic (or pass an explicit slug):
tyrion epic complete            # seals the currently active epic
tyrion epic complete <slug>     # seals a named epic
```

- Refuses (exits 1) if any story is not done — it names the undone stories.
- Pass `--force` to seal anyway (e.g. an epic intentionally left with deferred stories):

```bash
tyrion epic complete <slug> --force
```

On success it prints `Epic <slug> sealed as done.`

## After sealing

Verify the seal landed:

```bash
tyrion project show     # the epic should read `done`, not `[active]`
```

Then record the arc in the project ABOUT.md `## Timeline` section so the next agent knows why the epic existed:

```
- YYYY-MM-DD | <epic-slug> shipped (N/N) | review: <one-line finding> | spawned: <slug>
```

**Then look at what the seal just unlocked — don't go silent on next-epic choice.** `tyrion
epic complete` already prints a line naming any epic whose last unmet prerequisite was this
one:

```
Unlocked: <slug> — now eligible (tyrion epic activate <slug>)
```

When that line appears, don't just note it — offer to act on it: ask the user whether to run
`tyrion epic activate <slug>` now (or, for more than one unlocked epic, `tyrion epic waves`
to see them grouped and let the user pick). When the line is absent, say so plainly ("nothing
else was waiting on this epic") rather than leaving next-epic choice unaddressed.

## Honesty flip

Sealing is reversible by reality: if a story in a sealed epic is later started, claimed, blocked, or a new pending story is imported, the epic automatically flips back to `active`. You never have to un-seal manually.
