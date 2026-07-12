---
name: tyrion-implement
description: Use when implementing a Tyrion story. Triggered by phrases like "implement story", "work scenario", "resume implementation", "/tyrion-implement", or when starting or continuing a coding session on a tracked project. This is the killer skill — it owns agent discipline for the entire implementation loop.
---

# /tyrion-implement v0.3

Tyrion-aware implementation loop for one story. Follows a 9-step protocol in strict order — no skipping.

## Invocation

```
/tyrion-implement [slug] [--spike | --trivial | --tdd=strict|loose|off] [--review] [--no-prepush] [--plan=<path>] [--dark-factory | --adequate | --mediocre] [--vet] [--review-stack=superpowers]
```

### Modes

| Mode | Flag | TDD | Pre-push | Subagents | When to use |
|---|---|---|---|---|---|
| **Trivial** | `--trivial` | off | skipped | none — orchestrator implements directly | Mechanical edits: nav tweaks, rake tasks, simple migrations, throwaway dev tooling |
| **Spike** | `--spike` | off | skipped | per-batch | Exploring — no test infra expected, discovery-first |
| **Build** | *(default)* | loose | required | per-batch | Building to keep — tests encouraged, quality gate active |
| **Strict** | `--tdd=strict` | strict | required | per-batch | Production-grade — failing test must come first |
| **Dark factory** | `--dark-factory` | per underlying mode | required | per-batch | Unattended runs + orchestrate subagents — agent reviews its own work, never prompts |

`--trivial` — orchestrator implements all criteria directly, no subagent spawning, no UAT runbook, no pre-push. Use for edits where the right answer is obvious from the plan and ceremony costs more than the change.

`--spike` is shorthand for `--tdd=off --no-prepush`. Use when in SDRD discovery mode and you haven't decided whether to keep the work yet.

**`--dark-factory`** (aliases: `--adequate`, `--mediocre` — all three identical) — no human in the loop. Orthogonal to the TDD modes above: it composes with build or strict (default: build) and changes *who reviews*, not *whether* quality gates run. The agent runs the UAT runbook itself and records the result as a `uat` gate, never prompts, and pre-claims the next story automatically. Incompatible with `--review` (contradictory — refuse the combination and say why). This is the mode `/tyrion-orchestrate` subagents must run in: a subagent has no human to answer the Step 9 prompts. Use when "done" is the bar, not "great" — distinct from `--spike`, which skips the quality gate entirely because spike output is disposable.

**To promote a spike or trivial story to a keeper:** re-run `/tyrion-implement <slug>` (no `--spike`/`--trivial`) after done. It applies the quality gate retroactively.

**Fine-grained overrides:**
- `--tdd=loose` — tests encouraged but not blocking (Build default)
- `--vet` — Codex vets the plan before implementation (Step 4); verdict recorded as a `codex-vet` gate. Also auto-activates from a `RIGOR: <mode>+vet` tag in `[plan]` notes (set by `/tyrion-shape`), so shape can decide vetting once and no session ever has to ask.
- `--no-prepush` — skip pre-push only (keep TDD)
- `--review` — pause at each step boundary for user steering
- `--plan=<path>` — explicit plan file; overrides `Plan file:` in epic context_md
- `--review-stack=superpowers` — add a two-stage review at Step 8 (after `/pre-push`): a spec-compliance reviewer subagent and the `superpowers:code-reviewer` agent, verdicts recorded as `spec-review` and `code-review` gates. Off by default; see Step 8.

**Mode resolution** (first match wins):
1. `--trivial` flag → TDD off + no pre-push + orchestrator implements directly
2. `--spike` flag → TDD off + no pre-push
3. `--tdd=` flag on this invocation
4. `TYRION_TDD` env var (`strict|loose|off`)
5. **`RIGOR:` tag in story's `[plan]` notes** (set by `/tyrion-shape` at import time) → maps trivial/loose/strict automatically
6. Default: Build mode (TDD loose + pre-push required)

The RIGOR tag is the zero-friction path: when `/tyrion-shape` ingested the plan, it already assessed each story. Read it in Step 3 and act on it — never ask the user to specify a mode that shape already decided.

**Dark-factory is orthogonal to this resolution** — `--dark-factory`/`--adequate`/`--mediocre` modifies whichever TDD mode wins above (default: build). It never changes TDD or pre-push requirements; it only replaces every user prompt with the autonomous action + gate record described in Steps 4 and 9. `--dark-factory` with `--review` must refuse (`--review` means pause for the user at every boundary; dark factory means there is no user).

