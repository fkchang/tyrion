# Fleet Visibility: Global View sort, Fleet board, Epic cockpit

Date: 2026-09-01
Status: revision 3, after two Codex adversarial passes (see `2026-09-01-fleet-visibility-codex-review.md`)

## Problem

Forrest runs many Tyrion projects at once, several with parallel agent lanes (a coordinator plus builder subagents in isolated worktrees). Two visibility failures today:

1. **Global View (`/global`)** sorts by `projects.updated_at` (row touch time, not story activity), has no poller, and the in-motion projects are not on top. He refreshes by hand and scans 14 cards to find the 2 or 3 that matter.
2. **The terminal transcript is the only liveness signal.** A builder subagent ran 38 minutes and there was no way to tell working from stalled or crashed without scrolling a long, still-growing transcript. This is the same "too much stuff, scroll to find it" problem `/session-tabs` was built to solve for Claude Code sessions, and Tyrion has no equivalent.

Priority, in Forrest's order: **(B) is anything stuck or waiting on me** first, then **(A) what changed**, then **(D) what is each lane doing, with signs of being alive**. **(C) how long is left** is the stretch goal.

## Scope and phasing

All in the Tyrion Sinatra web app (`web/`), all reading one new liveness module. No StreamWeaver canvas: these views poll, and canvas-push has no polling.

| Phase | Deliverable | Depends on |
|---|---|---|
| 1 | `Tyrion::Liveness` + snapshot cache + bulk Store queries | nothing |
| 1 | Global View: sort by real activity, worst-lane glyph, 60s poll | phase 1 module |
| 1 | `/fleet`: cross-project board, one row per in-progress story | phase 1 module |
| 2 | `/cockpit`: Now / Changes / Trail for one epic | phase 1 + event derivation table below |
| 3 | "Typical" time left (stretch) | phase 2 |
| spike | Claude Code transcript adapter (waiting / question text) | attribution spike, see Follow-ups |

Out of scope, logged:

- Hiding old/done projects on Global View with archive or search: **disc-156**.
- An ambient-style narrow strip (DOM-patched) for a split pane. Not wanted now; the design keeps the door open.
- `tyrion heartbeat` push verb. Approach 1 (pull on poll) was chosen; heartbeat is the later hybrid upgrade.
- Harness adapters for Codex, Copilot, Gemini and the Claude transcript adapter. Each gated on a spike of that harness first.

## Decisions made during brainstorm

