Feature: Autonomous Discovery Filing & Ambient Awareness
  # Intent: Let an implementing agent file a mark/discovery mid-task, unasked, when it
  # notices a real gap, so a later agent can say "already tracked as disc-NNN" instead
  # of rediscovering it -- modeled on the beads issue tracker's autonomous filing, with
  # guardrails beads lacks: search-before-file dedup, a per-story filing budget, an
  # agent/human origin tag, a real deferral exit, and an ambient browser-pane view so
  # the human never has to run a check-in command. See features/discovery-autonomy.context.md
  # for the full design rationale, rejected alternatives, and the beads/herdr investigation.

  # ── Slice 1 — the filing/recall loop ──────────────────────────────────────────

  Scenario: discovery-search-command
    As an implementing agent about to file a mark
    In order to avoid filing a duplicate of something already tracked
    I want a fast, silent-on-no-match search over existing discoveries

    # RIGOR: strict — SQL LIKE construction with escaping; wrong behavior fails silently
    Given a project with existing discoveries across multiple statuses
    When I run tyrion discovery search "<term>"
    Then every space-separated word in <term> must match (case-insensitive, AND across words) at least one of question, finding, or recommendation
    And SQL LIKE wildcard characters "%" and "_" in <term> are escaped so they match literally, not as wildcards
    And matches include every discovery status (mark, findings_ready, active_spike, deferred, promoted_to_story, invalidated) — filtering by status is a separate --status flag, not a default exclusion
    And matches print newest-first, one per line, as "disc-NNN [status] <question or finding, truncated to 60 chars> (<age> ago)"
    And a blank or all-whitespace <term> prints a usage error and exits 1 rather than matching everything
    And no matches prints nothing and exits 0 — no "no results found" line
    And results are scoped to the active project only (parameterized SQL, no cross-project leakage)

    Given the DISCOVERY_ALIASES map in commands.rb has no entry for "marks"
    When I run tyrion discovery list --status marks
    Then it resolves to status=mark instead of dying with "Unknown status alias"

  Scenario: discover-noninteractive-flags
    As an implementing agent that already investigated a gap it previously filed as a mark
    In order to upgrade that mark into a full finding without hanging on an interactive prompt
    I want a non-interactive form of tyrion discover that operates on an existing mark

    # RIGOR: loose — flag parsing, one status-transition method, no novel logic
    Given the marks section of the web Discoveries view renders the chip "tyrion discover disc-NNN" on each mark row (not on findings_ready rows, which render "tyrion spike promote disc-NNN" instead)
    When I run tyrion discover <mark-id> --question "..." --finding "..."
    Then it requires <mark-id> to currently have status "mark" — any other status prints an error naming the current status and exits 1
    And an unknown or wrong-project <mark-id> prints "not found" and exits 1
    And --finding is required; --question is optional and defaults to the mark's original question when omitted
    And on success the discovery's status becomes findings_ready, finding (and question, if given) are set, and it prints "[findings_ready] disc-NNN"
    And no prompts are shown in this flagged form

    Given cmd_discover currently ignores args entirely and always runs three unconditional interactive prompts, creating a brand-new discovery
    When I run tyrion discover with no id and no flags
    Then this unchanged interactive path still creates a new findings_ready discovery exactly as it does today

  Scenario: mark-provenance
    As a future agent or human reading tyrion show on a story
    In order to trace a mark back to the story it was filed from, even after that mark is later promoted to a different story
    I want tyrion mark to record its filing story in a field promotion never overwrites

    # RIGOR: loose — correct lane-resolution edge cases matter more than the line count suggests
    Given promote_discovery_to_story already overwrites discoveries.story_id with the destination story created by promotion, so story_id cannot double as "where this was originally noticed"
    When the discoveries table is migrated (idempotent, PRAGMA table_info-gated, matching the existing MIGRATIONS pattern in store.rb)
    Then it gains a new source_story_id column, set once at creation and never updated by any later status transition, including promotion
    And epic_id continues to be set at creation as today (it is never overwritten elsewhere in the store)

    Given an implementing agent runs tyrion mark "<description>" mid-story
    When the mark is created
    Then source_story_id and epic_id are resolved via prime_story_for (the existing read-only lane lookup) — never via resolve_my_story, which claims/mutates and must not run as a side effect of filing a mark
    And prime_story_for only recognizes the current lane's own in-progress story or the legacy sole-unclaimed story — another lane's in-progress story, or a story that is pinned but not in-progress, resolve to no active story, exactly as prime_story_for behaves today
    And a mark filed with no active story, epic, or project resolved still succeeds with source_story_id and epic_id left nil
    And the confirmation line reports how many marks already exist with the same source_story_id, e.g. "[mark] disc-042 (2nd mark filed this story)" — this is the implementing agent's only way to self-enforce a per-story filing budget without querying SQLite directly, which the implementing-agent skill explicitly forbids

  Scenario: discovery-actor-origin
    As a human triaging the discovery list
    In order to tell "things I decided to track" apart from "things an agent noticed autonomously"
    I want every discovery to record who filed it, without relying on a guessable heuristic

    # RIGOR: strict — misclassification silently defeats the entire point of this story
    Given the MIGRATIONS pattern in store.rb (idempotent, PRAGMA table_info-gated)
    When the discoveries table is migrated
    Then it gains an origin column, CHECK(origin IN ('agent','human')), NOT NULL DEFAULT 'human' — existing rows backfill to 'human' automatically via the column default, no separate backfill step needed

    Given tyrion mark and tyrion discover both accept an explicit --auto flag
    When --auto is passed
    Then origin is recorded as 'agent'; when omitted, origin is recorded as 'human' — this is an explicit flag, not inferred from whether a story is currently active, because an active story does not imply an agent is the one typing the command
    And tyrion spike start and tyrion spike done also accept --auto, recording the same origin on the discoveries they create or update, for consistency — no other behavior of those commands changes

    Given tyrion status, tyrion discovery list, and the web Discoveries view
    When rendering any discovery
    Then each shows a visual marker distinguishing origin=agent from origin=human (e.g. a distinct glyph or "[agent]"/"[human]" tag) consistently across all three surfaces

  Scenario: resume-known-section
    As an implementing agent starting or resuming a story
    In order to see what's already tracked before investigating something new
    I want tyrion resume to surface recent open discoveries

    # RIGOR: loose — new section in an existing command, ordering must be correct
    Given a project has open discoveries (status mark or findings_ready) and list_discoveries currently orders results oldest-first
    When I run tyrion resume
    Then a "Known:" section appears after the existing Lessons block, listing up to 5 open discoveries ordered newest-created-first, each showing its id and actual text (question for marks, finding for findings_ready — never just a count)
    And a findings_ready discovery's line includes its promote command
    And the Known: section is scoped to the active project as a whole, not filtered to the current epic or story
    And more than 5 open discoveries adds a trailing "(N more — tyrion discovery list --status all)"
    And zero open discoveries omits the section entirely — no empty header

  Scenario: status-marks-text
    As a human running tyrion status
    In order to actually read what's been filed instead of just knowing a count exists
    I want the DISCOVERIES lane to show mark text, not a bare count

    # RIGOR: trivial — replace one puts line with the existing marks array's content
    Given cmd_status currently prints only "N unformalized mark(s)" with no text
    When I run tyrion status with open marks present
    Then it shows the 3 most recently created marks' actual question text, one line each, newest first
    And if more than 3 exist it adds a trailing "(N more — tyrion discovery list --status marks)"

  Scenario: prime-marks-nudge
    As an implementing agent at session start or right before compaction
    In order to be reminded to search before filing without having to remember it myself
    I want tyrion prime to carry the discovery-filing nudge automatically, in both its tiers

    # RIGOR: loose — adds a DB read inside prime's existing 2-second fail-open timeout
    Given tyrion prime is already wired to the SessionStart and PreCompact hooks via tyrion_hook_groups (lib/tyrion/commands.rb) — this story adds no new hook
    And print_prime_tier1 (no in-progress story) and print_prime_tier2 (has one) each render their own separate "Rules:" block today
    When I run tyrion prime with open marks present, in either tier
    Then one status line reports the open-marks count with the search command to check first
    And both tiers' Rules blocks gain the same one entry: "file what you notice (tyrion mark --auto); search before filing"
    And prime's total output, including this addition, still completes within its existing 2-second timeout and remains fail-open on any error

  Scenario: implement-skill-continuous-capture-guardrails
    As an implementing agent mid-story who notices a gap, edge case, or deferred decision
    In order to file it correctly instead of dodging in-scope work or flooding the ledger
    I want explicit skill guidance covering search-first, the mark-vs-lesson fork, and a hard filing budget backed by real commands

    # RIGOR: trivial — instruction text only, referencing commands this epic's other stories add
    Given skills/tyrion-implement/SKILL.md Step 7 (CONTINUOUS CAPTURE, hard rule) already has two subsections
    When a third subsection is added after them
    Then it instructs: run tyrion discovery search "<3-5 key words>" first; on a hit, say "already tracked as disc-NNN" in the response and record a re-sighting via tyrion note <slug> observation "re-encountered disc-NNN here: <file:line>" instead of filing a duplicate; on no hit, choose exactly one of: fix now (it's in this story's own criteria), fix inline (under 5 minutes, already touching the file), tyrion mark "<one line>" --auto (real gap, out of scope), tyrion discover <mark-id> --question --finding --auto (already investigated a prior mark), or tyrion block <slug> "<reason>" --discovery disc-NNN (it stops the story)
    And a hard guardrail is stated: at most 3 marks per story, self-checked via the running count tyrion mark already prints in its confirmation line — a 4th means stop and tell the user, not "use judgment"
    And a second guardrail is stated: never file a mark to avoid doing in-scope work — filing something covered by the story's own criteria is a dodge, and tyrion done's gate-refusal already blocks that story from closing anyway

    Given skills/tyrion-implement/SKILL.md Step 6's existing fork (generalizable mistake → tyrion lesson add)
    When a second arm is added
    Then it reads: a concrete product gap (the capability genuinely isn't built) is not a process lesson — it belongs in tyrion mark --auto, where tyrion spike promote can later turn it into a story

  # ── Slice 2 — anti-graveyard ──────────────────────────────────────────────────

  Scenario: discovery-defer-command
    As a human reviewing an open mark or finding that isn't worth doing
    In order to close the loop honestly instead of letting the list only grow
    I want a command that sets a discovery to deferred with a recorded reason

    # RIGOR: loose — new status-transition method plus a new column, validated source states
    Given deferred is already a valid discoveries.status value (schema CHECK) with an existing CLI list alias, but nothing can currently set it, and there is no reason field on the table today
    When the discoveries table is migrated to add a nullable defer_reason column (same idempotent MIGRATIONS pattern)
    And I run tyrion discovery defer <disc-id> ["why"]
    Then it only succeeds from status mark or findings_ready — any other current status (active_spike, deferred, promoted_to_story, invalidated) prints an error naming the current status and exits 1
    And on success the discovery's status becomes deferred, defer_reason is set from the optional argument (nil if omitted), and it no longer appears in the default open views (status, resume Known:, ambient page)
    And an unknown <disc-id> prints "not found" and exits 1
    And re-running defer on an already-deferred discovery prints a friendly no-op message rather than erroring

  Scenario: web-marks-aging-badge
    As a human scanning the web Discoveries view
    In order to notice marks that have been sitting untouched
    I want marks to show the same kind of aging signal findings_ready discoveries already have

    # RIGOR: trivial — mirrors an existing badge pattern in the same file, sharper threshold math
    Given render_ready_section already shows a "⚠ aging" badge using rounded age in days, so it can flip at roughly 2.5 days for a nominal 3-day threshold
    When render_marks_section renders a mark
    Then it shows the same "⚠ aging" badge once the mark's age is at or past 14 full days (unrounded day math against created_at, not the rounded display age), and not before

  Scenario: shape-skill-discovery-recall-check
    As an agent running /tyrion-shape to draft a new epic
    In order to fold already-known gaps into the new epic instead of leaving them silently stranded
    I want a recall step before drafting scenarios that never writes to the DB before the user approves the draft

    # RIGOR: loose — must respect the skill's existing "never write DB before approval" boundary
    Given skills/tyrion-shape/SKILL.md already promises never to write to the DB before the user says "yes" to a draft
    When a new epic is being shaped
    Then the skill first runs tyrion discovery list --status all and identifies any open discovery whose subject overlaps the epic being drafted
    And each overlapping discovery is either folded into a drafted scenario, or explicitly called out in the draft review as "leaving disc-NNN open — consider tyrion discovery defer disc-NNN if out of scope"
    And the skill itself never calls tyrion discovery defer at any point — that remains a manual decision the human makes afterward, exactly like every other DB write this skill performs only on explicit approval

  Scenario: claude-md-discovery-docs
    As a human or agent reading CLAUDE.md
    In order to know the autonomous-filing behavior exists, and read a correct discovery-ID convention, without reading the skill source
    I want a documentation paragraph under the existing Discovery layer section, and a correction to what's already there

    # RIGOR: trivial — documentation only
    Given CLAUDE.md's existing "### Discovery layer" section currently states disc-NNN uses a per-project sequential counter, while create_discovery's comment says the counter is deliberately global across all projects (disc-NNN is the table primary key and must be globally unique)
    When the section is edited
    Then the "per-project sequential counter" claim is corrected to "global sequential counter, not scoped per project"
    And a new paragraph describes autonomous filing, search-before-file, the per-story budget, the agent/human origin tag, and tyrion discovery defer
    And this remains documentation only — the behavioral instruction itself stays in skills/tyrion-implement/SKILL.md, not here, because a global always-on instruction would fire in non-Tyrion repos too, and CLAUDE.md is not hook-reinjected on /clear the way tyrion prime is

  # ── Slice 3 — ambient status page ─────────────────────────────────────────────

  Scenario: ambient-route-and-view
    As a human working in a terminal with a browser pane split alongside it
    In order to notice unread marks without ever running a check-in command
    I want a narrow, glanceable ambient status page

    # RIGOR: loose — new Phlex view + route; deliberately minimal content, several rendering edges
    Given every other route today renders through Views::Layout with full navbar/sidebar chrome
    When GET /ambient?project=<slug> renders
    Then it renders a new Views::Ambient directly, not wrapped in Views::Layout, styled to read well at a 300-360px viewport width (responsive, not a fixed-size guarantee)
    And an unknown or missing <slug> falls back to the resolved active project, same as other routes, or shows a minimal "no project" state if none resolves
    And content is deliberately minimal: the newest 3 open marks (actual question text, HTML-escaped, truncated for long unbroken text) colored per the 14-day aging rule from web-marks-aging-badge, plus one quiet line for the findings_ready count
    And nothing else appears — no story progress, no criteria, no git status
    And zero open marks with a nonzero findings_ready count still shows the findings_ready line — the marks section alone goes blank, not the whole page

  Scenario: ambient-poll-endpoint
    As the ambient page sitting open continuously in a peripheral browser pane
    In order to stay current without flickering or reloading on every glance
    I want a project-scoped poll endpoint whose response the page can apply without a full reload

    # RIGOR: strict — the update contract must stay internally consistent or the page silently goes stale
    Given the existing GET /api/poll is story-scoped, polls every 30 seconds, and triggers a full page reload on token change
    When GET /api/ambient_poll?project=<slug> is polled every 60 seconds
    Then the JSON response includes a token derived from the open marks' ids and content plus the findings_ready count, AND the actual marks list (id, question text, created_at) and the findings_ready count needed to render both sections — not just the token
    And an unresolvable <slug> returns 404 with an empty-state JSON payload rather than an error the page can't render
    And on a token change, the page's JS replaces both the marks list and the findings_ready line from the response payload — never just one of the two
    And separately from token-diffing, the page recomputes each mark's aging color on every poll tick directly from its created_at timestamp, independent of whether the token changed — a mark crossing the 14-day threshold updates visually even though its id/content, and therefore the token, did not change

  Scenario: web-ambient-command
    As a human who wants the ambient page open for a specific project without extra ceremony
    In order to get a narrow, persistent pane instead of a normal browser tab
    I want a dedicated command that opens directly to the correctly-scoped URL

    # RIGOR: loose — new WebServer method + CLI subcommand, must not assume server state
    Given Tyrion::WebServer already owns server start/open lifecycle (start, open_browser) and an already-running server may have been started for a different project than the one active in this shell
    When I run tyrion web ambient
    Then it starts the server if not already running (reusing WebServer.start) and opens /ambient?project=<slug>, where <slug> is resolved the same way tyrion web already resolves its active project — never a bare /ambient that could silently show another project's marks
    And it opens that URL in a narrow app-mode browser window (e.g. Chrome --app=<url> --window-size=340,960) invoked via an argument array, not shell string interpolation
    And if app-mode launch fails or no supported browser is detected, it falls back to a plain browser open of the same fully-scoped URL and still prints the URL to stdout
    And nothing about this command requires herdr or Chrome specifically to be useful — a user can always manually pin any browser tab to the same /ambient?project=<slug> URL in a split pane instead