---

## PROTOCOL — follow each step in order. Do not skip.

### 1. ORIENT

**Derive your lane token FIRST — before any other tyrion call.**

Every tyrion command self-identifies its lane through `Commands.current_lane_token`, which resolves in tiers: `TYRION_LANE` env (verbatim) → `CODEX_THREAD_ID` (→ `codex:<id>`, sandbox-safe) → process-walk (`claude:<pid>:<stamp>`) → `CMUX_CLAUDE_PID` accelerator → nil (legacy single-session). Ask the helper for the token once and export it so the whole shell reuses one stable, sandbox-safe identity:

```bash
export TYRION_LANE="$(ruby -rtyrion -e 'puts Tyrion::Commands.current_lane_token')"
```

This is idempotent: if `TYRION_LANE` is already set (a dispatcher or `/tyrion-orchestrate` set it), the helper returns it verbatim and the export is a no-op. If it is unset, the helper derives from process identity (or `CODEX_THREAD_ID` under Codex, where `ps` is denied) — the same OS process yields the same token across `/clear`, so re-running ORIENT after a clear re-derives an identical lane. There is no hardcoded session/JSONL path anymore; identity comes from the process, not a file.

If your environment does not persist `export` across separate shell invocations (e.g. Claude Code, where each Bash tool call is a fresh shell), inline `TYRION_LANE=<token>` on every tyrion command instead — same token, just prefixed rather than exported.

**Worktrees are optional.** A lane is identified by its token, not by its directory, so multiple lanes can share a single checkout. But same-directory lanes edit the same files: two agents implementing different stories in one working tree will collide on the filesystem even though the ledger keeps their ownership straight. Prefer a dedicated `git worktree` per lane when stories touch overlapping code; a shared directory is only safe when the lanes are read-only or you are certain their edits never overlap.
tyrion status        # read the plan view; understand where things are
tyrion project show  # read the project ABOUT.md — anchor on what this app/system *is*
tyrion epic show     # read the epic intent + context_md if present
tyrion lessons --at start   # just-in-time: lessons relevant to starting/orienting work
```

Read all output carefully before proceeding. The ABOUT.md and epic context define the frame — implementation decisions should stay consistent with them. `tyrion status` already surfaces a LESSONS lane ambiently when any apply to the active project/epic; `tyrion lessons --at start` is the targeted, fresh-output version — if it prints anything, follow it before doing anything else. It prints nothing when no `start`-triggered lessons exist (silent on none — don't report "no lessons found").

**Visual/prototype check — do this before Step 2:**

If the epic context_md contains a `PROTOTYPE:` line, or if the story's `[plan]` note contains a prototype template source:

- The prototype is the visual spec. Text descriptions in the plan are supplementary — they describe structure. The prototype shows what it should actually look like and how it should behave.
- For UI stories (views, components, tabs, nav): you must look at the prototype before writing any code. Navigate to the relevant page/view in the running app (or read the template source in the plan note). What you see is what you're building.
- If the plan note contains the prototype template source verbatim, read it now and treat it as the primary implementation reference — not a hint, the actual target.
- A story that passes tests but looks nothing like the prototype is not done.

**Plan file extraction — do this before Step 2:**

If the epic context_md contains a `Plan file:` line, OR `--plan=<path>` was passed:

1. Read the plan file now.
2. Find the section for the current story (match by slug, story number, or title).
3. Extract and hold: exact file paths, implementation code/pseudocode, gotchas, and any per-criterion implementation notes.
4. Record: `PLAN_SECTION = <extracted text>` — you will inject this into every subagent prompt in Step 5.

If no plan file is found, proceed normally — you will derive the plan from criteria and epic context in Step 4.

**Announce the active mode now** — one line, prominently:

- Trivial mode: `⚡ TRIVIAL MODE — orchestrator implements directly, no subagents, no pre-push. Fast path for mechanical changes.`
- Spike mode: `🔬 SPIKE MODE — TDD off, pre-push skipped. Discovery-first. Run /tyrion-implement <slug> (no --spike) when ready to apply quality gates.`
- Build mode: `🏗 BUILD MODE — TDD loose, pre-push required. Tests encouraged. Quality gate active before close.`
- Strict mode: `✅ STRICT MODE — TDD strict, pre-push required. Failing test must come first per criterion.`
- Dark factory (appended to the underlying mode's banner): `🏭 DARK FACTORY — no human in the loop. UAT self-run and recorded as a uat gate. "Done" is the bar, not "great".`

If `--review` mode: pause here and report what you found. Wait for user ok before Step 2.

---

### 2. CLAIM

Your lane token is derived and exported (Step 1), so every `tyrion` command self-identifies your lane. Claiming is lane-aware — it resolves against *your* token, not global state.

```bash
# If the user supplied a slug — start that specific story:
tyrion show <slug>                 # find which epic owns this story
tyrion epic activate <epic-slug>   # only if that epic isn't already active — never ask the user to do this manually
tyrion start <slug>                # transactional; stamps claimed_by = your lane token; refuses if any in-epic story is already in_progress

