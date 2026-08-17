# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Planning protocol

When planning work that will be tracked in the Tyrion ledger, use `/tyrion-plan` instead of raw plan mode — it handles plan mode entry AND wires approval directly to `/tyrion-implement`.

If the user says "let's plan" without specifying, ask: "Track this in Tyrion? (`/tyrion-plan`) or quick untracked plan?"

## Commands

```bash
# Run full RSpec suite
bundle exec rspec

# Run a single spec file
bundle exec rspec spec/commands/mark_spec.rb

# Run a single example by description
bundle exec rspec spec/commands/mark_spec.rb -e "creates a [mark] discovery"

# Run the CLI (from repo root)
ruby bin/tyrion status
ruby bin/tyrion help
```

Note: `ruby bin/tyrion` is used during development. When installed as a gem, `tyrion` is on PATH.

## Skill / UAT config

- Browser tool: `playwright-cli` (no auth needed — localhost only)
- UAT base URL: `http://localhost:4579`

## Architecture

Tyrion is a SQLite-backed resumability ledger. Its job is to answer "what was I building, what's done, and what does the next agent do first?" The data model is:

**projects → epics → stories → criteria + story_notes**  
**projects → discoveries** (the spike/finding layer, separate from stories)

### Module breakdown

- **`Store`** — all DB access. Every public method returns a plain `Hash` (SQLite row with string keys) or `Array` of hashes. No ORM. Uses `with_db` which opens SQLite in WAL mode with FK enforcement and returns the result of the block. All write paths use `db.transaction(:immediate)` for atomicity.
- **`Commands`** — all CLI logic. One `cmd_*` class method per command, dispatched from `Commands.run(ARGV)`. Commands receive `args` (dup'd ARGV slice) and a `Store` instance. Interactive commands accept `input:` and `output:` kwargs (default `$stdin`/`$stdout`) for testability. `resolve_my_story(store, epic, explicit_slug:, claim_if_none:)` is the 6-rung story resolver used by `cmd_resume`, `cmd_claim_next`, and `cmd_pocket` — explicit slug → lane-token match → pre-claim adopt → active-story pin → sole unclaimed → claim-next.
- **`Repo`** — git and worktree state. Reads `.tyrion/active-project` and `.tyrion/active-epic` files to know which project/epic is active. Per-lane state lives under `.tyrion/lanes/<hash>/` (keyed by `SHA256(token)[0,16]`); `active_epic`/`write_active_epic`/`active_story`/`write_active_story` accept a `token:` kwarg — token present → lane file, nil → shared legacy file. `lane_dir(token, root)` returns the lane directory. All methods are module-level (`self.`) and are stubbed in specs via rspec-mocks.
- **`Importer`** — parses `.feature` files (Gherkin) and upserts epics/stories/criteria into the DB. `tyrion import features/<epic>.feature` is how feature files get into the DB. The `.feature` file is the source of truth; importing is idempotent by SHA256 hash. If a sibling `features/<epic-slug>.context.md` exists, its content is loaded into `epics.context_md` and its SHA256 stored in `context_source_hash`; idempotency covers both files.
- **`Output`** — terminal formatting helpers (`Output.green`, `Output.dim`, `Output.story_icon`, etc.).

### Web UI (`web/`)

Sinatra 4 + Phlex + phlex-sinatra prototype. Runs separately from the CLI gem — not packaged into the gemspec, so `tyrion web` only works from a source checkout.

```bash
# Start/restart/stop (from anywhere, dev checkout only):
tyrion web              # start if needed, open browser (alias: tyrion dashboard)
tyrion web ambient      # start if needed, open /ambient?project=<slug> in a narrow app-mode window
tyrion web restart      # pick up code changes
tyrion web stop
tyrion web status
# --port N overrides; --no-open skips the browser; TYRION_PROJECT defaults to .tyrion/active-project

# Equivalent manual invocation (what `tyrion web` shells out to):
cd web && TYRION_PROJECT=<slug> bundle exec ruby app.rb
# Default port 4579; override with TYRION_PORT
# Binds 0.0.0.0 for Tailscale phone access
```

`lib/tyrion/web_server.rb` owns process lifecycle (PID file under `~/.tyrion/`, port-scan fallback, HTTP health-check polling, cross-platform browser open). `stop`/`restart` only ever kill a PID confirmed to be a `web/app.rb` process (command line + cwd check) — never just "whatever is squatting the port."

`tyrion web ambient` reuses that same lifecycle and project resolution, then opens `WebServer.ambient_url(port, project)` — always `?project=<slug>`-scoped, because an already-running server may have been started for a different project than the one active in this shell. `WebServer.open_app_window` launches the first available Chrome-family binary (`APP_MODE_BROWSERS`, macOS absolute paths / Linux PATH names) with `--app=<url> --window-size=340,960` via `Process.spawn` **argument array** — no shell string, so a URL can never be interpolated into a command line. It returns `false` (never raises) when no browser is found or the launch fails, and the caller falls back to `WebServer.open_url` on the same URL. The URL is printed either way, including under `--no-open`: app mode is convenience, not a dependency — pinning any browser tab to that URL in a split pane is equally valid.

**Key files:**
- **`web/app.rb`** — Sinatra routes. One route per view + `GET /api/poll` for live monitoring. Mutations use PRG (Post/Redirect/Get) with `session[:flash]`. `with_flash` helper in `helpers` block DRYs up all POST error handling.
- **`web/lib/tyrion_web/data.rb`** — `TyrionWeb::Data` module. All DB queries for views live here; routes stay thin. `load_*_view` methods return plain hashes passed to Phlex components.
- **`web/lib/tyrion_web/presenter.rb`** — `TyrionWeb::Presenter` module. Status glyphs, `time_ago`, `stale?`, epic seal CSS/glyph, story status badge CSS.
- **`web/views/layout.rb`** — `Views::Layout` Phlex component. Two-row topbar (brand+breadcrumbs / epic switcher / nav tabs), sidebar with story list + discovery strip, yields main content.
- **`web/views/active_story.rb`** — Story detail view. Shows MISSION BRIEF (Gherkin intent), Current Context, Next Action, criteria, notes. Live-polls `/api/poll` every 30s when story is `in_progress` — reloads on token change.
- **`web/views/roadmap.rb`** — All epics with expand/collapse story lists and mini progress tracks.
- **`web/views/global_view.rb`** — Project command center showing health cards for all projects in the DB.

**`GET /api/poll?story_id=<id>`** — returns `{token, slug, status, met, total}`. Token is `"#{last_note_at}:#{met}:#{status}"` — changes when a note, criterion check, or status change occurs.

**Ambient pane (`GET /ambient` + `GET /api/ambient_poll?project=<slug>`)** — `web/views/ambient.rb` renders a chrome-free glance surface (newest 3 open marks + a findings_ready line) for a narrow browser pane beside a terminal. Its poller is deliberately *not* the story poller: 60s instead of 30s, and it patches the DOM in place instead of reloading (a reload would blank a pane someone is glancing at). The payload is `{token, marks:[{id,question,created_at}], findings_ready_count}` — it carries what both sections need to repaint, not just a change signal, and `Views::Ambient#render_js` always repaints *both* the marks list and the findings_ready line together so the two can't disagree. `TyrionWeb::Data.ambient_token` fingerprints only mark ids + question text + the count: aging is a pure function of `created_at` and wall-clock time, so folding it into the token would churn it every tick — instead the JS recomputes each mark's aged class from `data-created-at` on *every* tick, token change or not, which is the only way a mark crossing the 14-day threshold ever turns amber. `AGING_DAYS`/`TRUNCATE_AT`/`POLL_INTERVAL_MS` are interpolated into the JS from the Ruby constants so the repaint can't drift from the first render. Project resolution goes through the same `load_ambient_view` the page render uses (unknown slug falls back to the active project) — a stricter lookup in the poller would blank a pane that is rendering fine. 404 is reserved for "no project resolved at all," and even then the body is the same-shaped empty payload, so the page needs no error branch.

**Multi-tab URL scoping** — each browser tab stays pinned to its own project/epic via `?project=&epic=` query params rather than shared ambient state, so opening several tabs against different epics doesn't cause one tab's navigation to bleed into another. `Views::Layout#nav_href` threads both params into every topbar tab link and the sidebar's in-progress-story row whenever `@project_slug`/`@epic` are present. `TyrionWeb::Data.load_active_story_view(epic_slug:)` and `load_war_room_view(epic_slug:)` both pin to the exact epic named by the param (no cross-epic fallback) when one is given — the fallback-search-across-epics behavior only runs when no explicit epic scope was requested. `GET /` redirects to `/global` when neither `?project=` nor `TYRION_PROJECT` resolves a project — deliberately narrower than `resolve_active_project`'s full fallback chain (which also checks `.tyrion/active-project` and the DB's first project), so a bare tab with no scope lands on the project picker instead of silently guessing.

**Epic switcher dropdown** — the topbar epic crumb is a `<select data-action="epic-switch">` (rendered by `Views::Layout#render_epic_switcher`) only on the two routes whose content actually honors `?epic=`; everywhere else it's a plain span. `Layout#initialize` takes `epic_scope_mode:` (`:none` default / `:scoped` / `:cross_epic`) to gate this: `:none` renders the old static `<span class="topbar-crumb active">`; `:scoped` and `:cross_epic` render the interactive dropdown. `web/app.rb`'s `/` route passes `epic_scope_mode: :scoped` to `Views::ActiveStory`; `/warroom` hardcodes `epic_scope_mode: :cross_epic` inside `Views::WarRoomView` (its only call site). `Views::ActiveStory` is shared between `/` (wants `:scoped`) and `/stories/:id` Story Detail (wants `:none` — the epic there is fixed by the story, not selectable), so it alone needs the `epic_scope_mode:` kwarg threaded from its two call sites; Roadmap/Global/Discoveries/About/NotFound never pass it and get `:none` for free. `TyrionWeb::Data.epic_switcher_epics(project)` lists every epic in the project decorated with `done`/`total` story counts and `cli_active` (whether it matches the *raw* `.tyrion/active-epic` file content via `Tyrion::Repo.active_epic`, not `resolve_active_epic`'s DB-status fallback — this is a legacy/shared-file read, same quirk noted in AGENTS.md). Fully-done epics get a trailing `✓`; the CLI-active epic gets a trailing `⚑`. In `:cross_epic` mode the dropdown's first option is `(All Epics)` (`value=""`); the delegated `change` listener (`render_epic_switcher_js`) navigates via client-side GET, stripping the `epic` param entirely when the selected value is empty rather than merging in `epic=` — this is War Room's only way back to its cross-epic "no lane hidden" board, deliberately not offered on Active Story (would reintroduce the ambient-epic-resolution bleed multitab-url-scoping eliminated). Never a POST, never touches `.tyrion/active-epic`.

### Discovery layer

`discoveries` table sits directly under `projects` (not epics). Two entry modes:
- `tyrion mark "desc"` — zero-friction bookmark, status=`mark`
- `tyrion discover` — 30-second organic capture, status=`findings_ready`
- `tyrion discover <disc-id> --finding "…" [--question "…"]` — non-interactive upgrade of an existing `mark` to `findings_ready`
- `tyrion spike start/done` — structured spike cycle, `active_spike` → `findings_ready`
- `tyrion spike promote <disc-id>` — converts `findings_ready` → story with `born_from_discovery` traceability

The first four take `--auto` to record `origin=agent` — see **Discovery origin** under Key conventions.

Status aliases for `tyrion discovery list --status`: `active`→`active_spike`, `marks`→`mark`, `ready`→`findings_ready`, `promoted`→`promoted_to_story`, `deferred`→`deferred`, `all`→no filter.

`tyrion discovery search "<term>" [--status <alias>]` is the dedup check an agent runs before filing a new mark. `Store#search_discoveries` splits the term on whitespace and ANDs the words, ORing each word across `question`/`finding`/`recommendation` via LIKE; `%`, `_` and `\` are escaped (`ESCAPE '\'`) so they match literally. No status is excluded by default — that's what makes it a real dedup check. Newest-first, one line per hit, and **silent on no match** (exit 0, no "no results" line) so it costs nothing to run mid-task.

Autonomous filing is the point of that dedup check: an implementing agent is expected to file marks itself, mid-task and unasked, when it notices a real gap — so a later session can say "already tracked as disc-NNN" instead of rediscovering it. The behavioral instruction that makes this happen lives in `skills/tyrion-implement/SKILL.md` (Step 7, CONTINUOUS CAPTURE), deliberately **not** in any CLAUDE.md: a global always-on instruction would fire in non-Tyrion repos too, where `tyrion mark` just errors with no active project, and CLAUDE.md is not hook-reinjected on `/clear` the way `tyrion prime` is, so it would decay exactly when it's needed most. What's recorded here is only the shape of the guardrails, so a human reading this file knows the behavior exists and why it can be trusted: **search before filing** (`tyrion discovery search "<3-5 key words>"` — on a hit, cite the `disc-NNN` and record a re-sighting with `tyrion note <slug> observation "..."` rather than filing a duplicate); a **per-story filing budget** of at most 3 marks, where a 4th means stop and tell the user rather than "use judgment"; `--auto` on every autonomous filing so the row records `origin=agent` and the human can bulk-triage "the agent noticed this" apart from "I decided to track this"; and `tyrion discovery defer <disc-id> ["why"]` as a real exit — it flips a `mark` or `findings_ready` row to `deferred` with a stored `defer_reason` (any other source status is refused), so the list can shrink honestly instead of only growing. Those four together are what keep autonomous filing from turning the discovery list into a guilt inbox.

### Key conventions

**Error exits** — always use `die "message"` (writes to `$stderr`, calls `exit 1`). Never use bare `$stderr.puts + exit 1`.

**Interactive prompts** — use `prompt(input, output, "Label: ")` helper. Never read `$stdin` directly.

**Presence checks** — use `presence(str)` helper instead of `str && !str.empty? ? str : nil`.

**Blocked stories** — `blocked` is a first-class story status (alongside `pending|in_progress|done|abandoned`). Use `tyrion block <slug> "reason" [--discovery disc-NNN]` / `tyrion unblock <slug>`. Blocking stores `blocked_on TEXT` (human reason) and optionally `blocked_on_discovery TEXT` (linked disc-id). `tyrion start` refuses a blocked story with the reason and the unblock command. `tyrion status` renders a distinct `BLOCKED` lane below the story list; if the linked discovery has resolved (`promoted_to_story|deferred|invalidated`), the lane shows `[disc-NNN resolved → unblock?]`.

**Epic completion seal** — an epic's `status` is never auto-flipped to `done`. `tyrion done` on the last story prompts `Seal epic <slug> as complete? [y/N]` (skipped, with a tip printed, when stdin is not a tty). `tyrion epic complete [slug] [--force]` is the manual seal; it refuses unless every story is done (or `--force`). The web roadmap seal/glyph and the `project show` status key off `epic['status']`, so sealing makes a done epic read as DONE everywhere. Honesty flip: starting, claiming, blocking a story, or importing a new pending story into a sealed epic flips it back to `active` (`Store#reopen_epic_if_done!`).

**Gate-refusal on close** — `tyrion done` refuses (exits 1, lists each offending gate on `$stderr`) when any gate's *latest* result is `fail`, so a story can't be sealed over a failing quality gate. `--force` bypasses it and records the bypass as its own `force-close: PASS` gate note (metadata `detail: "overrode failing: <names>"`) so the override is itself traceable in `tyrion show`'s Gates section. A gate that failed but was later re-recorded as `pass` no longer blocks (only the latest result per gate name counts, matching how `print_gates_section` renders). Enforced in `cmd_done` via `latest_failing_gates` (commands.rb), which prefers the note's `metadata` `{gate,result}` and falls back to the body regex.

**Epic archive** — `tyrion epic archive <slug>` sets `archived_at` (via `Store#archive_epic`); `tyrion epic unarchive <slug>` clears it (`Store#unarchive_epic`). Archived epics drop out of the main `tyrion epic list` into a separate `Archived:` section (shown with an `[archived]` marker) and move to the collapsed Archived section on the web roadmap; the web split keys off `archived_at` (`active_epics`/`archived_epics` in `web/lib/tyrion_web/data.rb`). The `archived_at` column is added idempotently via `MIGRATIONS`.

**Non-interactive discover** — `tyrion discover` is one verb with two forms, discriminated *only* by a positional disc-id (flags alone still fall through to the interactive path, and `--auto` is consumed before the positional read so it can't be mistaken for an id). With an id it calls `cmd_discover_upgrade` → `Store#upgrade_mark`, which refuses anything whose status isn't `mark` (a `findings_ready` row already has its finding; an `active_spike` belongs to `spike done`) and keeps the same disc-NNN so existing references still resolve. `--finding` is required (its absence is a usage error, never a prompt); an omitted `--question` preserves the mark's original wording via `question=COALESCE(?, question)`, same contract as `close_spike`'s origin. A disc-id in another project is reported as plain "not found" — project scope is the boundary and leaking its existence would be a false lead. This is what makes the web Discoveries view's `tyrion discover disc-NNN` chip on mark rows a real command rather than a no-op.

**Discovery IDs** — `disc-NNN` format, global sequential counter (not scoped per project), zero-padded to 3 digits, generated inside `db.transaction(:immediate)`. The counter is deliberately global — `disc-NNN` is the `discoveries` table primary key, so it must be unique across every project, and `create_discovery`'s `MAX(...)` lookup runs without a `project_id` filter for exactly that reason.

**Discovery origin** — `discoveries.origin` is `agent` or `human` (`CHECK`, `NOT NULL DEFAULT 'human'`), answering "did I decide to track this, or did an agent notice it?" so the list can be bulk-triaged. It is set **only** from an explicit `--auto` flag on `tyrion mark`, `tyrion discover`, `tyrion spike start`, and `tyrion spike done` — never inferred from whether a story is in progress, because an active story does not mean an agent is the one typing. **Agents filing autonomously must pass `--auto`; without it the row records `human` and the column silently means nothing.** `Commands.consume_auto_flag(args, default:)` deletes the flag from `args` (so it can't be mistaken for a description/question) and returns the origin; `default:` is `'human'` on the commands that *create* a row and `nil` on `spike done`, which *updates* one — `Store#close_spike` writes `origin=COALESCE(?, origin)`, so closing an agent-framed spike without the flag preserves its origin rather than relabelling it. `Tyrion::Output.origin_label` is the single source of the `[agent]`/`[human]` wording; `origin_tag` adds CLI colour and `TyrionWeb::Presenter.origin_tag` returns `{text:, css:}` for the web, so `tyrion status`, `tyrion discovery list`, `tyrion discovery show`, and the web Discoveries view can't drift apart. Anything not literally `agent` renders as human, so a NULL never reads as agent.

**Mark provenance** — `discoveries.source_story_id` records where a mark was *noticed*; `discoveries.story_id` records what it *became* (`promote_discovery_to_story` overwrites `story_id` with the story it creates, which is why the two can't be one column). Only `tyrion mark` sets it, at creation, alongside `epic_id`; no status transition — promotion, defer, invalidate — ever touches it, and pre-existing rows stay NULL rather than being backfilled with a guess. Both are resolved through `Commands.prime_story_for` (the read-only lane lookup: this lane's own `in_progress` story, or the legacy sole-unclaimed one) — **never** `resolve_my_story`, which can claim/adopt/pin and must not run as a side effect of filing a mark. Another lane's story, or a story pinned but not `in_progress`, resolves to no story; a mark with no epic or story still files, with both fields nil. The confirmation line then reports the running count for that story — `[mark] disc-042 (2nd mark filed this story)`, via `Store#count_marks_from_story` — because the implementing-agent skill forbids querying SQLite directly, so this line is an agent's only way to self-police its per-story filing budget. The count is by `source_story_id` alone, not status, so an already-promoted mark still counts.

**Schema migrations** — new columns use the `MIGRATIONS` constant (array of `[name, lambda]` pairs in `store.rb`), not raw `ALTER TABLE` in `setup_db`. The lambda checks `PRAGMA table_info` before altering so it's idempotent.

**Default DB path** — `~/.tyrion/tyrion.db`, overridable via `TYRION_DB_PATH` env var (`spec_helper.rb` sets this to a tmp path so specs never touch the real ledger). Always pass explicit `db_path:` to `Store.new` in specs (the `tyrion_worktree` helper does this automatically).

### Test conventions (RSpec)

Specs live in `spec/` and use the `TyrionTestHelpers` module (loaded automatically via `spec/support/tyrion_test_helpers.rb`).

**Stub `Tyrion::Repo`** using rspec-mocks — auto-restores at end of each example, no leakage between random-ordered specs:

```ruby
# Full worktree setup (project + epic + Repo stubs):
let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic', git_branch: 'feature/x') }
let(:store) { ctx.store }

# Override one Repo method within a context:
before { stub_repo(active_project: nil) }
```

**Output assertions** — prefer RSpec's `output` matcher when only asserting; use `capture_io` only when extracting a value from the output:

```ruby
# Preferred (assertion only):
expect { Commands.cmd_mark([], store) }.to output(/\[mark\] disc-\d+/).to_stdout
expect { Commands.cmd_show(['disc-999'], store) }.to raise_error(SystemExit)
  .and output(/not found/).to_stderr

# Use capture_io when you need the string (e.g. to extract an id):
out, = capture_io { Commands.cmd_mark(['desc'], store) }
disc_id = out[/\[mark\] (disc-\d+)/, 1]
expect(store.find_discovery(disc_id)['question']).to eq 'desc'
```

### Gherkin narrative format

Every scenario should include the standard "As a / In order to / I want" narrative between the `Scenario:` line and the first `Given`. This tells the implementing agent WHO the user is, WHY this story exists, and WHAT capability they need:

```gherkin
Scenario: user-login
  As a registered user with valid credentials
  In order to access the system without re-entering my password each request
  I want to exchange my credentials for a JWT

  Given a registered user with valid credentials
  When they POST /auth/login
  Then they receive a JWT and a 200 response
```

The importer parses these lines and stores them as the story's `intent` field. A `# Intent:` comment takes priority if both are present (for backward compatibility). The intent surfaces in `tyrion show` and `tyrion resume`, giving implementing agents the WHY without reading the full feature file.

### Drift detection

`tyrion drift` compares the SHA256 of each tracked feature file against the stored hash and reports: `up to date`, `feature file changed - run tyrion import <path>`, or `feature file missing`. `tyrion status` and `tyrion resume` also surface a one-line yellow warning automatically when the active epic's feature file has changed since import, so agents don't need to run `tyrion drift` explicitly.

### Workflow: feature file → DB

1. Write/edit `features/<epic-slug>.feature` (Gherkin)
2. `tyrion import features/<epic-slug>.feature` — upserts epic + stories + criteria
3. Use `--force` to re-import when only non-story content changed (hash unchanged)
4. `--confirm-abandon` required if an in-progress story exists in that epic
5. Use `--criteria=then` to make only Then/And-under-Then steps into checkable criteria; Given/When steps are stored as an observation note on the story (useful when Given/When are setup context, not acceptance criteria)
