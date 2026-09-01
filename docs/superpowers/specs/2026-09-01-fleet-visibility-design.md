# Fleet Visibility: Global View sort, Fleet board, Epic cockpit

Date: 2026-09-01
Status: draft, brainstormed with Forrest, pending Codex vet

## Problem

Forrest runs many Tyrion projects at once, several with parallel agent lanes (a coordinator plus builder subagents in isolated worktrees). Two visibility failures today:

1. **Global View (`/global`)** sorts by `projects.updated_at` (row touch time, not story activity), has no poller, and the in-motion projects are not on top. He refreshes by hand and scans 14 cards to find the 2 or 3 that matter.
2. **The terminal transcript is the only liveness signal.** A builder subagent ran 38 minutes and there was no way to tell working from stalled or crashed without scrolling a long, still-growing transcript. This is the same "too much stuff, scroll to find it" problem `/session-tabs` was built to solve for Claude Code sessions, and Tyrion has no equivalent.

Priority, in Forrest's order: **(B) is anything stuck or waiting on me** first, then **(A) what changed**, then **(D) what is each lane doing, with signs of being alive**. **(C) how long is left** is the stretch goal.

## Scope

Three deliverables, all in the Tyrion Sinatra web app (`web/`), all reading one new liveness module. No StreamWeaver canvas: these views poll, and canvas-push has no polling.

1. **Global View, minimal change**: keep the look, sort by real activity, add a liveness dot, poll.
2. **`/fleet`, new route**: "what is in motion now" across every project, one row per in-progress story.
3. **`/cockpit`, new route**: the session-tabs analogue, scoped to one epic. Tabs: Now, Changes, Trail.

Out of scope, logged:

- Hiding old/done projects on Global View with archive or search: **disc-156**.
- An ambient-style narrow strip (DOM-patched) for a split pane. Not wanted now; the design keeps the door open.
- `tyrion heartbeat` push verb. Approach 1 (pull on poll) was chosen; heartbeat is the later hybrid upgrade.
- Liveness adapters for Codex, Copilot, Gemini. Each gated on a spike of that harness first (see Follow-ups).

## Decisions made during brainstorm

| Question | Decision |
|---|---|
| Row unit | One row per **in-progress story**, grouped by project. An unclaimed in-progress story (protocol violation) shows as a row with no lane, which is itself an attention item. |
| Liveness sources | Ledger + worktree as the floor (agent-agnostic), plus per-harness adapters when detectable. Claude Code adapter first. |
| Form factor | Board and cockpit in the web app; no strip for now. |
| Cockpit tabs | Now / Changes / Trail. Grows toward session-tabs' six only when a tab has real data. |
| "Since you looked" delta | **Dropped.** Nobody can know when eyes landed on a pane beside a terminal. Changes is a recency feed with running relative timestamps that dim with age. |
| Update mechanism | Reload-on-token-change, the existing `/api/poll` pattern. No JSON row rendering in JS. |
| Liveness thresholds | live < 2m, working < 15m, quiet < 30m, stalled >= 30m. Constants, tunable. |
| Time left | "Typical" from completed-story wall clock in the epic, never criteria velocity. Shown with n. |

## Liveness layer

New module `Tyrion::Liveness` in `lib/tyrion/liveness.rb` (in lib, not web, so `tyrion status` can use it later). Pure functions over injected inputs; every poll recomputes; nothing is written to the DB.

### Inputs per lane

A lane is an in-progress story row (`stories.claimed_by` token, or nil if unclaimed) plus its project.

**Ledger signals** (existing columns, no schema change):

- `stories.started_at`, `stories.claimed_at`
- newest `story_notes.created_at` and its `kind` for the story
- newest `criteria.checked_at` for the story
- newest `gate` note (`metadata.gate`, `metadata.result`) and newest `commit` note (`metadata.shas`)

**Worktree signals**:

- Worktree path resolution: `Repo.worktrees(project['primary_repo_identity'])` lists the repo's worktrees; the one whose `Repo.lane_hashes(path)` includes `Repo.lane_hash(claimed_by)` is the lane's worktree. Same matching `cmd_worktrees` uses (`lib/tyrion/commands.rb` ~1244-1262). `primary_repo_identity` is already the realpath of the main repo root.
- newest mtime among files in the worktree (skip `.git`, `node_modules`, `tmp`, `log`, `vendor`; cap at a file-count budget, report `partial: true` when hit)
- dirty file count (`git status --porcelain | wc -l`)
- newest commit time and subject on the worktree's HEAD (`git log -1 --format=%ct%n%s`)
- path missing or unreadable: all worktree signals nil, `worktree_missing: true`