# Otherwise — no slug given:
tyrion claim-next                  # no-arg, lane-aware (see below)
```

**No-arg `tyrion claim-next` is the resume-safe claim.** It self-identifies your lane and resolves in two outcomes:

- If your lane already owns an `in_progress` story (its `claimed_by` matches your token), claim-next returns that same story — **rung 2** of the resolver. This is what makes it idempotent across `/clear`: re-running ORIENT + `tyrion claim-next` in a fresh context re-adopts the story you were already on, because the token is derived from your process/env, not from your memory.
- Otherwise it claims the lowest-sequence pending story and stamps `claimed_by = <your lane token>` — **rung 6**. That stamp is the ownership record.

Never pass a slug to `claim-next` to "resume" — bare `tyrion claim-next` already returns your in-flight story. Use an explicit slug only to *start a specific new story* (via `tyrion start <slug>`, which also stamps `claimed_by`).

**Auto-activate the right epic.** If a supplied slug lives in a different epic than the active one, activate that epic before claiming. Never tell the user to run `tyrion epic activate` manually — that is the skill's job.

**Remember the slug for the rest of this session.** Every subsequent command uses it.

**Ownership lives in `claimed_by`, not in a note.** Both `tyrion start` and `tyrion claim-next` stamp the story's `claimed_by` column with your lane token. That column is the authoritative record of who owns the story; it is what survives `/clear` and lets a resuming context re-adopt its own work (rung 2 above). You do not need to write anything to establish ownership — the claim already did it.

**Optionally drop a session breadcrumb for postmortem** — a transcript pointer, nothing more:

```bash
tyrion note <slug> session "${TYRION_AGENT:-claude}:${TYRION_SESSION_ID:-$TYRION_LANE}"
```

This is a convenience for reading back the decision trail later (`tyrion show <slug>` → session note → open that transcript). It is *not* how ownership is tracked — `claimed_by` is — so skip it freely; the story is fully owned without it. There is no JSONL-path discovery here anymore: the breadcrumb carries the agent's own session id if it exports one (`TYRION_SESSION_ID`), else falls back to the lane token.

**Name the session after the story (for badge visibility and GEA orientation):**

```bash
# Claude Code — updates the session badge and triage UI (self-detects the current session)
/Users/fkchang/work/claude_code_history/bin/name-session "tyrion: <slug>" 2>/dev/null || true

