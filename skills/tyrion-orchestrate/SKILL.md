---
name: tyrion-orchestrate
description: Fan out one subagent per story in the current wave, collect summaries, advance waves until epic done. Triggered by "/tyrion-orchestrate", "run all stories in parallel", "dispatch wave", or "orchestrate epic". Requires tyrion-assign, tyrion-wave-next, and per-lane infrastructure. Runs each story through the full /tyrion-implement protocol in an isolated Agent subagent.
---

# /tyrion-orchestrate

Fan out one Claude subagent per ready story, collect 1-2 sentence summaries, advance through waves until the epic is done.

**Prerequisites**: `tyrion assign`, `tyrion wave next`, and per-lane infrastructure must be in place (`parallel-execution` epic in the tyrion project tracks this).

## When to use

- You have a Tyrion epic with a wave plan (`tyrion wave show` shows waves)
- You want to run multiple stories in parallel without babysitting each one
- Stories in the current wave don't have overlapping file conflicts (or each runs in its own worktree)

## Protocol

### 1. ORIENT

```bash
tyrion status        # confirm active project + epic, see pending count
tyrion wave show     # see the wave plan — current frontier is the first wave with pending stories
```

Capture the active epic slug now — you will pass it to every subagent.

```bash
tyrion epic show     # note the slug from the first line
```

If `tyrion status` shows 0 pending stories, there is nothing to dispatch — stop.

### 2. WAVE LOOP

Repeat until the termination check passes (step 2f) OR a blocked story surfaces:

#### 2a. Get the current wave's ready stories

```bash
tyrion wave next --with-pocket
```

Output per story:
```
story-slug-A
  epic: my-epic
  story: story-slug-A
  [ ] Given <criterion>
  [ ] Then <criterion>

story-slug-B
  epic: my-epic
  story: story-slug-B
  [ ] Given <criterion>
```

Parse: extract each slug and its criteria block. If output is "(no pending stories)", proceed to step 2f (termination check) — do NOT declare done yet.

#### 2b. Dispatch stories to lanes (starts them immediately — ledger is never stale)

```bash
tyrion dispatch story-slug-A --to lane-1
tyrion dispatch story-slug-B --to lane-2
# one per story, numbered sequentially
```

`tyrion dispatch` starts each story immediately (`in_progress`, `claimed_by = "dispatched:lane-N"`) and records an initial context event. The War Room shows real in_progress stories from the moment of dispatch — the "nothing started during active work" violation this epic was born from is no longer possible. When the subagent later runs `tyrion start <slug>`, it adopts the story (re-stamps `claimed_by` to its real lane token) without requiring `--steal`.

If `tyrion dispatch` returns "Story is not pending" for a slug that `wave next` returned, the story was orphaned `in_progress` from a prior dispatch. Treat it as a stuck subagent (see **Stuck story recovery** below).

#### 2c. Dispatch subagents — one per story, all in parallel

Send a **single message** with N Agent tool calls (one per story). For wide waves (> 8 stories), chunk into batches of 6-8 to avoid saturating the concurrency pool.

Each subagent receives:
- The **active epic slug** (captured in step 1) — they must activate it immediately
- Their **lane identity**: `TYRION_LANE=lane-N` inlined on every tyrion command
- The **pocket briefing** for their story (criteria block from step 2a output)
- Implementation instructions (see template below)

**Return constraint**: subagents must return only a 1-2 sentence summary. No file contents, test output, or large code blocks. Context must not flow back through the main session.

---

**Subagent prompt template** (fill in `<slug>`, `<N>`, `<epic-slug>`, criteria):

> You are implementing Tyrion story `<slug>` in a parallel orchestration session.
>
> **Lane identity**: Your lane is `lane-<N>`. Prefix EVERY tyrion command with `TYRION_LANE=lane-<N>`:
> ```bash
> TYRION_LANE=lane-<N> tyrion epic activate <epic-slug>
> TYRION_LANE=lane-<N> tyrion start <slug>
> # and so on for every tyrion command
> ```
> Do NOT use `export` — it will not persist across tool calls.
>
> **Step 1 — activate epic and claim:**
> ```bash
> TYRION_LANE=lane-<N> tyrion epic activate <epic-slug>
> TYRION_LANE=lane-<N> tyrion start <slug>
> ```
>
> **Your pocket briefing:**
> ```
> epic: <epic-slug>
> story: <slug>
> [ ] Given <criterion 1>
> [ ] Then <criterion 2>
> ...
> ```
>
> **Step 2 — implement:**
> Invoke `/tyrion-implement <slug> --dark-factory` — follow the full protocol (orient, plan, implement, pre-push gate, self-run UAT recorded as a uat gate, close). Dark-factory mode is required: you have no human to answer prompts. Commit your work BEFORE `tyrion done` so the auto commit-capture includes it. Do NOT pre-claim a next story — the orchestrator manages waves.
> All tyrion commands inside that skill must also carry `TYRION_LANE=lane-<N>`.
>
> **Step 3 — return your result:**
>
> Return EXACTLY one of:
> - `DONE: <slug> — <1-2 sentence summary of what was built and any key decision>`
> - `BLOCKED: <slug> — <1-2 sentence description of what blocks it>`
>
> Nothing else. No file contents. No test output. No long explanations.

