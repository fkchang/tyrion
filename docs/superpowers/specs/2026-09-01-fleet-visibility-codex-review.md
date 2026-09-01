# Fleet Visibility design: adversarial Codex review

## 1. Factual errors

1. **The proposed poll contract does not match `GET /api/poll`.** The design says the existing pattern returns `{token}` and seeds `data-token`. In fact, `/api/poll` returns `token`, `slug`, `status`, `met`, and `total` (`web/app.rb:286-298`), while Active Story initializes `knownToken = null` and bootstraps it on the first poll (`web/views/active_story.rb:391-419`). The seeded-token pattern belongs to Ambient/Discoveries, not Active Story.

2. **There are no existing Rack::Test route specs to copy.** The cited “existing web specs” load Data and view classes directly (`spec/ambient_poll_spec.rb:3-6`), then unit-test token functions and rendered HTML (`spec/ambient_poll_spec.rb:16-21`, `spec/ambient_poll_spec.rb:111-169`). They do not issue requests to Sinatra. The build needs either a real request-test harness or accurately scoped Data/view specs.

3. **`primary_repo_identity` is not guaranteed to be a usable main-worktree path.** The column is nullable (`lib/tyrion/store.rb:27-39`), and `Repo.identity` returns nil outside a Git repo (`lib/tyrion/repo.rb:14-23`). It is derived from the realpath of Git's common directory with a textual `/.git` suffix removed, not validated as an existing Tyrion worktree. The spec treats it as unconditionally present and usable.

4. **A complete story-status event feed does not exist.** Stories store only current status plus timestamps (`lib/tyrion/store.rb:60-83`). A normal claim/start merely updates the story row and emits no event note (`lib/tyrion/store.rb:1655-1664`). Completion adds an unstructured handoff note (`lib/tyrion/store.rb:1051-1059`). Block/unblock/reopen do have action metadata (`lib/tyrion/commands.rb:1524-1530`, `1549-1558`, `1586-1591`), but that cannot reconstruct all the promised started/done/blocked/unblocked/reopened events reliably.

5. **Global View cannot currently attach one unambiguous lane glyph to its displayed story.** It counts in-progress stories across all epics but selects only the first in-progress story from the resolved active epic (`web/lib/tyrion_web/data.rb:133-174`); `in_progress_story` itself deliberately hides sibling lanes (`lib/tyrion/store.rb:663-667`). The spec does not say whether the card should show the worst lane, newest lane, every lane, or only this legacy-selected row.

## 2. Design gaps and risks

### Critical

1. **Lane-to-worktree mapping is not a safe invariant.** The web defaults its repo root to `Dir.pwd` (`web/lib/tyrion_web/data.rb:34-36`), and the app is launched from `web/`; therefore every cross-project Git call must receive an explicit, validated project root and must never silently fall back to cwd. More importantly, `Repo.lane_hashes` only reports persistent directory names (`lib/tyrion/repo.rb:65-74`). It provides no freshness or ownership record, so a token hash can be stale or appear in multiple worktrees. `cmd_worktrees` tolerates that ambiguity and will render the lane under every match (`lib/tyrion/commands.rb:1252-1265`). Define a resolver that scans each unique canonical repo once, builds `lane_hash -> [worktree paths]`, accepts exactly one match, and reports distinct `missing`, `ambiguous`, `repo_missing`, and `identity_missing` states.

2. **The Claude transcript lookup cannot attribute a transcript to a lane.** `claimed_by` is an explicit label, Codex thread token, or Claude PID/start-stamp token (`lib/tyrion/commands.rb:4378-4405`); it contains no Claude session id. `~/.claude/projects/<encoded cwd>` is only a worktree bucket. Choosing its newest JSONL can select another tab, a coordinator, a prior session, or an `agent-*.jsonl` subagent, falsely marking the story live or waiting. “Process gone” is also undefined for non-PID tokens; the existing API intentionally returns `unknown` for them (`lib/tyrion/repo.rb:137-176`). The spec simultaneously promises the adapter and calls its key association question a later spike. Make that spike a prerequisite and require a verified join key; otherwise omit harness state from v1. Never display transcript text until attribution is trustworthy.

3. **Token stability is underspecified and internally contradictory.** Attention items contain a continuously changing `age`, yet the fleet token includes “the attention item list.” Hashing rendered ages will reload every poll. Hash only canonical fields and discrete bucket identifiers with stable ordering. Conversely, Changes says relative times “run” and dim by age, but its token changes only for a new event id; with no new event, the page never reloads at the 15m/1h boundaries. Either update ages client-side (as Ambient explicitly does outside its token branch, `spec/ambient_poll_spec.rb:157-165`) or include discrete Changes age bands. Specify 404 handling too: a nil/error token must not cause an infinite reload loop.

### High

4. **The polling cost is unbounded and multiplicative.** Every 15 seconds, every browser can trigger, across every project, `git worktree list`, recursive file traversal, `git status`, and `git log`; lanes sharing a worktree can repeat the same work. A changed token then causes a page render that computes it all again, while Global and Cockpit pollers may overlap. A file-count cap does not bound slow filesystem or subprocess time. Require per-request deduplication by repo/worktree, a short server-side TTL/single-flight cache shared across endpoints and clients, subprocess timeouts, a wall-clock scan budget, and metrics. Prefer one worktree snapshot reused by all lanes.