# Any terminal — set OS window title as fallback
printf '\e]2;tyrion: <slug>\a' 2>/dev/null || true
```

Both are safe no-ops if the target isn't available. The badge/title stays for the life of the session so GEA tab switching always shows which story is in flight.

---

### 3. RESUME-STATE SANITY

Ground yourself in reality before touching any code.

```bash
tyrion resume <slug>
```

**Never query the tyrion SQLite DB directly.** The schema is internal and changes without notice. Everything you need is available through tyrion CLI commands — `tyrion resume`, `tyrion show`, `tyrion status`. If a CLI command doesn't surface what you need, that's a gap to note, not a reason to reach for sqlite3.

Read the output carefully:
- `current_context` — what was understood last time
- `next_action` — what was planned next
- recent notes — what actually happened; **look for `[plan]` notes — these contain `RIGOR:`, `BATCHING:`, and `PLAN:` set by `/tyrion-shape`. Read them now and lock in the mode before Step 4.**
- unchecked criteria — what still needs to be done
- git branch, worktree path, dirty-file count — ground truth
- **`Lessons:` section, if present** — `tyrion resume` auto-surfaces any active lesson scoped to the current project/epic/story (same ambient mechanism as the drift warning). If shown, it is not optional context — follow it for the rest of the session, same as a `tyrion lessons --at start` result in Step 1.

**If a `[plan]` note contains `RIGOR: trivial` → switch to trivial mode now, no override needed. If `RIGOR: strict` → switch to strict. If `RIGOR: loose` → stay in build mode. A `+vet` suffix (e.g. `RIGOR: strict+vet`) additionally activates vet mode — Codex reviews the plan at Step 4 before any implementation. This is the decision `/tyrion-shape` already made from the plan — don't re-derive it.**

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

**If a PLAN_SECTION was extracted in Step 1:** use it as the primary implementation plan. Extract file paths, code structure, and gotchas from it. Record the plan in a single note:

```bash
tyrion note <slug> plan "Using plan file section: <1-2 sentence summary of what it specifies>"
tyrion next <slug> "<first concrete action from the plan>"
```

**If no plan file exists:** derive the plan from criteria, epic context, and existing code. Write it as ≤5 sentences:

```bash
tyrion note <slug> plan "<your derived implementation plan>"
tyrion next <slug> "<first concrete action>"
```

**Criteria sharpness check — apply to every criterion (new or existing):**

Each criterion must contain a *verifiable assertion* — something a human or script can check without interpretation.

- VAGUE: `Then they see who engaged`
- SHARP: `Then GET /priority returns HTTP 200 with at least one account row containing name and score fields`

A criterion is sharp if you can write the UAT runbook step (Step 7.5) before writing any code. If you cannot, it is not sharp enough.

**HARD STOP — criterion sharpness is a requirements decision, not a mechanical fix:**

If any criterion is vague, **do not edit any file and do not write any code.** Instead:

1. List each vague criterion verbatim
2. Propose a sharp rewrite for each one
3. Wait for the user to confirm, modify, or reject each proposed rewrite

Only after the user approves, update the `.feature` file (source of truth) and re-import:

```bash
tyrion import features/<epic-slug>.feature [--confirm-abandon] [--force]
```

**This gate applies in all modes, including trivial.** Autonomy mode does not override this stop.

**Dark-factory variant of this stop:** there is no user to answer, and guessing at sharpness is forbidden in every mode. Instead of waiting, block the story with the analysis attached and move on:

```bash
tyrion block <slug> "vague criteria — proposed sharp rewrites: <criterion N: proposed rewrite; ...>"
```

Then return `BLOCKED: <slug> — vague criteria, rewrites proposed in block reason` (orchestrate treats this as a full stop for the story; the human resolves it by editing the .feature and re-importing).

**Vet mode (`--vet` flag or `RIGOR: <mode>+vet` tag) — Codex reviews the plan before you build it:**

After the plan note is written and criteria are confirmed sharp, invoke the `/design-review` skill on this story's plan: package the criteria, the `[plan]` notes / PLAN_SECTION, and the key files it touches; Codex returns `SHIP IT | SIMPLIFY | RETHINK`. Record the verdict — always:

```bash
# SHIP IT:
tyrion gate <slug> codex-vet pass --detail "SHIP IT — <minor suggestions worth taking, if any>"
# SIMPLIFY or RETHINK:
tyrion gate <slug> codex-vet fail --detail "<VERDICT>: <top concerns, one line each>"
```

On fail: revise the plan (update the `[plan]` note with the new approach), re-run `/design-review`, and record the new gate result. Do not proceed to Step 5 until the latest `codex-vet` gate is pass. In dark-factory mode, a second consecutive fail → `tyrion block` with both verdicts in the reason (don't loop forever arguing with Codex).

If `--review` mode: present the criteria and plan, wait for user ok/steer before Step 5.

---

### 5. IMPLEMENT

**Trivial mode:** Orchestrator implements all criteria directly — no subagent spawning. Read the plan section and/or [plan] notes, make the file edits, record evidence, check criteria. Move to Step 7.5 (skip UAT runbook — write a one-line verification note instead). Then skip Step 8 and go directly to Step 9.

**All other modes — grouped subagent cycle:**

#### Step 5a. Determine batching

**Before spawning any subagent**, check for a `[plan]` note containing a `BATCHING:` instruction in `tyrion resume` output. If present, use that grouping exactly — it was set by a human who reviewed the story and knows the right unit of work.

If no BATCHING instruction exists, apply this default logic:
- Criteria that test the same class/file/action → one batch
- Criteria with a Given/When/Then cluster that belongs to one behavior → one batch
- Never default to one subagent per criterion unless each criterion truly tests an independent, unrelated behavior

Document the batching plan before spawning:
```bash
tyrion note <slug> plan "Batching: criteria 1-4 → subagent A (AccountHitsCache); criteria 5-7 → subagent B (AccountProcessor)"
```

#### Step 5b. Per-batch subagent cycle

For each batch:

**Spawn a fresh subagent** with exactly this context:
- The criteria text for this batch (all Given/When/Then steps)
- The story's `current_context` and `next_action` from `tyrion resume`
- The relevant file paths (from plan section or your Step 4 plan)
- The active TDD mode and test command
- **The PLAN_SECTION for this story** (from Step 1) — paste it in full if ≤ 300 lines; summarize key decisions if longer
- **The `[plan]` notes** from `tyrion resume` — paste them verbatim; they contain gotchas and implementation decisions that must not be re-derived

Subagent instructions vary by TDD mode:

**strict**: "Invoke the `superpowers:test-driven-development` skill and follow it exactly — red-green-refactor, no production code without a failing test first, delete any code written before its test. Write a failing test for these criteria first. Run it to confirm it's red. Then implement until green. Return: files changed, full test command + verbatim output." (The superpowers skill owns the TDD discipline — don't restate or soften its rules in the prompt. **If the superpowers plugin isn't installed or the agent has no Skill tool — e.g. Codex running this protocol — skip the invoke and follow the rules as written in this prompt; they are the same discipline.**)

**loose**: "Implement these criteria. Write tests if they can be done without significant overhead. Return: files changed, test output if run, or the exact command + expected output that proves each criterion."

**off/spike**: "Implement these criteria. Return: files changed, the exact command + expected output that proves each criterion works."

**After each batch**, write evidence and check criteria:

```bash
tyrion note <slug> progress "batch <A>: <files changed, verbatim test/command output>"
tyrion check <slug> <position> "<evidence — must be reproducible>"  # for each criterion in batch
tyrion context <slug> "<one-paragraph: what is implemented, what is pending>"
tyrion next <slug> "<next concrete action>"
```

Evidence must be *verbatim* — paste the actual output, not a paraphrase.

**Repeat for each batch in order.**

---

### 6. ON BLOCKER

When you hit a blocker (can't proceed, need info, dependency missing):

```bash
tyrion note <slug> blocker "<what the blocker is and what you already tried>"
tyrion next <slug> "<best recovery step when resumed>"
```

**Before moving on, ask: is this a generalizable mistake or gap (something a future agent on a different story would also be at risk of), or a one-off specific to this code?** If generalizable, record it as a lesson so it doesn't recur silently:

```bash
tyrion lesson add --at <trigger> "<the rule, stated as an instruction to a future agent>"
```

Pick `<trigger>` from the workflow moment where the mistake would actually happen again (`start`, `uat`, `pre-push-pass`, `import-existing`, or a new one if none fit — triggers are just string tags, no registry to update). Skip this for genuine one-offs; not every blocker is a lesson.

Then either resolve it or stop. Do not thrash.

---

### 7. CONTINUOUS CAPTURE (hard rule)

**The FIRST thing you do at the start of every turn while a story is in_progress — before clarifying questions, before tool calls, before any response — is check: did the user just request something new or different?**

If yes:

```bash
tyrion note <slug> progress "user requested: <exact request verbatim>"
```

Write that note before anything else. Then ask your clarifying question. Then implement. The note captures the request *as it arrived*. If the session crashes between the request and the clarification, the ledger still shows what was asked.

**Also applies to code changes:**

Any Write, Edit, or Bash tool call made while the story is in_progress — for any reason, planned or ad-hoc, in-scope or off-scope — MUST be followed immediately by:

```bash
tyrion note <slug> progress "<what changed, why, which files>"
```

---

### 7.5. UAT RUNBOOK

**Before drafting the runbook, in every mode (including trivial):**

```bash
tyrion lessons --at uat
```

This is a just-in-time check — it prints nothing when no `uat`-triggered lessons exist (stay silent, do not report "no lessons"). If it prints anything, honor it before writing the runbook. The lesson most likely to fire here: do not re-offer the rspec/test suite as UAT when `/pre-push` already ran it — write CLI/browser checks that exercise observable behavior instead.

**Trivial mode:** Skip the runbook. Write one verification note instead:

```bash
tyrion note <slug> handoff "Verification: <the one command or page visit that proves this is done>"
```

**All other modes:** Write a runbook so the user can verify the story independently:

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

The runbook must be executable: copy-paste the command, see the expected output. If you cannot write a runbook step, the criterion evidence was not sharp enough — go back and sharpen it.

If `--review` mode: present the runbook. User can run it now to verify, or skip if trust is high.

---

### 8. REVIEW (quality gate)

**Trivial mode:** Skip pre-push entirely. Go directly to Step 9.

**Spike mode:** Skip pre-push. Instead, print:

```
🔬 SPIKE — quality gate skipped. To promote this story to production-grade:
  /tyrion-implement <slug> --tdd=loose   (apply pre-push + encourage tests)
  /tyrion-implement <slug> --tdd=strict  (apply pre-push + require failing test first)
