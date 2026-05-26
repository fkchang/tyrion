Feature: Discovery Layer
  Add a discovery/spike layer above the existing epic/story structure.
  Answers "What did I learn, and what should I build from it?" — filling
  the gap where the current impl layer assumes you already know what to
  build. Maps to SDRD's spike → finding → implement loop. Two entry
  modes: intentional spike (known unknown) and organic capture (unknown
  unknown). Both converge at findings_ready, then promote to linked stories.

  Scenario: discoveries-schema
    # Intent: Create the discoveries table in SQLite with full state machine support (mark|capturing|active_spike|findings_ready|promoted_to_story|deferred|invalidated) and all required columns
    Given a fresh Tyrion::Store.new(db_path: tmp_path)
    When create_discovery(project_id: id, status: 'mark', question: 'test q') is called
    Then returns hash with non-nil disc-NNN id, status == 'mark', created_at and updated_at present
    Given a discovery created with all optional fields (hypothesis, exit_criteria, finding, confidence, recommendation, git_context, epic_id)
    When store.find_discovery(id) is called
    Then returned hash contains all 14 columns with values matching what was written
    Given discoveries in states mark, active_spike, and findings_ready exist in the store
    When store.list_discoveries(project_id:, status: 'active_spike') is called
    Then only the active_spike discovery is returned; unfiltered list_discoveries returns all 3
    Given test/test_store.rb extended with discovery CRUD tests covering create, find, and list_discoveries
    When ruby -Ilib test/test_store.rb is run
    Then 0 failures, 0 errors; test count visibly higher than the previous 24 runs

  Scenario: tyrion-mark
    # Intent: Zero-friction 5-second in-flow bookmark — auto-captures git context and timestamp, creates a [mark] breadcrumb in discoveries table, no interaction beyond the description
    Given the tyrion ledger has an active project
    When tyrion mark "brief description" is run
    Then the command prints a single line [mark] disc-NNN to stdout and exits 0, and store.find_discovery(id) returns status='mark', question='brief description', git_context containing branch, dirty_files (integer), last_commit (SHA)
    Given no active project is set in the tyrion ledger
    When tyrion mark "anything" is run
    Then the command prints an error message to stdout and exits without creating any discovery row

  Scenario: tyrion-discover
    # Intent: ~30-second organic capture prompting "What were you trying to do?" + "What did you find?"; auto-captures git context and recently-touched files; creates discovery in findings_ready immediately; asks "Spec this out now?"
    Given the tyrion ledger has an active project
    When tyrion discover is run with stdin providing "testing authentication flow" then "JWT expiry not refreshed on activity"
    Then a discovery is created with status='findings_ready', question='testing authentication flow', finding='JWT expiry not refreshed on activity', git_context containing branch, dirty_files (integer), last_commit (SHA), and touched_files (array of recently-touched file paths), and stdout contains [findings_ready] disc-NNN
    Given tyrion discover created a discovery and prompted "Spec this out now? [y/later/no]"
    When the user responds y
    Then stdout includes "tyrion spike promote disc-NNN" as the next-step suggestion
    Given tyrion discover created a discovery and prompted "Spec this out now? [y/later/no]"
    When the user responds later or no
    Then the command exits after printing [findings_ready] disc-NNN with no promote suggestion in stdout

  Scenario: tyrion-spike-start
    # Intent: Frame a known unknown with question, optional hypothesis, and exit criteria ("what does success produce?"); creates discovery in active_spike; enforces one active spike per project
    Given the tyrion ledger has an active project with no existing active_spike discovery
    When tyrion spike start "Can concurrent writes cause scan duplication?" is run with stdin providing hypothesis and exit_criteria
    Then a discovery is created with status='active_spike', question matching the argument, hypothesis and exit_criteria matching stdin inputs, git_context captured, and stdout prints [active_spike] disc-NNN
    Given a discovery with status='active_spike' already exists for the active project
    When tyrion spike start "another question" is run
    Then the command exits with an error message containing both the existing spike's disc-NNN id and its question text, and no new discovery row is created
    Given the tyrion ledger has an active project with no existing active_spike discovery
    When tyrion spike start "question" is run and the user presses Enter on both hypothesis and exit_criteria prompts
    Then a discovery is created with status='active_spike', question='question', hypothesis=nil, exit_criteria=nil, and stdout prints [active_spike] disc-NNN

  Scenario: tyrion-spike-done
    # Intent: Close the active spike by capturing key finding (one paragraph max), confidence (high|medium|low), and recommendation; transitions discovery from active_spike to findings_ready
    Given an active_spike discovery exists for the active project
    When tyrion spike done is run with stdin providing finding text, 'high' for confidence, and recommendation text
    Then the discovery status is updated to 'findings_ready', finding/confidence/recommendation fields match inputs, and stdout prints [findings_ready] disc-NNN
    Given no active_spike discovery exists for the active project
    When tyrion spike done is run
    Then the command exits with an error message indicating no active spike and no discovery row is modified
    Given an active_spike exists and the user enters an invalid confidence value on first prompt
    When tyrion spike done re-prompts for confidence until a valid value (high/medium/low) is entered
    Then the command completes normally with the valid confidence value stored and stdout prints [findings_ready] disc-NNN

  Scenario: tyrion-spike-promote
    # Intent: Convert a findings_ready discovery to a linked story with LLM-assisted draft acceptance criteria; establishes born_from_discovery traceability field; optionally prompts for story title
    Given a findings_ready discovery disc-NNN exists with question='Q?', recommendation='Use mutex'
    When tyrion spike promote disc-NNN is run with stdin providing title 'Concurrent Write Safety'
    Then stdout prints '[promoted] <story-slug> <- disc-NNN'; stdout includes 'tyrion criteria add <story-slug>' with at least one of the discovery's finding or recommendation text pre-filled; store.find_discovery shows status='promoted_to_story'; created story has born_from_discovery='disc-NNN', title='Concurrent Write Safety', intent containing 'Use mutex'
    Given a findings_ready discovery with question='What causes the duplication?'
    When tyrion spike promote disc-NNN is run with stdin providing an empty line
    Then created story title equals the discovery question 'What causes the duplication?' and stdout prints '[promoted] <slug> <- disc-NNN'
    Given a discovery exists with status='active_spike'
    When tyrion spike promote <disc-id> is run
    Then exits 1, stderr contains the disc-id and 'findings_ready', no story added to the active epic
    Given disc-999 does not exist in the DB
    When tyrion spike promote disc-999 is run
    Then exits 1, stderr contains 'disc-999' and 'not found', no story created

  Scenario: tyrion-discovery-list
    # Intent: List discoveries filtered by status (active|ready|promoted|deferred|all) and show full detail for a single discovery by id
    # TODO: criteria — fill during /tyrion-implement step 4

  Scenario: tyrion-orient-ext
    # Intent: Extend tyrion status/orient to show a DISCOVERIES section: active spikes, findings_ready items with "→ promote?" prompt, and count of unformalized marks from this session
    # TODO: criteria — fill during /tyrion-implement step 4
