---
name: tyrion-implement
description: Use when implementing a Tyrion story. Triggered by phrases like "implement story", "work scenario", "resume implementation", "/tyrion-implement", or when starting or continuing a coding session on a tracked project. This is the killer skill — it owns agent discipline for the entire implementation loop.
---

# /tyrion-implement v0.2

Tyrion-aware implementation loop for one story. Follows a 9-step protocol in strict order — no skipping.

## Invocation

```
/tyrion-implement [slug] [--spike | --tdd=strict|loose|off] [--review] [--no-prepush]
```

### Modes

| Mode | Flag | TDD | Pre-push | When to use |
|---|---|---|---|---|
| **Spike** | `--spike` | off | skipped | Exploring — no test infra expected, discovery-first |
| **Build** | *(default)* | loose | required | Building to keep — tests encouraged, quality gate active |
| **Strict** | `--tdd=strict` | strict | required | Production-grade — failing test must come first |

`--spike` is shorthand for `--tdd=off --no-prepush`. Use it when you're in SDRD discovery mode and haven't decided whether to keep the work yet.

**To promote a spike to a keeper:** re-run `/tyrion-implement <slug>` (no `--spike`) after the story is done. It will apply the quality gate retroactively.

**Fine-grained overrides** (when the named modes aren't quite right):
- `--tdd=loose` — tests encouraged but not blocking (Build default)
- `--no-prepush` — skip pre-push only (keep TDD)
- `--review` — pause at each step boundary for user steering

**Mode resolution** (first match wins):
1. `--spike` flag → TDD off + no pre-push
2. `--tdd=` flag on this invocation
3. `TYRION_TDD` env var (`strict|loose|off`)
4. Default: Build mode (TDD loose + pre-push required)

---

## PROTOCOL — follow each step in order. Do not skip.

### 1. ORIENT

```bash
tyrion init          # idempotent — registers repo if needed
tyrion status        # read the plan view; understand where things are
tyrion project show  # read the project ABOUT.md — anchor on what this app/system *is*
tyrion epic show     # read the epic intent + context_md if present
```

Read all output carefully before proceeding. The ABOUT.md and epic context define the frame — implementation decisions should stay consistent with them.

**Announce the active mode now** — one line, prominently, before anything else:

- Spike mode: `🔬 SPIKE MODE — TDD off, pre-push skipped. Discovery-first. Run /tyrion-implement <slug> (no --spike) when ready to apply quality gates.`
- Build mode: `🏗 BUILD MODE — TDD loose, pre-push required. Tests encouraged. Quality gate active before close.`
- Strict mode: `✅ STRICT MODE — TDD strict, pre-push required. Failing test must come first per criterion.`

This keeps both the user and the agent aligned on what gates are active for this run.

If `--review` mode: pause here and report what you found. Wait for user ok before Step 2.

---

### 2. CLAIM

```bash
# If user supplied a slug:
tyrion start <slug>      # transactional; refuses if any in-epic story already in_progress

# Else if tyrion status shows an in_progress story:
# Story already claimed — use that slug for all subsequent steps.

# Else:
tyrion claim-next        # transactional claim of lowest-sequence pending story
```

**Remember the slug for the rest of this session.** Every subsequent command uses it.

---

### 3. RESUME-STATE SANITY

Ground yourself in reality before touching any code.

```bash
tyrion resume <slug>
```

Read the output carefully:
- `current_context` — what was understood last time
- `next_action` — what was planned next
- recent notes — what actually happened
- unchecked criteria — what still needs to be done
- git branch, worktree path, dirty-file count — ground truth

**If the worktree shows partial edits inconsistent with `current_context`:**

```bash
tyrion note <slug> recovery "found dirty state: <describe what you see in git status>"
tyrion context <slug> "<corrected one-paragraph summary of actual current state>"
tyrion next <slug> "<corrected next action>"
```

Do not proceed to implementation until context and reality are aligned.

---

### 4. PLAN

```bash
tyrion show <slug>   # read full story: intent, criteria, notes
```

**If the story has no criteria yet** (TODO markers left by `/tyrion-shape`):

Propose criteria from the story's title, intent, and epic context. Write them BEFORE any code:

```bash
tyrion criteria add <slug> \
  --given "the precondition that must be true" \
  --when "the action the user or system takes" \
  --then "the observable outcome that proves success"
```

**Criteria sharpness check — apply to every criterion (new or existing):**

Each criterion must contain a *verifiable assertion* — something a human or script can check without interpretation.

- VAGUE: `Then they see who engaged`
- SHARP: `Then GET /priority returns HTTP 200 with at least one account row containing name and score fields`
- VAGUE: `Then the report is generated`
- SHARP: `Then stdout contains "Rows: N" and "Columns: col1, col2" and exits 0`

A criterion is sharp if you can write the UAT runbook step for it (Step 7.5) before writing a single line of code. If you cannot, it is not sharp enough.

**HARD STOP: if any criterion is vague, do not touch code. Rewrite in the source first:**

```bash
# 1. Edit the .feature file — fix the vague Then lines to be sharp
$EDITOR features/<epic-slug>.feature

# 2. Re-import to update the DB (idempotent if hash changed)
tyrion import features/<epic-slug>.feature
```

The `.feature` file is the source of truth. Rewriting criterion text only in evidence (while leaving the vague text in the DB) is **not acceptable** — future agents will see the vague version and the problem repeats.

Then record the plan:

```bash
tyrion note <slug> plan "<your implementation plan — ≤5 sentences>"
tyrion next <slug> "<first concrete action>"
```

If `--review` mode: present the criteria and plan, wait for user ok/steer before Step 5.

---

### 5. IMPLEMENT (Ralph-light, TDD mode-aware)

**The orchestrator (you) never implements directly.** For each unmet criterion, spawn a fresh subagent.

#### Per-criterion cycle:

**a. Spawn a fresh subagent** with exactly this context:
- The criterion text (Given/When/Then)
- The story's `current_context` and `next_action` from `tyrion resume`
- The relevant file paths the subagent should read (from your Step 4 plan)
- The active TDD mode
- The test command to run (if applicable; e.g., `bundle exec rspec spec/...`, `ruby -Ilib test/...`)

Subagent instructions vary by TDD mode:

**strict**: "Write a failing test for this criterion first. Run it to confirm it's red. Then implement until green. Return: files changed, full test command + verbatim output."

**loose**: "Implement the criterion. Write a test if it can be done without significant overhead. Return: files changed, test output if run, or the exact command + expected output that proves the criterion."

**off**: "Implement the criterion. Return: files changed, the exact command + expected output that proves the criterion works (e.g., a curl command with response body, or a script invocation with its output)."

**b. The orchestrator receives the subagent's return** and writes evidence immediately:

```bash
tyrion note <slug> progress "criterion <N>: <files changed, verbatim test/command output>"
```

Evidence must be *verbatim* — paste the actual output, not a paraphrase. This is what makes notes re-verifiable after a crash.

**c. Mark the criterion met:**

```bash
tyrion check <slug> <position> "<evidence — must be reproducible>"
```

Evidence shape by mode:
- strict/loose (with test): `"<test_path>:<line> — <test command> → PASSED"`
- off: `"curl http://localhost:PORT/route → HTTP 200, body: <actual snippet>"`

**d. Update resume state:**

```bash
tyrion context <slug> "<one-paragraph: what is implemented, what is pending>"
tyrion next <slug> "<next concrete action>"
```

**Repeat a–d for each unchecked criterion in order.**

Do not batch these. Each criterion is its own spawn-capture-note-check cycle.

---

### 6. ON BLOCKER

When you hit a blocker (can't proceed, need info, dependency missing):

```bash
tyrion note <slug> blocker "<what the blocker is and what you already tried>"
tyrion next <slug> "<best recovery step when resumed>"
```

Then either resolve it or stop. Do not thrash.

---

### 7. CONTINUOUS CAPTURE (hard rule)

**Any Write, Edit, or Bash tool call made while the story is in_progress — for any reason, planned or ad-hoc, in-scope or off-scope, user-requested or agent-initiated — MUST be followed immediately by:**

```bash
tyrion note <slug> progress "<what changed, why, which files>"
```

Before responding each turn, confirm: "did anything change since my last tyrion note? if yes, note it now."

This rule closes the beads-style drift where interactive follow-ons (run the server, add an index route, restart a process) escape the ledger. The story is in_progress until `tyrion done` — everything that happens during that time belongs in the ledger.

---

### 7.5. UAT RUNBOOK

Before closing, write a runbook so the user can verify the story independently:

```bash
tyrion note <slug> handoff "<UAT runbook: per-criterion steps>"
```

Runbook format — one entry per criterion:

```
Criterion 1 — <Given/When/Then summary>
  $ <exact command to run>
  Expected: <exact output or HTTP response to look for>
  Edge case: <one additional check, if applicable>

Criterion 2 — ...
```

The runbook must be executable: copy-paste the command, see the expected output. If you cannot write a runbook step, the criterion evidence (Step 5c) was not sharp enough — go back and sharpen it.

If `--review` mode: present the runbook. User can run it now to verify, or skip if trust is high.

---

### 8. REVIEW (quality gate)

**Spike mode (`--spike`):** Skip pre-push. Instead, print:

```
🔬 SPIKE — quality gate skipped. To promote this story to production-grade:
  /tyrion-implement <slug> --tdd=loose   (apply pre-push + encourage tests)
  /tyrion-implement <slug> --tdd=strict  (apply pre-push + require failing test first)
```

**Build or Strict mode:** Run `/pre-push`. It covers tests + quality (DHH) + docs + ai-slop.

```
/pre-push
```

If `/pre-push` finds blocking issues: fix them, re-run, do not close until it passes. Do not rationalize past a required step failure — use `--spike` if this is genuinely a throwaway with no test infra, or fix the underlying issue.

If `--review` mode: share the /pre-push output. Wait for user ok before Step 9.

---

### 9. CLOSE

```bash
tyrion done <slug> "<one-paragraph completion summary: what was built, key decisions made, what the next story should know>"
tyrion status   # verify plan view shows the story as done
```

`tyrion done` refuses if any criterion is still `pending` (unless `--force`). That refusal is the quality gate — don't bypass it without a written reason.

The completion summary should reference or embed the UAT runbook note so the ledger is self-contained.

---

## Why this protocol works

- **Verbatim evidence** (Steps 5b/5c) makes notes re-verifiable — "I did X" is hearsay; a pasted test output is a fact.
- **Fresh subagent per criterion** (Step 5a) prevents context bloat from corrupting evidence quality mid-story.
- **Continuous capture** (Step 7) closes the beads-style drift — interactive follow-ons don't escape the ledger.
- **UAT runbook** (Step 7.5) makes criteria self-enforcing — if you can't write the step, the criterion was never testable.
- **/pre-push** (Step 8) makes quality consistent and non-negotiable before close.
- **Gloria's Law**: the skill owns the discipline. The agent doesn't remember to update Tyrion — these instructions tell it exactly when, with literal commands.
