Feature: Roadmap state model — honest, Triumvirate-driven project gauge

  The web roadmap channel-overloads color (amber = active AND focus AND stale pointer)
  so epics mis-represent their state. A sealed epic shows a yellow active bar; "N in progress"
  lumps queued/empty epics; the single .tyrion/active-epic pointer survives crashes.

  Fix: derive a single-truth `epic_state` from stories + recency + epics.status, then render
  each visual channel to carry exactly one meaning. Gloria's Law = instant attention routing;
  Matt's Law = segmented header digest; Forrest's Law = state-specific inline actions.

  Scenario: epic-state-presenter
    As a Phlex component that renders the roadmap
    In order to render each epic correctly without querying the DB itself
    I want a pure Presenter.epic_state method that derives the state from stories + metadata

    Given a set of stories and an epic row with a status and optional archived_at
    When Presenter.epic_state(epic, stories, active_epic_id) is called
    Then it returns a hash with :state, :color_css, :glyph, :label, :action, :focus, :archived
    And the state is :empty when there are no stories
    And the state is :sealed when epic status is 'done'
    And the state is :ready when all stories are done and status is not 'done'
    And the state is :blocked when >=1 story is blocked and 0 are in_progress
    And the state is :active when >=1 story is in_progress and last_note_at is within STALE_HOURS
    And the state is :cold when >=1 story is in_progress and last_note_at is beyond STALE_HOURS
    And the state is :paused when epic status is 'paused'
    And the state is :started when some stories are done and some pending with 0 in_progress
    And the state is :queued when all stories are pending
    And :focus is true when the epic id matches active_epic_id
    And :archived is true when epic archived_at is set
    And the cold label includes the hours-idle string from Presenter.time_ago

  Scenario: roadmap-data-activity
    As the roadmap view
    In order to derive epic_state without querying the DB itself
    I want load_roadmap_view to supply per-epic story counts and max last_note_at

    Given the tyrion project has several epics with stories in various states
    When load_roadmap_view(store, project, active_epic_slug) is called
    Then each epic entry includes a :story_stats hash with :done, :in_progress, :blocked, :pending, :total counts
    And each epic entry includes :max_last_note_at (the maximum last_note_at across its stories, or nil)
    And the return value splits epics into :active_epics and :archived_epics by archived_at presence

  Scenario: roadmap-view-redesign
    As a developer opening the web roadmap
    In order to instantly route my attention to what needs action
    I want the roadmap header and epic rows to render honest state with one meaning per channel

    Given the tyrion project roadmap is open at /roadmap?project=tyrion
    When I view the page
    Then the header shows a segmented gauge (e.g. "2 sealed · 1 ready ✦ · 1 active ● · 1 cold ⚠") not "N in progress"
    And the header includes a story completion rollup (e.g. "24/40 stories")
    And epics are sorted by attention weight: ready first, then blocked, cold, active, started, queued, sealed last
    And each epic row's mini-bar length encodes completion percent only (no amber keyed off focus)
    And each epic row shows the state glyph and label derived from epic_state
    And a sealed epic's bar and seal are emerald (not amber)
    And an all-done-but-unsealed epic shows the ✦ glyph and "READY TO SEAL" label
    And an in-progress-but-stale epic shows the ⚠ glyph and "cold · Nh idle" label
    And an empty epic renders a dash track not a 0% active bar
    And the active_epic pointer epic has a ★ prepended to its row
    And sealed epics appear collapsed at the bottom of the list
    And archived epics appear in a collapsed "Archived" details block

  Scenario: epic-web-actions
    As a developer on the roadmap
    In order to act on epic state without leaving the page or memorizing CLI commands
    I want state-specific inline action buttons on each roadmap row

    Given the roadmap page is open and an epic is in the 'ready' state
    When I click the [Seal] button on that epic's row
    Then the epic status is set to 'done' (POST /epic/:slug/seal → epic complete with all-done guard)
    And the page reloads showing the epic as sealed with a flash confirmation

    Given the roadmap page shows an archived epic in the collapsed Archived section
    When I click the [Unarchive] button
    Then the epic's archived_at is cleared (POST /epic/:slug/unarchive)
    And the epic reappears in the main list

    And the [Resume] button links to the war room for that epic's active story
    And the [blocker] link leads to the story or discovery that is blocking
    And the [import] link leads to the import flow for an empty epic

  Scenario: epic-archive-store-cli
    As a developer managing a large project
    In order to tuck away quiet or finished epics without deleting them
    I want tyrion epic archive/unarchive commands and a supporting store migration

    Given the epics table has an archived_at column (added via MIGRATIONS, idempotent)
    When I run tyrion epic archive <slug>
    Then the epic's archived_at is set to the current time
    And tyrion epic list no longer shows the epic in the main list (shown with [archived] marker)
    And the web roadmap moves it to the collapsed Archived section

    When I run tyrion epic unarchive <slug>
    Then the epic's archived_at is cleared
    And the epic reappears in tyrion epic list and the web roadmap main list

    And archive_epic and unarchive_epic are available as Store methods
    And the archived_at migration is idempotent (safe to run twice)
