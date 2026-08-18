# Spike Visibility (v1) — epic context

## Why this epic exists

Global View showed crimson-maestro (a project that is 100% SDRD spike work, zero epics) as fully
idle right after it closed a 5-spike queue with real running-code proof behind every finding. Root
cause: `TyrionWeb::Data.load_global_view` (`web/lib/tyrion_web/data.rb`) only counts
`stories_for_epic`; it never touches the `discoveries` table. Compounding bug:
`Views::Layout#render_sidebar` / `TyrionWeb::Data.load_sidebar_data` hard-gate the entire sidebar
(stories list AND the discovery strip) on `project && epic`, so an epic-less project's sidebar
falsely says "No active project" on every page, not just Global View.

Full design synthesis — root-cause code reads, five grounded scenarios, both peer sessions' full
answers verbatim — lives at:
`~/work/harness_research/agent-drops/20260818-161059__tyrion-spike-ux__spike-visibility-design-plan.md`
Reviewed with Forrest as a StreamWeaver doc (canvas session `tyrion-spike-ux`, theme `:doc`) before
this import; he approved "Option 1" from that doc as this epic's scope.

## What this epic deliberately does NOT include (v2 candidate)

Two independent sessions — the one that ran a 5-spike queue (`crimson maestro spikes`) and the one
that authored the plan it executed (`Ruby harness project`) — separately named: dependency/ordering
edges between spikes, batch-promote-as-a-set grouping, a dedicated Spike Board `/spikes` nav tab,
cross-session provenance (designed-by vs run-by), and an evidence-artifact link field. All real, all
deferred — building that data model off one spike-heavy project (n=1) would be speculative SDRD; the
right move is to wait for a second spike-heavy project to confirm the shape before committing to it.

Forrest explicitly asked for this epic to "dovetail quickly into" that v2 work. That's why
`verdict` (an orthogonal epistemic axis, not lumped into lifecycle status) and `parent_spike_id`
(mark→spike linkage) are IN this epic even though the fuller dependency/scoreboard view is deferred:
both peer sessions agreed those two are the expensive-to-retrofit pieces — the dependency graph and
batch-promote grouping are purely additive on top of them later, so getting the axis and the linkage
right now avoids a second retrofit.

## Discovery recall (Step 2b, tyrion-shape)

`tyrion discovery list --status all` reviewed in full for the tyrion project's own ledger. No open
discovery (mark / findings_ready / active_spike — i.e. not deferred, promoted, or invalidated)
overlaps this epic's scope. The open ones are either about the ambient pane's readability
(disc-020/021/022/029/030/031 — a separate, already-worked feature area) or unrelated CLI/status
bugs (disc-002, disc-004 through disc-009, disc-018 — claim_next messaging, epic-resolution
disagreement, CLAUDE.md block content, shape/claim-gate conflict). None concern Global View, the
sidebar, or the Discoveries page's rendering, verdict, or linkage. Nothing folded in, nothing left
dangling.

## Note on ledger plan notes (claim-gate limitation, disc-009)

`tyrion-shape`'s Step 5b normally bakes RIGOR/BATCHING/PLAN into each story via `tyrion note
<slug> plan "..."` right after import. That was blocked here by the claim gate ("no in_progress
story in this lane") — the exact conflict already tracked as disc-009 (claim-gate blocks `tyrion
note plan` on pending stories from unclaimed lanes). Per disc-009's own resolution, the payload
lives in the feature file's `# RIGOR:` comments plus this sidecar instead. The per-story
implementation notes below are the fuller version of what would otherwise be a ledger note —
read this section, not `tyrion show <slug>`, for implementation detail until each story is
claimed (at which point `/tyrion-implement` should bake a note from this section as its own first
step).

## Per-story implementation notes

**global-view-discovery-momentum** — Modify `TyrionWeb::Data.load_global_view`
(`web/lib/tyrion_web/data.rb:122`) to call `load_discovery_summary(proj['id'])` per project card
and merge discovery counts into the card hash. In the `card_status` computation, add a precedence
branch: when `total` (epic/story count) is 0 but discoveries exist (spike present OR
`ready_count > 0` OR `mark_count > 0`), status must NOT be `:idle` — introduce a new status symbol
(suggest `:discovery`). Existing precedence (`active_count > 0` → `:active`/`:stale`, then
all-done → `:done`) stays untouched; this only changes the current `else → :idle` fallback. Add a
config entry to `Views::GlobalView::STATUS_CONFIG` (`web/views/global_view.rb`) for the new status
(label + css, following the existing amber/gold palette). Update `render_project_card` to show a
one-line discovery summary (e.g. "N ready to promote · N marks") in place of "No story in
progress" when there's no epic but discovery activity exists. Specs: (a) 0 stories + discoveries
present → not `:idle`; (b) real story activity → status unchanged from today; (c) nothing at all →
still `:idle`.

**sidebar-epic-gating-fix** — In `data.rb`, change `load_sidebar_data(project, epic)`'s guard from
`unless project && epic` to `unless project`; when epic is nil but project is present, return
`{ stories: [], disc_summary: load_discovery_summary(project['id']), epic_switcher:
epic_switcher_epics(project) }`. In `web/views/layout.rb#render_sidebar`, change the outer
condition from `if @project && @epic` to `if @project`; gate only the "Stories · <epic>" section
on `@epic` truthy, but always attempt the discovery strip. Add a project-only header line for when
`@epic` is nil (currently hardcoded `"#{@project['slug']} › #{@epic['slug']}"`, which will NPE on
nil epic today). Only the true `@project` nil case should still render "No active project".

