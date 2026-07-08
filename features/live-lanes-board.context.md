# Live Lanes Board — Epic Context

## Origin

Shaped 2026-07-07 from the Orca (onorca.dev) recon + Tyrion integration-surface survey.
Durable sources: `~/work/cultiv-ai/wiki/research/orca-ade.md` and the "Integration
surface" section of `~/work/cultiv-ai/wiki/research/tyrion.md`.

## Design rationale

Orca's cockpit watches agents at **process altitude** (live terminals, diffs,
bake-offs). Tyrion owns the cross-project ledger, so it is the only layer that can
watch at **fleet altitude** — lanes × stories × liveness. This epic does NOT rebuild
Orca's half (terminal streaming, diff review); it adds the semantic board Orca lacks.
Division of labor: the lanes board tells you which lane needs attention; Orca (or a
terminal) is where you go look at it.

The board doubles as the Rule-of-3 surface: Forrest is productive at ~3 concurrent
things and wants the system, not discipline, to enforce that (transparency +
"reporting back" is his stated #1 system gap).

## Constraints

- Read-only over existing truth: stories.state/claimed_by + story_notes timestamps.
  No new instrumentation, no schema change, no LLM anywhere (IoC Phase 3).
- Fleet scope: rows span ALL projects/epics in the ledger, not just the active project.
- Stalled threshold: 30 minutes, a named constant — not config, not a setting (pareto).

## Deferred (v1.1, explicitly out of scope)

- Per-lane worktree diffstat. Blocked on Tyrion recording the worktree path at claim
  time — session provenance notes today carry the transcript path, not the worktree.
  Schema-adjacent, so it stays out of v1.
- An "attempt/run" concept (needed for Orca-style bake-offs where N agents try the
  same story). Logged as a design note, not this epic.
- Deep links into an Orca task (unverified whether the `orca` CLI can focus a task).

## Key files

- `web/app.rb` — Sinatra app (port 4579); add GET /lanes here.
- `lib/tyrion/store.rb` — sole DB access module; `active_lanes` belongs here.
- Existing POST routes in web/app.rb:201-237 show the app's route conventions.
