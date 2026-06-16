Feature: Scott-feedback Tier 3 — followup lifecycle, reconcile, import grouping, cross-agent

# Intent: Close the lifecycle gaps Scott hit: followups that never drain, no
# reconcile flow for stale story state, verbose criteria on import. Add AGENTS.md
# so non-Claude agents (Codex, Gemini) get the canonical loop they need.
# All state changes live in Store so the web UI inherits them.
# Design guardrail: do NOT assume criteria-met => done (game dev needs a human
# playtest gate before story closure).

Scenario: followup-list-and-resolve
  As a user whose NEEDS FOLLOW-UP lane never drains
  In order to dismiss a followup that has been addressed
  I want tyrion followup list to show open followups and tyrion followup resolve to mark one done

  Given a done story has two followup notes
  When I run tyrion followup list <slug>
  Then each followup is shown with an index, body, and created_at
  And when I run tyrion followup resolve <slug> 1
  Then followup 1 has resolved_at set and no longer appears in NEEDS FOLLOW-UP
  And unresolved followup 2 still appears

Scenario: story-notes-resolved-at-migration
  As a Store consumer
  In order to record which followups have been resolved
  I want story_notes to have a nullable resolved_at column via a MIGRATIONS entry

  Given the MIGRATIONS constant does not include resolved_at on story_notes
  When setup_db runs the new migration
  Then story_notes has a resolved_at TEXT NULL column
  And the migration is idempotent (safe to run twice)
  And all future story_notes table-rebuild migrations use explicit column lists not SELECT *

Scenario: followup-query-filter-unresolved
  As a user running tyrion status
  In order to see only actionable followups in NEEDS FOLLOW-UP
  I want done_stories_with_followup_notes to filter out followups where resolved_at IS NOT NULL

  Given a done story has one resolved and one unresolved followup note
  When tyrion status renders NEEDS FOLLOW-UP
  Then only the story with the unresolved followup appears
  And the latest unresolved followup body is shown (not the latest overall)

Scenario: tyrion-reconcile-command
  As an agent whose story context, next action, and criteria are stale after a debugging session
  In order to bring the ledger back in sync with reality in one command
  I want tyrion reconcile <slug> to update context, next, notes, and optionally check criteria atomically

  Given a story with a stale next_action
  When I run tyrion reconcile <slug> --context "new context" --next "next step" --note "what changed"
  Then context, next_action, and a decision note are written in one atomic Store operation
  And if the operation fails mid-write no partial state is committed
  And the interactive form prompts for each field using the prompt helper
  And --check <n> "evidence" within reconcile is supported for marking criteria done

Scenario: gherkin-criteria-then-only-flag
  As a developer importing a feature file where Given/When steps are setup context not acceptance criteria
  In order to get a cleaner criteria list without changing the Gherkin
  I want tyrion import --criteria=then to make only Then/And-under-Then lines into checkable criteria

  Given a scenario with 2 Given, 1 When, 3 Then/And-under-Then steps
  When I run tyrion import --criteria=then features/<epic>.feature
  Then only the 3 Then/And-under-Then steps become criteria
  And the Given/When lines are stored as setup context (in intent or a context note) not clobbering an existing narrative intent
  And the default behavior (every step = criterion) is unchanged when the flag is absent

Scenario: agents-md
  As a non-Claude agent (Codex, Gemini) reading project docs
  In order to use tyrion correctly without access to the Claude Code skill layer
  I want AGENTS.md to contain the canonical tyrion loop, sequencing rules, and feature-identity facts

  Given no AGENTS.md exists at the repo root
  When the file is created
  Then it contains the canonical status-resume-note-check-done loop
  And it states that activation commands are sequencing boundaries (never parallelize with reads)
  And it states that mutating tyrion commands must be serialized (never parallel)
  And it states epic identity = filename not Feature title
  And it lists all valid note kinds including observation
  And it links to the skills directory for Claude Code users
  And it is operational not aspirational (no aspirational vague guidance)