**Harness signals** via an adapter registry `Tyrion::Liveness::Adapters`. Each adapter implements `detect(lane, worktree_path) -> Hash | nil`. `nil` means "not my lane". Nothing depends on an adapter being present.

First adapter, **Claude Code**:

- Transcript dir: `~/.claude/projects/<worktree path with "/" replaced by "-">/`. Newest `*.jsonl` by mtime is the live session (session ids rotate on `/clear`, mtime does not care).
- `last_activity_at` = that file's mtime.
- `state` from the tail of the file: `working` if the last entry is a tool call or a tool result; `waiting` if the last entry is an assistant turn that ended (or an `AskUserQuestion` tool_use with no result); `ended` if the process is gone and mtime is old. Exact tail heuristics are a spike item; the adapter must return `nil` rather than guess on an unparseable tail.
- Question text for `waiting`: the last assistant text, truncated, so the attention item can say what was asked.
- **Open question (spike before build):** where Agent-tool background subagent transcripts live and whether they are keyed by the subagent's worktree path. If not, builder lanes get worktree signals only from this adapter.

### Derived state per lane

Newest signal across all sources (`newest_at`) drives the ladder:

| State | Rule | Glyph | Attention item? |
|---|---|---|---|
| live | `newest_at` < 2m | green, pulsing | no |
| working | < 15m | green | no |
| quiet | < 30m | amber | no |
| stalled | >= 30m and story still in_progress | red | yes |
| waiting | harness adapter reports `waiting` | hand | yes, regardless of age |
| unclaimed | in_progress with `claimed_by` nil | `?` | yes |
| blocked | story status `blocked` (not a lane, but same pass) | stop sign | yes |

Overrides beat the age ladder: `waiting` and `unclaimed` are decided first.

The row also carries the **newest signal per source** (`edit 40s · commit 6m · note 9m · gate 38m · harness 12m`), not just the winner. This is what separates "busy coding, no notes for 20 minutes" from "nothing at all for 38 minutes".

### Attention items

Produced by the same pass, across the scope (fleet: all projects; cockpit: one epic):

- stalled lanes, waiting lanes, unclaimed in-progress stories, blocked stories, worktree-missing lanes
- ordered by severity (waiting, stalled, worktree missing, unclaimed, blocked) then age descending
- each has: story slug, lane, reason text, age

### Time left ("typical", stretch goal)

Pure function in the same module.

- Sample: stories in the epic with status `done`, `completed_at - started_at` in minutes. Exclude blocked and abandoned. `n` = sample size.
- `typical_minutes` = median of the sample when `n >= 2`; else the project-wide median when that has `n >= 5`; else nil (show nothing).
- Progress band: `remaining_pending_or_in_progress * typical_minutes / max(live_lanes, 1)`, rendered as a rounded range ("about 1h") with `n` visible ("typical 14m per story, n=4").
- Lane row: elapsed since `started_at` against `typical_minutes`. Past 2x typical turns the elapsed figure amber ("alive but slow"), distinct from the stalled state. No attention item in v1.
- RIGOR-tag weighting deferred to v2, only with data behind it.

## Endpoints and views

### Update mechanism

One token endpoint per view, same contract as `GET /api/poll`: JSON `{token}`; the page JS polls, reloads on change, and seeds `data-token` at render time so there is no null-sentinel bootstrap branch. 404 on an unknown project/epic returns the same-shaped body.

- `GET /api/fleet_poll` (15s): token fingerprints every in-progress story's id, status, `claimed_by`, criteria met count, and **liveness bucket** (not raw age, so it flips once on a threshold crossing), plus the attention item list.
- `GET /api/cockpit_poll?project=&epic=` (15s): fleet token restricted to the epic, plus the newest Changes event id.
- `GET /api/global_poll` (60s): per-project status bucket + newest activity time.

Active tab on the cockpit lives in the URL (`?tab=now|changes|trail`) so a reload lands on the same tab. Relative ages are recomputed by the reload.

### Global View (`/global`)

