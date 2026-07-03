# AGENTS.md

Operational reference for non-Claude coding agents (Codex, Gemini, or any agent
without access to the Claude Code skill layer) using the `tyrion` CLI in this
repo.

- **Architecture, conventions, terminology** (discoveries, blocked stories,
  epic seal, drift detection, module breakdown): see `CLAUDE.md` at repo root.
- **Claude Code users**: use the `/tyrion-*` skills in [`skills/`](skills/)
  instead of raw CLI commands where possible (e.g. `/tyrion-orient`,
  `/tyrion-implement`, `/tyrion-checkpoint`). Those skills wrap the same
  commands documented here with additional guardrails.

This doc assumes `ruby bin/tyrion <cmd>` during development, or `tyrion <cmd>`
if installed as a gem on PATH.

## The canonical loop

Every work session on a story follows this sequence:

1. **`tyrion status`** — plan view. Shows active project/epic, story list,
   progress. Run this first, always.
2. **`tyrion resume [slug]`** — read-only context dump for a specific story
   (or the active story if omitted). Gives you `current_context`,
   `next_action`, intent, and unmet criteria before you touch anything.
3. **`tyrion start <slug>`** (or **`tyrion claim-next`**) — claim the story
   transactionally before making changes. Do not edit code for a story you
   have not claimed.
4. **`tyrion note <slug> <kind> "body"`** — log plans, decisions, progress,
   and blockers as you work. Use this liberally; it is the resumability
   record for the next agent (or yourself after a context reset).
5. **`tyrion check <slug> <position> "evidence"`** — mark a criterion met,
   with concrete evidence (command output, file path, test name). Use
   **`tyrion uncheck <slug> <position>`** to revert if evidence turns out
   wrong.
6. **`tyrion done <slug> "summary" [--force]`** — complete the story once all
   criteria are checked. `--force` overrides unmet-criteria protection; avoid
   it unless you have a documented reason (record it in a note first).

Supporting commands used within that loop:
- **`tyrion context <slug> "text"`** — update `current_context` (what state
  the story is in right now).
- **`tyrion next <slug> "text"`** — update `next_action` (what the next agent
  should do first).
- **`tyrion block <slug> "reason" [--discovery disc-NNN]`** /
  **`tyrion unblock <slug>`** — mark/clear a story as blocked. `tyrion start`
  refuses a blocked story and prints the unblock command.
- **`tyrion show <slug>`** — full story detail (read-only), useful mid-session
  when `resume` output has scrolled away.

## Sequencing rules

Tyrion keeps per-lane state in `.tyrion/lanes/<hash>/` (one directory per
calling-agent lane, keyed by a derived token). Two classes of race exist and
both are the caller's responsibility to avoid — Tyrion does not lock across
processes.

### Rule 1: Activation commands are sequencing boundaries

`tyrion project activate <slug>` and `tyrion epic activate <slug>` write the
active-project/active-epic file for the calling lane. Never run an activation
command in parallel with a read command (`tyrion status`, `tyrion show`,
`tyrion resume`, etc.) against the same lane. Run them strictly sequentially:
activate first, wait for it to complete, then read.

- **Bad**: fire `tyrion epic activate my-epic` and `tyrion status` at the same
  time (e.g. two background shell calls, or a tool-call batch that executes
  both concurrently).
- **Good**: run `tyrion epic activate my-epic`, wait for it to exit, then run
  `tyrion status`.

Known quirk: `tyrion status` reads the shared/legacy active-epic file (no lane
token), while `tyrion show`, `tyrion epic activate`, and most other commands
resolve the active epic via the caller's lane token. In a multi-lane session
this means `tyrion status` and `tyrion show` can legitimately report a
different active epic. This is expected behavior, not a bug — if the two
commands disagree, trust the one relevant to your current lane and re-run
`tyrion epic activate <slug>` for that lane if unsure.

### Rule 2: Mutating commands must be serialized

Never invoke two mutating tyrion commands concurrently against the same story
or lane. Mutating commands include (non-exhaustive): `start`, `note`,
`context`, `next`, `check`, `uncheck`, `done`, `block`, `unblock`,
`claim-next`, `mark`, `discover`, `spike start`, `spike done`,
`spike promote`, `criteria add`, `lesson add`, `lesson retire`,
`followup resolve`, `unstart`, `backfill`, `epic complete`,
`project activate`, `epic activate`, `import`.

- **Bad**: issuing two `tyrion note <slug> progress "..."` calls in the same
  parallel tool-call batch, or from two background processes at once, against
  the same story.
