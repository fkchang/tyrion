# Fleet Visibility — Epic Context

Read this before touching any story in this epic. Every fact below was verified against
the tree at shaping time. If a line number has drifted, fix it here in the same commit as
your story, then keep going — do not re-derive what is already recorded.

## 1. Origin

Brainstormed 2026-09-01. Forrest runs many Tyrion projects at once, several with parallel
agent lanes (a coordinator plus builder subagents in isolated worktrees). Two failures
drove this: Global View sorts by `projects.updated_at` (row touch time, not story
activity) and has no poller, so the in-motion projects are not on top; and the terminal
transcript is the only liveness signal, so a builder that ran 38 minutes could not be told
apart from a stalled or crashed one without scrolling a still-growing transcript. Priority
order is Forrest's: what is stuck or waiting on me, then what changed, then what each lane
is doing with signs of being alive, with time-left as the stretch. The spec is
`docs/superpowers/specs/2026-09-01-fleet-visibility-design.md`, at revision 3 after three
adversarial Codex passes recorded in
`docs/superpowers/specs/2026-09-01-fleet-visibility-codex-review.md`. Read the spec for
the full design; this file carries only what a builder needs that the spec does not say.

## 2. Verified facts, with file:line

Verified 2026-09-01 against the working tree. Several of these differ from the line
numbers quoted in the spec and the Codex review, which had drifted; the numbers here are
the corrected ones.

### Liveness and lane identity

- `Repo.lane_liveness(token)` — `lib/tyrion/repo.rb:173-177`. Spec says ~137-176; drifted.
  Returns `:live`, `:dead`, `:unknown`. Its helper `Repo.pid_alive?(pid, stamp)` is at
  `repo.rb:164-169` and checks the start stamp against PID reuse.
- `Commands.derive_lane_token` — `lib/tyrion/commands.rb:4378-4406`, `private_class_method`
  at `:4407`. This is the taxonomy source for `claimed_by`. Memoized read at `:4259`.
- `Store#dispatch_story` — `lib/tyrion/store.rb:717-742`. Spec says ~714-728; drifted.
  Writes `claimed_by = "dispatched:#{label}"` at `:725` and also inserts a `progress` note
  at `:731-734`, which matters for the Changes feed.
- `Repo.identity(path = Dir.pwd)` — `repo.rb:16`. Note the cwd default in the signature.
- `Repo.lane_hash(token)` — `repo.rb:54`. `Repo.lane_hashes(root = nil)` — `repo.rb:68`,
  also cwd-defaulted, reads directory names under `<root>/.tyrion/lanes` (`repo.rb:62,70`).
- `Repo.worktrees(path = nil)` — `repo.rb:248`, cwd-defaulted; raw porcelain seam at
  `repo.rb:238-242`, parsed into `[{path:, branch:, head:}]` at `repo.rb:246`.
- Existing porcelain record counter — `repo.rb:271`. It only counts lines. The `-z` path
  listing this epic needs is new; a second `git status` call site is at `repo.rb:294`.

### Store schema and query surface

- `projects.primary_repo_identity` — column at `store.rb:32`, index at `:39`. Nullable.
  Looked up by `find_project_by_repo_identity` at `store.rb:182`.
- `story_notes.kind` CHECK — `store.rb:109`, 12 values:
  `plan progress decision blocker test handoff recovery session followup observation gate commit`.
  Migration history is at `store.rb:1843`, `:1872`, `:1895`, `:2011`.
- `Commands::VALID_NOTE_KINDS` — `commands.rb:2330`, 10 values. `gate` and `commit` are
  deliberately excluded from the general `tyrion note` command; `:2343` rejects them.
- Lifecycle `metadata.action` writers: block at `commands.rb:1529`, unblock at `:1557`,
  reopen at `:1590`. These are the rows the generic note stream must exclude.
- Story-scoped APIs that do NOT scale to an epic feed: `notes_for_story` at `store.rb:820`,
  `gate_notes_for_story` at `:831`, `criteria_for_story` at `:1112`.
