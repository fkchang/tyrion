Feature: Lessons — Just-In-Time Mistake Prevention
  # Intent: "Never make that mistake again" — but as a trigger-bound interrupt fired
  # fresh into agent context at the workflow moment a mistake happens, not as a stored
  # fact an agent must remember to consult. Mined from 36 real Tyrion session transcripts.
  # Triumvirate laws applied: Gloria's Law (pushed at the trigger, not pulled from
  # memory — a lesson read once at session start is physiologically bypassed by the
  # decision point 8 steps later); Matt's Law (agent finds the right lesson without
  # searching); Forrest's Law (fires automatically, zero friction, ships seeded with
  # real proven value).
  # Design doc: ~/.claude/plans/read-users-fkchang-cultiv-os-research-re-gleaming-thompson.md
  # Motivated by: ~/cultiv-os/research/results/2026-06-30-001-.../research.md
  # (the "harness engineering" 5-layer article's Verification-Layer thesis) plus a
  # parallel mining pass over Tyrion's own session history.

  Background:
    Given the Tyrion project at ~/work/tyrion with the discoveries table/pattern as precedent
    And the idempotent MIGRATIONS constant in lib/tyrion/store.rb (PRAGMA-guarded ALTER / CREATE TABLE IF NOT EXISTS)
    And the disc-NNN global-counter-inside-transaction ID pattern (store.rb ~line 630-650)
    And the drift-warning auto-inject pattern (drift_changed_path + print_drift_warning, surfaced in cmd_status and cmd_resume) as the surfacing template to copy
    And mined evidence that the #1 recurring mistake (UAT≠specs) was already documented in
      auto-memory AND CLAUDE.md yet recurred anyway ("the 2nd time") — proving the gap is
      delivery timing, not capture

  # ── PHASE A: storage + the load-bearing surfacing half (the bet) ───────────────

  Scenario: lessons-schema-and-store
    As an implementing agent building this feature
    In order to persist lessons durably and query them cheaply by trigger/scope
    I want a lessons table and Store API mirroring the discoveries pattern

    # RIGOR: loose — mirrors the existing discoveries table/counter pattern closely;
    # standard Store method conventions (plain Hash returns, with_db, transaction(:immediate)).
    Given the MIGRATIONS idempotent-add pattern in lib/tyrion/store.rb
    When the lessons migration runs via setup_db (CREATE TABLE IF NOT EXISTS lessons)
    Then a lessons table exists with columns id, project_id, epic_id, story_id, trigger,
      text, source, status, created_at, updated_at
    And re-running setup_db against an already-migrated DB is a no-op

    Given a project_id and a trigger tag
    When store.create_lesson(project_id:, trigger:, text:, epic_id: nil, story_id: nil, source: 'manual') is called
    Then it runs inside db.transaction(:immediate) and assigns a globally-unique id
      formatted "lesson-NNN" via SUBSTR(id, 8) following the disc-NNN counter pattern
    And the row defaults status to 'active'

    Given lessons with varying triggers, scopes, and statuses already exist
    When store.list_lessons(project_id:, trigger: nil, epic_id: nil, status: 'active') is called
    Then only active lessons scoped to that project are returned, optionally filtered by trigger and epic_id

    Given an existing lesson id
    When store.retire_lesson(id) is called
    Then its status flips to 'retired' and it is excluded from default list_lessons results

  Scenario: lessons-cli-command
    As an agent or Forrest at the CLI
    In order to record and inspect lessons without touching SQL directly
    I want a tyrion lesson command family mirroring cmd_discovery's sub-dispatch

    # RIGOR: loose — standard cmd_* dispatch + usage-block plumbing, same shape as
    # existing cmd_discovery/cmd_spike sub-commands.
    Given the active project (and active epic, if any)
    When `tyrion lesson add --at <trigger> "text"` is run
    Then a new active lesson is created scoped to the active project, and to the active
      epic unless a future --project-wide flag is passed

    When `tyrion lessons` or `tyrion lesson list` is run with no flags
    Then all active lessons for the project are listed, grouped or labeled by trigger

    When `tyrion lessons --at <trigger>` is run
    Then only active lessons matching that trigger print, one per line
    And it prints nothing at all when no lessons match that trigger (silent on none)

    When `tyrion lesson retire <lesson-NNN>` is run
    Then that lesson's status flips to retired and a confirmation line prints

    Then `tyrion help` lists the lesson/lessons subcommands in the usage block

  Scenario: lessons-status-resume-surfacing
    As an implementing agent running tyrion status or tyrion resume
    In order to see relevant lessons without having to remember to ask for them
    I want lessons auto-injected as a lane/section, silent when none apply

    # RIGOR: loose — output assembly mirrors the existing DISCOVERIES lane in cmd_status
    # and the drift-warning auto-inject in cmd_resume; no new architecture.
    Given the existing DISCOVERIES lane in cmd_status (commands.rb ~480-494) and the
      drift-warning auto-inject in cmd_resume (~988-991) as the template
    When `tyrion status` runs and active lessons exist for the project or active epic
    Then a LESSONS lane prints them, styled consistently with the DISCOVERIES lane

    When no active lessons apply to the current project/epic
    Then no LESSONS lane prints at all (silent on none — matches the drift-warning pattern of staying quiet when there's nothing to say)

    When `tyrion resume <slug>` runs
    Then any active project-wide, epic-scoped, or story-scoped lessons print as a section
      in the resume output, in the same place the drift warning appears

  Scenario: lessons-seed-data
    As Tyrion shipping this feature
    In order to deliver proven value on day one instead of an empty table
    I want the five mined lessons seeded for the tyrion project

    # RIGOR: trivial — five `tyrion lesson add` invocations with exact text given below;
    # no code logic, pure data entry via the CLI built in lessons-cli-command.
    Given the five lessons mined from real Tyrion session history (see context doc for exact text):
      | trigger          | text                                                                                          |
      | uat               | Don't re-offer the rspec suite as UAT when /pre-push already ran it — use CLI/browser checks |
      | pre-push-pass     | Once /pre-push passes, proceed immediately to the next step — don't stop and wait for confirmation |
      | import-existing   | When importing into an existing epic, execute the runbook exactly as written — never silently deviate |
      | start             | Don't run activation and read commands in parallel against the same lane — sequence them |
      | import-existing   | Test import-mutating behavior (e.g. --force on a done story) on a disposable fixture, not the live epic |
    When the tyrion project is set up with this feature
    Then `tyrion lessons` lists all five as active and project-wide (epic_id nil)

  Scenario: lessons-skill-wiring-implement
    As an agent following /tyrion-implement
    In order to receive the right lesson at the moment I'm about to make the mistake
    I want the skill to call tyrion lessons --at <trigger> at the named steps where mistakes happened

    # RIGOR: trivial — mechanical insertion of `tyrion lessons --at <trigger>` calls at
    # three exact, already-identified step locations in the skill markdown; no new logic.
    Given Step 1 ORIENT / Step 3 RESUME-STATE in skills/tyrion-implement/SKILL.md
    When the skill executes either step
    Then it also runs `tyrion lessons --at start` and surfaces any printed lines as part of orientation

    Given Step 7.5 UAT RUNBOOK in skills/tyrion-implement/SKILL.md
    When the skill reaches that step
    Then it runs `tyrion lessons --at uat` before assembling the UAT plan and follows any
      lesson returned (e.g. does not re-offer rspec as UAT)

    Given the Step 8 → Step 9 boundary (immediately after /pre-push passes)
    When pre-push succeeds
    Then the skill runs `tyrion lessons --at pre-push-pass` and follows any "don't stop, proceed
      immediately" lesson rather than pausing for confirmation

  # ── PHASE B: close the capture loop (manual + failure-prompted) ────────────────

  Scenario: lessons-failure-capture-wiring
    As an agent that just got blocked or failed review
    In order to make my mistake un-repeatable for future agents
    I want failure points to prompt me to record a lesson, and the false engineering-review
    auto-invocation claim resolved

    # RIGOR: loose — skill markdown edits plus one judgment call (whether to wire
    # engineering-review invocation or correct its docs) that needs a recorded decision.
    Given Step 6 ON BLOCKER and Step 8 REVIEW in skills/tyrion-implement/SKILL.md, and the
      engineering-review skill's NEEDS_REVISION verdict branch
    When a blocker is recorded via `tyrion note blocker` or a review returns NEEDS_REVISION
    Then the skill instructs the agent to consider `tyrion lesson add --at <trigger>` for
      generalizable mistakes (not one-off bugs) before moving on

    Given that skills/tyrion-implement/SKILL.md Step 8 today only runs /pre-push and never
      actually invokes /engineering-review, despite engineering-review's own SKILL.md
      claiming it runs "automatically... Step 8, rigor Level 3+"
    When this story is implemented
    Then this gap is resolved one of two ways, with the choice recorded in a story note:
      either Step 8 explicitly invokes /engineering-review for rigor 3+ stories, or
      engineering-review's SKILL.md is corrected to stop claiming auto-invocation

  # ── PHASE C: automate capture (history-miner) ───────────────────────────────────

  Scenario: lessons-mine-command
    As Forrest wanting lessons captured without manually re-deriving them every time
    In order to automate what was done by hand to seed this very epic
    I want tyrion lesson mine to scan session history and propose lessons for approval

    # RIGOR: strict — novel parsing/clustering logic over JSONL transcripts; could
    # produce plausible-looking but wrong proposals if the signal heuristics are off,
    # so correctness needs a test-first approach against the known corpus.
    Given Tyrion session JSONL logs under ~/.claude/projects/<project-dir>/
    When `tyrion lesson mine` runs
    Then it scans recent sessions for correction signals (no/don't/again/2nd time/you keep,
      and assistant "you're right"/"I should have"), reusing the signal set described in
      the extract-skill-candidates skill

    Given candidate correction clusters found by the scan
    When they are presented to the user
    Then each shows a suggested --at trigger derived from a keyword map
      (uat→uat, pre-push/stop→pre-push-pass, import→import-existing, else→start)

    Given a user approves a proposed lesson
    When the approval is given
    Then the command calls `tyrion lesson add` to persist it
    And it never auto-writes a lesson without explicit approval

    Given the 36-session corpus already mined by hand for this epic
    When `tyrion lesson mine` is run against that same corpus
    Then it re-surfaces the known themes (UAT≠specs, stop-early, runbook-deviation) as a
      built-in regression check for the miner's own correctness