- **Good**: run one mutating command, wait for it to exit (check the exit
  code), then run the next.

Rationale: all writes go through SQLite in WAL mode with `db.transaction
(:immediate)`, but concurrent invocations from the *same lane* can still race
on the lane's file-based active-epic/active-story state and interleave in
ways that produce a story pointed at the wrong epic scope, or a
lost/duplicated note. Read commands are safe to run in parallel with each
other; only interleave with a mutating or activation command is unsafe.

## Epic and story identity

**Epic identity is the `.feature` filename, not the `Feature:` title line
inside the Gherkin file.**

`lib/tyrion/importer.rb` line 26:
```ruby
epic_slug    = File.basename(path, '.feature')
```

So `features/agents-md.feature` imports as epic slug `agents-md` regardless
of what its `Feature:` line says. The `Feature:` title is stored as
`epic['name']` and used only for display (`tyrion epic show`, web UI
headers) — it is never used as a lookup key.

Practical implications:
- `tyrion epic activate <slug>` takes the filename-derived slug, e.g.
  `tyrion epic activate agents-md`, not the title text.
- To rename an epic's display name without changing its identity, edit the
  `Feature:` line and re-import (`--force` if the file hash didn't change).
  To change the identity itself, rename the `.feature` file and re-import —
  this creates a *new* epic slug; it does not rename the old one.
- When in doubt about an epic's slug, run `tyrion epic list` or check the
  `.feature` filename directly — never infer the slug from the `Feature:`
  title text.

## Note kinds

`tyrion note <slug> <kind> "body"` accepts exactly these 10 kinds (from
`lib/tyrion/commands.rb` `VALID_NOTE_KINDS`):

```
plan, progress, decision, blocker, test, handoff, recovery, session, followup, observation
```

Any other value is rejected with `Invalid kind: <kind>. Must be one of: ...`.
Use `observation` for Given/When setup context captured during import (see
`--criteria=then` in the import workflow) or general non-categorized
findings that don't fit the other nine kinds.

## Quick command reference

```
tyrion status                              Plan view (run first, every time)
tyrion resume [slug]                       Read-only context dump
tyrion show <slug>                         Full story detail (read-only)
tyrion start <slug>                        Claim a story (transactional, mutating)
tyrion claim-next                          Claim next pending story (transactional, mutating)
tyrion note <slug> <kind> "body"           Append note (mutating)
tyrion context <slug> "text"               Update current_context (mutating)
tyrion next <slug> "text"                  Update next_action (mutating)
tyrion check <slug> <position> "evidence"  Mark criterion met (mutating)
tyrion uncheck <slug> <position>           Revert a checked criterion (mutating)
tyrion done <slug> "summary" [--force]     Complete story (mutating)
tyrion block <slug> "reason" [--discovery disc-NNN]  Block a story (mutating)
tyrion unblock <slug>                      Unblock a story (mutating)
tyrion project activate <slug>             Sequencing boundary (mutating)
tyrion epic activate <slug>                Sequencing boundary (mutating)
tyrion import <file.feature>               Import gherkin scenarios (mutating)
```

Full command list with all flags: `tyrion help`.

<!-- BEGIN UKF FEDERATION SECTION (generated by `ukf init`) -->

## UKF — Universal Knowledge Facade (the knowledge federation)

This repo participates in a federated knowledge base spanning multiple wikis and collections
("wiki-of-wikis"). Plain markdown + shell CLIs — no vendor machinery required. Two standing
obligations for any agent working here:

1. **Before researching or re-deriving anything, check whether the knowledge already exists.**
2. **When you produce durable knowledge (research, decisions, patterns), file it.**

### Find knowledge (progressive disclosure — index before content)

```bash
uregistry list --kind wiki        # which knowledge bases (members) exist
ukf search "<term>"               # cross-member search -> member | title | path
```

Read the page it points to. A `resource:` frontmatter field links the live artifact the page
is about — fetch via an authenticated CLI where one exists, never a raw API. Master member
list: `members.md` at the hub — run `ukf hub` to locate it.

### Add knowledge

Register this repo's own docs/wiki as a member (only if it has a substantial corpus worth
federating — do not do this reflexively):

```bash
ukf register <path> [--reference]
```

Full model (full vs. reference members, frontmatter convention, pre-commit gate):
`wiki-of-wikis.md` at the hub (`ukf hub` prints the hub path).

<!-- END UKF FEDERATION SECTION -->