- `in_progress_story(epic_id)` at `store.rb:666` deliberately returns one story and hides
  sibling lanes; `in_progress_story_for(epic_id, token)` at `:685` is the lane-scoped form.

### Web app

- `TyrionWeb::Data.load_global_view` — `web/lib/tyrion_web/data.rb:133-179`. Spec says
  133-175; drifted. This is the N+1 over projects, epics, stories and discovery summaries.
- The cwd trap: `TyrionWeb::Data.repo_root` — `data.rb:34-36`, returns
  `ENV['TYRION_REPO_ROOT']` or `Dir.pwd`. The web process runs from `web/`. Never use this
  for cross-project git work.
- Binding — `web/app.rb:22` sets `0.0.0.0`, `:25` disables protection, `:26` clears
  `permitted_hosts`. No auth. This is the privacy boundary: no transcript or prompt
  content in any phase of this epic.
- Existing pollers, all in `web/app.rb`: `/api/discoveries_poll` at `:174`,
  `/api/ambient_poll` at `:232`, `/api/poll` at `:286`. There is no `/api/global_poll` and
  no War Room poller. Copy the seeded-token pattern from Discoveries and Ambient, never
  Active Story's `knownToken = null` bootstrap.

### Specs

- `spec/ambient_poll_spec.rb` (172 lines) is the pattern to follow. It requires
  `spec_helper`, `phlex`, then globs `web/lib/tyrion_web/*.rb` and `web/views/*.rb`
  directly (`:3-6`) and unit-tests token functions and rendered HTML. There is no
  Rack::Test harness in this repo and no route specs. Do not invent one; test `Data` and
  view classes directly.
- Sibling examples worth reading: `spec/discoveries_poll_spec.rb`,
  `spec/global_view_data_spec.rb`, `spec/war_room_data_spec.rb`.

## 3. Gotchas already paid for

Each of these cost an adversarial review pass. Do not rediscover them.

1. **The cwd trap.** `Repo.identity`, `Repo.lane_hashes`, `Repo.worktrees` and
   `Data.repo_root` all default to `Dir.pwd`, and the web process runs from `web/`. Every
   cross-project git call must receive an explicit, validated project root. The resolver
   spec asserts this by stubbing `Repo.worktrees` to raise when called with nil.
2. **PID tokens versus label tokens.** `claimed_by` may be an explicit `TYRION_LANE` label,
   a Codex `<label>:<thread_id>`, a Claude `<label>:<pid>:<16-hex-stamp>`, a
   `dispatched:<label>` placeholder, or nil. Only the Claude form is probeable. "Process
   gone" is undefined for the others and `lane_liveness` returns `:unknown` for them by
   design. `:unknown` must never be rendered or treated as dead.
3. **Tokens must not contain ages.** Hashing a rendered age reloads the page every poll.
   Fingerprint canonical ids, counts, discrete buckets and event timestamps only, stably
   ordered. The converse trap is equally real: a token that changes only on a new event id
   never reloads at the 15m/1h dimming boundaries, so ages tick client-side from `data-at`
   attributes instead. Ambient already does exactly this outside its token branch.
4. **Lifecycle notes double-emit.** `tyrion block`, `unblock` and `reopen` persist real
   `blocker` and `recovery` notes carrying `metadata.action`. The Changes derivation emits
   those lifecycle events from the action metadata, so the generic note stream must exclude
   the same rows or every block and reopen appears twice.
5. **Dirty-path parsing.** Use `git status --porcelain -z --untracked-files=all` and parse
   NUL-delimited records. Rename and copy records carry two NUL-separated paths, so consume
   the destination. Skip deletions and any path whose stat fails; they are not errors. The
   existing helper at `repo.rb:271` only counts lines and cannot be reused for this.
6. **Snapshot generation handoff.** `Snapshot.current` plus a mutex cannot promise that a
   page render reuses the exact snapshot that answered the poll, because the TTL may expire
   between the two requests. The honest contract is same-or-newer generation, with the page
   reseeding its `data-token` from the snapshot it actually rendered from.
