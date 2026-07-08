# parallel-execution — Cross-cutting context

Plan file: ~/.claude/plans/let-s-revisit-the-parallel-clever-tiger.md
  → MVP plan (approved 2026-06-17, empirically grounded). READ THIS FIRST before implementing any story.
  → Contains: full tier model, per-lane file layout, 5 MVP stories with implementation detail, spike findings.
Original full design: ~/.claude/plans/so-what-i-think-magical-conway.md (background; MVP plan supersedes it).

## Why process identity (not session id)

The /clear empirical finding (2026-06-16): `/clear` rotates the session id — it writes a brand-new
JSONL with a new sessionId (parentUuid:null, no back-link). `CLAUDE_CODE_SESSION_ID` equals that
rotating JSONL id, so it also rotates on /clear. The OS `claude` process does NOT restart on /clear
(in-process conversation reset). Therefore: key off process identity, never the session id.
See memory: clear-rotates-session-id.

## Lane token tiers (empirically verified 2026-06-17 — UPDATED from spike findings)

1. `TYRION_LANE` explicit env — universal, sandbox-safe. Set by skill/dispatch. Returns verbatim.
2. `CODEX_THREAD_ID` env → `"codex:<thread-id>"` — **Codex is sandboxed; ps is denied ("Operation not
   permitted")**. This is the Codex-safe identity. Do NOT attempt ps walk under Codex.
3. Process-walk `ps -o ppid=,comm=` up to nearest `claude|codex|gemini` ancestor (basename match) →
   `"claude:<pid>:<stamp>"` — terminal-agnostic for un-sandboxed claude (verified: cmux + iTerm).
4. `CMUX_CLAUDE_PID` env — fast-path accelerator for tier 3 in cmux; skips the ps walk. Never load-bearing.
5. nil → legacy single-session (shared .tyrion/active-epic, claimed_by=NULL).

Token format union: `"claude:<pid>:<stamp>"` (walk path) OR `"<agent>:<session-id>"` (sandbox path).
Only stability + uniqueness per lane is required. See Commands.current_lane_token (commands.rb).

SECURITY: never run broad env dumps in Codex — the env carries live API keys. Probe only named vars.

PID start-stamp: `ps -o lstart=`, normalize whitespace, SHA256 hex prefix [0,16]. Rescue → nil on
ps denied. macOS only (`ps -o lstart`); Linux `/proc/<pid>/stat` field 22 is more stable but not needed here.

## Codex vet correctness points (must respect during implementation)

1. TWO partial indexes, not one. A single `(epic_id, claimed_by) WHERE in_progress` index would allow
   multiple NULL-owned in_progress stories per epic (SQLite allows multiple NULLs in a unique index).
   Use: `(epic_id, claimed_by) WHERE in_progress AND claimed_by IS NOT NULL` PLUS
        `(epic_id) WHERE in_progress AND claimed_by IS NULL`.

2. Double-claim safety is `BEGIN IMMEDIATE`, not `RETURNING`. The existing SELECT-then-UPDATE inside
   transaction(:immediate) is already double-claim-safe; RETURNING is convenience only. The
   busy_timeout is not a guarantee — surface claim as retryable on SQLite3::BusyException.

3. `complete_story` / `unstart_story` / `block` MUST NULL `claimed_by` and `claimed_at`. Currently
   complete_story (store.rb:415) does not — a done story would otherwise keep its lane token and a
   reused PID could appear to own it.

4. Same-dir two-agent file collisions are REAL. DB ownership is safe (distinct PIDs → distinct tokens);
   file isolation is NOT (both agents edit files in the same working tree). Mitigation: `status` and
   `worktrees` show "N lanes share this working tree" warning; the skill runs a dirty/clean check
   before editing. Worktrees remain the recommended isolation for code work.

## Data model (stories table additions)

```
claimed_by TEXT   — lane token "agent:pid:stamp" or "assigned:<label>" placeholder; NULL = legacy
claimed_at TEXT   — ISO8601 stamp; feeds staleness display; cleared on done/unstart/block
```

Wave orchestration layer (B2, separate concern):
```
depends_on TEXT       — JSON array of slugs; the one durable dependency truth
wave_override INT     — nullable; pure-preference reordering independent of depends_on
wave_rationale TEXT   — why the planner ordered it (traceability)
```

## Supersession notes

These 13 stories fold in and rewrite the earlier scattered versions:
- `relax-in-progress-index` + `claim-next-as-pool` + `active-story-pin` (parallel-execution):
  absorbed and updated with the process-identity correctness points above.
- `tyrion-worktrees-command` (web-epics-multitab): the original story's criteria assumed
  cross-worktree navigation; this version is a process-identity cross-lane dashboard. Leave the
  web-epics-multitab version in place for now (it is in a separate epic and won't conflict); reconcile
  the two when implementing the web-epics-multitab epic.
- The `NOTE: Do NOT implement in the same session as web-epics-multitab` in the old feature file is
  intentionally dropped — that guard was against the old worktree-only design. The new design (DB
  ownership, process tokens) is safe to implement alongside other work.

## No PROTOTYPE

This is CLI/library work only. No visual spec needed.
