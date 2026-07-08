Feature: Lessons — Promote, Demote, and Triage View
  # Intent: Give lessons a real scope hierarchy (story < epic < project < global,
  # mirroring ~/.claude/CLAUDE.md's universal-vs-project-scoped model) with a safe
  # way to widen a lesson's reach one rung at a time, undo a mistaken promotion,
  # and see enough per-lesson metadata (scope/source/age) to decide what's
  # promote-worthy. Follow-on to the lessons-jit epic, once the just-in-time
  # surfacing mechanism was proven live.
  # Design doc: docs/superpowers/specs/2026-06-30-lesson-promote-and-verbose-view-design.md
  # (brainstormed + spec-reviewed 3x; a StreamWeaver mockup session surfaced the
  # demote/origin-tracking requirement and the promote-to-a-chosen-level convenience
  # — both driven by a real human-triage-UI walkthrough, not speculative scope.)
  # Triumvirate laws applied: Gloria's (scope is a color-coded badge, not a sentence
  # you read); Matt's (grouped/scannable, not a wall of text); Forrest's (one click
  # widens a lesson, no confirmation dialog, no menu).

  Background:
    Given the lessons-jit epic already shipped: lessons table, tyrion lesson CLI
      (add/list/retire/mine), ambient status/resume surfacing, JIT injection wired
      into tyrion-implement's own steps
    And lessons are currently scoped by nullable epic_id/story_id only — project_id
      is NOT NULL, so a lesson can never apply beyond the one project it was created in
    And there is at least one other real Tyrion user whose local database already has
      the lessons table with the old NOT NULL constraint — every migration in this
      epic must be safe to run against that existing, populated database
    And Store#list_lessons currently builds its WHERE clause from bare (unqualified)
      hash keys — any JOIN added against a table sharing column names (epics has its
      own project_id and status columns) will break it unless those keys are
      qualified with the lessons. table prefix

  Scenario: lesson-scope-nullable-and-store
    As an implementing agent building the promote mechanism
    In order to let a lesson widen all the way to "applies to every project, present
      and future" without copying it anywhere
    I want project_id to become nullable, list_lessons to include global rows for
      every project's query, and a hierarchical promote_lesson primitive

    # RIGOR: strict — the migration is explicitly safety-critical (must not break a
    # real other user's existing database) and promote_lesson's ladder logic already
    # had a story_id-scoping gap caught during spec review; correctness here needs a
    # failing-test-first approach, not just "looks right."
    # BATCHING: batch A (make_lessons_project_id_nullable migration — the rename/
    # recreate/copy dance, safety tests first), batch B (list_lessons OR-based
    # project_id query + epic_name join), batch C (promote_lesson hierarchical widen).
    Given lessons.project_id currently has a NOT NULL constraint, added via the
      create_lessons_table migration's CREATE TABLE IF NOT EXISTS (which is a no-op
      against an already-existing table — editing that lambda's SQL in place would
      silently do nothing for an existing user)
    When a new, separate MIGRATIONS entry rebuilds the lessons table without NOT NULL
      on project_id, using the same rename-recreate-copy pattern already used three
      times in this file for story_notes' CHECK constraint, with an explicit column
      list on both CREATE TABLE and INSERT ... SELECT
    Then an existing user's lesson rows survive the migration with every column value
      unchanged, running the migration twice is a no-op, and inserting a row with
      project_id: nil succeeds afterward
    And the migration is guarded to run correctly whether the database is brand new
      (create_lessons_table creates NOT NULL first, this migration immediately widens
      it) or already has the old constraint

    Given Store#list_lessons(project_id:, trigger: nil, epic_id: nil, status: 'active')
      currently filters with unqualified column names, which would become ambiguous
      once epics is joined in (both tables have project_id and status columns)
    When list_lessons is rewritten to LEFT JOIN epics (adding epic_name to every
      returned row) and to treat project_id as "(lessons.project_id = ? OR
      lessons.project_id IS NULL)" instead of a plain equality, with all other filter
      keys qualified with the lessons. prefix
    Then every existing filter combination (trigger:, epic_id:, status:, combined)
      still works without a SQLite ambiguous-column error
    And a global lesson (project_id: nil) is returned by every project's
      list_lessons(project_id:) call, not just the project it was promoted from
    And epic_name is present for an epic-scoped lesson and nil for project-wide or
      global lessons

    Given a lesson's current scope is determined by its most-specific non-null field
      (story_id, then epic_id, then project_id)
    When Store#promote_lesson(id) is called
    Then it clears exactly that one field to NULL inside a transaction, widening the
      lesson by exactly one rung (story-scoped becomes epic-wide; epic-wide becomes
      project-wide; project-wide becomes global)
    And calling it on an already-global lesson (project_id already nil) raises a
      clear "already global" error rather than silently no-op'ing
    And it raises "Lesson not found" for an unknown id

  Scenario: lesson-promote-cli
    As an agent or Forrest triaging lessons at the CLI
    In order to widen a lesson's scope without touching SQL, and to jump straight to
      a target level for the batch-promote workflow surfaced during UI mockup review
    I want tyrion lesson promote <id> [--to <level>]

    # RIGOR: loose — CLI plumbing over an already-correct, already-tested Store
    # primitive; the --to convenience is a plain loop, no new logic to get subtly wrong.
    # BATCHING: one batch (both forms share the same cmd_lesson_promote implementation).
    Given store.promote_lesson(id) already exists and is correct (previous story)
    When `tyrion lesson promote <id>` is run with no flags
    Then it calls store.promote_lesson(id) once, rescues the RuntimeError (not-found
      or already-global) into a clean die (not a raw backtrace), and prints a
      confirmation naming the lesson's new scope (read off the returned row via the
      same 3-way scope check the verbose view uses — not a separate before/after diff)

    When `tyrion lesson promote <id> --to <epic|project|global>` is run
    Then it calls store.promote_lesson(id) repeatedly until the lesson's current
      scope matches the named target
    And it dies cleanly if the target is at or below the lesson's current scope
      (e.g. --to epic on an already-project-wide lesson) rather than doing nothing
      silently or promoting in the wrong direction

  Scenario: lesson-verbose-list
    As a human triaging which lessons deserve a wider scope
    In order to see enough per-lesson metadata to decide, without reading a sentence
      per row to figure out what's already global vs still epic-scoped
    I want tyrion lesson list --verbose

    # RIGOR: loose — pure rendering logic over data the Store layer already returns
    # (epic_name from the prior story's JOIN, source/created_at already on every row).
    # BATCHING: one batch.
    Given list_lessons already returns epic_name, source, and created_at on every row
    When `tyrion lesson list --verbose` is run (no --at, the grouped/human path only —
      the --at <trigger> JIT path stays byte-identical to today, untouched)
    Then each lesson's line shows a 3-way scope label (global when project_id is nil,
      project-wide when epic_id is nil, otherwise the epic's name), its source
      (manual/auto-extracted), and its age via the existing Output.time_ago helper —
      not a newly-written duplicate of that formatting logic
    And running `tyrion lesson list` without --verbose is byte-identical to today's
      output (verbose is strictly additive, not a default behavior change)

  Scenario: lesson-origin-tracking-and-demote
    As someone who promoted a lesson by mistake (the failure mode raised directly
      during the StreamWeaver mockup walkthrough: "since people make mistakes we
      could demote")
    In order to undo it without having permanently lost which epic/project it
      actually came from
    I want every promote to preserve the lesson's original scope, and a demote
      command that restores it in one step

    # RIGOR: strict — this is exactly where spec review caught two real bugs (a
    # missing origin_story_id column that would have silently produced wrong demote
    # results for story-scoped lessons, and a migration-ordering claim that was
    # actually a hard data-loss risk, not a stylistic preference). Both are already
    # fixed and re-verified in the design doc by tracing real scenarios — but the
    # implementation still needs failing-test-first discipline given that history.
    # BATCHING: batch A (add_lesson_origin_columns migration + create_lesson
    # capturing origin_project_id/origin_epic_id/origin_story_id automatically),
    # batch B (Store#demote_lesson's three-branch restore logic + tyrion lesson
    # demote <id> CLI).
    Given promote_lesson clears exactly one field per call and never records what it
      cleared
    When a new add_lesson_origin_columns migration adds origin_project_id,
      origin_epic_id, origin_story_id (plain nullable ADD COLUMN, no constraint
      change) — and create_lesson is updated to capture all three from whatever
      project_id:/epic_id:/story_id: it was called with, once, at creation, never
      touched again by promote_lesson
    Then this migration must run strictly after the previous story's
      make_lessons_project_id_nullable migration in the MIGRATIONS array (that
      migration's rebuild uses an explicit column list and would silently drop these
      columns if it ran second) — both migration lambdas carry an explicit warning
      comment cross-referencing each other, since MIGRATIONS has no automatic
      ordering enforcement
    And an existing user's pre-migration lesson rows come back with all three
      origin_* columns NULL, without erroring

    Given a lesson at any current scope (global, project-wide, or epic-scoped) with
      its origin_* columns intact
    When Store#demote_lesson(id) is called
    Then it restores the lesson straight back to its original creation-time scope in
      one step (not a symmetric one-rung-at-a-time undo of promote) — demoting a
      lesson that was promoted story→epic→project→global lands it back at the
      original story in a single call, not at an intermediate epic or project stop
    And demoting a lesson that was project-wide at creation (no origin epic or
      story) restores it to project-wide, not further
    And it raises "already at its original scope" both for a lesson that genuinely
      hasn't been promoted and for a pre-migration lesson with no recorded origin —
      one unified message, since both mean the same actionable thing to the caller

    Given store.demote_lesson(id) exists and is correct
    When `tyrion lesson demote <id>` is run
    Then it mirrors cmd_lesson_promote's shape: resolves the id, calls
      store.demote_lesson(id), rescues RuntimeError into a clean die, prints a
      confirmation naming the restored scope