---

#### 2d. Collect summaries and record progress

After all subagents in the wave complete, for each result:

For `DONE: <slug> — <summary>`:
```bash
tyrion note <slug> progress "orchestrated: <summary>"
```

For `BLOCKED: <slug> — <reason>`:
```bash
tyrion note <slug> blocker "reported by subagent: <reason>"
```

For any result that is **neither `DONE:` nor `BLOCKED:`**:
```bash
tyrion note <slug> blocker "subagent did not return expected format — treat as blocked; manual review required"
```

#### 2e. Check status and surface blocks

```bash
tyrion status     # see which stories are done; check for blocked or stuck in_progress
```

If any story is `blocked`, **stop**. Print the blocked story slug and reason. Do not dispatch the next wave until the user resolves the block (or runs `tyrion unblock <slug>` and `/tyrion-orchestrate` again to continue).

#### 2f. Termination check

Before looping or declaring done, verify all stories are actually in terminal state:

```bash
tyrion status    # confirm: 0 in_progress, 0 pending (or all done ✓)
tyrion wave next # should return "(no pending stories)"
```

**Only declare the epic done if `tyrion status` shows all stories as `done` (✓).** `tyrion wave next` returning "(no pending stories)" is necessary but not sufficient — a crashed subagent can leave a story `in_progress` with no pending siblings, making `wave next` return empty while the epic is not done.

If stories remain `in_progress` after all subagents have returned (stuck/orphaned), see **Stuck story recovery** below.

If `tyrion status` shows 0 in_progress and 0 pending (all done), loop terminates normally → proceed to step 3.

Otherwise loop back to step 2a.

### 3. DONE

When step 2f confirms all stories are done:

```
Epic complete — all stories done.
```

Run `tyrion status` for the final view. If the epic is fully done (all stories ✓), record the arc in the project ABOUT.md `## Timeline` section (create the section if absent):

```
- YYYY-MM-DD | <epic-slug> shipped (N/N) | review: <one-line finding if any> | spawned: <next-epic-slug if any>
```

### Stuck story recovery

A story is "stuck" when it appears `in_progress` after all subagents have returned, OR when `tyrion assign` refuses it with "Story is not pending."

```bash
# Diagnose
tyrion show <slug>      # see current status, claimed_by, last notes

# If the story was partially completed — check criteria, mark what's done, resume:
tyrion note <slug> recovery "orchestration session found story stuck in_progress — resuming"
/tyrion-implement <slug>   # resume in the main session

# If the story was never started (assign placeholder only, no real work done):
# The assign placeholder (assigned:lane-N) is not in_progress; the story is still pending.
# wave next will return it again. Simply re-dispatch.
```

## Constraints

| Constraint | Why |
|---|---|
| Activate epic before tyrion start | Fresh subagent lanes have no per-lane active-epic file; start fails with "No active epic" without it |
| Inline `TYRION_LANE=` on every command | Env exports do not persist across separate Bash tool calls; inline is the only reliable form |
| Termination = all stories done (not just wave-next empty) | Crashed subagent leaves story in_progress with no pending siblings; wave-next returns empty but epic is not done |
| Pre-assign before dispatch | Makes dispatch visible in tyrion status during the wave; note that start overwrites claimed_by with the real token |
| Subagents return summaries only | Main session context stays lean; large context collapses orchestration |
| Blocked = full stop | Dispatching the next wave on top of a blocked story creates unresolvable dependency tangles |
| Chunk wide waves (> 8 stories) | Avoid saturating the Agent concurrency pool — batch 6-8 per dispatch |
| Subagents use `/tyrion-implement` | They run the full quality protocol (TDD, pre-push, UAT). The orchestrating session dispatches only — it never implements stories directly |

## Termination conditions

- `tyrion status` shows all stories done AND `tyrion wave next` returns "(no pending stories)" → normal completion
- A story surfaces as `blocked` → pause, surface to user
- A story is stuck `in_progress` after all subagents return → stuck story recovery (see above)
- A subagent returns neither DONE nor BLOCKED → treat as blocked, note it, surface to user
