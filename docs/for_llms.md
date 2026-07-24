# Tyrion - Documentation for LLMs

This document provides context for LLMs working with the Tyrion codebase, or using Tyrion to track work in another project.

## Overview

Tyrion is a resumability ledger for coding agents: a spec-driven, evidence-gated project tracker (Ruby gem + Sinatra web UI, MIT) that answers "what was I building, what's done, what does the next agent do first?" without relying on an agent's memory or discipline. SQLite ledger at `~/.tyrion/tyrion.db` (override `TYRION_DB_PATH`); `Store` (`lib/tyrion/store.rb`) is the only module touching the DB — every write goes through `db.transaction(:immediate)`.

**Deep analysis with architecture/maturity assessment**: `/Users/fkchang/work/cultiv-ai/wiki/research/tyrion.md` (external, cultiv-ai wiki — read that for the full trust-mechanics and generalization writeup). This file is the fast orientation; that one is the design deep-dive.

## Data Model

```
projects (slug, name, about_md)
  epics (slug, name, intent, feature_source_path + hash)
    stories (slug, title, intent, current_context, next_action, status,
             claimed_by, completed_by, depends_on, born_from_discovery)
      criteria (Given/When/Then/And/But, status: pending|met|not_applicable, evidence)
      story_notes (kind: plan|progress|decision|blocker|test|handoff|recovery|
                    session|followup|observation)
  discoveries (status: mark|capturing|active_spike|findings_ready|promoted_to_story|...)
  lessons (trigger, text, scoped to project/epic/story)
```

Story status: `pending | in_progress | blocked | done | abandoned`. A unique index enforces one `in_progress` story per (epic, claimed_by) lane — `tyrion start` refuses transactionally otherwise, which is what makes multi-agent fan-out (`tyrion-orchestrate`) safe.

`features/<epic-slug>.feature` (Gherkin) is the **source of truth** — human-reviewed before import. The DB is a derived, idempotent import (SHA256-hashed; re-import is a no-op unless the file changed).

## Key Entry Points

- `bin/tyrion` — the CLI (executable, gemspec entry point)
- `lib/tyrion/commands.rb` — command dispatch
- `lib/tyrion/store.rb` — sole DB access layer
- `lib/tyrion/repo.rb`, `lib/tyrion/importer.rb` — repo registration, Gherkin import
- `web/app.rb` — Sinatra war-room UI, port 4579 (Tailscale-reachable)
- `skills/tyrion-*/SKILL.md` — 10 Claude Code skills wrapping the CLI (see below)

## Common Tasks (CLI)

```bash
tyrion init                                    # register this repo
tyrion project new myapp "My App" && tyrion project activate myapp
tyrion import features/myapp.feature           # Gherkin -> stories + criteria
tyrion status                                  # war room: plan view

tyrion start my-story                          # claim (transactional, one per lane)
tyrion note my-story progress "..."            # kinds: plan|progress|decision|blocker|handoff|followup
tyrion context my-story "current understanding"
tyrion next my-story "next concrete action"
tyrion reconcile my-story --context "..." --next "..." --note "..." [--check N]  # atomic combo

tyrion check my-story 1 "auth_spec.rb:42 — rspec spec/auth → PASSED"  # evidence, not assertion
tyrion done my-story "summary"                 # refuses if any criterion still pending

tyrion resume [slug]                           # full context dump for cold-start agent
tyrion pocket                                  # compact handoff briefing
tyrion prime                                   # read-only tiered briefing for SessionStart/PreCompact hooks

tyrion mark "worth remembering later"          # instant reconnaissance bookmark
tyrion spike start "question" / tyrion spike done / tyrion spike promote <disc-id>
tyrion depends add <slug> <dep> / tyrion wave show / tyrion wave next
```

## The Claude Code Skills (the driver; CLI is the engine)

`/tyrion-orient` (session start, read-only) -> `/tyrion-new` (bootstrap) / `/tyrion-shape --from docs` (documents -> stories) -> `/tyrion-import` (deterministic load) / `/tyrion-add-story` (one story mid-epic) -> `/tyrion-implement <slug>` (9-step build loop) -> `/tyrion-orchestrate` (fan out one subagent per story) -> `/tyrion-checkpoint` (before `/compact`/`/clear`).

`/tyrion-implement` is the heavy lifter: orient+claim -> resume+plan -> per-criterion subagent loop (continuous capture: log a progress note before responding to any new user request, and after every Write/Edit/Bash call) -> UAT runbook -> `/pre-push` (build/strict modes) -> `tyrion done`. Modes: default, `--spike` (no quality gate, exploration), `--tdd=strict` (failing test first), `--dark-factory` (agent runs UAT and closes without human review — pair with a `/goal` directive for unattended epics).

