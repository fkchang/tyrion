Feature: Scott-feedback Tier 2 — drift detection and full note access

# Intent: Surface when a feature file has changed since import so agents and
# developers don't accidentally work from stale criteria. Also make full note
# bodies accessible (currently truncated at every surface), preserving the
# BMAD-style total transparency the notes exist for.

Scenario: tyrion-drift-command
  As a developer who has edited a feature file after importing
  In order to know which epics need re-import before criteria are trustworthy
  I want tyrion drift to compare stored feature_source_hash values against current file SHAs

  Given an epic with a stored feature_source_hash
  When the feature file has changed since import
  Then tyrion drift reports: feature file changed — run tyrion import features/<slug>.feature
  And when the file is unchanged tyrion drift reports: up to date
  And when the file is missing tyrion drift reports: feature file missing

Scenario: drift-warning-in-resume-and-status
  As an agent resuming work on a story
  In order to notice stale criteria without running tyrion drift first
  I want a one-line warning in tyrion resume and tyrion status when the active epic has drifted

  Given the active epic feature file has changed since import
  When I run tyrion resume or tyrion status
  Then a warning line appears: feature file changed since import — criteria may be stale
  And the warning includes the exact re-import command

Scenario: tyrion-notes-command
  As an agent or developer wanting to read the full body of all notes on a story
  In order to benefit from BMAD-style total transparency without being cut off at 70 chars
  I want tyrion notes <slug> to print every note with full untruncated body

  Given a story with a decision note whose body exceeds 120 characters
  When I run tyrion notes <slug>
  Then all notes are printed with kind, timestamp, and full untruncated body
  And --kind <k> filters to only that kind
  And tyrion show and tyrion resume keep their existing summary truncation

Scenario: web-note-expand
  As a web UI user reading a decision or test note that trails off with ellipsis
  In order to read the full note without switching to the CLI
  I want to click a note card to toggle the 4-line CSS clamp off

  Given a note card rendered with -webkit-line-clamp: 4 in shared.css
  When I click the note card
  Then the card expands to show the full body
  And clicking again collapses it
  And no server round-trip is needed (the full body is already in the DOM)
