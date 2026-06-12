Feature: v0.2 Features
  Improvements discovered during Phase 3.5 gate validation and new capabilities needed before Phase 4 real-world use.

  Scenario: lean-resume
    # Intent: reduce the 4-command ORIENT step to a single output for fast agent resumption
    Given a tyrion ledger with an active project, epic, and at least one story
    When I run `tyrion pocket`
    Then I see the active epic slug, next_action story, and unchecked criteria — nothing else

  Scenario: gem-tests
    # Intent: gate-run found real bugs (delete_pending_criteria, --force) that tests would have caught; establish coverage before Phase 4
    Given test/test_store.rb covering delete_pending_criteria (removes only pending, preserves met), create_project, add_criteria, check_criterion, and criteria_for_story
    When ruby -Ilib test/test_store.rb is run
    Then all tests pass, 0 failures, 0 errors, 0 skips
    Given test/test_importer.rb covering basic feature import and --force reimport (proceeds even when hash matches)
    When ruby -Ilib test/test_importer.rb is run
    Then all tests pass, 0 failures, 0 errors, 0 skips; --force test confirms second import is NOT skipped

  Scenario: importer-hardening
    # Intent: gate agent wrote these fixes inline; they need tests and a clean commit
    Given store.rb has delete_pending_criteria and importer.rb has --force, both covered by test/test_store.rb and test/test_importer.rb
    When ruby -Ilib test/test_store.rb && ruby -Ilib test/test_importer.rb && ruby -Ilib test/test_pocket.rb is run
    Then 41 runs total, 0 failures, 0 errors, 0 skips
    Given all v0.2 changes are uncommitted (.gitignore, commands.rb, importer.rb, store.rb, features/, test/)
    When git commit is made with a descriptive conventional-commits message
    Then git log shows the commit, git status is clean, and the full test suite still passes

  Scenario: blocked-story-status
    As a developer whose story is stuck waiting on an external dependency
    In order to represent the real backlog state without lying about what can be started
    I want to mark a story as blocked with a reason and see it surface clearly in the war room

    Given a pending story in the active epic
    When tyrion block <slug> "waiting for stakeholder answer from Finance" is run
    Then the story status is 'blocked', blocked_on is 'waiting for stakeholder answer from Finance', and tyrion status renders a BLOCKED lane showing the slug, reason, and an unblock hint
    Given a blocked story with blocked_on set
    When tyrion unblock <slug> is run
    Then the story status returns to 'pending', blocked_on is cleared, and blocked_on_discovery is cleared
    Given a blocked story in the active epic
    When tyrion start <slug> is run
    Then the command exits 1, stderr contains the blocked reason and 'tyrion unblock <slug>'
    Given a done story in the active epic
    When tyrion block <slug> "any reason" is run
    Then the command exits 1, stderr contains a message about done stories refusing to block
    Given a blocked story linked to a disc-NNN that has transitioned to promoted_to_story
    When tyrion status is run
    Then the BLOCKED lane shows "[disc-NNN resolved → unblock?]" next to the story

  Scenario: tyrion-with-tyrion-dogfood
    # Intent: validates the full shape→import→implement loop on real work, surfaces v0.3 needs from actual use
    # TODO: criteria — fill during /tyrion-implement step 4