Dark-factory also persists per epic: `tyrion epic mode <slug> dark_factory` (read back with `tyrion epic mode <slug>`, a bare `dark_factory`/`shape` word) makes it the default for that epic without retyping the flag — `/tyrion-implement` treats a persisted `dark_factory` epic as equivalent to the explicit flag, `/tyrion-orchestrate` auto-advances wave to wave instead of pausing after each one, and `tyrion prime`'s Tier-2 briefing surfaces a `mode:` contract line so an agent resuming mid-story knows the cadence without asking. `shape` (unset) stays the human-in-the-loop default everywhere.

## Auto-Engagement (Claude Code)

`tyrion setup claude` wires a target repo's `.claude/settings.json` in one idempotent, atomic
command: `SessionStart`/`PreCompact` hooks invoking `tyrion prime`, a `PreToolUse` claim-gate
hook invoking `tyrion hook claim-gate`, and the `tyrion` permission whitelist. Both hooks route
through a small versioned shim (`.claude/hooks/tyrion-shim.sh`) that execs the real `tyrion`
binary and fails open silently if it isn't resolvable — the gate's actual decision logic lives
in the `tyrion hook claim-gate` CLI subcommand (ported from `hooks/claim-gate.sh`), so upgrading
the gem upgrades every installed repo's enforcement without re-copying anything. Merging preserves
foreign hooks/permissions/keys untouched and replaces only Tyrion's own stale entries in place.
It also writes a versioned, hash-checked `<!-- BEGIN/END TYRION-MANAGED-BLOCK -->` section into
the target's `CLAUDE.md` (mandate rules + a pointer at `tyrion prime`, not a static command dump)
-- created fresh if the file has none, replaced in place on re-run with everything outside the
markers untouched byte-for-byte, and refused with zero writes if the markers are ambiguous
(duplicate/nested/reversed/unpaired). `tyrion setup claude --check` writes nothing and reports
each surface (hooks, gate shim + version, whitelist, CLAUDE.md block) with an exit code
distinguishing current/drift/partial/fail-open.

## Non-Claude Agents (Codex, anything reading ~/.agents/skills)

`tyrion setup-codex` symlinks `skills/` into `~/.agents/skills/tyrion` — Codex's native skill
discovery (same convention obra/superpowers uses). After a Codex CLI restart the tyrion skills
are directly invocable there. The tyrion CLI itself is agent-agnostic: set `TYRION_AGENT` and
`TYRION_SESSION_ID` for session notes, and inline `TYRION_LANE=<token>` on every command when
running parallel to other sessions. Skill references to Claude-Code-only helpers (`/pre-push`,
`/design-review`, `superpowers:*` skill invocations) degrade to instructions — follow their
intent with your own tools (run the test suite for the pre-push gate; record results with
`tyrion gate <slug> pre-push pass|fail`). Install is from source until the gem is published
(see README Install); once `gem install tyrion` exists, that plus `tyrion setup-codex` is the
whole setup.

## Gotchas

