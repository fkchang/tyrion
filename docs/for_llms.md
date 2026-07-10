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

tyrion mark "worth remembering later"          # instant reconnaissance bookmark
tyrion spike start "question" / tyrion spike done / tyrion spike promote <disc-id>
tyrion depends add <slug> <dep> / tyrion wave show / tyrion wave next
```

## The Claude Code Skills (the driver; CLI is the engine)

`/tyrion-orient` (session start, read-only) -> `/tyrion-new` (bootstrap) / `/tyrion-shape --from docs` (documents -> stories) -> `/tyrion-import` (deterministic load) / `/tyrion-add-story` (one story mid-epic) -> `/tyrion-implement <slug>` (9-step build loop) -> `/tyrion-orchestrate` (fan out one subagent per story) -> `/tyrion-checkpoint` (before `/compact`/`/clear`).

`/tyrion-implement` is the heavy lifter: orient+claim -> resume+plan -> per-criterion subagent loop (continuous capture: log a progress note before responding to any new user request, and after every Write/Edit/Bash call) -> UAT runbook -> `/pre-push` (build/strict modes) -> `tyrion done`. Modes: default, `--spike` (no quality gate, exploration), `--tdd=strict` (failing test first), `--dark-factory` (agent runs UAT and closes without human review — pair with a `/goal` directive for unattended epics).

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
- Command is one of those, but the lane has no `in_progress` story → **exit 2**
  (blocks the tool call and tells the agent to run `tyrion start <slug>` first).

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

**Install in another project** (one that has the `tyrion` gem on its PATH):

1. Copy `hooks/claim-gate.sh` into the project (e.g. `hooks/claim-gate.sh`) and
   `chmod +x` it. In a source checkout it finds the library at `../lib`; installed
   as a gem it resolves `require 'tyrion'` from the load path.
2. Add the `PreToolUse` block above to the project's `.claude/settings.json`,
   pointing `command` at wherever you put the script.
3. New sessions pick it up automatically; already-running sessions load hooks at
   start, so restart to activate.