7. **Failure must not fake "stalled".** When worktree signals are nil the row shows
   `ledger only` and a stalled state renders as `stalled?`. Absence of evidence is not
   evidence of absence, and this board is worthless the first time it lies about a lane.

## 4. Lane plan

Four lanes. **Lanes run serially: B starts after A merges, C after B, D after C.** Each
lane is ONE builder session in the main checkout, not one subagent per story, so the
builder stays warm across the lane's stories instead of re-reading this file three times.

| Lane | Stories | Phase | Depends on |
|---|---|---|---|
| A | store-bulk-liveness-queries, worktree-resolver-and-probe, liveness-ladder-and-attention, liveness-snapshot-cache | 1 | nothing |
| B | global-view-activity-sort, fleet-board | 1 | A merged |
| C | epic-event-queries, cockpit-now-tab, cockpit-changes-trail-tabs | 2 | B merged |
| D | typical-time-left | 3 | C merged |

Lane A is the whole liveness layer and is entirely strict: it is the thing every other lane
reads. Lanes B, C and D are loose because their failures are visible on a page rather than
silent in a derived state. Browser-observable criteria are prefixed `UAT:` in the feature
file; builders leave those unchecked with a handoff note, and the conduct coordinator runs
those gates personally.

## 5. Prior art: the `live-lanes-board` epic

There is an older epic, `live-lanes-board`, shaped 2026-07-07 from an Orca recon. Both its
stories, `lanes-query` and `lanes-board-panel`, are marked done in the ledger, and its
`features/live-lanes-board.feature` describes `Store#active_lanes` and a `GET /lanes`
board. Neither exists in the code today.