```

**Build or Strict mode:** Run `/pre-push`. It covers tests + quality (DHH) + docs + ai-slop.

```
/pre-push
```

**Record every run in the ledger — pass or fail. Traceability is the point: a failed pre-push that got fixed is history worth keeping, not noise.**

If `/pre-push` finds blocking issues, record the failure BEFORE fixing anything:

```bash
tyrion gate <slug> pre-push fail --detail "<comma-separated failing step names + one-phrase reason each>"
```

Then fix, re-run `/pre-push`, and record again. Do not close until it passes. If a blocking issue is a generalizable mistake (the same review check would catch it again on a future story, in a different epic), record it as a lesson per the Step 6 ON BLOCKER guidance above before re-running — don't just fix and move on.

For an optional deeper spot-check beyond `/pre-push` (criteria-evidence completeness, not just code quality), `/engineering-review <slug>` is available manually — it is not auto-invoked by any rigor level; see its own SKILL.md for what it checks.

If `--review` mode: share the /pre-push output. Wait for user ok before Step 9.

**Once `/pre-push` passes:**

```bash
tyrion gate <slug> pre-push pass --detail "<one-line summary: test count, notable checks>"
tyrion lessons --at pre-push-pass
```

Just-in-time check, silent when nothing applies. The lesson most likely to fire here is the rule this very line encodes: don't stop, don't summarize, don't wait for confirmation — proceed immediately to Step 9. Pre-push passing is not the finish line — `tyrion done` + the UAT block is.

**`--review-stack=superpowers` — opt-in two-stage review (only when the flag is present):**

Off by default. `/pre-push` remains the standard quality gate; this adds a deeper review on top for stories where a recorded review verdict is worth the extra passes. When `--review-stack=superpowers` is set, run these two stages after `/pre-push` passes, before Step 9. Each stage records a gate — pass AND fail, every run — so the ledger holds the review history.

**Stage 1 — spec-compliance reviewer (Tyrion's criteria ARE the spec):**

Spawn a fresh general-purpose subagent (prompt adapted from superpowers' `subagent-driven-development/spec-reviewer-prompt.md`). Give it:
- The story's criteria verbatim (all Given/When/Then) plus the `check` evidence recorded for each — this is the spec.
- The diff to inspect: `git diff <BASE_SHA>..<HEAD_SHA>` where the SHAs come from the `tyrion commits <slug>` capture (see Stage 2 for deriving them).
- The instruction: **do not trust the implementer's evidence — read the actual diff and verify each criterion independently.** Flag missing requirements, extra/unrequested work, and misunderstandings, each with a `file:line` reference.
- Its verdict format: `✅ Spec compliant` or `❌ Issues found: <list with file:line>`.

Record the verdict:

```bash
# ✅ Spec compliant:
tyrion gate <slug> spec-review pass --detail "spec compliant — all N criteria verified against diff"
# ❌ Issues found:
tyrion gate <slug> spec-review fail --detail "<each issue with file:line, one per line>"
```

**Stage 2 — code-quality review via the `superpowers:code-reviewer` agent:**

First derive the review range from the commit capture:

```bash
tyrion commits <slug>   # writes/refreshes the commit note; metadata.shas lists this story's commits (newest first)
```

`HEAD_SHA` = the newest commit (first sha in `metadata.shas`); `BASE_SHA` = `<oldest-sha>^` (the parent of the last sha in the list). If the capture recorded `no commits — no changes required`, skip Stage 2 and record `tyrion gate <slug> code-review pass --detail "no commits — nothing to review" --meta '{"critical":0,"important":0,"minor":0}'`.

Dispatch the `superpowers:code-reviewer` agent (template at `~/.claude/plugins/cache/superpowers-marketplace/superpowers/5.0.5/skills/requesting-code-review/code-reviewer.md`), filling `{BASE_SHA}`/`{HEAD_SHA}`, `{WHAT_WAS_IMPLEMENTED}` (story intent + criteria), and `{PLAN_REFERENCE}` (the `[plan]` notes / PLAN_SECTION). Craft its context precisely from the story — never hand it raw session history. It returns Strengths / Issues (Critical | Important | Minor, each with file:line) / Assessment ending in `Ready to merge? [Yes/No/With fixes]`.

Map the verdict and record the severity counts in `--meta` JSON:

```bash
# Ready to merge: Yes  → pass
tyrion gate <slug> code-review pass --detail "Ready to merge: Yes — <1-line reasoning>" \
  --meta '{"critical":0,"important":0,"minor":<n>}'