| Question | Decision |
|---|---|
| Row unit | One row per **in-progress story**, grouped by project. An unclaimed in-progress story (protocol violation) shows as a row with no lane, which is itself an attention item. |
| Liveness sources | Ledger + worktree + process liveness as the floor (agent-agnostic). Transcript-reading adapters only after an attribution spike. |
| Form factor | Board and cockpit in the web app; no strip for now. |
| Cockpit tabs | Now / Changes / Trail. Grows toward session-tabs' six only when a tab has real data. |
| "Since you looked" delta | **Dropped.** Nobody can know when eyes landed on a pane beside a terminal. Changes is a recency feed with running relative timestamps that dim with age. |
| Update mechanism | Reload-on-token-change with a seeded token (the Ambient/Discoveries pattern, not Active Story's null-bootstrap). Relative ages tick client-side between reloads. |
| Liveness thresholds | live < 2m, working < 15m, quiet < 30m, stalled >= 30m. Constants, tunable. |
| Time left | "Typical" from completed-story wall clock in the epic, never criteria velocity. Shown with n. Stretch, phase 3. |

## Liveness layer

New module `Tyrion::Liveness` in `lib/tyrion/liveness.rb` (in lib, not web, so `tyrion status` can use it later). Pure functions over an injected snapshot; nothing is written to the DB.

### Lane

A lane is an in-progress story row plus its epic and project. `stories.claimed_by` is one of (see `Commands.derive_lane_token`, `lib/tyrion/commands.rb` ~4378):

- explicit label from `TYRION_LANE` (e.g. `v0-A`), no process to probe
- Codex thread token `<label>:<thread_id>`, no process to probe
- Claude PID token `<label>:<pid>:<16-hex-start-stamp>`, probeable
- `dispatched:<label>` pre-claim placeholder written by `tyrion assign` until a lane adopts it (`lib/tyrion/store.rb` ~714-728), no process to probe; renders as state `dispatched` (attention item only once older than the stalled threshold, since a dispatched-but-never-adopted story is a lane that never started)
- nil: unclaimed

### Signal sources, per lane

**Ledger** (existing columns, no schema change): `started_at`, `claimed_at`, `updated_at`; newest `story_notes.created_at` + `kind`; newest `criteria.checked_at`; newest `gate` note (`metadata.gate/result`); newest `commit` note (`metadata.shas`).

**Process** (existing API): `Repo.lane_liveness(claimed_by)` returns `:live`, `:dead`, or `:unknown` (`lib/tyrion/repo.rb` ~137-176). `:dead` is a positive "the process is gone" finding, start-stamp checked against PID reuse. `:unknown` covers explicit labels, Codex tokens, and sandboxes where `ps` is denied; it is never treated as dead.

**Worktree** (bounded, see resolver and budget below): `git status --porcelain -z --untracked-files=all`, NUL-delimited so paths with spaces or newlines parse; dirty file count = record count; newest mtime **among those paths only** (bounded by the dirty count, no recursive scan). Rename records (`R`/`C`) carry two NUL-separated paths, stat the new one; deleted records (`D`) and any path whose stat fails are skipped, not errors. Newest commit time + subject from `git log -1 --format=%ct%n%s`. Missing or ambiguous resolution is reported as such, not as inactivity. (`Repo` already has a porcelain record counter at ~269-271; the `-z` path listing is new.)

Every source reports `nil` for "no evidence" separately from a timestamp. The row carries the **newest signal per source** (`edit 40s · commit 6m · note 9m · gate 38m · process live`), not just the winner. This is what separates "busy coding, no notes for 20 minutes" from "nothing at all for 38 minutes".

### Lane-to-worktree resolver

`Tyrion::Liveness::WorktreeResolver.new(projects)` builds, **once per snapshot**, `lane_hash -> [worktree paths]` per canonical repo:

1. Repo root is `projects.primary_repo_identity` (nullable, `lib/tyrion/store.rb` ~27-39). Nil → every lane in the project is `identity_missing`. Path not a directory or `git -C <root> rev-parse` fails → `repo_missing`.
2. `Repo.worktrees(root)` with the explicit root, never `Dir.pwd` (the web process runs from `web/`, `web/lib/tyrion_web/data.rb` ~34-36 defaults to cwd and must not be used here).
3. For each worktree, `Repo.lane_hashes(path)`; the lane hash is `Repo.lane_hash(claimed_by)`.
4. Exactly one match → that path. Zero → `missing`. More than one → `ambiguous` with the paths listed (`cmd_worktrees` tolerates this by rendering the lane under every match; the fleet must not pick one silently).

`missing`, `ambiguous`, `repo_missing`, `identity_missing` are all distinct resolution states surfaced on the row and, for `missing` and `ambiguous`, as attention items. All git subprocesses run with a 2s timeout via `Open3` + `Timeout`; a timeout yields `nil` signals and `partial: true`.

### Snapshot cache

`Tyrion::Liveness::Snapshot.current(store, ttl: 10)` is the single entry point for every endpoint and page render. It is process-wide, TTL 10s, single-flight (a mutex; concurrent callers wait for the in-progress build rather than starting another). One snapshot holds every project's resolver result, every lane's signals, and the bulk ledger rows, stamped with a monotonically increasing `generation`. A page render triggered by a token change uses whatever snapshot is current at render time, which is the same generation or a newer one (the TTL may have expired between the poll and the reload); either way the render reflects state at least as fresh as the token that triggered it, and the page seeds its new `data-token` from the snapshot it rendered from, so the next poll compares against what is actually on screen. Two browsers polling three views do not multiply git work. The TTL is below the 15s poll interval so a poll never sees a snapshot older than one interval.

Wall-clock budget: the whole worktree pass is capped at 3s per snapshot; repos not reached in time carry `partial: true` and their last known signals (or nil on first build).

### Bulk Store queries (no per-row queries)

New `Store` methods, each one SQL statement, keyed by story id:

- `in_progress_stories_across_projects` → stories joined to epics and projects with `claimed_by`, `started_at`, `updated_at`, `last_note_at`, project `primary_repo_identity`, plus `blocked` stories for attention items.
- `latest_note_per_story(story_ids)` → newest note `(created_at, kind, metadata)` per story via a window or `MAX` group.
- `latest_gate_and_commit_per_story(story_ids)` → newest `gate` and newest `commit` note per story.
- `latest_criterion_check_per_story(story_ids)` → `MAX(checked_at)` and met/total per story.
- `project_activity` → per project `MAX` of `stories.updated_at`, `stories.last_note_at`, `criteria.checked_at`, `discoveries.updated_at` (if the column exists, else `created_at`), plus done/total story counts.

Phase 2 adds the event queries for the Changes feed. Existing note and criteria APIs are story-scoped (`store.rb` ~820-837, ~1112-1113) and the five queries above cover only in-progress/blocked stories with their latest row, so the feed needs its own, all keyed by `epic_id` and each capped at the feed limit (50) newest-first:

- `epic_notes_recent(epic_id, limit:)` → notes for every story in the epic, any status, with `metadata`.
- `epic_criteria_checked_recent(epic_id, limit:)` → checked criteria with text and `checked_at`.
- `epic_story_lifecycle(epic_id)` → every story's `started_at`, `completed_at`, status.
- `epic_marks_recent(epic_id, limit:)` → discoveries whose `source_story_id` is in the epic.

Four statements, merged and re-capped in Ruby.

`load_global_view` is currently N+1 over projects, epics, stories and discovery summaries (`data.rb` ~133-175); phase 1 replaces its activity and lane parts with these queries. The rest of the card stays as is.

### Derived state per lane

Overrides first, then the age ladder over `newest_at` (newest non-nil signal across sources):

| State | Rule | Glyph | Attention item? |
|---|---|---|---|
| dead | process liveness `:dead` | red X | yes, severity 1 |
| unclaimed | in_progress with `claimed_by` nil | `?` | yes |
| worktree missing/ambiguous | resolver state | broken link | yes |
| live | `newest_at` < 2m | green, pulsing | no |
| working | < 15m | green | no |
| quiet | < 30m | amber | no |
| stalled | >= 30m | red | yes |
| blocked | story status `blocked` (not a lane, same pass) | stop sign | yes |

**Evidence marker.** When worktree signals are nil (resolver failure, timeout, partial) the ladder runs on ledger + process only and the row shows `ledger only` next to the state. A `stalled` with `ledger only` renders as `stalled?` (question mark) because absence of evidence was not confirmed. Unknown is always visible, never presented as proof of inactivity.

### Attention items

From the same pass, scoped (fleet: all projects; cockpit: one epic). Ordered by severity (dead, worktree missing/ambiguous, stalled, unclaimed, blocked) then age descending. Each has story slug, lane label, reason, and the timestamp the reason is measured from. **Tokens never include a rendered age.**

### Time left ("typical", phase 3)

- Sample: stories in the epic with status `done`, `completed_at - started_at` in minutes, excluding blocked and abandoned. Known limitation: time spent blocked mid-story is not subtracted (no per-story block-duration in the schema); `n` is shown so the reader can weigh it.
- `typical_minutes` = median when `n >= 2`, else project-wide median when `n >= 5`, else nil (show nothing).
- Progress band: `remaining * typical / max(live_lanes, 1)` as a rounded range ("about 1h") with `typical 14m per story, n=4`.
- Lane row: elapsed vs typical; past 2x turns amber ("alive but slow"), no attention item in v1.
- RIGOR weighting deferred until there is data.

## Endpoints and views

### Update mechanism

One token endpoint per view, JSON `{token}`. The page seeds `data-token` at render time from the same snapshot (the Ambient/Discoveries pattern; Active Story's `knownToken = null` bootstrap is not the model). The poll JS reloads on token change and **stops polling on a non-200**, so a 404 cannot loop. Relative ages on the page tick client-side from `data-at` attributes every 15s (as Ambient does outside its token branch), so ages and dimming stay honest without a reload.

**Token composition rule:** fingerprint every value the page renders whose change should be seen, as canonical ids, counts, discrete buckets, or the timestamp of a discrete event, stably ordered. Never a rendered age, never a wall-clock-derived value that changes without a new fact behind it.

- `GET /api/fleet_poll` (15s): for each in-progress story, `id:status:claimed_by:met:liveness_state:resolution_state` plus the newest-per-source event timestamps (`last_note_at`, newest `checked_at`, newest gate/commit note `created_at`, newest commit sha, dirty count, newest dirty-file mtime as an epoch integer), plus each attention item's `story_id:kind`. A new note within the same liveness bucket therefore reloads, because the row displays it; the bucket itself still flips once per threshold crossing.
- `GET /api/cockpit_poll?project=&epic=` (15s): the fleet token restricted to the epic, plus the newest Changes event key and the epic's status counts.
- `GET /api/global_poll` (60s): per project `slug:status_bucket:worst_lane_state:done:total:activity_at`, in sort order (so a re-sort, a count change, and a new activity timestamp are each a change; `activity_at` is a stored event time, not an age).

Active cockpit tab lives in the URL (`?tab=now|changes|trail`).

### Global View (`/global`)

- Sort: `project_activity` max descending; nil falls back to `projects.updated_at`. Activity includes `stories.updated_at` so context/next-action updates count.
- Card glyph: the **worst** lane state across every in-progress story in the project (dead > worktree > stalled > quiet > working > live), with the count of lanes when more than one. The card's displayed story line is unchanged (still the legacy first-in-progress-of-active-epic pick, `data.rb` ~133-174); the glyph is project-level so sibling lanes are never hidden.
- Poll every 60s, reload on token change.

### Fleet board (`/fleet`)

New route and `Views::Fleet`. Not a War Room extension: War Room is per-project Kanban, the board is cross-project rows.

- Header: `N live · N need you · snapshot age`.
- **Needs you** band first, each item linking to its cockpit.
- **Lanes** grouped by project; project header links to the cockpit. Row = shared `Views::Components::LaneRow`: glyph · lane label · story · `met/total` · newest-per-source signals · evidence marker · (phase 3) elapsed vs typical.
- Idle projects fold into one dim footer line with last-activity age.
- Sort inside a project: attention weight, then `newest_at` descending.

### Epic cockpit (`/cockpit?project=&epic=`), phase 2

New route and `Views::Cockpit`. Honors `?project=&epic=` multi-tab scoping; epic switcher in `:scoped` mode.

- **Now**: Needs you · Lanes (`LaneRow`) · Progress (segmented bar; typical line in phase 3).
- **Changes**: recency feed, newest first, cap 50, dim by age band (< 15m, < 1h, older), ages ticking client-side. Events are **derived**, there is no event log:

| Event | Derived from |
|---|---|
| started | `stories.started_at` |
| done | `stories.completed_at` |
| blocked / unblocked / reopened | `story_notes` with `metadata.action` (`commands.rb` ~1524-1591) |
| criterion checked | `criteria.checked_at` (+ text) |
| note | `story_notes` by kind (plan, progress, decision, blocker, recovery, handoff, followup, observation, session, test), **excluding** rows whose `metadata.action` is block/unblock/reopen, which are already emitted above (the block/unblock/reopen commands persist exactly such blocker/recovery notes, so without this exclusion each lifecycle event appears twice) |
| gate | `gate` note `metadata.gate/result` |
| commit | `commit` note `metadata.shas` |
| mark filed | `discoveries.created_at` where `source_story_id` in epic |
| lane dead | process liveness transition observed by the snapshot (in-memory, not persisted; disappears on server restart, acceptable) |

Claim events are not derivable (a claim only updates the row, `store.rb` ~1655-1664) and are omitted.

- **Trail**: existing full note timeline for the epic, no cap, no poll.

### Shared pieces

- `TyrionWeb::Data.load_fleet_view`, `load_cockpit_view`, extended `load_global_view` all read `Liveness::Snapshot.current`.
- `Views::Components::LaneRow` is the single lane rendering.
- `TyrionWeb::Presenter` gets `liveness_glyph(state)`, `resolution_label(state)`, `age_band_css(seconds)`.

### Privacy boundary

The server binds `0.0.0.0` with no auth (`web/app.rb` ~21-28) for Tailscale phone access. Nothing in phases 1 to 3 renders transcript or prompt content: signals are timestamps, counts, commit subjects, and Tyrion's own notes. If the transcript adapter spike ever adds "question text" it is opt-in via env var, off by default, and truncated.

## Error handling

Every source degrades to nil (visible as `ledger only` / resolution state), never to a crash and never to a false "alive" or a confirmed "dead":

- `primary_repo_identity` nil, path gone, not a git repo: resolution states above.
- Git subprocess timeout (2s) or snapshot budget (3s): `partial: true`, nil signals for the unreached lanes.
- `ps` unavailable: process liveness `:unknown`, ladder ignores it.
- Future timestamps / clock skew: age clamps to 0.
- Unknown project/epic on a poll endpoint: 404 with `{token: null}`; the page stops polling.
- A snapshot build raising: the previous snapshot is served with `stale: true` and the error logged; a first-build failure renders the ledger-only view.

## Testing

Existing web specs exercise `TyrionWeb::Data` and view classes directly (e.g. `spec/ambient_poll_spec.rb`), not Sinatra via Rack::Test. Follow that:

- `spec/liveness_spec.rb`: ladder states and overrides from a hand-built snapshot; newest-per-source selection; evidence marker when worktree signals are nil; `stalled?` vs `stalled`; clock skew clamp.
- `spec/liveness/worktree_resolver_spec.rb`: uses `tyrion_worktree` helper to create real worktrees with lane dirs; asserts one match, `missing`, `ambiguous` (same hash in two worktrees), `repo_missing`, `identity_missing`; explicit-root is passed (assert `Dir.pwd` is never consulted by stubbing `Repo.worktrees` to raise on nil).
- `spec/liveness/snapshot_spec.rb`: TTL reuse, single-flight under two threads, budget `partial`, previous snapshot served on raise.
- Store bulk query specs: shapes and that each is one statement (count `db.execute` calls via a spy).
- Token specs: stable across ticks with no change; flips exactly once on a bucket crossing; never contains a digit sequence that looks like an age (regression guard for the rendered-age mistake).
- Data/view specs for `/fleet` ordering and idle folding, `/cockpit` tab param and Changes derivation table, `/global` sort order and worst-lane glyph.
- Phase 3: `n < 2` shows nothing, project fallback at `n >= 5`, amber past 2x, blocked/abandoned excluded.

## Follow-ups (not in this epic)

- **Spike, blocks the transcript adapter:** how to join a lane to a Claude Code session. `claimed_by` carries a PID for Claude lanes but no session id; `~/.claude/projects/<encoded cwd>/` is a worktree bucket holding multiple sessions and `agent-*.jsonl` subagent transcripts. Candidates: `lsof -p <pid>` for the open JSONL, or a lane-dir breadcrumb written by the implement skill. Until a verified join exists, no `waiting` state and no question text.
- Spike each of Codex, Copilot, Gemini for a liveness signal before designing their adapters.
- `tyrion heartbeat` verb and the hybrid fallback (approach 3).
- `tyrion status` using `Tyrion::Liveness` for its lane lines.
- Ambient-style strip (DOM-patched) if a split-pane glance surface is wanted again.
- disc-156: hide/archive old projects on Global View, bring back via search.

## Codex review disposition

| Finding | Disposition |
|---|---|
| `/api/poll` contract misdescribed | Fixed: seeded-token pattern named as Ambient/Discoveries. |
| No Rack::Test specs exist | Fixed: testing section follows Data/view-direct pattern. |
| `primary_repo_identity` nullable/unvalidated | Fixed: resolver states. |
| No story-status event log | Fixed: derivation table; claim events omitted. |
| Global glyph ambiguity | Fixed: worst lane state per project. |
| Lane→worktree not safe | Fixed: resolver with explicit root, single-match rule, four failure states. |
| Transcript attribution unproven | Accepted: adapter removed from v1; replaced by existing `Repo.lane_liveness` process check; attribution is a blocking spike. |
| Token instability | Fixed: bucket-only composition rule, client-side age ticking, stop on non-200. |
| Unbounded poll cost | Fixed: single-flight TTL snapshot, dirty-files-only mtime, subprocess timeouts, wall-clock budget. |
| No bulk-query path | Fixed: five named Store queries. |
| Privacy of transcript text | Fixed: no transcript content in phases 1-3; opt-in only after spike. |
| Activity omits `updated_at` | Fixed. |
| Failure can fake "stalled" | Fixed: evidence marker, `stalled?`. |
| Cut typical-time | Kept as phase 3 (Forrest's stated stretch goal) with the blocked-time limitation documented. |
| Defer cockpit | Kept as phase 2 with explicit derivation and bulk-query contracts, per Forrest's priority order. |
| (pass 2) `dispatched:` lanes missing | Fixed: added to the lane taxonomy with its own state. |
| (pass 2) tokens miss same-bucket signal changes | Fixed: composition rule now fingerprints displayed event timestamps and counts. |
| (pass 2) snapshot handoff over-promised | Fixed: generation wording; render uses same-or-newer snapshot and reseeds the token from it. |
| (pass 2) dirty-path parsing unspecified | Fixed: `-z --untracked-files=all`, rename/delete/stat-fail rules. |
| (pass 2) no phase-2 event queries | Fixed: four epic-scoped capped queries. |
| (pass 2) lifecycle notes double-emitted | Fixed: excluded from the generic note stream by `metadata.action`. |
| (pass 3) fleet token misses same-count edits | Fixed: newest dirty-file mtime added to the fleet token (a file timestamp, not an age). |