**What happened: the work was built but never merged.** It lives on the unmerged branch
`fkchang/live-lanes-board`, whose head is `dbb796d` (2026-07-08). The relevant commits are
`b06c6de` "feat(store): add Store#active_lanes fleet-wide read query" (+24 lines in
`lib/tyrion/store.rb`, +96 in `spec/store_spec.rb`), `a3fda0c` "feat(store): expose active
lanes", and `45f5adb` "feat(web): add live lanes board" (+199 lines across `web/app.rb`,
`web/views/lanes.rb`, `web/lib/tyrion_web/data.rb`, `web/lib/tyrion_web/presenter.rb`,
`web/views/layout.rb`, `spec/web/lanes_spec.rb`). `git merge-base --is-ancestor 45f5adb
main` is false and `main:web/views/lanes.rb` does not exist. So this is an orphaned branch,
not a build-then-remove and not a supersession: War Room's lane visibility landed
separately on main the same day (`9cc1c19`, 2026-07-08, "feat(cli+web): multi-lane
in_progress queries + lane visibility").

Two consequences for this epic. First, `git show 45f5adb` and `git show b06c6de` are worth
reading before writing the fleet board: there is a working prior implementation of the
stalled-lane flag, the heartbeat-with-fallback query and the board view, even though this
epic's design supersedes it with the snapshot and resolver layer. Second, this is a live
example of the ledger claiming done for work that never reached main, which is exactly the
kind of thing the fleet board is being built to make visible. **Do not modify the
`live-lanes-board` epic or its branch as part of this work.**

## 6. Per-story plan payload

This section carries what `/tyrion-shape` Step 5b would normally bake into a `[plan]` note
per story. It lives here instead because the claim gate (`hooks/claim-gate.sh`, wired at
`.claude/settings.json:9`) blocks `tyrion note <slug> plan` on a *pending* story from a
lane holding no in-progress story, which is exactly the shaping situation. That conflict is
already tracked as **disc-009**, whose recorded workaround is precisely this: keep the
payload in the feature file's `RIGOR:` comments and the epic context sidecar. This is its
third recurrence (previously on `prime-and-setup` and `dark-factory-mode`).

Builders: read your story's block here at claim time. Once you have run `tyrion start
<slug>` the gate opens, so you may copy your block into a real `[plan]` note then if you
want it in `tyrion resume` output.

### store-bulk-liveness-queries — RIGOR: strict · LANE: A · PHASE: 1
Add five bulk read methods to `Store`, each exactly one SQL statement, keyed by story id,
replacing the per-row fan-out the fleet would otherwise need.
`in_progress_stories_across_projects` joins stories to epics and projects and also returns
blocked rows for the attention pass. The other four take `story_ids` or project scope and
return newest-per-story values via a window function or a MAX group. Prove single-statement
with a spy counting `db.execute` calls, and short-circuit an empty `story_ids` list without
issuing SQL.
Files: `lib/tyrion/store.rb`, `spec/store_spec.rb`.

### worktree-resolver-and-probe — RIGOR: strict · LANE: A · PHASE: 1
New `Tyrion::Liveness::WorktreeResolver` builds `lane_hash -> [worktree paths]` once per
snapshot per canonical repo, rooted at `projects.primary_repo_identity` and never at
`Dir.pwd`. Exactly one match resolves; zero is `missing`, two or more is `ambiguous` with no
silent pick; nil identity is `identity_missing` and a bad path is `repo_missing`. Dirty
signals parse `git status --porcelain -z --untracked-files=all` NUL-delimited, consuming
rename destinations and skipping deletions and stat failures. Every subprocess runs under a
2s `Open3` + `Timeout`, degrading to nil signals with `partial: true`.
Files: `lib/tyrion/liveness/worktree_resolver.rb` (new), `lib/tyrion/repo.rb`,
`spec/liveness/worktree_resolver_spec.rb` (new).

### liveness-ladder-and-attention — RIGOR: strict · LANE: A · PHASE: 1
Pure functions in `Tyrion::Liveness` over an injected snapshot, no DB writes. Apply the
overrides first (dead, unclaimed, worktree missing or ambiguous, blocked), then the age
ladder over `newest_at` at 2m / 15m / 30m. Keep the newest signal per source on the row, not
just the winner. When worktree signals are nil, show the `ledger only` evidence marker and
render stalled as `stalled?`. Attention items sort by severity then age descending and carry
the timestamp the reason is measured from; clock skew clamps age to zero.
Files: `lib/tyrion/liveness.rb` (new), `spec/liveness_spec.rb` (new).

### liveness-snapshot-cache — RIGOR: strict · LANE: A · PHASE: 1
`Tyrion::Liveness::Snapshot.current(store, ttl: 10)` is the single process-wide entry point
for every page render and poll endpoint. A mutex makes it single-flight so concurrent
callers wait for the in-progress build rather than starting another; each build carries a
monotonically increasing `generation`. Cap the whole worktree pass at a 3s wall-clock budget
with `partial: true` for unreached repos, and serve the previous snapshot with `stale: true`
when a build raises, falling back to a ledger-only snapshot on a first-build failure.
Files: `lib/tyrion/liveness/snapshot.rb` (new), `spec/liveness/snapshot_spec.rb` (new).

### global-view-activity-sort — RIGOR: loose · LANE: B · PHASE: 1
Replace the activity and lane parts of `load_global_view` (`data.rb:133-179`, the N+1) with
`project_activity` and the snapshot, leaving the rest of the card as is. Sort by the
activity maximum descending, falling back to `projects.updated_at` only when nil. Derive the
card glyph as the worst lane state across every in-progress story in the project. Add the
new `GET /api/global_poll` route with a bucket-only token in sort order, and a 60s seeded
poller on the page.
Files: `web/lib/tyrion_web/data.rb`, `web/app.rb`, `web/views/global_view.rb`,
`web/lib/tyrion_web/presenter.rb`, `spec/global_view_data_spec.rb`.

### fleet-board — RIGOR: loose · LANE: B · PHASE: 1
New `GET /fleet` route and `Views::Fleet`, plus the shared
`Views::Components::LaneRow` both this and the cockpit render. Needs-you band first, then
lanes grouped by project, then idle projects folded into one dim footer line. Add
`GET /api/fleet_poll` whose token carries per-story identity, liveness and resolution state
plus the newest-per-source event timestamps, newest commit sha, dirty count and newest
dirty-file mtime, and never a rendered age. 15s seeded poller, client-side age ticking,
stop on non-200.
Files: `web/app.rb`, `web/views/fleet.rb` (new), `web/views/components/lane_row.rb` (new),
`web/lib/tyrion_web/data.rb`, `web/lib/tyrion_web/presenter.rb`, `web/views/layout.rb`,
`spec/fleet_data_spec.rb` (new).

### epic-event-queries — RIGOR: loose · LANE: C · PHASE: 2
Four epic-scoped capped queries (`epic_notes_recent`, `epic_criteria_checked_recent`,
`epic_story_lifecycle`, `epic_marks_recent`) plus the Ruby merge that implements the
derivation table. The load-bearing detail is excluding rows whose `metadata.action` is
block, unblock or reopen from the generic note stream, since those commands persist real
blocker and recovery notes (`commands.rb:1529`, `:1557`, `:1590`) and would otherwise emit
every lifecycle event twice. Claim events are omitted entirely.
Files: `lib/tyrion/store.rb`, `lib/tyrion/liveness.rb`, `spec/store_spec.rb`,
`spec/liveness_events_spec.rb` (new).

### cockpit-now-tab — RIGOR: loose · LANE: C · PHASE: 2
New `GET /cockpit?project=&epic=` route and `Views::Cockpit`, honoring both params for
multi-tab scoping and rendering the epic switcher in `:scoped` mode. The Now tab reuses
`Views::Components::LaneRow` from lane B. Tab state lives in `?tab=`, defaulting to `now`
for an absent or unrecognized value. Add `GET /api/cockpit_poll` returning the fleet token
restricted to the epic plus the newest Changes event key and status counts, 404 with a null
token for an unknown project or epic.
Files: `web/app.rb`, `web/views/cockpit.rb` (new), `web/lib/tyrion_web/data.rb`,
`web/views/layout.rb`, `spec/cockpit_data_spec.rb` (new).

### cockpit-changes-trail-tabs — RIGOR: loose · LANE: C · PHASE: 2
Render the Changes feed from lane C's merged events, newest first and capped at 50, dimmed
by age band via a new `Presenter.age_band_css`, with ages ticking client-side from `data-at`
so a dimming boundary does not need a token change. Lane-dead events come from an in-memory
snapshot transition and are never persisted. Trail renders the existing full epic note
timeline with no cap and no poller.
Files: `web/views/cockpit.rb`, `web/lib/tyrion_web/presenter.rb`,
`web/lib/tyrion_web/data.rb`, `spec/cockpit_changes_spec.rb` (new).

### typical-time-left — RIGOR: loose · LANE: D · PHASE: 3
Median of `completed_at - started_at` over done stories only, excluding blocked and
abandoned. Median when `n >= 2`, else the project-wide median when that `n >= 5`, else nil
and render nothing at all. Progress band is `remaining * typical / max(live_lanes, 1)`,
rounded, annotated with typical-per-story and `n`. Lane rows show elapsed against typical and
turn amber past 2x with no attention item. State the blocked-time limitation wherever the
figure appears.
Files: `lib/tyrion/liveness.rb`, `web/views/cockpit.rb`, `web/views/fleet.rb`,
`web/views/components/lane_row.rb`, `spec/typical_time_spec.rb` (new).

## 7. Measurement (pareto rigor)

Builders fill their own row when the lane closes. Rediscoveries means facts a builder had
to re-derive that should have been in this file; a nonzero count is a bug in this file, not
in the builder.

| Lane | Builder tier | Wall-clock | Rediscoveries | Notes |
|---|---|---|---|---|
| A |  |  |  |  |
| B |  |  |  |  |
| C |  |  |  |  |
| D |  |  |  |  |

**Every builder appends what they learned under the `## Learnings` heading below**, and
corrects any drifted file:line above in the same commit as the story that found it.

## Learnings
