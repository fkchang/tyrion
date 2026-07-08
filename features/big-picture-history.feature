Feature: Big-Picture History & Autonomous Orchestration
  # Intent: Make the project north star and "what's still left" impossible to lose
  # across pivots, /clear, and session resets — for both human and agent.
  # Triumvirate laws applied: Gloria's Law (deliver it, don't store it);
  # Matt's Law (north-star → epic → open-threads → story, progressive disclosure);
  # Forrest's Law (zero extra commands, surface by default).
  # Design doc: docs/big-picture-history-design.md
  # Motivated by the doc-parity arc: visual-plan-components shipped autonomously
  # → review found gaps → doc-parity spawned → mid-session pivot to designing Tyrion.

  Background:
    Given the Tyrion project at ~/work/tyrion with existing lane/wave/parallel-execution infrastructure
    And the schema already has projects.about_md, epics.context_md, epics.context_source_hash
    And upsert_epic already accepts context_md: keyword arg (store.rb)
    And the importer at lib/tyrion/importer.rb never reads <epic>.context.md (the linchpin bug)

  # ── PILLAR 1: Big picture that can't be lost ────────────────────────────────

  Scenario: context-md-import
    # Intent: Fix the documented-but-unimplemented .context.md → epics.context_md load.
    # ~10 lines in importer.rb. This unblocks all downstream orientation improvements.
    # RIGOR: trivial — read sibling file, hash it, pass to existing upsert_epic kwarg.
    Given features/doc-parity.context.md exists alongside features/doc-parity.feature
    And tyrion import features/doc-parity.feature currently ignores the .context.md sibling
    When the importer checks for a sibling <epic-slug>.context.md after reading the .feature file
    And reads the content + SHA256-hashes it
    And passes context_md: and context_source_hash: to upsert_epic
    Then tyrion epic show doc-parity displays the Context: section from doc-parity.context.md
    And re-importing with unchanged .context.md is idempotent (context_source_hash match = no-op)
    And importing with no .context.md file is a no-op (context_md remains nil)

  Scenario: orient-surfaces-big-picture
    # Intent: Add a project north-star + open-threads header to tyrion resume / tyrion brief.
    # Progressive disclosure: north-star → epic intent → open threads → story state.
    # RIGOR: medium — new output assembly in cmd_resume or new cmd_brief in commands.rb.
    # Depends on: context-md-import (so epic context_md is actually populated)
    Given tyrion resume shows story-level breadcrumbs only (zero project/epic context)
    And the orient skill claims "that is the full agent context" after resume
    When tyrion resume (or a new tyrion brief) is run
    Then it prints a compact header: project name + first line of about_md (the north star)
    And it prints the active epic name + one-line intent + done/total count
    And it prints an "open threads" lane: each non-done epic in the project with pending-story count
    And it prints the existing story-level output (current_context, next_action, criteria, notes)
    And the entire header is ≤ 10 lines by default
    And tyrion status gains the north-star line as a single leading line above the epic block

  Scenario: orient-skill-update
    # Intent: Fix tyrion-orient SKILL.md so it reflects the new big-picture output.
    # RIGOR: trivial — prose edit to the skill file.
    # Depends on: orient-surfaces-big-picture
    Given tyrion-orient/SKILL.md says "That is the full agent context for the in-progress story"
    When the skill is updated to reflect that tyrion resume now includes project + epic context
    Then the Output section describes: north-star header, epic intent, open threads, story state
    And the Next steps section is accurate (no instructions that assume context was missing)

  Scenario: about-md-timeline-convention
    # Intent: Document the ABOUT.md ## Timeline section convention so humans and agents
    # can record the epic→review→spawn arc in prose. Convention first; CLI helper later.
    # RIGOR: trivial — update tyrion-implement SKILL.md + tyrion-checkpoint SKILL.md.
    # Independent of context-md-import (convention-only, no schema change).
    Given project ABOUT.md has no convention for recording the arc across epics
    When an agent closes an epic or spawns a corrective epic
    Then the tyrion-implement and tyrion-checkpoint skills document a ## Timeline section format
    And the format is: "- YYYY-MM-DD | <epic-slug> shipped (N/N) | review: <finding> | spawned: <slug>"
    And the stream-weaver project ABOUT.md is seeded with the visual-plan-components → doc-parity arc
    And the StreamWeaver north star is captured in stream-weaver's ABOUT.md

  Scenario: migrate-handoff-doc
    # Intent: Once big-picture-history ships, pull the sw-doc-parity-checkpoint.md
    # handoff doc into Tyrion proper (stream-weaver ABOUT.md + doc-parity context_md).
    # Currently the checkpoint doc lives in the repo as a gitignored personal-content file.
    # RIGOR: trivial content migration — after P1.1 and P1.4 land.
    # Depends on: context-md-import, about-md-timeline-convention
    Given docs/sw-doc-parity-checkpoint.md contains the big-picture narrative for the doc-parity arc
    And it is gitignored because it contains personal content (to be sanitized later)
    When the relevant non-personal sections are migrated into stream-weaver ABOUT.md Timeline
    And the locked decisions + root causes are copied into features/doc-parity.context.md
    Then tyrion project show stream-weaver surfaces the StreamWeaver north star
    And tyrion epic show doc-parity shows the design decisions and root causes
    And the checkpoint doc can be removed from the repo (its content now lives in Tyrion)

  # ── PILLAR 2: Autonomous in-session orchestration (designed, build later) ──

  Scenario: tyrion-assign-command
    # Intent: Add the missing dispatch-side writer for the "assigned:<lane>" pre-claim path.
    # The adopt side (resolve_my_story rung 3) already exists; only the write side is missing.
    # RIGOR: trivial — one new cmd_assign clause in commands.rb + one store write.
    # Independent of Pillar 1 (different subsystem).
    Given stories.claimed_by can hold "assigned:<lane>" to pre-assign a story
    And resolve_my_story rung 3 already adopts a story where claimed_by == "assigned:<TYRION_LANE>"
    And no tyrion assign command exists to write that placeholder
    When tyrion assign <slug> <lane> is run
    Then it sets stories.claimed_by = "assigned:<lane>" on the named pending story
    And the story status remains pending (not in_progress)
    And when the target agent runs tyrion start <slug>, rung 3 adopts and re-stamps to its real lane

  Scenario: tyrion-wave-next-command
    # Intent: Return the next wave of ready stories as a dispatch list (machine-readable).
    # Reads Store#wave_plan; emits the first wave with all-pending, dependency-satisfied stories.
    # RIGOR: medium — new cmd_wave_next in commands.rb reading existing wave_plan output.
    # Depends on: wave-derivation (done in parallel-execution epic)
    Given Store#wave_plan correctly computes topological waves from stories.depends_on
    And no command exposes "which stories are ready right now" as a machine-readable list
    When tyrion wave next is run
    Then it outputs newline-delimited slugs of the first fully-pending wave
    And tyrion wave next --with-pocket appends each story's tyrion pocket briefing below its slug
    And if no stories are pending the command exits cleanly with "(no pending stories)"

  Scenario: tyrion-orchestrate-skill
    # Intent: In-session orchestrator that fans out one subagent per story, main thread lean.
    # The main session reads wave_plan, dispatches subagents, collects summaries, advances waves.
    # Designed here; build is a separate session.
    # RIGOR: medium — new SKILL.md; relies on tyrion-assign, tyrion-wave-next, lane infrastructure.
    # Depends on: tyrion-assign-command, tyrion-wave-next-command
    Given tyrion-assign, tyrion wave next, and the lane/pre-claim infrastructure exist
    When the tyrion-orchestrate skill is invoked in a session with doc-parity active
    Then it runs tyrion wave next to get the ready story slugs
    And dispatches one Agent subagent per slug, each receiving the tyrion pocket briefing
    And each subagent runs: tyrion start <slug> → implement loop → tyrion done <slug> "summary"
    And the main session only sees short summaries (no large file contents flow through)
    And after all subagents complete it checks tyrion status and advances to the next wave
    And it repeats until no pending stories remain or a story is blocked
