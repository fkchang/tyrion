# Big-Picture History — Epic Context

## The Problem in One Sentence

Tyrion already *stores* the big picture (`projects.about_md`, `epics.context_md`) but never *surfaces* it at orientation — so it is physiologically bypassed, as if it doesn't exist.

## Motivating Arc (the doc-parity scenario)

1. `visual-plan-components` (StreamWeaver Canvas) shipped autonomously, 11/11 stories done.
2. Forrest reviewed the output and found gaps: no TOC numbers, sidebar scrolled away, mermaid invisible in dark mode, card headers missing badge layout, font/spacing mismatches vs the Anthropic artifact.
3. He spawned `doc-parity` (16 stories) to close those gaps.
4. Mid-session while setting up the doc-parity epic, the root problem became visible: Tyrion had no way to surface "why doc-parity exists" or "what's still left in doc-parity" once the active epic changed. He pivoted from implementing doc-parity to designing Tyrion to fix this.

The pivot itself proved the bug: a pivot in the middle of work caused the context to evaporate from Tyrion's orientation surface.

## The Linchpin Bug

`lib/tyrion/importer.rb` lines 43-50: the `upsert_epic` call passes `intent`, `feature_source_path`, `feature_source_hash` — but never reads the sibling `<epic>.context.md` file. The schema column (`epics.context_md`), the `upsert_epic(context_md:)` kwarg, and the display code in `cmd_epic_show` all exist. Only the file-read in the importer is missing. ~10 lines unblocks everything downstream.

The `tyrion-import` skill documents this behavior ("If `features/<epic-slug>.context.md` exists...") — the code just never implemented it.

## Design Principles

All three Triumvirate laws applied to BOTH the human (Forrest, GEA pattern, pivots constantly) and the agent (context resets on `/clear`):

- **Gloria's Law**: deliver the big picture at orientation, don't store it where you must know to look. "That is the full agent context" (current tyrion-orient claim) is a Gloria's Law violation — it says complete while omitting two entire context layers.
- **Matt's Law**: progressive disclosure — north-star → epic intent → open threads → story → next action. Each layer ≤ 3 lines by default; drill with `epic show` / `project show`.
- **Forrest's Law**: surface by default. Knowing to run `epic show` is friction. Kill the silo; the perk is that the agent can orchestrate autonomously once it has the whole picture.

## Decisions

1. **Narrative-only history model (least code).** The epic→review→epic arc is prose in ABOUT.md `## Timeline`. No new schema for lineage. The `epics.spawned_from` FK and the event-stream table are explicitly deferred — add when a web view needs to draw the chain.
2. **Two pillars:** Pillar 1 (context surfacing, pareto core) built first; Pillar 2 (orchestration) designed now, built in a later session.
3. **Dogfooding:** this feature is itself tracked in the `tyrion` Tyrion project, using the feature-file workflow being extended.

## Story Dependencies

```
context-md-import
  → orient-surfaces-big-picture
    → orient-skill-update
about-md-timeline-convention  (independent)
  → migrate-handoff-doc        (needs context-md-import too)
tyrion-assign-command
  → tyrion-wave-next-command
    → tyrion-orchestrate-skill
```

Pillar 1 stories depend on each other in sequence. Pillar 2 stories are independent of Pillar 1 (different subsystem). `migrate-handoff-doc` depends on both pillars being done enough for the content to have a home.

## What the StreamWeaver Handoff Doc Contains (will migrate here)

`docs/sw-doc-parity-checkpoint.md` (in stream_weaver repo, gitignored) holds:
- The full original goal (PRD parity, outcompeting the Anthropic artifact)
- What was built before doc-parity started (doc_header.rb, render_doc_header, etc.)
- User feedback from annotated screenshots
- Root-cause analysis of each visual gap
- Locked decisions (new :doc theme, light default + visible toggle, everything in one pass)
- The Tyrion orchestration model for this epic

Once `context-md-import` and `about-md-timeline-convention` land, this content migrates into:
- stream-weaver ABOUT.md Timeline section (the arc + north star)
- features/doc-parity.context.md (root causes + locked decisions)
Then the checkpoint doc can be removed.

## Key Files (for implementation reference)

- `lib/tyrion/importer.rb:43-50` — the linchpin bug (missing context.md read)
- `lib/tyrion/store.rb:724-739` — `upsert_epic` (already accepts `context_md:`)
- `lib/tyrion/commands.rb:276-310` — `cmd_epic_show` (reads context_md, truncated at 800 chars)
- `lib/tyrion/commands.rb:894-997` — `cmd_resume` (the orientation command to enhance)
- `lib/tyrion/commands.rb:348-486` — `cmd_status` (add north-star line here)
- `skills/tyrion-orient/SKILL.md` — the skill that overclaims completeness
- `skills/tyrion-implement/SKILL.md` — add Timeline convention note to the CLOSE step
- `lib/tyrion/store.rb:285-327` — `wave_plan` (topological layers, used by P2.2)
- `lib/tyrion/commands.rb:1380-1469` — `cmd_wave` / `cmd_depends` (P2.2 builds on these)
