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
- The epic's persisted **mode** governs your cadence between waves: `dark_factory` runs wave-to-wave to epic completion; `shape` (the default when unset) pauses after each wave for human inspection — worker subagents are unaffected either way (see 2c)
- Overlapping files within a wave are fine — every lane runs in its own git worktree on its own `story/<slug>` branch (standard since the worktree-lanes epic), so lanes cannot sweep each other's uncommitted work, and enforcement-config changes (hooks, settings) stay lane-local until merged

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

Read and display the epic's current **mode** so the user knows the cadence this run will use:

```bash
tyrion epic mode <epic-slug>   # prints "dark_factory" or "shape" (unset epics read as shape)
```

`dark_factory` → the parent auto-advances wave to wave until the epic is done. `shape` (or unset) → the parent pauses after each wave for inspection. This read is **informational only** — do NOT cache it for the run. The authoritative check that gates looping re-reads mode fresh at step 2f every time (a user may flip it mid-run).

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

#### 2b-2. Create and seed one worktree per lane

Every lane gets its own git worktree on its own branch. From the main checkout, per story:

```bash
# Fail fast if the main checkout isn't a seedable tyrion root:
test -f .tyrion/marker && test -f .tyrion/active-project || { echo "not a seedable tyrion root — aborting dispatch"; }

git worktree add .worktrees/lane-<N> -b story/<slug> main
mkdir -p .worktrees/lane-<N>/.tyrion
cp .tyrion/marker .tyrion/active-project .worktrees/lane-<N>/.tyrion/
cd .worktrees/lane-<N> && TYRION_LANE=lane-<N> tyrion epic activate <epic-slug>
```

Why the seed matters: `.tyrion/` is gitignored, so a fresh worktree checkout has none — and `Repo.tyrion_root` looks for the `.tyrion/marker` FILE, walking upward from cwd. Without the seed, lane state silently lands in the main checkout's `.tyrion/lanes/` (breaking the `tyrion worktrees` dashboard mapping and per-lane git resolution). With it, the worktree is a real tyrion root: lane state is worktree-local, `tyrion worktrees` maps each lane to its own tree, and git helpers (dirty count, commit capture) resolve to the lane's branch. The epic activation at seed time writes the lane-scoped active-epic under the worktree's own `.tyrion/lanes/<hash>/`, so the subagent's first `tyrion start` just works.

#### 2c. Dispatch subagents — one per story, all in parallel

Send a **single message** with N Agent tool calls (one per story). For wide waves (> 8 stories), chunk into batches of 6-8 to avoid saturating the concurrency pool.

Each subagent receives:
- Their **worktree path** (`.worktrees/lane-<N>` under the main checkout) — every command runs there via a `cd` prefix; the epic is already activated for their lane (seeded in 2b-2)
- Their **lane identity**: `TYRION_LANE=lane-N` inlined on every tyrion command
- The **pocket briefing** for their story (criteria block from step 2a output)
- Implementation instructions (see template below) — including the READY contract: subagents do NOT close their own story; the orchestrator closes after merge

**Return constraint**: subagents must return only a 1-2 sentence summary. No file contents, test output, or large code blocks. Context must not flow back through the main session.

---

**Subagent prompt template** (fill in `<slug>`, `<N>`, `<epic-slug>`, criteria):