# Ready to merge: No / With fixes  → fail
tyrion gate <slug> code-review fail --detail "Ready to merge: With fixes — <top Critical/Important issues, file:line each>" \
  --meta '{"critical":<n>,"important":<n>,"minor":<n>}'
```

**Fix → re-review loop:** any Critical or Important issue (from either stage) means the gate is a **fail** — fix the issues, then re-run that stage and record the new gate result. Minor-only issues do not block (record pass, note them in `--detail`). Repeat until both `spec-review` and `code-review` gates are pass. **Cap the loop at 3 iterations per stage** (superpowers convention); if still failing after the third, stop looping and block the story for a human:

```bash
tyrion block <slug> "review-stack=superpowers: <stage> still failing after 3 iterations — <remaining Critical/Important issues>"
```

In dark-factory mode the same cap applies — block rather than loop forever. Do not proceed to Step 9 until both gates are pass (or the story is blocked).

---

### 9. CLOSE

**Dark-factory override — self-run UAT before closing, then close without asking:**

In dark-factory mode, do not print prompts anywhere in this step. Instead:

1. Execute the Step 7.5 UAT runbook yourself, now, before `tyrion done`: CLI checks inline; browser checks via playwright-cli (isolated session — never the shared Chrome).
2. Record the result — always:

```bash
tyrion gate <slug> uat pass --detail "<per-check ✅ results, one line each>"
# or, on any failed check:
tyrion gate <slug> uat fail --detail "<per-check ✅/❌ results — ❌ lines say what was seen instead>"
```

3. All checks ✅ → close with gate coverage enforced, then claim the next pending story with `tyrion start <next-slug>` automatically — no pre-claim question:

```bash
tyrion done <slug> "<completion summary>" --require-gates=pre-push,uat
```

   `--require-gates=pre-push,uat` refuses the close (exit 1) unless both the `pre-push` gate (Step 8) and the `uat` gate (step 2 above) have a recorded note — gate coverage is otherwise honor-system, so a dark-factory run that skipped or misnamed either gate must not silently seal. Use the generic `tyrion done` form below only in interactive modes where a human ran the gates.
4. Any check ❌ → fix and re-run UAT (recording each run), or if unfixable, `tyrion note <slug> blocker` + `tyrion block` and stop. Never close a story whose latest uat gate is fail.

Everything below that is phrased as a question to the user ("Want me to run...?", "Pre-claim...?", "re-run any of the above?") is skipped in dark-factory mode — the answers are hardwired to: run everything, report results, pre-claim on success.

```bash
tyrion done <slug> "<one-paragraph completion summary: what was built, key decisions made, what the next story should know>"
tyrion status   # verify plan view shows the story as done; note the next pending story slug
```

`tyrion done` refuses if any criterion is still `pending` (unless `--force`). That refusal is the quality gate — don't bypass it without a written reason.

**Epic close → Timeline update.** When `tyrion status` shows the epic is fully done (all stories ✓), record the arc in the project ABOUT.md `## Timeline` section:

```
- YYYY-MM-DD | <epic-slug> shipped (N/N) | review: <one-line finding> | spawned: <slug>
```

- `review:` captures what prompted a corrective epic (missing feature, gap found in review, etc.). Omit if nothing was spawned.
- `spawned:` names the corrective epic slug. Omit if nothing followed.
- Use `tyrion project edit <project-slug>` to update the about_md, or edit the project's ABOUT.md file directly if one exists in the repo root.
- This entry is the memory of WHY the next epic exists — without it, the next agent sees only the spawned epic in isolation.

The completion summary should reference or embed the UAT runbook note so the ledger is self-contained.

**SHEPHERD MODE `/clear` GATE — this is the natural context-reset point.**

After `tyrion done` succeeds: the ledger is authoritative. The story is done. The next agent can reconstruct full state from `tyrion resume`. This means:

- **It is safe to `/clear` right now.** You will not lose any work.
- In shepherd mode, you SHOULD `/clear` here to defeat context rot. Then `/tyrion-implement` for the next story.
- The context you are holding is now *redundant* — the ledger has it all. `/clear` is free.
- If you do NOT `/clear`, you must mark THIS story done before implementing the next. Never implement story N+1 while story N is marked done but story N-1 is still in_progress in the ledger. The ledger reflects reality, not your memory.