**discovery-verdict-field** — Add a `verdict TEXT` column via the `MIGRATIONS` array in
`lib/tyrion/store.rb` (idempotent `PRAGMA table_info` check, same idiom as every other migration
there). Add an optional `--verdict <value>` flag to `cmd_spike_done` (validate against
`confirmed|falsified|falsified_alternative|partial`, `die` with usage error on an invalid value);
thread it into `Store#close_spike` via `verdict = COALESCE(?, verdict)`, matching the origin
column's existing COALESCE convention. Surface verdict in `tyrion discovery show` / `discovery
list` CLI output (`Tyrion::Output`) and add `TyrionWeb::Presenter.verdict_tag` (mirrors
`origin_tag`'s `{text:, css:}` shape) for the web views — color it distinctly (confirmed=emerald,
falsified=red, falsified_alternative=amber "redirect" treatment, partial=neutral).

**mark-parent-spike-linkage** — Add a `parent_spike_id TEXT` column (same migration pattern,
no enforced FK — matches this schema's existing soft-FK style). In `cmd_mark`, after resolving
project/epic/story context, also call `store.active_spike_for(project['id'])`; if present, pass
its id as `parent_spike_id:` into `Store#create_discovery` (new kwarg, default nil). Same
read-only-lookup discipline as the existing mark-provenance `source_story_id`/`story_id` fields —
no claiming side effects.

**discovery-show-view** — New `GET /discoveries/:id` route in `web/app.rb`, new
`TyrionWeb::Data.load_discovery_show_view(id)` (resolve via `store.find_discovery`, plus its
project/epic for sidebar context, plus child marks via a new `Store` query filtering
`parent_spike_id = id`). New `Views::DiscoveryShow` Phlex view rendered inside `Layout`, following
`active_story.rb`'s show-page structure (header block, meta rows, sections). Link to it from
`DiscoveriesView`'s existing cards (the `d['id']` text becomes `a(href: "/discoveries/#{d['id']}")`).

**discoveries-markdown-rendering** — Check `web/Gemfile` for an existing markdown gem before adding
one; if none, add a small dependency (redcarpet is a reasonable default — no native-dep surprises,
widely used). Add `TyrionWeb::Presenter.render_markdown(text)` (HTML-escape input, then render —
CLI-authored text could contain `<script>`-looking strings and must not inject raw HTML) and swap
it in for `plain(...)` on finding/recommendation/hypothesis/question text on both `DiscoveriesView`
and the new show view via `raw safe(...)`.

**mark-flag-parsing-fix** — Root cause: `cmd_mark` only consumes `--auto` via
`consume_auto_flag`; anything else starting with `--` is left in `args` and silently joined into
the mark's free-text content (this is exactly how disc-026 became the literal string `"--list"`).
Fix: after `consume_auto_flag`, scan the remaining `args` for any token matching `/\A--/` and `die`
with a usage error (no discovery created) before treating the remainder as content. Scope: only
double-dash tokens (`--foo`) error; leave single-dash text alone (e.g. `"-1 result"` is common real
mark content, not a flag typo). RIGOR strict — write the failing test first (`tyrion mark --list`
→ usage error, no row created) before the fix, per this project's TDD convention. Check whether
`cmd_discover`/`cmd_spike_start`/`cmd_spike_done` share the same gap; if so, that's a new mark for
a follow-up story, not silently expanded scope here.

**discovery-delete-command** — Add `Store#delete_discovery(id)`, inside
`db.transaction(:immediate)`: refuse (return/raise a distinguishable error) when the row's
`story_id` is non-nil (promoted-to-story traceability would break) — surface that as a `die` in
the CLI naming the story. Add a `tyrion discovery delete <id>` subcommand next to the existing
`defer`/`show`/`search` subcommands in `cmd_discovery`'s dispatcher, no confirmation prompt (matches
this codebase's existing non-interactive-command convention), success line mirrors other commands'
confirmation style (e.g. `[deleted] disc-026`).

**discoveries-live-poll** — Follow the exact pattern already used for `/api/poll`
(`active_story.rb`) and `/api/ambient_poll` (`ambient.rb`): add `GET /api/discoveries_poll?
project=<slug>` returning `{token, ...}` where token is a SHA256 fingerprint (same shape as
`TyrionWeb::Data.ambient_token`) over spike/findings_ready/marks ids + status + verdict + question
text. Add polling JS to `DiscoveriesView` at a 30s interval (matches `active_story.rb`'s cadence —
Discoveries is an actively-watched page during a live spike session, unlike ambient's 60s glance
pane) that re-fetches on token change and repaints the three sections in place.

## Naming note for a future v2

Leave this epic's slug (`spike-visibility`) as the v1 marker. The future dependency/scoreboard epic
should get its own distinct slug (e.g. `spike-dependency-board`) rather than reopening this one, so
the seal on this epic stays honest once its 9 stories are done.
