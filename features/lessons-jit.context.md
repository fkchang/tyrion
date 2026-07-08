# Lessons (Just-In-Time) — Epic Context

## The Problem in One Sentence

"Never make that mistake again" sounds like a storage problem (write the lesson down) but the
Tyrion session evidence says it's a **delivery-timing problem** — lessons that are already written
down keep recurring anyway.

## Motivating Research

Source note: `~/cultiv-os/research/results/2026-06-30-001-i-d-like-to-understand-more-abo/research.md`
— extract-wisdom of "Anthropic Just Shipped Three of the Five Harness Layers..." (Apr 2026). The
load-bearing claim: Mitchell Hashimoto's principle — "anytime you find a mistake, you engineer a
solution such that the agent never makes that mistake again" — is literally the Verification Layer
(L4), and the article's own framing is "success is silent, failure is loud."

To ground this in real Tyrion data rather than designing in a vacuum, three agents mined the
codebase + 36 real Tyrion session transcripts (Jun 16–30 2026, heavy dogfooding) in parallel before
any design was written.

## The Linchpin Finding

The single highest-cost recurring mistake in the corpus — offering the rspec suite as UAT when
`/pre-push` had already run it — was **already documented** in both auto-memory
(`feedback-uat-no-rspec-after-prepush.md`) and `CLAUDE.md`. Forrest still had to correct it again:

> "this is the 2nd time you offer specs as UAT when you just ran them earlier in /pre-push"

Contrast: the classic low-level style conventions that ARE encoded in CLAUDE.md (`die` not
`stderr.puts`, `presence()` helper, Forrest-not-Fred, 3-hyphen markdown tables) showed **zero
correction events** across the whole corpus.

**Conclusion:** capture is not the gap. A lesson sitting in a file gets skimmed once at session
start and is physiologically bypassed (Gloria's Law) by the time the agent reaches the actual
decision point, often 8 steps later in a different skill. The lessons that hold are the ones
re-injected as fresh, unmissable output at the exact moment they matter — which is exactly how
Tyrion's existing **drift warning** already works (`drift_changed_path` → `print_drift_warning`,
auto-injected into `cmd_status`/`cmd_resume`, silent when nothing changed, loud when it has).

## The Five Seeded Lessons (verbatim, mined by hand — see `lessons-seed-data` story)

| trigger | text |
|---|---|
| `uat` | Don't re-offer the rspec suite as UAT when /pre-push already ran it — use CLI/browser checks instead |
| `pre-push-pass` | Once /pre-push passes, proceed immediately to the next step — don't stop and wait for confirmation |
| `import-existing` | When importing into an existing epic, execute the runbook exactly as written — never silently deviate |
| `start` | Don't run activation and read commands in parallel against the same lane — sequence them |
| `import-existing` | Test import-mutating behavior (e.g. --force on a done story) on a disposable fixture, not the live epic |

Secondary themes mined but NOT seeded as lessons (logged here for traceability, not lost):
permission-prompt friction (drove the separate `tyrion whitelist` feature, not a lesson),
wrong-repo-root bugs (fixed in code, not a recurring judgment call), CLI-output jargon clarity and
UI contrast (Matt's/Gloria's-law design standards, not Tyrion-specific triggers).

## Design Principle

A lesson is **not a stored fact — it's a trigger-bound interrupt** fired fresh into the agent's
context at the named workflow moment where the mistake happens.

- **Matt's Law** — the agent finds the right lesson without searching; it's pushed via the trigger
  tag, not pulled by remembering to look something up.
- **Forrest's Law** — fires automatically inside commands the agent already runs (`status`,
  `resume`, the implement skill's own steps); zero new habit required; ships seeded with real
  proven value instead of an empty table.
- **Gloria's Law** — injected into live, fresh tool output rather than a file requiring active
  recall; silent when nothing applies (no noise → nothing to physiologically bypass), loud exactly
  at the trigger.

## Pareto Cut — What We Deliberately Did NOT Build

- **No fuzzy relevance engine.** No path-globs, no keyword matching against story intent. The
  mined data shows triggers are *named workflow moments* the implement skill already knows it's
  standing on (assembling UAT, just passed pre-push, importing into an existing epic). `trigger`
  is a plain string tag, matched exactly — not a matching/scoring system.
- **No web UI surfacing in this epic.** Implementing agents work at the CLI; surface there first.
  Web attention-rail surfacing (see `web/views/active_story.rb` nudge pattern) is a natural
  follow-on epic once the CLI mechanism is validated, not part of this one.
- **Not the full Constraint/Verification/Lifecycle three-layer stack** from the source article —
  only the Verification "never make that mistake again" loop, because that's where the mined data
  says the actual pain is. Constraint-layer (deterministic pre-flight gates) and Lifecycle-layer
  (cost/runaway tracking) are explicitly deferred until real recurrence justifies them, per the
  article's own "don't pre-build L5" warning and Forrest's `pareto sdrd` instinct.

## Build Order — Why Phase A Ships and Gets Dogfooded Before B and C

Phase A (storage + surfacing) → dogfood checkpoint → Phase B (capture wiring) → Phase C (miner).

The dogfood checkpoint after Phase A is the actual test of the thesis: seed the `uat` lesson, run
a real story through `/tyrion-implement`, and confirm `tyrion lessons --at uat` injected at Step
7.5 changes agent behavior — i.e., it does NOT re-offer rspec as UAT, the exact failure the corpus
documents twice. If just-in-time injection doesn't change behavior, Phase C (automating capture)
would be polishing the wrong half of the problem, so it's sequenced last and is allowed to be
revisited if the checkpoint fails.

## Known Pre-Existing Gap Surfaced During Mapping (relevant to `lessons-failure-capture-wiring`)

`skills/engineering-review/SKILL.md` documents itself as running "automatically by
`/tyrion-implement` (Step 8, rigor Level 3+)" — but the actual repo `skills/tyrion-implement/SKILL.md`
Step 8 only runs `/pre-push` and never invokes `/engineering-review`. Separately, on a
`NEEDS_REVISION` verdict, engineering-review persists nothing to the ledger today — the verdict is
ephemeral console output. Both gaps are exactly the article's "a failed verdict should write back a
constraint or context note, not just block" critique, and are the explicit target of the
`lessons-failure-capture-wiring` story.

## Schema/Pattern References (for the implementing agent — no need to re-derive)

- Idempotent migrations: `MIGRATIONS` constant, `lib/tyrion/store.rb` ~lines 864–975
  (`PRAGMA table_info` guard for ALTER; `CREATE TABLE IF NOT EXISTS` needs no guard).
- Sequential ID-in-transaction pattern: discovery counter, `store.rb` ~lines 630–650
  (`SUBSTR(id, N)` strips the prefix; global counter inside `db.transaction(:immediate)`).
- Surfacing template to copy: `drift_changed_path` / `print_drift_warning`, invoked in
  `cmd_status` (~line 405) and `cmd_resume` (~line 988) — cheap condition, one injected line,
  silent when nothing applies.
- Existing "lane" pattern in `cmd_status` to mirror: DISCOVERIES lane, `commands.rb` ~lines 480–494.
- `cmd_discovery` / `cmd_spike` sub-dispatch pattern (`commands.rb` ~lines 778–838) is the template
  for `cmd_lesson`'s sub-commands.
- `VALID_NOTE_KINDS` / `cmd_note` (`commands.rb` ~line 1054) is the template for command-arg
  validation style, though lessons are their own table, not a note kind (notes are queried
  `WHERE story_id = ?` only — invisible to future, different stories, which defeats the point of a
  lesson).
