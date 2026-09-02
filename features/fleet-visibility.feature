Feature: Fleet Visibility: Global sort, Fleet board, Epic cockpit
  Forrest runs many Tyrion projects at once, several with parallel agent lanes. Today
  the terminal transcript is the only liveness signal and Global View sorts by row
  touch time, so the in-motion projects are not on top and a 38-minute builder cannot
  be told apart from a crashed one without scrolling. This epic adds one liveness
  layer (ledger + worktree + process, agent-agnostic) and three surfaces over it:
  a re-sorted Global View, a cross-project Fleet board, and a per-epic cockpit.

  Background:
    The Sinatra web app (web/, port 4579) renders Global View, War Room, Discoveries
    and Ambient today. Three pollers already exist (web/app.rb:174, :232, :286) in two
    patterns: reload-on-token-change with a seeded token (Discoveries, Ambient) and
    Active Story's null-bootstrap (not the model here). Liveness is derived, never
    written: no schema change in any phase. Read features/fleet-visibility.context.md
    before starting any story in this epic.

  Scenario: store-bulk-liveness-queries
    # RIGOR: strict — SQL join/aggregation errors fail silently with plausible output; a wrong "latest note" reads as a real timestamp
    # LANE: A
    # PHASE: 1
    As Forrest watching many projects from one page
    In order to render every lane on the fleet without the N+1 fan-out Global View does today
    I want five bulk Store queries that answer liveness for all lanes in one statement each

    Given a ledger holding stories in every status across several projects and epics
    And some stories carrying notes, checked criteria, gate notes and commit notes
    When the five new phase-1 Store methods are called

    Then Store#in_progress_stories_across_projects returns one row per in_progress story across ALL projects and epics, joined to its epic and project, carrying claimed_by, started_at, updated_at, last_note_at and the project's primary_repo_identity
    And that same method also returns blocked stories, which the attention pass needs, and never returns done, pending or abandoned rows
    And Store#latest_note_per_story(story_ids) returns the newest created_at, kind and metadata per story, and only for the ids given
    And Store#latest_gate_and_commit_per_story(story_ids) returns the newest gate note and the newest commit note per story as separate values
    And Store#latest_criterion_check_per_story(story_ids) returns MAX(checked_at) plus met and total counts per story
    And Store#project_activity returns, per project, the MAX across stories.updated_at, stories.last_note_at, criteria.checked_at and the discoveries timestamp, plus done and total story counts
    And each of the five methods issues exactly one SQL statement, asserted by a spy counting db.execute calls, and an empty story_ids argument returns empty without issuing one

  Scenario: worktree-resolver-and-probe
    # RIGOR: strict — a cwd fallback or a silently-picked ambiguous match reports another repo's state as this lane's
    # LANE: A
    # PHASE: 1
    As Forrest whose lanes live in isolated git worktrees across many repos
    In order to trust that a lane's edit and commit signals came from that lane's own worktree
    I want a resolver that maps lane to worktree from an explicit root and names every failure state instead of guessing

    Given projects whose primary_repo_identity is variously present, nil, or pointing at a path that is gone
    And worktrees under those roots carrying lane directories under .tyrion/lanes
    When Tyrion::Liveness::WorktreeResolver.new(projects) builds its lane_hash to worktree-path map once per snapshot

    Then every git subprocess receives an explicit repo root and the web process cwd is never consulted, asserted by stubbing Repo.worktrees to raise when called with nil
    And a nil primary_repo_identity yields resolution state identity_missing for every lane in that project, while a path that is not a directory or where rev-parse fails yields repo_missing
    And exactly one worktree whose lane hashes contain Repo.lane_hash(claimed_by) resolves to that path, zero yields missing, and two or more yields ambiguous listing every matching path with no silent pick
    And dirty-file signals parse git status --porcelain -z --untracked-files=all as NUL-delimited records, taking the dirty count as the record count and the newest mtime among only those paths
    And rename and copy records consume the destination path, while deleted records and any path whose stat fails are skipped without raising
    And the newest commit time and subject come from git log -1 --format=%ct%n%s for the resolved worktree
    And every git subprocess runs under a 2 second timeout, and a timeout yields nil signals with partial true rather than an exception

  Scenario: liveness-ladder-and-attention
    # RIGOR: strict — state derivation is the product; a false "alive" or a false "dead" is the failure that makes the whole board untrustworthy
    # LANE: A
    # PHASE: 1
    As Forrest deciding which of a dozen lanes deserves my attention right now
    In order to tell working from stalled from crashed without opening a terminal
    I want a derived state per lane whose unknowns stay visible and are never presented as proof of inactivity

    Given lanes whose claimed_by is an explicit TYRION_LANE label, a Codex thread token, a Claude PID token, a dispatched: placeholder, or nil
    And per-lane signals from the ledger, the process probe and the worktree resolver, each reporting nil separately from a timestamp
    When Tyrion::Liveness derives a state for each lane

    Then Repo.lane_liveness returning :dead yields state dead at severity 1, while :unknown is never treated as dead and the ladder simply ignores the process source
    And the age ladder over newest_at yields live under 2 minutes, working under 15, quiet under 30 and stalled at 30 or more, with the overrides dead, unclaimed, worktree missing, worktree ambiguous and blocked all applied before the ladder runs
    And the row carries the newest signal per source rather than only the winner, so a lane editing files with no note for 20 minutes reads differently from one with no signal at all
    And when worktree signals are nil the ladder runs on ledger and process only, the row shows the evidence marker "ledger only", and a stalled row renders as "stalled?" because absence of evidence was not confirmed
    And an in_progress story with claimed_by nil yields state unclaimed and an attention item, while a dispatched: lane becomes an attention item only once it is older than the stalled threshold
    And attention items are ordered by severity, dead then worktree then stalled then unclaimed then blocked, and then by age descending, each carrying story slug, lane label, reason and the timestamp the reason is measured from
    And a future timestamp from clock skew clamps its age to zero rather than producing a negative age or a bogus state

  Scenario: liveness-snapshot-cache
    # RIGOR: strict — TTL and single-flight bugs are silent: the board keeps rendering, just from work done twice or from state nobody notices is stale
    # LANE: A
    # PHASE: 1
    As Forrest with three views open in two browsers polling the same fleet
    In order that watching the board never costs more git work than watching it once
    I want a process-wide single-flight snapshot with a TTL that degrades honestly under failure

    Given a store with several projects and lanes and a resolver that performs real git work
    When Tyrion::Liveness::Snapshot.current(store, ttl: 10) is called repeatedly, concurrently, and under failure

    Then a second call within the TTL reuses the cached snapshot and performs no further git work
    And two concurrent threads calling it produce exactly one build, the second waiting for the in-progress build rather than starting another
    And each rebuilt snapshot carries a monotonically increasing generation, and the default TTL of 10 seconds is below the 15 second poll interval so a poll never sees a snapshot older than one interval
    And the whole worktree pass is capped at a 3 second wall-clock budget, with repos not reached in time carrying partial true and their last known signals, or nil signals on a first build
    And a snapshot build that raises serves the previous snapshot marked stale true and logs the error, while a first-build failure yields a ledger-only snapshot rather than propagating the exception
    And one snapshot holds every project's resolver result, every lane's signals and the bulk ledger rows, so all three views and both pollers read the same build

  Scenario: global-view-activity-sort
    # RIGOR: loose — sorting and glyph selection over the phase-1 module; wrong output is visible on the page, not silent
    # LANE: B
    # PHASE: 1
    As Forrest opening Global View and scanning fourteen project cards
    In order to find the two or three projects actually in motion without reading all of them
    I want the cards sorted by real story activity with the worst lane state shown per card

    Given a project list whose projects.updated_at order disagrees with their real story activity
    And projects with several in-progress lanes in differing liveness states
    When Global View renders and its poller runs

    Then cards sort by the project_activity maximum descending, falling back to projects.updated_at only when that maximum is nil
    And activity includes stories.updated_at, so editing a story's context or next action re-sorts the card without any note being written
    And the card glyph is the worst lane state across every in-progress story in the project, ordered dead then worktree then stalled then quiet then working then live, with the lane count shown when there is more than one
    And the card's displayed story line is unchanged, still the legacy first-in-progress-of-the-active-epic pick, since the glyph is project-level and hides no sibling lane
    And GET /api/global_poll returns a token composed per project of slug, status bucket, worst lane state, done, total and activity_at in sort order, containing no rendered age and no wall-clock-derived value
    And UAT: the page seeds data-token at render time, polls every 60 seconds, reloads on token change, and stops polling on a non-200 response

  Scenario: fleet-board
    # RIGOR: loose — a new route and view assembling values the phase-1 module already derived
    # LANE: B
    # PHASE: 1
    As Forrest running lanes across several projects at once
    In order to see every lane and everything waiting on me on one screen, worst first
    I want a cross-project board of one row per in-progress story that tells me what each lane is doing and how I know

    Given in-progress stories across several projects in varying liveness and resolution states
    And some projects with no in-progress work at all
    When I open GET /fleet

    Then the board renders one row per in-progress story grouped by project, with each project header linking to that project's cockpit
    And the header line reads N live, N need you, and the snapshot age
    And the "Needs you" band renders first, above the lanes, with each item linking to its cockpit
    And each row is the shared Views::Components::LaneRow showing glyph, lane label, story, met over total, the newest-per-source signals and the evidence marker
    And projects with no in-progress work fold into a single dim footer line carrying their last-activity age, while rows inside a project sort by attention weight then newest_at descending
    And GET /api/fleet_poll returns a token carrying per story id, status, claimed_by, met, liveness state and resolution state, plus newest-per-source event timestamps, newest commit sha, dirty count, newest dirty-file mtime as an epoch integer, and each attention item's story_id and kind, with no rendered age anywhere in it
    And UAT: the page seeds data-token at render, polls every 15 seconds, reloads on token change, ticks relative ages client-side from data-at attributes between reloads, and stops polling on a non-200

  Scenario: epic-event-queries
    # RIGOR: loose — four capped queries plus a derivation mapping; the double-emit trap is named and testable
    # LANE: C
    # PHASE: 2
    As Forrest returning to one epic after hours away
    In order to read what actually happened without a scrollback archaeology dig
    I want epic-scoped bulk event queries that derive a feed from the ledger, since no event log exists

    Given an epic whose stories carry notes of every kind, checked criteria, lifecycle transitions and sourced discovery marks
    And block, unblock and reopen commands having persisted blocker and recovery notes with metadata.action
    When the phase-2 event queries run and their results are merged

    Then Store#epic_notes_recent, #epic_criteria_checked_recent, #epic_story_lifecycle and #epic_marks_recent each key on epic_id, cover every story in the epic regardless of status, and cap at the limit newest-first
    And the generic note event stream excludes rows whose metadata.action is block, unblock or reopen, so each lifecycle event appears exactly once rather than twice
    And started derives from stories.started_at and done from stories.completed_at, while blocked, unblocked and reopened derive from those metadata.action notes
    And criterion checked derives from criteria.checked_at with the criterion text, gate from a gate note's metadata gate and result, commit from a commit note's metadata shas, and mark filed from discoveries whose source_story_id is in the epic
    And claim events are omitted entirely, since a claim only updates the story row and emits no note
    And the four result sets are merged and re-capped in Ruby to 50 events newest-first

  Scenario: cockpit-now-tab
    # RIGOR: loose — route, tab param and view assembly over phase-1 and phase-2 data
    # LANE: C
    # PHASE: 2
    As Forrest drilling from the fleet into the one epic that needs me
    In order to see that epic's lanes, blockers and progress on a single screen
    I want a cockpit route whose Now tab reuses the fleet's lane rendering, scoped to one epic

    Given an epic with several lanes, at least one attention item and a mix of done and pending stories
    When I open GET /cockpit?project=<slug>&epic=<slug>

    Then the route renders Views::Cockpit honoring both the project and epic query params, so several tabs can hold different epics without bleeding into each other
    And the Now tab shows Needs you, then Lanes rendered with the same Views::Components::LaneRow the fleet uses, then Progress as a segmented bar
    And the active tab lives in the URL as ?tab=now, changes or trail, defaulting to now when the param is absent or unrecognized
    And the topbar epic switcher renders in :scoped mode, since this route's content honors ?epic=
    And GET /api/cockpit_poll?project=&epic= returns the fleet token restricted to that epic plus the newest Changes event key and the epic's status counts
    And an unknown project or epic on that poll endpoint returns 404 with a null token so the page stops polling rather than looping
    And UAT: the cockpit page renders for a live epic, the tab param survives a reload, and the poller reloads the page on a token change

  Scenario: cockpit-changes-trail-tabs
    # RIGOR: loose — feed rendering and age banding over the phase-2 queries
    # LANE: C
    # PHASE: 2
    As Forrest catching up on an epic several lanes have been working
    In order to read what changed most recently and dig into the full history when I need it
    I want a Changes recency feed that dims with age and a Trail tab holding the complete note timeline

    Given an epic with more than fifty derived events spanning minutes to days old
    When I open the cockpit's Changes and Trail tabs

    Then Changes renders derived events newest first, capped at 50, with no "since you looked" delta since nothing can know when my eyes landed on the pane
    And events dim by age band, under 15 minutes, under an hour, and older, via TyrionWeb::Presenter.age_band_css
    And relative ages tick client-side from data-at attributes every 15 seconds, so a boundary crossing dims without waiting for a new event to change the token
    And a lane dead event comes from a process-liveness transition the snapshot observed in memory, is never persisted, and disappears on server restart
    And Trail renders the existing full note timeline for the epic with no cap and no poller
    And UAT: both tabs render for a live epic, Changes shows at most 50 rows, and switching tabs changes only the ?tab= param

  Scenario: typical-time-left
    # RIGOR: loose — a median over existing timestamps, shown with n so the reader can weigh it
    # LANE: D
    # PHASE: 3
    As Forrest deciding whether an epic finishes tonight or needs another day
    In order to get a rough honest sense of what is left without pretending to a precision the data cannot support
    I want a "typical" time-left figure derived from completed-story wall clock, never from criteria velocity

    Given an epic whose done stories carry started_at and completed_at, alongside blocked and abandoned stories
    When the cockpit and fleet render their progress and lane rows

    Then the sample is done stories only, measured as completed_at minus started_at in minutes, excluding blocked and abandoned stories
    And typical_minutes is the median when n is 2 or more, else the project-wide median when that n is 5 or more, else nil, in which case nothing at all is rendered
    And the progress band shows remaining times typical divided by the live lane count, floored at one lane, as a rounded range such as "about 1h", annotated with the typical per-story minutes and n
    And a lane row shows elapsed against typical, turning amber past twice typical to read as alive but slow, and raising no attention item in this version
    And the known limitation that time spent blocked mid-story is not subtracted is stated where the figure is shown, since the schema carries no per-story block duration
    And UAT: an epic with fewer than 2 done stories and no project fallback renders no time-left figure anywhere