- **Sharp-criterion hard stop**: if any criterion is vague ("Then they see who engaged" instead of a verifiable assertion), `/tyrion-implement`'s plan step refuses to touch any file until the user approves a sharpened rewrite. Not overridable by any autonomy flag, including `--trivial`.
- **`tyrion done` refuses to close** a story with any criterion still `pending`, unless forced — this is the mechanical evidence gate, not a convention to remember.
- **`tyrion done` is the declared safe `/clear` boundary** — once it succeeds, the ledger is authoritative and held context is redundant. Don't `/clear` before it if you want the next agent to resume cleanly.
- **Evidence means verbatim output**, not paraphrase: `tyrion check <slug> <n> "<file>:<line> — <command> → PASSED"`.
- **Idempotent re-import**: `tyrion import` is a no-op unless the `.feature` file's SHA256 changed; use `--force` if only non-story content changed.
- **`current_context`/`next_action` must be updated continuously**, not just at session end — that's what makes `tyrion resume` a true cold-start mechanism instead of a stale snapshot.
- **Model-independent verification is a known gap** (per the project's own `docs/harness-layers-mapping.md`): `/pre-push` runs every cycle, but nothing today confirms the verifier is a different model/session than the maker.

## Known Failure Modes

Real incidents that have already happened once. Read these before orienting — the point is to recognize the setup before you repeat it, not to rediscover it on the next collision.

### Headless/subagent sessions bypassing the skill loop (2026-07-09)

**What happened.** A headless lead session was told "tyrion spec-first." It wrote a good
7-scenario `.feature` file — then hand-created the stories with raw `tyrion` CLI calls and
dispatched subagents that never invoked `/tyrion-implement`. The `.feature` file looked right,
so nothing obvious was wrong.

**How it showed up (the symptoms to recognize).**

- No story was ever claimed — every completed story had `claimed_by = NULL` the whole time.
- `current_context` and `next_action` stayed empty throughout.
- Status jumped straight from `pending` to `done` in one 33-second batch at the end, instead of tracking work as it happened.
- A live dashboard reading the ledger showed "nothing started" while two subagents were mid-flight on real implementation. A human caught it by eyeballing the dashboard against known active work — the ledger itself surfaced nothing.

**Why it happened.** Claiming a story (`tyrion start <slug>`) and continuous context-tracking
live *inside* `/tyrion-implement` and `/tyrion-orchestrate` — they were documented protocol, not
anything the bare CLI enforced. A subagent that treats itself as "dispatched to execute a
specific task" and skips skill-checking entirely has nothing in `tyrion` itself nudging it to
claim before writing code.

**How to avoid it.** If you are a subagent dispatched to "just execute a task" — *including one
told to skip skill-checking discipline upstream* — still check whether `/tyrion-implement` or
`/tyrion-orchestrate` applies **before** running `tyrion` commands by hand. Claiming, context
updates, and continuous capture live inside those skills, not the raw CLI. If you find yourself
about to hand-create stories or mark work `done` without ever having run `tyrion start`, stop:
that is this failure mode beginning.

Full timeline and DB evidence: `docs/retro-2026-07-09-llm-delegation.md`.

## Testing

RSpec with `TyrionTestHelpers`; see `spec/`. Run `bundle exec rspec`.

## Enforcement: the claim-gate PreToolUse hook

`hooks/claim-gate.sh` turns "claim a story before you touch the ledger" from
skill-prose convention into a mechanism. It is a Claude Code **PreToolUse** hook
on the Bash tool: before any Bash command runs, the hook inspects it.

- Command is not `tyrion note|check|done` → exit 0 (allow).
- Command is one of those, and the active lane owns an `in_progress` story → exit 0.
- Command is `tyrion note` targeting a story that is already `done` or `blocked`,
  from a lane with no `in_progress` story → exit 0 (the **orchestrator affordance**:
  an unclaimed coordinator session may record a post-hoc note on a story its
  subagents already finished, without weakening the gate for live mutations).
- Command is one of those, but the lane has no `in_progress` story → **exit 2**
  (blocks the tool call and tells the agent to run `tyrion start <slug>` first).
  This covers `tyrion check`/`tyrion done` always, and `tyrion note` on a
  `pending` or `in_progress` story.

The gate only fires on a tyrion command in **command position** — the `tyrion`
(or `.../bin/tyrion`) token at the start of a command segment or after a shell
separator, following only optional `VAR=value` env assignments and plain
interpreter words (`ruby`, `bundle exec`, ...), with the gated verb as a complete
immediate subcommand. A tyrion-ending path buried in an argument or a quoted
string does not match, so `git -C ~/work/tyrion check-ignore ...` and
`git commit -m "tyrion note: ..."` pass through untouched.

The gate honors a `TYRION_LANE=<token>` prefix on the command so it resolves the
same lane the command will run under. It is **fail-open**: a non-tyrion command,
a repo outside any Tyrion project, a missing `ruby`, or any internal error all
exit 0. A claim gate that breaks unrelated Bash calls is worse than one that
occasionally lets a ledger write through.

This repo wires it in `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/hooks/claim-gate.sh" }
        ]
      }
    ]
  }
}
```

**Install in another project.** The hook resolves the tyrion library one of two
ways: in a **source checkout** it finds it at `../lib` relative to the script; a
**gem-installed** tyrion resolves via `require 'tyrion'` on the load path. In a
foreign repo you get **neither** for free — the `../lib` fallback only exists in
a checkout, and the gem is unpublished — so `require 'tyrion'` fails, the hook
**silently fail-opens, and the gate is not actually enforced** (F2, dogfood
2026-07-10 test 4b). Put the library on the load path with a `RUBYLIB=` prefix:

1. Copy `hooks/claim-gate.sh` into the project (e.g. `hooks/claim-gate.sh`) and
   `chmod +x` it.
2. Add the `PreToolUse` block to the project's `.claude/settings.json`, pointing
   `command` at wherever you put the script and prefixing it with
   `RUBYLIB=<path-to-tyrion>/lib` so `require 'tyrion'` resolves:

   ```json
   {
     "hooks": {
       "PreToolUse": [
         {
           "matcher": "Bash",
           "hooks": [
             { "type": "command", "command": "RUBYLIB=<path-to-tyrion>/lib \"$CLAUDE_PROJECT_DIR\"/hooks/claim-gate.sh" }
           ]
         }
       ]
     }
   }
   ```

3. **Verify the gate is armed.** Run the script's `--check` mode from the repo
   root (it reports arming status, takes no input, and never blocks):

   ```bash
   RUBYLIB=<path-to-tyrion>/lib hooks/claim-gate.sh --check
   ```

   Confirm it prints `armed`. Anything else means the gate is **not** enforcing:
   `fail-open: tyrion lib not loadable` (fix the `RUBYLIB` path),
   `fail-open: no .tyrion project found from this directory` (run from a Tyrion
   project root), or `fail-open: no ruby on PATH` (install ruby).
4. New sessions pick it up automatically; already-running sessions load hooks at
   start, so restart to activate.
