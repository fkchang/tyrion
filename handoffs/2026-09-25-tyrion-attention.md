# Handoff: `tyrion attention` — what needs Forrest's attention, Tyrion-wise

**Status:** done, committed to main.
**Consumer:** cultiv-ai's `bin/gea-triage` (StreamWeaver canvas board), joins by pid via
`lanes[].pid` against `bin/fleet-pulse --json`.

## What shipped

- **Fold**: `lib/tyrion/attention.rb`, `Tyrion::Attention` — `gather(store)` (DB reads only,
  one `Store#epic_graph` + one `Store#stories_for_epic` per project) and `build(gathered,
  snapshot_rows:, now:, stale_days:, project_slug:)` (pure — no DB, no git, no clock of its
  own). Never computed twice: the CLI and the web view both call `build` over the identical
  `gather` + the identical `Tyrion::Liveness::Snapshot.current(store)['rows']`.
- **CLI**: `tyrion attention [--json] [--stale-days N] [--project <slug>]`. Read-only,
  cross-project by construction — does **not** call `resolve_project`, so it works from any
  cwd including one with no active project. `--project` validates the slug and `die`s on an
  unknown one.
- **Web**: `GET /attention` (+ `GET /api/attention_poll`), a new nav tab (🔔 Attention) next to
  Fleet/Global View, unscoped like those two (`?project=` narrows the fold itself, not just
  the sidebar). Reload-on-token-change poller, same pattern as Fleet/Global/Discoveries.
- **Specs**: `spec/attention_spec.rb` (20 examples, pure fold), `spec/commands/attention_spec.rb`
  (9 examples, CLI incl. `--json`, `--stale-days`, `--project`, cross-cwd), `spec/
  attention_data_spec.rb` (5 examples, web data loader + poll token + render). Full suite:
  **1669 examples, 0 failures** after this change.
- **Docs**: `CLAUDE.md` (new "Attention layer" section under Architecture), `AGENTS.md` +
  `docs/for_llms.md` quick command references, `tyrion help` usage text.

## The JSON contract (as shipped)

```json
{
  "generated_at": "2026-09-25T22:22:59Z",
  "stale_days": 7,
  "summary": { "stalled": 8, "waiting": 5, "fine": 37 },
  "epics": [
    {
      "project_slug": "tyrion", "epic_slug": "tyrion-polish",
      "epic_name": "Tyrion Polish — Epic Seal + LLM Architecture Wiki",
      "mode": "shape", "status": "active", "category": "stalled",
      "counts": { "done": 1, "pending": 1, "in_progress": 0, "blocked": 0, "total": 2 },
      "last_activity_at": "2026-06-30T19:03:12Z", "idle_days": 87,
      "waiting_reasons": [],
      "current_story": { "slug": "wiki-llm-architecture", "title": "wiki-llm-architecture", "next_action": null },
      "lanes": [],
      "suggested_commands": [
        "tyrion epic activate tyrion-polish && tyrion resume wiki-llm-architecture",
        "tyrion epic pause tyrion-polish",
        "tyrion epic archive tyrion-polish"
      ]
    }
  ]
}
```

`epics` is `stalled` epics first (sorted `dark_factory` mode before `shape`, then longest-idle
first), then `waiting` epics (longest-idle first). Everything else — unstarted, fully done, or
recently active — is only reflected in `summary.fine`'s count, never listed.

A lane example (from the live run — a dead pid, still worth showing since `live: false` is a
real, correct answer, not an error):

```json
{
  "token": "claude:34720:9d72169847022595",
  "pid": 34720,
  "live": false,
  "story_slug": "shape-seeds-org-context",
  "worktree_path": "/Users/fkchang/work/tyrion"
}
```

## Live sample against the real DB (2026-09-25, `~/.tyrion/tyrion.db`)