5. **“No per-row queries” has no implementation path.** Existing Global View is N+1 over projects, epics, stories, and discovery summaries (`web/lib/tyrion_web/data.rb:133-175`), and criteria/notes APIs are story-scoped (`lib/tyrion/store.rb:820-837`, `1112-1113`). The spec must name bulk Store queries and their result shapes before promising one liveness call.

6. **Transcript content creates a privacy boundary the design ignores.** The server binds `0.0.0.0`, disables protection, and has no authentication (`web/app.rb:21-28`). Rendering “last assistant text” can expose prompt or repository content to the LAN. Require localhost binding/authentication or make transcript text opt-in and redacted; liveness must not depend on exposing content.

### Medium

7. **Activity semantics omit real edits.** Context and next-action updates change only `stories.updated_at` (`lib/tyrion/store.rb:913-924`), but Global's proposed activity maximum excludes it. Discovery edits likewise deserve `updated_at`, not only `created_at`. Define “activity” once and use it for sorting and tokens.

8. **Failure semantics can produce false “stalled.”** “Every source degrades to unknown” conflicts with deriving `stalled` from an old ledger timestamp when worktree/harness inspection failed. Unknown evidence must be visible and must not be presented as proof of inactivity.

## 3. Over-engineering

- Cut the Claude adapter from v1 until the attribution spike proves a lane/session join.
- Cut recursive newest-file mtime scanning; ledger timestamps plus one deduplicated `git status`/HEAD snapshot are a safer v1 floor.
- Defer “typical time left.” Blocked time cannot be excluded from `completed_at - started_at` with the present schema, and the concurrency formula is too weak to justify operational guidance.
- Defer the full Changes merger and uncapped Trail tab. Start with Global sorting/polling and a Fleet board using existing ledger facts; add Cockpit only after lifecycle events and bulk queries have explicit contracts.

## 4. Verdict

**NEEDS_REVISION**

Top three required changes:

1. Specify and test an explicit, ambiguity-detecting `project identity -> worktrees -> lane hash` resolver that never depends on the web process cwd.
2. Make Claude transcript attribution a blocking spike with a verified lane/session key, or remove harness-derived `waiting`, `ended`, and question text from v1.
3. Define canonical bucket-only poll tokens and a bounded, shared snapshot/cache model so time transitions occur once without rescanning every repo per client every 15 seconds.

## Second pass (revision 2)

### Required changes

1. **ADDRESSED** — The WorktreeResolver now uses the explicit nullable project identity, scans worktrees from that root, accepts exactly one lane-hash match, and distinguishes `missing`, `ambiguous`, `repo_missing`, and `identity_missing`, with focused tests specified.
2. **ADDRESSED** — Transcript-derived waiting/question state is removed from phases 1–3; attribution is now a blocking spike, while the existing tri-state process probe is described consistently with `Repo.lane_liveness` (`lib/tyrion/repo.rb:137-176`).
3. **ADDRESSED** — Stable bucket tokens, client-side aging, non-200 polling shutdown, a process-wide single-flight TTL snapshot, subprocess timeouts, and a whole-pass budget are now explicit.

### New factual errors and gaps

- The `claimed_by` taxonomy is incomplete. An in-progress dispatched story carries `dispatched:<label>` until adoption (`lib/tyrion/store.rb:714-728`), although the spec lists only explicit, Codex, Claude-PID, and nil forms. Separately, the fleet token omits displayed signal changes (new note/gate/commit within the same liveness bucket), and the global token omits counts/activity changes that do not alter sort order or worst state. Those pages can remain stale despite meaningful new data.
- `Snapshot.current(store, ttl: 10)` plus a mutex cannot guarantee that a subsequent page-render HTTP request reuses the exact snapshot that answered the poll: the TTL may expire between requests. The promise at `docs/superpowers/specs/2026-09-01-fleet-visibility-design.md:84` needs either generation pinning or weaker wording. The dirty-mtime implementation also needs a NUL-delimited `git status --porcelain -z --untracked-files=all` path contract, including rename and deletion handling; the existing helper only counts porcelain records (`lib/tyrion/repo.rb:269-271`).
- The five bulk queries cannot produce the phase-2 Changes feed. They return only in-progress/blocked stories and only the latest note/check per story, while Changes needs up to 50 events across all epic stories and discoveries; existing APIs remain story-scoped (`lib/tyrion/store.rb:820-837`, `1112-1113`). The derivation table also double-emits block/unblock/reopen action notes as generic blocker/recovery notes because those commands persist exactly such notes (`lib/tyrion/commands.rb:1524-1530`, `1553-1558`, `1586-1591`).

### Verdict

**NEEDS_REVISION**

1. Complete the lane/token contract: include `dispatched:` lanes and fingerprint every rendered value whose meaningful change must reload a view.
2. Specify snapshot-generation handoff honestly and define safe dirty-path parsing/stat semantics.
3. Add bulk phase-2 event queries for all epic stories/discoveries and exclude lifecycle action notes from the generic-note event stream.