> You are implementing Tyrion story `<slug>` in a parallel orchestration session.
>
> **Your worktree**: `<main-checkout>/.worktrees/lane-<N>` — an isolated git worktree on branch `story/<slug>`. ALL work happens there. Prefix EVERY command (tyrion, git, tests, file inspection) with `cd <main-checkout>/.worktrees/lane-<N> && `, and use paths relative to the worktree. Never edit files in the main checkout.
>
> **Lane identity**: Your lane is `lane-<N>`. Prefix EVERY tyrion command with `TYRION_LANE=lane-<N>` (unquoted). Do NOT use `export` — it will not persist across tool calls.
>
> **Step 1 — claim** (your epic is already activated for this lane):
> ```bash
> cd <main-checkout>/.worktrees/lane-<N> && TYRION_LANE=lane-<N> tyrion start <slug>
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
> Invoke `/tyrion-implement <slug> --dark-factory` — follow the full protocol (orient, plan, implement, pre-push gate, self-run UAT recorded as a uat gate) **with one override: do NOT run `tyrion done` and do NOT pre-claim a next story.** The orchestrator merges your branch and closes the story — a close before merge would record work that main cannot yet see. Commit your work on your branch as you go.
> All commands inside that skill must also carry the `cd` prefix and `TYRION_LANE=lane-<N>`.
>
> **Step 3 — hand off for merge** (after your uat gate is recorded as pass):
> ```bash
> cd <main-checkout>/.worktrees/lane-<N> && TYRION_LANE=lane-<N> tyrion commits <slug>
> cd <main-checkout>/.worktrees/lane-<N> && TYRION_LANE=lane-<N> tyrion gate <slug> merge-ready pass --detail "awaiting orchestrator merge"
> ```
> The commits capture is branch-scoped (runs from your worktree, pre-merge) — it is the authoritative commit record for your story. The merge-ready gate makes your readiness a ledger fact.
>
> **Step 4 — return your result:**
>
> Return EXACTLY one of:
> - `READY: <slug> — <1-2 sentence summary of what was built and any key decision>`
> - `BLOCKED: <slug> — <1-2 sentence description of what blocks it>`
>
> Nothing else. No file contents. No test output. No long explanations.

---

**Workers are always headless, always `--dark-factory` — this is deliberate and mode-independent.** The `/tyrion-implement <slug> --dark-factory` invocation above is hardcoded and must NEVER be made conditional on the epic's mode. A dispatched subagent has no human prompt channel, so there is nothing for a `shape`-mode cadence to pause *for* inside a worker. The epic's mode governs only the **parent** orchestrator's between-wave cadence (step 2f) — never how a worker runs. A future editor must not wire this template to `tyrion epic mode`.

#### 2d. MERGE PHASE — merge, validate, close, clean up (strictly sequential)

After all subagents in the wave return, process each `READY: <slug>` **one at a time** — never merge two lanes concurrently. For each, from the main checkout:

**1. Merge the lane branch:**
```bash
git merge --no-ff story/<slug> -m "merge: <slug> (lane-<N>)"
```

On **conflict**: abort and block — the wave is over:
```bash
git merge --abort
tyrion block <slug> "merge conflict with earlier-merged work: <conflicting files>"
# keep the worktree at .worktrees/lane-<N> for human inspection — do NOT remove it
```

**2. Integration validation** — the lane's gates ran against dispatch-time main; verify the *merged* result:
```bash
bundle exec rspec   # or the project's suite command
# pass:
tyrion gate <slug> integration pass --detail "<verbatim: suite command + summary line>"
# fail:
tyrion gate <slug> integration fail --detail "<verbatim failures>"
git reset --hard ORIG_HEAD   # safe: merges are sequential; orchestrator owns main during this phase
tyrion block <slug> "integration failure after merge: <summary> — worktree kept at .worktrees/lane-<N>"
# keep the worktree; full-stop the wave
```

**3. Close — from INSIDE the lane worktree** (lane-local state must resolve; the lane token preserves `completed_by` provenance):
```bash
cd .worktrees/lane-<N> && TYRION_LANE=lane-<N> tyrion done <slug> "<summary>" --require-gates=pre-push,uat,merge-ready,integration
```
The pre-merge branch-scoped commit capture (subagent step 3) is authoritative; `tyrion done` skips auto-capture when a commit note already exists, so the post-merge time window never pollutes the record.

**4. Clean up the merged lane** — the seeded `.tyrion/` is protocol-created, not work; exclude it from the dirt check:
```bash
git -C .worktrees/lane-<N> status --porcelain | grep -v '^?? .tyrion/'   # must output nothing
# clean (only the seed remains — --force is required because the seed is untracked
# in repos where .tyrion/ isn't gitignored; it is always safe to delete post-close):
git worktree remove --force .worktrees/lane-<N> && git branch -d story/<slug>
# real dirt (anything the grep let through):
tyrion note <slug> progress "worktree kept: .worktrees/lane-<N> has leftover files: <list> — remove manually after inspection"
```

For `BLOCKED: <slug> — <reason>`:
```bash
tyrion note <slug> blocker "reported by subagent: <reason>"
# keep the worktree for inspection
```

For any result that is **neither `READY:` nor `BLOCKED:`** — including a bare completion/idle with no message: **read the ledger before assuming failure** (`tyrion show <slug>` — a story with uat + merge-ready gates recorded is READY regardless of what the subagent said). If the ledger shows it isn't ready:
```bash
tyrion note <slug> blocker "subagent did not return expected format and ledger shows no merge-ready gate — treat as blocked; manual review required"
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

Otherwise (pending stories remain, nothing blocked or stuck), the decision to auto-advance or pause is governed by the epic's **mode**. Re-read it fresh here — do NOT reuse the value captured at ORIENT (step 1); a user may have flipped it mid-run:

```bash
tyrion epic mode <epic-slug>   # authoritative read that gates looping
```

