# Superpowers Stack Integration — Design

Goal (Forrest, 2026-07-06): take Tyrion to the next level by adopting what makes
obra/superpowers great — the coherent brainstorm → spec → plan → agent-driven-development
chain and its self-sufficient subagent execution — while keeping Tyrion light, invoking
superpowers skills instead of duplicating them, adding gate traceability to the ledger
(pre-push results, code review verdicts, commits — even "no changes"), and making Codex
vetting a first-class flag.

## What the study found

### Superpowers (v5.0.5, installed locally)

The chain, with exact handoff contracts:

1. **brainstorming** — collaborative dialogue, one question at a time, 2-3 approaches.
   Output: spec at `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`, committed,
   validated by a spec-document-reviewer subagent loop (max 3 iterations then human).
   Terminal state: invoke writing-plans.
2. **writing-plans** — bite-sized checkbox tasks (2-5 min each), exact file paths,
   complete code in plan, exact commands with expected output. Output:
   `docs/superpowers/plans/YYYY-MM-DD-<feature>.md` with a required header telling
   agentic workers to use subagent-driven-development. Plan-reviewer subagent loop.
3. **subagent-driven-development** — the "so agentic and self-sufficient" part:
   - Fresh implementer subagent per task; controller pastes full task text (subagent
     never reads the plan file). Questions surfaced *before* work.
   - Implementer statuses: `DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT`, with
     an explicit escalation ladder: more context → more capable model → split task → human.
   - **Two-stage review after every task**: (1) spec-compliance reviewer — "do not trust
     the report", reads the actual code, flags missing/extra/misunderstood with file:line;
     (2) code-quality reviewer (`superpowers:code-reviewer` agent) — returns
     Strengths / Issues (Critical|Important|Minor) / Assessment. Fix → re-review loops.
   - Review is diff-based: `BASE_SHA`/`HEAD_SHA` bracket each task. **Commits are the
     unit of review** — this is the traceability hook Tyrion can adopt.
   - Model selection by task complexity (cheap for mechanical, capable for review).
4. **test-driven-development** — "NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST",
   red-green-refactor, delete code written before its test.
5. **verification-before-completion** — "NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION
   EVIDENCE" — same philosophy as Tyrion's verbatim-evidence rule.
6. **finishing-a-development-branch / using-git-worktrees** — merge/PR mechanics and
   isolated workspaces.

### Tyrion today (gaps this epic closes)

- `/tyrion-implement` v0.3 has modes trivial|spike|build|strict, per-batch subagents,
  `/pre-push` at Step 8, UAT pause at Step 9. But:
- **`--dark-factory` (`--adequate`/`--mediocre`) is documented in the README and
  implemented nowhere** — not in the skill, not in lib.
- `/tyrion-orchestrate` fans out one subagent per story running `/tyrion-implement` —
  but the implement protocol *pauses at UAT to ask the human*, which a subagent cannot
  answer. Dark-factory mode is the missing piece that makes implement subagent-safe.
- `story_notes.kind` CHECK allows only
  `plan|progress|decision|blocker|test|handoff|recovery|session|followup` — no gate,
  commit, review, or vet records. No commit SHA is captured anywhere. Pre-push results
  and review verdicts live only in session transcripts (lost on /clear).
- Prior stated intent (2026-05-27, hedgeye-admin session): "write up a plan, have
  /codex vet it, then I want to ingest that plan into tyrion" — never made mechanical.
- `/design-review` skill already does adversarial Codex plan review with verdict
  `SHIP IT | SIMPLIFY | RETHINK` — it just isn't wired into the Tyrion loop or ledger.

## Design principles

- **Don't duplicate the wheel** — invoke `superpowers:brainstorming`, `writing-plans`,
  `test-driven-development`, and `code-reviewer` directly. Tyrion adds what superpowers
  lacks: a durable ledger, resumability across /clear, and gate traceability. Superpowers
  adds what Tyrion shouldn't rebuild: brainstorm/plan/TDD/review discipline.
- **Stay light** — no new tables. Gates and commits are `story_notes` rows with two new
  kinds (`gate`, `commit`) and structured `metadata` JSON (column already exists).
  Rendering is a GATES section in `tyrion show`/`resume`. Web UI display deferred.
- **Traceability = append-only history** — every gate run is recorded, pass AND fail.
  A story that failed pre-push twice before passing shows three gate notes. "No commits —
  no changes required" is an explicit record, not an absence.
