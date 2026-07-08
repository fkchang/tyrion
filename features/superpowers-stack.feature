Feature: Superpowers Stack Integration — Gates, Vetting & Dark Factory
  Adopt the good parts of obra/superpowers (coherent pipeline, self-sufficient
  subagent execution, diff-based review) without duplicating them: superpowers
  provides brainstorm/plan/TDD/review skills, Tyrion provides the durable ledger,
  resumability, and gate traceability. Design: docs/superpowers-stack-design.md

  Scenario: gate-ledger
    As an agent (or Forrest doing a postmortem) looking at a story after the session is gone
    In order to know whether pre-push failed, how code review went, and what quality gates ran
    I want every gate run recorded in the ledger as an append-only history

    # RIGOR: strict — schema migration + new CLI command, core ledger integrity
    Given the story_notes kind CHECK does not currently allow gate or commit kinds
    When the schema migration runs on an existing database
    Then PRAGMA table_info shows story_notes accepts kinds gate and commit and the migration is idempotent on re-run
    When I run tyrion gate <slug> pre-push fail --detail "2 rspec failures in store_spec"
    Then a story_notes row with kind gate and body "pre-push: FAIL — 2 rspec failures in store_spec" exists for the story
    When I run tyrion gate <slug> pre-push pass --detail "all steps green"
    Then tyrion show <slug> renders a GATES section showing pre-push ✓ with 2 runs recorded
    And tyrion resume <slug> includes the same GATES section
    When I run tyrion gate <slug> nonexistent-story pass
    Then it exits 1 with a not-found error via die

  Scenario: commit-capture
    As Forrest tracing what a story actually shipped
    In order to see the commits belonging to a story — including the honest case where there are none
    I want commit SHAs captured against the story at close time

    # RIGOR: strict — git interrogation + auto-hook into tyrion done
    Given a story started at a known timestamp with two commits made on the current branch after it
    When I run tyrion commits <slug>
    Then a story_notes row with kind commit records both SHAs with their one-line subjects
    Given a story with no commits since it started
    When I run tyrion commits <slug>
    Then a story_notes row with kind commit records "no commits — no changes required"
    When tyrion done <slug> runs with all criteria met
    Then the commit capture runs automatically before the story closes
    And tyrion show <slug> renders the commit record in the GATES section

  Scenario: prepush-gate-wiring
    As an implementing agent at the Step 8 quality gate
    In order to leave a durable record of every pre-push run instead of losing it to /clear
    I want the tyrion-implement skill to record a pre-push gate on every run, pass or fail

    # RIGOR: trivial — skill text edit only, no lib code
    Given /tyrion-implement Step 8 runs /pre-push in build or strict mode
    When /pre-push reports blocking issues
    Then the skill records tyrion gate <slug> pre-push fail --detail "<failing step names>" before fixing anything
    When /pre-push passes
    Then the skill records tyrion gate <slug> pre-push pass
    And the skill text shows the gate commands verbatim in Step 8

  Scenario: codex-vet-flag
    As Forrest who routinely has Codex vet plans, code, and assessments
    In order to make that vetting a one-word decision with a recorded verdict instead of a manual ritual
    I want a --vet flag that runs the design-review skill and records the verdict as a gate

    # RIGOR: loose — skill wiring around the existing /design-review skill
    Given /tyrion-implement <slug> --vet reaches the end of Step 4 PLAN
    When the plan note is written
    Then the skill invokes /design-review on the plan and records tyrion gate <slug> codex-vet pass for SHIP IT
    And records tyrion gate <slug> codex-vet fail --detail "<verdict>: <top concerns>" for SIMPLIFY or RETHINK
    And on fail the skill revises the plan and re-vets before Step 5 IMPLEMENT
    Given a story whose [plan] note contains RIGOR: strict+vet
    When /tyrion-implement runs without flags
    Then vet mode activates automatically from the RIGOR tag
    And /tyrion-plan documents the same --vet flag for plan-time vetting

  Scenario: superpowers-review-gate
    As Forrest wanting to start using superpowers code review with a paper trail
    In order to know how the code review went for any story after the fact
    I want an opt-in two-stage review at Step 8 whose verdicts land in the ledger

    # RIGOR: loose — skill wiring, dispatches existing superpowers:code-reviewer agent
    Given /tyrion-implement <slug> --review-stack=superpowers completes implementation
    When Step 8 runs
    Then a spec-compliance reviewer subagent checks the diff against the story criteria and evidence
    And its verdict is recorded as tyrion gate <slug> spec-review pass|fail with file:line issues in --detail
    And the superpowers:code-reviewer agent reviews BASE_SHA to HEAD_SHA from the commit capture
    And its verdict is recorded as tyrion gate <slug> code-review pass|fail with Critical/Important/Minor counts in metadata JSON
    And Critical or Important issues mean gate fail and the fix→re-review loop repeats until pass

  Scenario: superpowers-pipeline-handoff
    As a session starting new work from a rough idea
    In order to go brainstorm → spec → plan → tracked implementation without duplicating any wheel
    I want tyrion-shape to ingest superpowers plan documents natively

    # RIGOR: loose — shape skill extension + docs
    Given a superpowers plan at docs/superpowers/plans/<date>-<feature>.md with checkbox Task sections
    When I run /tyrion-shape --from that plan
    Then each Task section becomes a story with its steps as criteria and the epic context_md gains a "Plan file:" line pointing at the plan
    And a sibling spec doc in docs/superpowers/specs/ is ingested into the epic context_md
    Given /tyrion-implement runs in strict mode
    When it dispatches an implementer subagent
    Then the subagent prompt invokes superpowers:test-driven-development instead of restating TDD rules inline
    And the README documents the recommended flow: superpowers:brainstorming → superpowers:writing-plans → /tyrion-shape → /tyrion-implement

  Scenario: dark-factory-mode
    As Forrest running stories he is not going to babysit
    In order to have "done is the bar" execution that is safe for subagents and still leaves a full evidence trail
    I want the documented --dark-factory mode (--adequate, --mediocre aliases) actually implemented

    # RIGOR: loose — skill protocol changes, the README contract already exists
    Given /tyrion-implement <slug> --dark-factory
    When the protocol runs
    Then the mode announcement prints a dark-factory banner and no step ever prompts the user
    And at Step 9 the agent executes the UAT runbook itself via CLI checks and playwright-cli where browser checks apply
    And the UAT results are recorded as tyrion gate <slug> uat pass|fail --detail "<per-check ✅/❌ results>"
    And after done the next pending story is pre-claimed automatically without asking
    Given a vague criterion is found at Step 4
    When dark-factory mode is active
    Then the story is blocked via tyrion block with the proposed sharp rewrites in the reason instead of waiting on a question
    And --adequate and --mediocre resolve to identical behavior
    And quality gates still run per the underlying TDD mode — dark factory changes who reviews, not whether

  Scenario: dogfood-dark-factory-orchestrate
    As Forrest deciding whether to trust mediocre mode
    In order to see how well subagents actually run in dark-factory mode
    I want this epic's tail run through tyrion-orchestrate with dark-factory subagents and a gate-based scorecard

    # RIGOR: loose — meta-story, runs the machinery built above on real stories
    Given at least two pending stories in this epic after dark-factory-mode is done
    When /tyrion-orchestrate dispatches them with /tyrion-implement <slug> --dark-factory
    Then each story closes with pre-push, uat gates and commit records visible in tyrion show
    And a decision note on this story summarizes the scorecard: gates passed/failed per story, interventions needed, verdict on dark-factory readiness
    And any generalizable failure is recorded via tyrion lesson add with an appropriate trigger

  Scenario: setup-codex-command
    As a new Codex user adopting Tyrion
    In order to use the tyrion skills directly in Codex without knowing any setup lore
    I want a single tyrion setup-codex command that installs native skill discovery

    Given tyrion is installed as a gem or run from a repo checkout
    When I run tyrion setup-codex
    Then ~/.agents/skills/tyrion is a symlink pointing at tyrion's skills directory
    And the command prints the discovered skill names and restart-Codex guidance
    And re-running the command is idempotent and refreshes a stale symlink without error
    When ~/.agents/skills/tyrion already exists as a real directory rather than a symlink
    Then the command exits 1 via die telling the user to move it aside
