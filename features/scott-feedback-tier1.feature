Feature: Scott-feedback Tier 1 — bugs and self-guiding CLI

# Intent: Fix confirmed bugs (WAL lock, import sequence collision, non-atomic
# import) and make every CLI error hand the operator the next correct command
# pre-filled. Highest-leverage pass; foundation for the dogfood loop.

Scenario: fix-wal-busy-timeout-order
  As a CLI user or agent running concurrent tyrion commands
  In order to not hit SQLite BusyException on the PRAGMA journal_mode=WAL line
  I want busy_timeout set before journal_mode=WAL in with_db, WAL set once at init, and a central with_retry wrapper on all write paths

  Given the store.rb with_db method sets journal_mode=WAL before busy_timeout=5000
  When multiple processes (web UI + CLI agents) write to the DB concurrently
  Then no BusyException propagates to the CLI from the WAL pragma
  And write operations retry transparently up to 5 times with backoff before failing

Scenario: fix-atomic-import
  As an agent running tyrion import
  In order to never leave a partially-updated epic in the DB on failure
  I want one epic import to be wrapped in a single transaction(:immediate) at the Store layer

  Given a feature file with multiple scenarios
  When tyrion import is interrupted after upsert_epic but before all stories are written
  Then the DB state is unchanged (full rollback, no partial epic)
  And re-running import succeeds cleanly

Scenario: fix-import-sequence-collision
  As a developer adding a scenario to an existing feature file
  In order to import the updated file without a UNIQUE constraint failure
  I want new stories to get sequence MAX+1 and the create wrapped in a transaction

  Given a feature file with 5 imported scenarios
  When a new scenario is appended and the file is re-imported
  Then the new story gets sequence 6 (MAX+1) with no ConstraintException
  And existing story sequences are unchanged
  And sequence assignment is inside a transaction(:immediate) to prevent concurrent-import races
  And the policy is documented: sequence = stable ledger order append-only

Scenario: self-guiding-check-error
  As an agent calling tyrion check with only a slug
  In order to know the exact command without a follow-up tyrion show call
  I want the error to print the criteria list and the exact tyrion check form

  Given a story with 3 criteria
  When I run tyrion check <slug> with no position argument
  Then the error shows all criteria numbered with their text
  And the error shows the exact usage: tyrion check <slug> <n> "evidence"
  And --all "evidence" checks all unmet criteria with one call

Scenario: self-guiding-done-error
  As an agent calling tyrion done <slug> with no summary
  In order to know what to provide without re-reading the story
  I want the error to show met criteria and a summary-shaped prompt

  Given a story with all criteria met
  When I run tyrion done <slug> with no summary argument
  Then the error prints the list of met criteria
  And the error shows: tyrion done <slug> "..." with the exact slug pre-filled
  And --from-checks synthesizes a summary from criterion evidence

Scenario: resume-empty-state
  As an agent or developer who has imported and activated an epic but not started a story
  In order to know what to do next without re-reading the docs
  I want tyrion resume to show the pending queue instead of a bare error

  Given an epic is active with 3 pending stories and no in-progress story
  When I run tyrion resume with no arguments
  Then output lists the next pending stories by slug
  And output shows: tyrion start <first-pending-slug>
  And no bare "Error: No in_progress story" with no further guidance

Scenario: epic-list-labels
  As a user running tyrion epic list
  In order to tell which epic is currently active vs merely open
  I want only the current epic to show the active marker and others to show a bracket only for non-default statuses

  Given 5 epics all with default status active
  When I run tyrion epic list
  Then only the current active-pointer epic shows the cyan arrow marker
  And the other 4 epics show no bracket for the default active status
  And an epic with status paused shows [paused]

Scenario: stdout-sync
  As an agent or user whose tyrion output is piped or slow-repo
  In order to see streaming output and not a command that looks hung
  I want $stdout.sync = true set at the top of bin/tyrion

  Given bin/tyrion does not set $stdout.sync
  When output is piped to another process
  Then each puts line appears immediately without buffering
  And resume and status output stream continuously even before git shell-outs complete

Scenario: add-observation-note-kind
  As an agent or user wanting to record a tool quirk or non-blocking finding
  In order to use the right note kind without misusing decision or progress
  I want observation as a valid note kind in CLI and DB

  Given VALID_NOTE_KINDS does not include observation
  When I run tyrion note <slug> observation "some finding"
  Then the note is accepted and stored
  And tyrion show displays it with kind observation
  And the DB CHECK constraint accepts observation via a migration
  And the help text lists observation