- **Gloria's Law** — the skill wires gate recording into Step 8 so the agent never has
  to remember; the flags (`--vet`, `--dark-factory`) make rigor and autonomy one-word
  decisions.

## The four workstreams

### WS1 — Gate + commit traceability (the ledger learns about quality)

- Migration (existing MIGRATIONS pattern): extend `story_notes.kind` CHECK with
  `gate` and `commit`.
- `tyrion gate <slug> <gate-name> pass|fail [--detail "..."] [--meta '<json>']`
  — gate-name is a free-form tag (convention: `pre-push`, `code-review`, `spec-review`,
  `codex-vet`, `uat`), same no-registry philosophy as lesson triggers. Body format:
  `<gate-name>: PASS|FAIL — <detail>`.
- `tyrion commits <slug>` — records `git log --oneline` for commits on the current
  branch since the story's `started_at` as a `commit` note; when empty, records
  `no commits — no changes required`. Auto-invoked by `tyrion done`.
- `tyrion show` / `tyrion resume` render a GATES section: latest result per gate name
  (✓/✗) plus run count, and the commit record.
- `/tyrion-implement` Step 8 wraps `/pre-push`: record `pre-push` gate pass/fail with
  the failing steps in `--detail`. Failures are recorded *before* fixing — the history
  shows the journey.

### WS2 — Codex vetting first-class (`--vet`)

- `--vet` flag on `/tyrion-plan` and `/tyrion-implement`: after the plan step, run the
  existing `/design-review` skill (codex exec), record `codex-vet` gate:
  SHIP IT → pass; SIMPLIFY/RETHINK → fail with concerns in detail; revise plan and
  re-vet before implementing.
- `/tyrion-shape` can stamp `RIGOR: strict+vet` so vetting is decided at shape time
  and the implement session never has to ask.
- Post-implementation vet variant: Codex reviews the diff (BASE/HEAD from the commit
  record) — same gate, `codex-vet` name, recorded identically.

### WS3 — Superpowers pipeline handoff (superpowers front-end, Tyrion ledger)

- Recommended flow documented in README:
  `superpowers:brainstorming → superpowers:writing-plans → /tyrion-shape --from <plan> →
  /tyrion-implement` (optionally `--vet`, optionally `/tyrion-orchestrate`).
- `/tyrion-shape --from` recognizes the superpowers plan format (checkbox Task N
  sections → stories/criteria; spec doc → epic context_md; plan path → `Plan file:`
  line so Step 1 of implement injects PLAN_SECTION into every subagent).
- `/tyrion-implement` strict mode: subagent prompts invoke
  `superpowers:test-driven-development` instead of restating TDD inline.
- Optional two-stage review at Step 8 (`--review-stack=superpowers`): spec-compliance
  reviewer (criteria + evidence vs actual diff — Tyrion's criteria ARE the spec) then
  `superpowers:code-reviewer` (BASE/HEAD from commit capture). Verdicts recorded as
  `spec-review` and `code-review` gates with Critical/Important/Minor counts in
  metadata. Critical or Important issues → gate fail → fix → re-review (superpowers'
  loop, Tyrion's record).

### WS4 — Dark factory for real + dogfood (mediocre/adequate mode)

- Implement `--dark-factory` (aliases `--adequate`, `--mediocre`) in
  `/tyrion-implement`: never prompt; run the UAT runbook itself (playwright-cli /
  CLI checks) and record results as a `uat` gate; auto pre-claim next story; on vague
  criteria, `tyrion block` the story instead of asking (the criteria-sharpness HARD
  STOP becomes a block, not a question); quality gates still run — dark factory is
  "you're not in the loop", not "no loop".
- This makes `/tyrion-implement` subagent-safe, which `/tyrion-orchestrate` has been
  assuming all along.
- Dogfood: run the tail of this very epic via `/tyrion-orchestrate` with dark-factory
  subagents. The gate records ARE the scorecard: pre-push fails, review verdicts,
  uat results, commits per story. Findings become lessons (`tyrion lesson add`) and a
  verdict note on "how well do subagents run in mediocre mode."

## Deferred (deliberately, to stay light)

- Web UI gates display — `tyrion show` is the surface for now; add a web lane when the
  CLI rendering proves its shape.
- New tables (gates, events, commits) — notes + metadata JSON carry it; promote to a
  table only if querying across stories becomes a real need.
- superpowers `finishing-a-development-branch` integration — personal projects commit
  to main; revisit for work projects.
- Auto-invoking engineering-review — stays manual per its SKILL.md.
