Feature: parallel-execution — Parallel story execution via process-identity lanes and wave orchestration

  Run 2+ agent sessions in parallel (GEA pattern) — same dir OR separate git worktrees — each running
  /tyrion-implement with no args, doing UAT/tweak/clear/repeat, each picking up ITS OWN story without
  collision. Identity is a process-derived lane token "<agent>:<pid>:<start-stamp>" stored in
  stories.claimed_by; it survives /clear (the OS process does, the session id does not). Layer two:
  wave orchestration stores depends_on as the one durable truth and derives waves by topo-layering.
  Full design + 15-case vet: ~/.claude/plans/so-what-i-think-magical-conway.md.

  Scenario: relax-in-progress-index
    As a Tyrion lane (an agent process that owns a story)
    In order to let N sessions each hold their own in_progress story in one epic without breaking the
      legacy single-session invariant
    I want the one-in-progress constraint relaxed correctly plus a claimed_by owner column

    # Intent: Replace the single hard-block index with per-lane ownership columns + TWO partial indexes (NULL-safe).
    # RIGOR: strict — SQLite allows multiple NULLs in a unique index; a single combined index silently permits double-ownership.

    Given the stories table has the single partial index idx_one_in_progress_story_per_epic
    When a MIGRATION adds claimed_by TEXT and claimed_at TEXT (idempotent, PRAGMA table_info guard)
    And it drops idx_one_in_progress_story_per_epic
    And it creates idx_one_in_progress_story_per_lane ON stories(epic_id, claimed_by) WHERE status='in_progress' AND claimed_by IS NOT NULL
    And it creates idx_one_unclaimed_in_progress_story_per_epic ON stories(epic_id) WHERE status='in_progress' AND claimed_by IS NULL
    Then two stories in one epic with distinct non-null claimed_by tokens can both be in_progress
    And two in_progress stories with NULL claimed_by in one epic are still rejected (legacy invariant preserved)
    And a fresh DB built from setup_db has both indexes and the claimed_by/claimed_at columns

  Scenario: claim-next-as-pool
    As a lead session distributing work across parallel lanes
    In order to hand each concurrent caller a distinct story with no double-claim
    I want claim-next to stamp claimed_by atomically under BEGIN IMMEDIATE

    # Intent: Thread claimed_by through start/claim; safety is transaction(:immediate), not RETURNING; clear owner on done/unstart/block.
    # RIGOR: strict — concurrency correctness; a double-claim is a silent data-integrity bug.

    Given two sessions invoke tyrion claim-next on the same epic within one contention window
    When both transactions run under transaction(:immediate)
    Then each caller receives a distinct story slug (no duplicate claim)
    And each claimed story has claimed_by set to the caller's lane token and claimed_at set
    When a story is completed via complete_story (or unstart, or block)
    Then its claimed_by and claimed_at are reset to NULL
    And start_story and claim_next_story accept a claimed_by: kwarg defaulting to nil so legacy callers and specs are unchanged

  Scenario: lane-token-identity
    As an agent session that survives /clear as the same OS process
    In order to keep owning my story across /clear instead of grabbing a new one
    I want a deterministic lane token derived from agent identity, stable per session

    # Intent: current_lane_token resolves via tiers: TYRION_LANE > CODEX_THREAD_ID > process-walk > CMUX_CLAUDE_PID accelerator > nil.
    # Token format: "claude:<pid>:<start-stamp>" (walk path) OR "codex:<thread-id>" (sandbox path); any stable+unique string works.
    # RIGOR: strict — the entire design rests on token stability across /clear; verified empirically across cmux, iTerm, Codex.

    Given the helper Commands.current_lane_token
    When TYRION_LANE is set in the environment
    Then it returns TYRION_LANE verbatim (explicit override, sandbox-safe, universal)
    When TYRION_LANE is unset but CODEX_THREAD_ID is set
    Then it returns "codex:<CODEX_THREAD_ID>" (sandbox-safe Codex identity; ps is denied in Codex)
    When neither TYRION_LANE nor CODEX_THREAD_ID is set and ps walk finds a claude/codex/gemini ancestor
    Then it returns "claude:<pid>:<normalized-start-stamp>" using that ancestor's pid
    When CMUX_CLAUDE_PID is set and the walk succeeds it may use CMUX_CLAUDE_PID as the pid (fast-path accelerator)
    Then the token is identical to what the walk would produce (never a different token)
    When ps is unavailable or denied or there is no agent ancestor
    Then it returns nil (legacy single-session path), never a guessed token
    And Repo.agent_pid rescues any ps failure (Permission denied or empty output) by returning nil
    And Repo.pid_start_stamp normalizes the lstart string before hashing so equality is locale/format/OS stable
    And re-deriving the token in the same OS process after a /clear yields an identical token

  Scenario: story-resolver-ladder
    As a lane running /tyrion-implement with no slug after a /clear
    In order to resume MY story unambiguously, same-dir or cross-worktree
    I want one resolver ladder that prefers the DB lane token over any file pin

    # Intent: resolve_my_story with 6 rungs (explicit slug > lane-token match > pre-claim adopt > worktree pin > sole in_progress > claim-next); rewire resume/claim-next/pocket/start/done.
    # RIGOR: strict — rung ORDER is the correctness core; wrong order grabs the wrong or a second story.

    Given resolve_my_story(store, epic, explicit_slug:, claim_if_none:)
    When an explicit slug is supplied
    Then it always wins (rung 1)
    When no slug is given and an in_progress story has claimed_by == current_lane_token
    Then that story resolves (rung 2 — primary; same-dir-safe; survives /clear)
    When no token match but a story has claimed_by == "assigned:<TYRION_LANE>"
    Then it is adopted and re-stamped to the real token (rung 3)
    When none match but .tyrion/active-story pins a slug
    Then that resolves (rung 4 — optional convenience)
    When none match but exactly one NULL-claimed in_progress story exists in the epic
    Then it resolves (rung 5 — legacy single-session)
    When none match and claim_if_none is true
    Then claim-next runs and stamps claimed_by (rung 6)
    And re-running claim-next after a /clear returns the SAME story via rung 2, never a second one

  Scenario: active-story-pin
    As a single agent in its own worktree wanting human-readable resume state
    In order to pin and re-read my story without depending on process identity
    I want an optional per-worktree .tyrion/active-story file mirroring active-epic

    # Intent: Demoted from load-bearing to an optional rung-4 convenience; Repo.active_story/write_active_story mirror active-epic.
    # RIGOR: loose — small file I/O mirroring an existing pattern; not on the correctness path.

    Given Repo.write_active_story(slug, root) mirrors Repo.write_active_epic
    When a lane claims a story
    Then .tyrion/active-story may be written as a convenience pin
    And the resolver consults it only at rung 4 (after the lane-token match)
    And its absence never breaks resolution because the DB token is authoritative

  Scenario: per-lane-active-epic
    As an agent session that already has a per-lane identity token
    In order to keep working on MY epic while another session works on a different one in the same dir
    I want the active epic to be stored per-lane rather than in the one shared .tyrion/active-epic file

    # Intent: Repo.active_epic/write_active_epic gain a token: kwarg → .tyrion/lanes/<hash>/active-epic;
    # resolve_project_epic passes current_lane_token; set_active_epic_for_lane prints ⚠ EPIC SWITCHED on change.
    # RIGOR: strict — this is the core fix; wrong epic means every command is wrong for the session.

    Given two agent sessions (lane A and lane B) running in the same worktree
    When lane A runs tyrion epic activate epic-a and lane B runs tyrion epic activate epic-b
    Then Repo.active_epic(token: lane_a_token) returns "epic-a"
    And Repo.active_epic(token: lane_b_token) returns "epic-b"
    And Repo.active_epic (no token) returns the shared fallback (last human-written value)
    When a lane activates an epic different from its current per-lane epic
    Then set_active_epic_for_lane prints a loud warning on stderr ("⚠ EPIC SWITCHED old → new")
    And re-activating the same epic is silent (no alert)
    When current_lane_token is nil (legacy single-session)
    Then resolve_project_epic reads the shared .tyrion/active-epic file (byte-for-byte today's behavior)
    And all existing specs pass with no changes (the nil/legacy path is untouched)

  Scenario: lane-aware-statusline
    As a developer with multiple Claude sessions open in the same dir
    In order to instantly see which epic and story each terminal is working on
    I want the statusline and session badge to show THIS lane's epic/story, not the shared file's

    # Intent: New "tyrion statusline" CLI subcommand outputs "<epic>/<story> (n/m)" for the calling lane.
    # statusline-command.sh becomes a dumb caller of the CLI rather than re-deriving the token in bash.
    # RIGOR: loose — new subcommand + shell script update; the hard logic is in current_lane_token (done).

    Given the tyrion CLI has a "tyrion statusline" subcommand
    When called inside a Claude Code session
    Then it resolves the lane token via Commands.current_lane_token and prints "<epic>/<story> (done/total)"
    And if the lane has no active epic it prints nothing (empty output, exit 0)
    When ~/.claude/statusline-command.sh calls "tyrion statusline" instead of querying sqlite3 directly
    Then the statusline shows the correct epic and story for THIS terminal's lane
    And a second terminal with a different lane sees its own epic and story
    And the statusline falls back to the shared .tyrion/active-epic query if tyrion is unavailable

  Scenario: suggest-next-epic
    As an agent or human who just finished the last story in an epic
    In order to keep momentum without manually figuring out what to do next
    I want tyrion done, tyrion status, and tyrion claim-next to suggest the next epic when the current one is drained

    # Intent: When active epic has no pending/in_progress stories, surface "Epic complete. Next: tyrion epic activate <slug>".
    # RIGOR: loose — read-only suggestion appended to existing command output; no state mutation.

    Given the active epic has no pending or in_progress stories remaining
    When I run tyrion done <last-story-slug>
    Then the done output includes "Epic '<x>' complete. Next: tyrion epic activate <y>"
    When I run tyrion status
    Then status output includes the next-epic suggestion below the story list
    When I run tyrion claim-next on a drained epic
    Then claim-next prints the suggestion and exits cleanly instead of erroring
    And the suggested next epic is the earliest-created epic with at least one pending story (excluding done/abandoned epics)
    And if no other epic has pending stories tyrion prints "All epics complete" and no suggestion

  Scenario: in-progress-plural
    As any reader of tyrion (status, importer, web)
    In order to see all lanes now that an epic can hold several in_progress stories
    I want the single-active assumptions relaxed to plural where they exist

    # Intent: Add in_progress_stories(epic_id) + in_progress_story_for(epic_id, token); update cmd_status lane list, importer --confirm-abandon, web data/war_room.
    # RIGOR: loose — mechanical fan-out of one single-row query to a list; visible in the UI.

    Given in_progress_story(epic_id) returns a single row
    When in_progress_stories(epic_id) and in_progress_story_for(epic_id, token) are added (old method kept)
    Then tyrion status renders a lane list, marking this process's lane "← you"
    And importer --confirm-abandon blocks on ANY active lane in the epic
    And the web War Room / data layer shows all lanes (an "N active" badge) and never auto-picks "mine"

  Scenario: tyrion-worktrees-command
    As a developer running parallel lanes across worktrees and/or same-dir
    In order to see which lane owns which story and whether it is still alive
    I want tyrion worktrees to print a cross-lane dashboard

    # Intent: One row per worktree AND per active lane: path/branch/epic/story/owner-token/age/live-dead, "← current" for this process; Repo.worktrees parses git worktree list --porcelain.
    # RIGOR: loose — read-only reporting over git + DB; no state mutation.

    Given the project has one or more git worktrees and/or multiple lanes
    When I run tyrion worktrees
    Then output shows one row per worktree and per active lane with path, branch, active epic, in-progress story (or none), owner token, age, and ● live / ✗ dead
    And the lane belonging to this process is marked ← current
    And a working tree shared by 2+ lanes shows an "N lanes share this working tree" warning

  Scenario: lane-liveness-and-unclaim
    As a developer recovering from a crashed or zombie lane
    In order to return an abandoned story to the pool safely
    I want liveness detection plus unclaim and whoami commands

    # Intent: Repo.pid_alive?(pid,start) tri-state live/dead/unknown; tyrion unclaim <slug> [--steal]; tyrion whoami; STALE lane reuses the BLOCKED-lane rendering.
    # RIGOR: loose — best-effort recovery UX; ps may be unavailable, so degrade gracefully.

    Given a lane whose owning pid has died
    When tyrion status / worktrees re-derive liveness via ps -p <pid> plus start-stamp match
    Then the dead lane renders as STALE / ✗ dead with an inline "tyrion unclaim <slug>" hint
    When I run tyrion unclaim <slug>
    Then claimed_by/claimed_at are NULLed and the story resets to pending
    And tyrion whoami prints the resolved lane token and this lane's story
    And adopting a token whose pid is dead or mismatched requires --steal (no silent hijack)

  Scenario: dispatch-pre-claim
    As a lead session orchestrating spawned agents
    In order to assign a story to a lane before that agent process exists
    I want to pre-claim with a label the agent adopts on startup

    # Intent: tyrion claim <slug> --as <label> writes claimed_by="assigned:<label>"; agent started with TYRION_LANE=<label> adopts via rung 3 and re-stamps.
    # RIGOR: loose — thin command plus the already-specified rung-3 adoption path.

    Given a lead runs tyrion claim <slug> --as lane1
    Then the story's claimed_by is "assigned:lane1"
    When an agent starts with TYRION_LANE=lane1 and resolves its story
    Then it adopts that story (rung 3) and re-stamps claimed_by to its real lane token
    And the pre-claim does not mark the story in_progress until the adopting lane starts it

  Scenario: skill-lane-rewire
    As the /tyrion-implement skill driving the /clear loop with zero args
    In order to have every tyrion call self-identify its lane
    I want ORIENT/CLAIM rewired to the lane token and resolver ladder

    # Intent: ORIENT derives + exports TYRION_LANE (drop the hardcoded hedgeye-admin JSONL path); CLAIM collapses if/elif to the ladder; the session note becomes a postmortem breadcrumb only.
    # RIGOR: loose — skill-doc edits; behavior is covered by the CLI stories above.

    Given skills/tyrion-implement/SKILL.md ORIENT and CLAIM steps
    When they are rewired
    Then ORIENT derives the lane token via the helper and exports TYRION_LANE for the shell
    And CLAIM uses no-arg tyrion claim-next which returns my lane's story (rung 2) or claims+stamps a fresh one (rung 6)
    And the session note is kept only as a transcript breadcrumb (ownership lives in claimed_by)
    And the skill documents that worktrees are optional and same-dir lanes risk edit collisions

  Scenario: depends-on-storage
    As a /tyrion-orchestrate skill or human author setting up wave planning
    In order to record which stories must complete before others can start
    I want stories to carry a depends_on JSON array column (the one durable truth)

    # Intent: Wave-orchestration layer (B2). depends_on is the only stored relation; waves derive from it.
    # RIGOR: loose — a nullable JSON column + add/rm command; retained verbatim from prior capture.

    Given a MIGRATION adds depends_on TEXT to stories (default NULL, idempotent)
    When I run tyrion depends add reconcile-command tyrion-drift-command
    Then store.find_story('reconcile-command') shows depends_on = ["tyrion-drift-command"]
    And tyrion wave show displays reconcile-command in a later wave than tyrion-drift-command
    When I run tyrion depends rm reconcile-command tyrion-drift-command
    Then depends_on is empty and waves recompute immediately

  Scenario: wave-derivation
    As a developer asking "what can I safely run in parallel right now?"
    In order to get a wave plan that is always fresh and never stale
    I want tyrion wave show to derive wave assignments by topological layering over depends_on

    # Intent: Waves are derived, never stored — topo-layering over depends_on so they never go stale.
    # RIGOR: strict — topological layering is novel logic that can be subtly wrong; retained verbatim.

    Given stories A (no deps), B (depends_on A), C (depends_on B)
    When I run tyrion wave show
    Then the output shows: wave 1 = [A], wave 2 = [B], wave 3 = [C]
    And waves are computed fresh from the DB each time (not stored)
    When I run tyrion depends rm C B
    Then tyrion wave show immediately shows wave 1 = [A, C] (C unblocked, no longer sequenced after B)

  Scenario: wave-override
    As a developer wanting to serialize a story for caution regardless of its dependencies
    In order to force a story to run alone without changing its depends_on
    I want tyrion wave set <slug> <N> to set a wave_override distinct from the derived wave

    # Intent: wave_override is a pure-preference schedule wish, separate from dependency truth; retained verbatim.
    # RIGOR: loose — store an override column + a set command; derivation already covered by wave-derivation.

    Given story web-note-expand is in derived wave 1 (no deps)
    When I run tyrion wave set web-note-expand 2
    Then tyrion wave show shows web-note-expand in wave 2
    And store.find_story shows depends_on unchanged and wave_override = 2
    And the wave_source for web-note-expand is "user" (not "inferred")
