Feature: War-Room Live Lanes Board
  Give the war-room an Orca-esque live fleet view at ledger altitude: one glance
  answers "which lanes are active right now, who claimed them, is anything stalled,
  and am I over my WIP limit?" Read-only over existing Store truth — no new
  instrumentation, no LLM. The board is the Rule-of-3 enforcement surface.

  Background:
    The web app (web/app.rb, port 4579) currently renders static story/ledger views.
    Active work is identified by stories in state in_progress, each claimed by a lane
    (claimed_by). Liveness is inferred from the most recent story_notes row for the
    story — the ledger already records this; nothing new is written.

  Scenario: lanes-query
    # Intent: one Store read method is the single source of truth for "who is working on what right now"
    # RIGOR: strict — join/aggregation bugs (wrong latest-note, leaked non-active stories) fail silently with plausible output
    Given a ledger containing stories in various states across projects, epics, and lanes
    When Store#active_lanes is called
    Then it returns one row per in_progress story across ALL projects and epics, with story slug, title, epic slug, project slug, claimed_by, and a heartbeat timestamp
    And the heartbeat is the most recent story_notes timestamp for that story, falling back to the story's own updated timestamp when it has no notes
    And stories that are done, pending, or abandoned never appear
    And the method performs no writes

  Scenario: lanes-board-panel
    # Intent: the human-facing fleet view — spot the lane that needs attention without opening terminals
    # RIGOR: loose — Sinatra route + view plumbing over the query; conventions, not novel logic
    Given the war-room web app is running with at least one in_progress story
    When I open GET /lanes
    Then I see one row per active lane showing story title, epic, claimed_by, and humanized heartbeat age (e.g. "4m ago")
    And a lane whose heartbeat is older than 30 minutes is visibly flagged as stalled
    And the header shows the active-lane count against a WIP limit of 3, visually highlighted when the count exceeds it
    And each row links to that story's existing war-room story view
    And the page auto-refreshes on an interval (~30s) without user action
    And the board is reachable from the war-room's main navigation