Ran for real, not a spec fixture: **8 stalled, 5 waiting, 37 fine** across every project
(`tyrion`, `position-monitor`, `multi-actor-utf`, `preso-skills`, `institutional-dashboard`,
`stream-weaver`, and others). Oldest stalled epic: `tyrion-polish` at 87 idle days. The `tyrion
epic-context` epic surfaced a real dead lane (`claude:34720`, `live: false`) — the exact
signal gea-triage needs to tell "someone's mid-story but the session died" apart from "someone's
mid-story and still there."

Human CLI output and the full JSON are reproducible any time with:
```bash
ruby bin/tyrion attention          # human table
ruby bin/tyrion attention --json   # the contract above
```

## Decisions made (asked nobody, noted here per the brief)

1. **`waiting` always outranks `stalled`.** A paused epic, or one with a blocked story, is
   never also reported as stalled even if it's also idle/partial — it's a decision someone
   already made, not a mystery. Pinned by spec (`spec/attention_spec.rb`, "waiting always wins
   over stalled").
2. **Threshold is strictly "longer than," not "at least."** An epic idle for *exactly*
   `stale_days * 86400` seconds does not yet qualify; one second past does. Matches the story's
   own wording ("no activity for longer than the threshold").
3. **`in_progress` counts toward "partial" exactly like `pending`.** "done > 0 AND (pending +
   in_progress) > 0" — an epic with one story done and one still in_progress (but idle) is just
   as much "partially complete and stuck" as one with a pending story.
4. **Lane pid parsing is narrower than `Repo.parse_lane_pid_token`.** The story named
   `Repo.agent_pid` for "use Tyrion's existing liveness code" — that method walks the *current*
   process's own ancestry to find an agent binary, which doesn't apply to probing an arbitrary
   *other* lane's token. What actually fits is `Repo.lane_liveness`/the tri-state process probe
   already wired into every `Liveness::Snapshot` row (`row['signals']['process']`). I reused
   that for `lanes[].live` rather than re-probing. For `pid`, I wrote a narrower one-off regex
   (`Attention::CLAUDE_LANE_TOKEN`, `/\Aclaude:(\d+):/`) instead of reusing
   `Repo.parse_lane_pid_token`, because that helper accepts *any* `label:pid:stamp` shape and
   the story is explicit that only `claude:<pid>:<stamp>` should report a pid — a codex thread
   token or a `dispatched:` placeholder must report `pid: nil`, not a guess.
5. **`current_story` selection**: the most-recently-active `in_progress` story if any, else the
   earliest-`sequence` `pending` story (what to pick up next). Not specified in the brief;
   this is the interpretation that makes `suggested_commands`' `tyrion resume <slug>` always
   point somewhere useful.
6. **`suggested_commands` are plain strings, never executed.** Stalled: resume the current
   story (+ `tyrion unclaim <slug>` when it's actually `in_progress`), then `epic pause`/`epic
   archive` as the two "reset" options. Waiting: `epic activate` (+ `resume <slug>` when there's
   a live current story) — checking status, not resetting, since waiting is already a decision.
7. **Web poller added even though not explicitly asked for** — `GET /api/attention_poll`,
   15s interval, reload-on-token-change, matching Fleet/Global's existing convention rather than
   shipping a static page inconsistent with the rest of the board. `TyrionWeb::Data.
   attention_poll_token` fingerprints only what the page renders (never a rendered age).

## Known gaps (tracked, not blocking)

- No spike/discovery-layer attention signal (e.g. an `active_spike` with no findings for weeks)
  — out of scope per the brief, which is epic-status-shaped only.
- The poll-badge markup/JS is now duplicated across **seven** view files (documented in
  `CLAUDE.md`'s existing "Known gap" note, updated in this change) — still worth a shared
  component, not done here.
- `waiting_reasons` for a paused epic is just the literal string `"paused"` with no timestamp of
  *when* it was paused (no `paused_at` column exists) — same class of imprecision `CLAUDE.md`
  already documents for `blocked_on`'s missing `blocked_at`.
