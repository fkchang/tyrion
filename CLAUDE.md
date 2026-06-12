# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

## Architecture

Tyrion is a SQLite-backed resumability ledger. Its job is to answer "what was I building, what's done, and what does the next agent do first?" The data model is:

**projects → epics → stories → criteria + story_notes**  
**projects → discoveries** (the spike/finding layer, separate from stories)

### Module breakdown

- **`Store`** — all DB access. Every public method returns a plain `Hash` (SQLite row with string keys) or `Array` of hashes. No ORM. Uses `with_db` which opens SQLite in WAL mode with FK enforcement and returns the result of the block. All write paths use `db.transaction(:immediate)` for atomicity.
- **`Commands`** — all CLI logic. One `cmd_*` class method per command, dispatched from `Commands.run(ARGV)`. Commands receive `args` (dup'd ARGV slice) and a `Store` instance. Interactive commands accept `input:` and `output:` kwargs (default `$stdin`/`$stdout`) for testability.
- **`Repo`** — git and worktree state. Reads `.tyrion/active-project` and `.tyrion/active-epic` files to know which project/epic is active. All methods are module-level (`self.`) and are stubbed in specs via rspec-mocks.
- **`Importer`** — parses `.feature` files (Gherkin) and upserts epics/stories/criteria into the DB. `tyrion import features/<epic>.feature` is how feature files get into the DB. The `.feature` file is the source of truth; importing is idempotent by SHA256 hash.
- **`Output`** — terminal formatting helpers (`Output.green`, `Output.dim`, `Output.story_icon`, etc.).

### Discovery layer

`discoveries` table sits directly under `projects` (not epics). Two entry modes:
- `tyrion mark "desc"` — zero-friction bookmark, status=`mark`
- `tyrion discover` — 30-second organic capture, status=`findings_ready`
- `tyrion spike start/done` — structured spike cycle, `active_spike` → `findings_ready`
- `tyrion spike promote <disc-id>` — converts `findings_ready` → story with `born_from_discovery` traceability

Status aliases for `tyrion discovery list --status`: `active`→`active_spike`, `ready`→`findings_ready`, `promoted`→`promoted_to_story`, `deferred`→`deferred`, `all`→no filter.

### Key conventions

**Error exits** — always use `die "message"` (writes to `$stderr`, calls `exit 1`). Never use bare `$stderr.puts + exit 1`.

**Interactive prompts** — use `prompt(input, output, "Label: ")` helper. Never read `$stdin` directly.

**Presence checks** — use `presence(str)` helper instead of `str && !str.empty? ? str : nil`.

**Blocked stories** — `blocked` is a first-class story status (alongside `pending|in_progress|done|abandoned`). Use `tyrion block <slug> "reason" [--discovery disc-NNN]` / `tyrion unblock <slug>`. Blocking stores `blocked_on TEXT` (human reason) and optionally `blocked_on_discovery TEXT` (linked disc-id). `tyrion start` refuses a blocked story with the reason and the unblock command. `tyrion status` renders a distinct `BLOCKED` lane below the story list; if the linked discovery has resolved (`promoted_to_story|deferred|invalidated`), the lane shows `[disc-NNN resolved → unblock?]`.

**Discovery IDs** — `disc-NNN` format, per-project sequential counter, zero-padded to 3 digits, generated inside `db.transaction(:immediate)`.

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

### Workflow: feature file → DB

1. Write/edit `features/<epic-slug>.feature` (Gherkin)
2. `tyrion import features/<epic-slug>.feature` — upserts epic + stories + criteria
3. Use `--force` to re-import when only non-story content changed (hash unchanged)
4. `--confirm-abandon` required if an in-progress story exists in that epic