- Sort: newest real activity first, where activity = max of `last_note_at`, newest `criteria.checked_at`, newest story `started_at`/`completed_at`, newest discovery `created_at`. Falls back to `projects.updated_at` only when all are nil.
- Add the liveness glyph next to the in-progress story line on each card (from the lane's derived state). Cards otherwise unchanged; the look Forrest likes stays.
- Poll every 60s, reload on token change.

### Fleet board (`/fleet`)

New route and `Views::Fleet`. Not a War Room extension: War Room is per-project Kanban, the board is cross-project rows.

- Header: `N live · N need you · last poll`.
- **Needs you** band first (attention items across all projects), each linking to its cockpit.
- **Lanes** grouped by project, project header links to the cockpit for that epic. Row = shared `Views::Components::LaneRow` Phlex component: glyph · lane · story · criteria `met/total` · newest-per-source signals · elapsed vs typical.
- Projects with no in-progress story fold into one dim footer line: `Idle: uregistry ✓ · preso-skills · ...` with last-activity age.
- Row sort inside a project: attention weight, then `newest_at` descending.

### Epic cockpit (`/cockpit?project=&epic=`)

New route and `Views::Cockpit`. Honors the existing `?project=&epic=` multi-tab scoping; epic switcher in `:scoped` mode.

- **Now tab**: three bands. Needs you (attention items for this epic) · Lanes (`LaneRow`, same component as `/fleet`) · Progress (done/in progress/blocked/pending segmented bar, typical-time line).
- **Changes tab**: recency feed, newest first, capped at 50 rows, dimming by age band (< 15m full, < 1h dim, older dimmer). Event sources merged by time: criteria checked, story status changes (started/done/blocked/unblocked/reopened), notes by kind (plan, progress, decision, blocker, recovery, handoff, followup, observation, session, test), gate results, commits, marks filed from a story in this epic (`source_story_id`), harness events (waiting/question) when an adapter exists. Each row: age · glyph · text · lane.
- **Trail tab**: the full note timeline for the epic, no cap, no poll. Existing data, existing rendering where possible.

### Shared pieces

- `TyrionWeb::Data.load_fleet_view`, `load_cockpit_view`, and the extended `load_global_view` all call `Tyrion::Liveness` once per request; no per-row queries.
- `Views::Components::LaneRow` is the single lane rendering; `/fleet` and `/cockpit` cannot drift.
- `TyrionWeb::Presenter` gets `liveness_glyph(state)` and `age_band_css(seconds)`.

## Error handling

Every source degrades to unknown, never to a crash and never to a false "alive":

- Worktree path missing/unreadable: signals nil, `worktree_missing` attention item.
- Adapter transcript missing or tail unparseable: adapter returns nil; lane shows ledger + worktree only; a malformed last line is skipped.
- Worktree scan over budget: `partial: true`, newest mtime so far is still used.
- Future timestamps / clock skew: age clamps to 0.
- Unknown project/epic on any poll endpoint: 404, same-shaped body.
- `git` not on PATH or repo gone: worktree signals nil, no exception escapes the module.

## Testing

- `spec/liveness_spec.rb`: pure inputs. Each ladder state, each override, newest-per-source selection, missing worktree, scan budget, clock skew. Worktree cases use the existing `tyrion_worktree` helper.
- `spec/liveness/claude_code_adapter_spec.rb`: one fixture transcript per state (working, waiting, ended) plus a malformed-tail fixture.
- Time-left: `n < 2` shows nothing, project fallback at `n >= 5`, amber past 2x typical, blocked/abandoned excluded.
- Token specs: stable across ticks with no change, flips exactly once on a bucket crossing.
- Route specs (rack-test, as existing web specs): `/fleet` attention ordering and idle folding, `/cockpit` tab param and Changes cap, `/global` sort order.

## Follow-ups (not in this epic)

- Spike: Claude Code subagent transcript location and tail heuristics (blocks the adapter design).
- Spike each of Codex, Copilot, Gemini for a liveness signal before designing their adapters (per Forrest's rule: verify every target environment before finalizing).
- `tyrion heartbeat` verb and the hybrid fallback (approach 3).
- `tyrion status` using `Tyrion::Liveness` for its lane lines.
- Ambient-style strip (DOM-patched) if a split-pane glance surface is wanted again.
- disc-156: hide/archive old projects on Global View, bring back via search.
