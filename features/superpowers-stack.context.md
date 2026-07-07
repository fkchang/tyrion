# Superpowers Stack Integration — Epic Context

Plan file: docs/superpowers-stack-design.md

## The Problem in One Sentence

Superpowers has the coherent brainstorm→spec→plan→agentic-execution chain and Tyrion has
the durable ledger — but they don't talk, quality-gate outcomes (pre-push failures, review
verdicts, commits) evaporate with the session, Codex vetting is a manual ritual, and the
README's `--dark-factory` mode is documented but implemented nowhere.

## What This Epic Is NOT

- Not a reimplementation of superpowers skills. brainstorming, writing-plans,
  test-driven-development, and code-reviewer are invoked as-is (installed at
  `~/.claude/plugins/cache/superpowers-marketplace/superpowers/5.0.5/`). Tyrion adds the
  ledger layer they lack.
- Not new tables. Gates and commits are `story_notes` rows with two new kinds
  (`gate`, `commit`) + the existing `metadata` JSON column. Web UI display deferred.

## Key Design Decisions

1. **Gate = append-only note, free-form gate-name tag** (`pre-push`, `codex-vet`,
   `code-review`, `spec-review`, `uat`) — same no-registry philosophy as lesson triggers.
   Failures are recorded before fixing; history shows the journey, not just the outcome.
2. **Commits captured at `tyrion done`** — `git log` since `started_at` on the current
   branch; the empty case records "no commits — no changes required" explicitly (an
   absence is not a record; Forrest asked for the no-changes case specifically).
3. **`--vet` wraps the existing `/design-review` skill** (codex exec, verdict
   SHIP IT|SIMPLIFY|RETHINK). SHIP IT → gate pass; otherwise fail → revise → re-vet.
   `RIGOR: strict+vet` from shape makes it zero-friction. This mechanizes the stated
   2026-05-27 intent: "write up a plan, have /codex vet it, then ingest into tyrion."
4. **Dark factory makes /tyrion-implement subagent-safe.** `/tyrion-orchestrate` already
   dispatches subagents that run the full implement protocol — which pauses at UAT to ask
   a human who isn't there. Dark factory replaces every prompt with an autonomous action
   + gate record (UAT self-run → `uat` gate; vague criteria → `tyrion block`, never guess).
5. **Two-stage review borrowed from superpowers**: spec-compliance (criteria+evidence vs
   actual diff — Tyrion's criteria ARE the spec) then code-quality
   (`superpowers:code-reviewer` over BASE/HEAD SHAs from the commit record). Opt-in via
   `--review-stack=superpowers`; verdicts land as gates.

## Story Dependencies

```
gate-ledger
  → commit-capture
  → prepush-gate-wiring
  → codex-vet-flag
  → superpowers-review-gate   (also needs commit-capture for BASE/HEAD)
  → dark-factory-mode         (needs uat gate recording)
      → dogfood-dark-factory-orchestrate
superpowers-pipeline-handoff   (independent — docs + shape skill only)
```

Suggested waves: W1 gate-ledger · W2 commit-capture, prepush-gate-wiring,
superpowers-pipeline-handoff · W3 codex-vet-flag, superpowers-review-gate,
dark-factory-mode · W4 dogfood-dark-factory-orchestrate.

The dogfood story is the point: W1-W2 build supervised, then the tail of the epic runs
through orchestrate + dark-factory subagents, and the new gate records score the run.

## Rigor / Batching

| Story | RIGOR | Notes |
|---|---|---|
| gate-ledger | strict | migration + CLI + rendering, one subagent |
| commit-capture | strict | git interrogation + done hook |
| prepush-gate-wiring | trivial | SKILL.md text only |
| codex-vet-flag | loose | wraps existing /design-review |
| superpowers-review-gate | loose | dispatches existing agent |
| superpowers-pipeline-handoff | loose | shape skill + README |
| dark-factory-mode | loose | SKILL.md protocol changes |
| dogfood-dark-factory-orchestrate | loose | meta-story, gate scorecard |