- **`dark_factory`** → loop back to step 2a immediately and dispatch the next wave.
- **`shape`** (or the command returns anything other than `dark_factory` — fail safe toward the conservative, human-in-the-loop behavior) → **STOP.** Do NOT auto-loop. Print a clear pause message with the current status, e.g.:

  ```
  Wave complete — pausing for inspection (mode: shape).
  ```

  Then run `tyrion status` for the current view and tell the user: re-invoke `/tyrion-orchestrate` when ready to continue with the next wave.

This mode-based pause is a normal, all-clear checkpoint — not a failure state. Every full-stop condition (blocked, conflict, integration failure, stuck, unexpected result) still fires regardless of mode; those halt work until the human intervenes, whereas this pause just waits for a "go ahead" to start the next wave.

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

**Worktree recovery:** a stuck lane's worktree at `.worktrees/lane-<N>` holds its uncommitted state — inspect before removing. A story with `merge-ready` + `uat` gates recorded but still `in_progress` crashed between handoff and merge: run the 2d merge phase for it manually. Stale worktrees from dead lanes: `git worktree list` + `tyrion worktrees` show them; after salvaging any work, `git worktree remove --force .worktrees/lane-<N>` and delete the `story/<slug>` branch if unmerged work is confirmed disposable.

## Constraints

| Constraint | Why |
|---|---|
| Seed `.tyrion/marker` + active-project into every worktree, activate the epic at seed time | `.tyrion/` is gitignored; without the marker FILE, `Repo.tyrion_root` walks up to the main checkout and lane state lands in the wrong tree (breaks `tyrion worktrees` mapping and per-lane git resolution) |
| Subagents never run `tyrion done` | Close happens after merge — closing pre-merge records work main cannot see. Readiness = the `merge-ready` gate, a ledger fact |
| Merges are strictly sequential, integration-validated, from the main checkout | Parallel merges race; a clean textual merge can still be behaviorally broken against earlier-merged siblings — the integration gate catches it, and `git reset --hard ORIG_HEAD` is only safe when nothing else advances main |
| Close from inside the lane worktree with the lane's token | `resolve_project_epic` needs the lane-local active-epic; the token preserves `completed_by` provenance |
| Pre-merge `tyrion commits` from the worktree is the authoritative capture | Post-merge time-window capture on main sweeps sibling merges + the merge commit; branch-scoped capture cannot |
| Keep the worktree on any block (conflict, integration failure, subagent blocker) | It is the human's forensic evidence; only merged-and-closed lanes get removed |
| Inline `TYRION_LANE=` on every command | Env exports do not persist across separate Bash tool calls; inline is the only reliable form |
| Termination = all stories done (not just wave-next empty) | Crashed subagent leaves story in_progress with no pending siblings; wave-next returns empty but epic is not done |
| Subagents return summaries only | Main session context stays lean; large context collapses orchestration |
| Blocked = full stop | Dispatching the next wave on top of a blocked story creates unresolvable dependency tangles |
| Workers always run `--dark-factory`, never conditional on epic mode | A subagent has no human prompt channel, so `shape`-mode cadence has nothing to pause for inside a worker; mode governs only the parent's between-wave cadence. Wiring the dispatch template to `tyrion epic mode` would be a bug |
| Mode-based pause (shape) ≠ full stop | A full stop (blocked, conflict, integration failure, stuck) needs human intervention before ANY further work, even in `dark_factory`. The shape-mode pause is weaker: all clear, just waiting for a "go ahead" to start the next wave — not a failure state |
| Re-read mode fresh at 2f every wave, never cache from ORIENT | The parent re-reads between waves so flipping `dark_factory`→`shape` mid-run pauses after the current wave; a cached value would ignore the flip |
| Chunk wide waves (> 8 stories) | Avoid saturating the Agent concurrency pool — batch 6-8 per dispatch |
| Subagents use `/tyrion-implement` | They run the full quality protocol (TDD, pre-push, UAT). The orchestrating session dispatches only — it never implements stories directly |

## Termination conditions

- `tyrion status` shows all stories done AND `tyrion wave next` returns "(no pending stories)" → normal completion
- A wave completes all-clear with pending stories remaining AND the epic's mode is `shape` (or unset) → **shape-mode pause**: stop, print the pause message + `tyrion status`, wait for the user to re-invoke `/tyrion-orchestrate` (not a failure — the next wave simply awaits a "go ahead")
- A story surfaces as `blocked` → pause, surface to user
- A story is stuck `in_progress` after all subagents return → stuck story recovery (see above)
- A subagent returns neither DONE nor BLOCKED → treat as blocked, note it, surface to user