**After `tyrion done` succeeds, print a Quick UAT block** — always, in every mode.

The steps are always printed in full so the user can run them manually regardless of whether automation is used. Format:

```
─────────────────────────────────────────────────
Quick UAT — optional. Run yourself or let me run it.
─────────────────────────────────────────────────
CLI checks:
  $ rake crm:seed_dev_data
    Expected: "Users created: N, Hits inserted: N"
  $ rails runner "puts Hit.where(salesforce_account_id: 'X').count"
    Expected: > 0

Browser checks:
  1. Visit: https://admin.hedgeye.test/cms/crm_accounts
     → Search box renders. Accounts tab active in nav.
  2. Search "samlyn" → Samlyn Capital row with user count badge
  3. Click Samlyn → /cms/crm_accounts/<sf_id>
     → User table with persona badges and 90d counts
  4. Visit: https://admin.hedgeye.test/cms/crm_accounts/NOTREAL
     → 404
  5. Logged out: visit /cms/crm_accounts → redirects to login
─────────────────────────────────────────────────
Want me to run the browser checks now? (y/skip)
```

UAT steps are story-type-aware — derive from the criteria and implementation, not generic advice:

- **Rake task / seed**: CLI only — `rake <task>` + `rails runner` count/existence check
- **Migration**: CLI only — the EXPLAIN query from the criteria, expected `key:` in output
- **Service object**: CLI only — `rails runner` with the exact call and expected return shape
- **Controller**: browser checks for each action (index, show, error cases) + auth redirect check
- **Phlex component**: browser check of the page that renders it + what element/text to look for
- **View / tab / nav**: browser checks for each tab/link with active-state and content expectations
- **Spec-only / test-only story**: DO NOT re-list specs as UAT — pre-push already ran them. Write CLI steps that exercise the observable behavior directly (set up data, run the command, observe the output). If the story has no CLI surface beyond the specs, print: `No additional UAT — behavior verified by pre-push test suite.`

**If the user answers `y`:** attempt browser automation. Try playwright-cli first (isolated session, no conflicts with other Claude Code sessions). If playwright-cli fails or isn't available, offer to use the Claude-in-Chrome plugin. Report each check as ✅ or ❌ with the actual page content seen. If automation fails entirely, say so — the steps are already printed for manual use.

After browser automation completes (all results reported), THEN ask:
```
Pre-claim `<next-pending-slug>` for the next session? [y/skip]
```
- All checks ✅: run `tyrion start <next-pending-slug>` if user says y.
- Any check ❌: do NOT pre-claim regardless of what user says. Surface the failures instead.

**If the user answers `skip` to browser checks:** do nothing with automation. Then ask:
```
Pre-claim `<next-pending-slug>` for the next session? [y/skip]
```
If user says y, run `tyrion start <next-pending-slug>`.

**If the story has no browser checks** (CLI-only UAT: rake tasks, migrations, service objects, component library stories): skip the "Want me to run browser checks?" question entirely — it doesn't apply. Run CLI checks inline automatically without asking. Then report results (✅/❌ per check) and state explicitly that you ran them. Always follow with:
```
(ran automatically — re-run any of the above? [y/skip])
```
If user says y, re-run and report again. Then ask:
```
Pre-claim `<next-pending-slug>` for the next session? [y/skip]
```

**NEVER ask "Want me to run browser checks?" and "Pre-claim?" in the same message.** These are two separate decisions that must be answered sequentially — a single `y` is ambiguous when both are present.

---

## Why this protocol works

- **Plan file injection** (Step 1 + 5b) means subagents execute a Claude-written plan rather than re-deriving it — the biggest source of wasted time in plan-driven stories.
- **Batching from `[plan]` notes** (Step 5a) lets a human set the right unit of work per story without changing the skill; the agent reads and follows it.
- **Trivial mode** (Steps 1/5/7.5/8) removes all ceremony for mechanical changes — nav tweaks, rake tasks, simple migrations — where the right answer is obvious from the plan.
- **Verbatim evidence** (Step 5b) makes notes re-verifiable — "I did X" is hearsay; a pasted test output is a fact.
- **Continuous capture** (Step 7) closes the beads-style drift — interactive follow-ons don't escape the ledger.
- **UAT runbook** (Step 7.5) makes criteria self-enforcing — if you can't write the step, the criterion was never testable.
- **/pre-push** (Step 8) makes quality consistent and non-negotiable before close.
- **Gloria's Law**: the skill owns the discipline. The agent doesn't remember to update Tyrion — these instructions tell it exactly when, with literal commands.
