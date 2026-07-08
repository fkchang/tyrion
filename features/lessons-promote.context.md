# Lessons — Promote, Demote, and Triage View — Epic Context

## Source

Full design detail lives in the approved, spec-reviewed design doc — read it before
implementing any story here, it has exact code for every component:

`docs/superpowers/specs/2026-06-30-lesson-promote-and-verbose-view-design.md`

This context file is the summary/why; the design doc is the how, including the exact SQL,
migration lambdas, and `demote_lesson` branch logic already traced against real scenarios.

## Why this epic exists

`lessons-jit` shipped the storage + just-in-time surfacing mechanism and proved it live
mid-implementation (a lesson fired at the exact skill step it targeted and visibly changed
agent behavior). What it didn't build: any way to widen a lesson's scope after the fact. Every
lesson created via `tyrion lesson add`/`tyrion lesson mine` gets stuck at whatever epic happened
to be active when it was noticed — even lessons that are obviously true for the whole project
(or every project), like "don't re-offer rspec as UAT."

## The model: nullable-project_id hierarchy, mirroring CLAUDE.md

```
story_id set                → scoped to one story
epic_id set (story_id nil)  → scoped to one epic
project_id set (epic_id nil)→ project-wide
project_id NULL             → global — every project, present AND future
```

Chosen over an earlier draft that proposed a `--global` flag copying a lesson into every
currently-tracked project's own table. The nullable-hierarchy version was strictly better: a
project added *after* a promote still inherits every global lesson for free (a copy-based fan-out
would silently miss it), retire never needs to decide whether to cascade to copies (there's only
one row), and the ambient surfacing already built in `lessons-jit` needs zero changes to respect
the new scope — it never filtered by `project_id` itself, it only ever renders whatever
`Store#list_lessons` already returned.

## How this design session went (worth knowing before touching the code)

This design was brainstormed, not handed down — and it changed shape twice under real scrutiny,
which is directly relevant to how carefully `lesson-origin-tracking-and-demote` needs to be
implemented:

1. First draft: `promote` widened only within one project (`--global` copy-fan-out for
   cross-project). Rejected after clarifying what "promote to global" should actually mean —
   replaced with the nullable-hierarchy model above.
2. A StreamWeaver canvas mockup session (applying Matt's/Forrest's/Gloria's laws explicitly —
   see the design doc's UI section) surfaced two requirements no amount of text-only brainstorming
   had produced: **promote-to-a-chosen-level** (a batch/multi-select triage UI wants to jump
   several lessons straight to "global," not click "promote" N times each) and **demote** ("since
   people make mistakes we could demote — which could be problematic if it goes back to the epic
   level unless we store the epic it came from even if it gets promoted" — the user's own words,
   and exactly the origin-tracking requirement that shipped).
3. **The spec-review loop caught two real bugs in the demote design**, not style nits:
   - The first `demote_lesson` draft only tracked `origin_project_id`/`origin_epic_id`, forgetting
     `origin_story_id` — silently wrong for story-scoped lessons (a shape the Store API and
     existing specs already support, even though no CLI path creates one today).
   - The first migration-ordering note said "no functional dependency, just readability" between
     the origin-columns migration and the NOT-NULL-removal migration — actually false: the NOT
     NULL migration's rebuild uses an explicit column list and would **silently drop the origin
     columns and their data** if it ran second. A real data-loss risk under any future reorder of
     `MIGRATIONS` (a plain Ruby array, no ordering enforcement), not a style preference.

Both were traced against actual scenarios (not just re-read) and fixed before the spec was
approved — the design doc has the corrected code. The `lesson-origin-tracking-and-demote` story
is marked STRICT rigor specifically because of this history: this is exactly the kind of
"plausible-looking but subtly wrong" logic that needs a failing test first, not a careful read.

## Deliberately deferred (named so they aren't lost, not designed here)

- **Folding a global-and-Tyrion-specific lesson back into Tyrion's own source** (SKILL.md/
  CLAUDE.md) — a further rung above "global," conceptually: not just "true for every project" but
  "actually a fact about Tyrion the tool, compile it into Tyrion's own docs." The way the
  `engineering-review` doc gap was fixed by hand during `lessons-jit`.
- **Directory-scoped lessons** (mirroring CLAUDE.md's subdirectory scoping). Plausible future
  granularity between project and epic-wide. Not enough real usage yet to know if it's needed.
- **Step-by-step demote** (full promotion-history audit log, symmetric undo of each rung). What
  shipped instead: demote always jumps straight to the origin in one step. Sufficient for the
  actual failure mode raised ("I promoted this by mistake"), not full audit-trail undo.
- **Multi-id / batch CLI operations.** The mockup showed a real batch-promote/demote workflow,
  but it composes over the single-id primitives (`promote_lesson`, `demote_lesson`) at the UI
  layer — no new CLI surface. A future web UI (Forrest's to build, using this same
  `Store#list_lessons` data layer) or agent script loops over ids itself.
- **Web UI Lessons view.** Not built in this epic. The StreamWeaver mockup validated the
  functional shape (multi-select, batch action bar, scope badges) but was explicitly static —
  Forrest confirmed static mockups were sufficient for this design pass; see auto-memory
  `streamweaver-functional-mockups.md` for the note that fully click-through-interactive
  StreamWeaver mockups are also possible when validating a workflow more deeply matters.

## Schema/pattern references (implementing agent — no need to re-derive)

- `lessons-jit`'s own precedents still apply: discovery counter pattern for IDs, `MIGRATIONS`
  idempotent-guard convention, `Output.time_ago`, the `rescue RuntimeError => e; die e.message`
  pattern used 9+ times in `commands.rb`.
- The three `story_notes` CHECK-constraint rebuild migrations (`add_session_to_story_notes_kind_check`
  et al., `lib/tyrion/store.rb`) are the exact template for `make_lessons_project_id_nullable`'s
  rename-recreate-copy dance — explicit column lists on both `CREATE TABLE` and `INSERT ... SELECT`.
- `add_blocked_on_to_stories`-style `PRAGMA table_info` guard is the template for
  `add_lesson_origin_columns` (plain `ADD COLUMN`, no constraint change, much lighter migration).
