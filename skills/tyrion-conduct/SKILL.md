---
name: tyrion-conduct
description: Use when conducting or supervising a Tyrion epic with model-tiered subagents — a frontier coordinator that never builds, per-story builders picked by the story's RIGOR tag, and verification gates the coordinator owns personally. Triggered by "conduct this epic", "supervise the epic with subagents", "orchestrate with model tiers", "run the epic without burning coordinator context", or "/tyrion-conduct". Use /tyrion-orchestrate instead for homogeneous parallel wave fan-out (one lane per story, same protocol for all); conduct is for heterogeneous epics where stories differ in rigor and each needs a different model tier and gate.
---

# /tyrion-conduct

Coordinator-driven, model-tiered, verification-gated execution of one Tyrion epic.

**Sibling, not replacement.** `/tyrion-orchestrate` fans out a wave: N stories, one lane each, same protocol, same model. Conduct maximizes correctness-per-token on a *heterogeneous* epic — stories that differ in rigor, risk, and verification surface. If every story in the wave is the same shape, use orchestrate.

---

## Core stance

- **The coordinator holds the arc, the taste, and the gates. It never builds.** No file edits, no test runs, no implement protocol in its head.
- **If the coordinator is reading its 5th file, it is doing a builder's job.** Stop and spawn.
- **The ledger is the shared memory.** Builders write evidence into criteria and notes; the coordinator's thread carries only ≤400-word summaries.
- **Anything important must be reconstructable from `tyrion show <slug>` + `git log`** — never from conversation. The thread is disposable; the ledger is not.

---

## Model routing: RIGOR is the signal

`/tyrion-shape` already baked `RIGOR: trivial|loose|strict` into every story's `[plan]` note at shaping time. Read it (`tyrion show <slug>`), don't re-derive it. Conduct maps RIGOR through the vendor ladder of whichever model family is driving:

| RIGOR | Claude (Fable driving) | Claude (Opus driving) | ChatGPT/Codex (Sol driving) |
|---|---|---|---|
| coordinator | Fable, never builds | Opus, never builds | Sol high, never builds |
| strict | Opus builder | Opus builder | Sol medium/high builder |
| loose | Sonnet builder | Sonnet builder | mid-tier builder |
| trivial/mechanical | Haiku or Sonnet | Haiku | mini-tier builder |

**Escalate one tier on a failed gate.** Nothing escalates onto the coordinator's tier — a story that fails twice at the top builder tier is a `tyrion block`, not a coordinator rescue.

---

## Builder contract — every spawn, no exceptions

1. **Self-contained prompt.** Absolute repo path, story slug, and everything else by path or ledger reference. Builders inherit nothing from your context.
2. **The builder invokes `/tyrion-implement <slug>` ITSELF.** Ledger discipline (claim, per-criterion evidence, notes, gates) travels with the work. The coordinator never carries that checklist.
3. **Reports ≤400 words.** Full output lands in the ledger and in commits, not in the report.
4. **Commits locally with explicit paths. Never pushes.** Push gates belong to the human.
5. **No TodoWrite.** The ledger is the task list.
6. **UAT/browser split** — the load-bearing rule:
   - The builder checks only **server-provable** criteria (tests, CLI output, HTTP responses it can produce itself).
   - Any criterion needing a **real browser or user-level verification** is left **UNCHECKED**, with a handoff runbook note: exact URLs, actions, expected observations, teardown.
     ```bash
     tyrion note <slug> handoff "UAT-BROWSER: 1) boot: SW_NO_OPEN=1 <cmd>; 2) visit <url>; 3) expect <observation>; 4) teardown: <cmd>"
     ```
   - The story stays `in_progress`. **The builder does NOT run `tyrion done`.**
   - The coordinator runs those gates itself. Standing lesson: subagent browser testing is unreliable — main-thread playwright-cli with screenshots is the only trustworthy path.

---

## Concurrency

- **ONE tree-modifying builder per checkout, ever.** Two builders in one working tree collide on the filesystem even when the ledger keeps ownership straight.
- **Parallelism only via git worktree isolation.** Spawn with worktree isolation; the builder runs `tyrion init` plus project/epic activate in its worktree. The DB is shared; active-state files are per-directory, so lanes never clobber each other.
- **Worktree builders report branch + commit. The COORDINATOR merges** into main, runs the full suite on the merged tree, then removes the worktree and branch.
- **Never merge while another builder is mid-flight on the target checkout.**
- **Sequence the critical path.** Parallelize only genuinely independent stories with disjoint-ish conflict surfaces. Two stories editing the same file are sequential, worktree or not.

---

## Verification gates — the coordinator's own work

**Closed loop on every completion.** An agent going idle WITHOUT a report is a non-event, not a completion. Before trusting it or re-asking, verify:

```bash
tyrion show <slug>     # criteria checked? gates recorded? notes present?
git log --oneline -5   # do the commits exist?
```

**Done = evidence in the ledger. Never assertion.**

**Browser/UAT gates.** The coordinator executes the handoff runbook itself (playwright-cli, isolated session, `SW_NO_OPEN=1` on any test boot), checks the remaining criteria with evidence, records the gate, and seals:

```bash
tyrion check <slug> <position> "<verbatim observation + screenshot path>"
tyrion gate <slug> uat pass --detail "<per-check results, one line each>"
tyrion done <slug> "<completion summary>" --require-gates=pre-push,uat
```

**Clean-room acceptance for documentation, skills, and tutorials.** Any deliverable whose product is *instructions* gets a fresh-context acceptance agent:

- Restricted to the deliverable file **alone** — no other docs, no source, no repo browsing.
- Tasked to **BUILD** from it, not to review it.
- Output checked against the reference by the coordinator.
- **An author's own audit encodes the author's expectations and will pass the author's bugs.** This is why the acceptance agent must be a stranger.
- Budget one failure-fix-retest cycle. **The failure is the criterion working**, not a setback.

---

## Findings routing

Discoveries flow **forward through the ledger, not the thread**.

- A finding from story N that affects story M becomes an addendum on M's plan note, written **before M's builder spawns**:
  ```bash
  tyrion note <slug-M> plan "ADDENDUM: <what story N discovered that M must know>"
  ```
- A followup that fits no story: `tyrion note <slug> followup "<...>"` or `tyrion mark "<...>" --headline "<...>" --auto`.
- **After each story, give the user a brief status**: what sealed, what's in flight, what surprised. Three lines, not a report.

---

## Anti-patterns

| Anti-pattern | Do instead |
|---|---|
| Coordinator implementing "just this small fix" | Spawn a builder, or do it as an explicit reviewed gate action |
| Merging a worktree while the main checkout has a live builder | Wait for the in-flight builder to report |
| Trusting "done" from a summary without ledger evidence | `tyrion show <slug>` + `git log` before believing anything |
| Re-running a builder's work to check it | Read its recorded evidence; re-running is the coordinator building |
| Letting a builder `tyrion done` a story with an unverified UAT criterion | Builder leaves it unchecked + handoff note; coordinator seals |
| Escalating a twice-failed story onto the coordinator's tier | `tyrion block <slug>` with both failure details |
| Coordinator reading files to "understand the codebase" | The builder's prompt points at paths; the builder reads them |

---

## Protocol

1. **ORIENT** — `tyrion status`, `tyrion epic show`. Read every story's `[plan]` note for its RIGOR tag. Build the routing table: slug → tier → checkout (main or worktree) → who owns the UAT gate.
2. **SEQUENCE** — order by dependency. Mark which stories can run concurrently (disjoint files) and which must be serial.
3. **SPAWN** — one builder per story, per the builder contract. Concurrent stories get worktrees; serial stories run in the main checkout, one at a time.
4. **VERIFY** — on each report (or each idle agent), close the loop against the ledger. Route findings forward to downstream plan notes.
5. **GATE** — run the browser/UAT gates and clean-room acceptances yourself. Check remaining criteria with evidence. `tyrion done`.
6. **MERGE** — for worktree stories: merge to main, full suite on the merged tree, then `git worktree remove` + delete the branch.
7. **STATUS** — three-line user update. Loop to 3 until the epic is done, then record the arc in the project ABOUT.md `## Timeline`.

---

## Worked example — 3-story epic

Epic `dev-overlay` with RIGOR tags already set by shape.

**Coordinator (Fable) reads the routing table:**

| Story | RIGOR | Builder | Checkout | UAT owner |
|---|---|---|---|---|
| `overlay-docs` | trivial | Sonnet | main | builder (CLI only) |
| `overlay-core` | strict | Opus | main | coordinator (browser) |
| `overlay-toggle` | loose | Sonnet | worktree | coordinator (browser) |

**Step 1 — `overlay-docs`, Sonnet, main checkout.** Prompt: repo path, slug, "invoke `/tyrion-implement overlay-docs`, commit with explicit paths, do not push, report ≤400 words." Reports back: doc written, criteria checked with `grep` evidence, committed. Coordinator verifies with `tyrion show overlay-docs` — all criteria checked, commit present. Sealed by the builder (no browser criteria). Because it's a doc deliverable, the coordinator additionally spawns a **clean-room acceptance agent**: fresh context, given only `docs/dev-overlay.md`, told to set up the overlay from it. It fails at step 3 (the doc never says which port). Coordinator sends the builder one fix cycle, re-runs a fresh acceptance agent, passes.

**Step 2 — `overlay-core`, Opus, main checkout** (serial: it touches the same files the toggle story will). Builder implements, runs `/pre-push`, checks the four server-provable criteria with verbatim test output, leaves criterion 5 ("overlay renders on page load") UNCHECKED with a handoff note: `boot with SW_NO_OPEN=1 bin/dev; visit http://127.0.0.1:<port>/; expect .sw-dev-overlay visible top-right; teardown: kill the pid`. Story stays `in_progress`. Reports 180 words.

**Step 3 — `overlay-toggle`, Sonnet, worktree.** Spawned with worktree isolation while the coordinator handles step 2's gate. Builder runs `tyrion init` + project/epic activate in the worktree, implements, commits on `story/overlay-toggle`, leaves its browser criterion unchecked with a runbook, reports branch + SHA.

**Step 4 — coordinator runs both browser gates.** playwright-cli, isolated session, screenshots. Overlay renders; toggle hides it. Checks criterion 5 on each with the screenshot path as evidence, records `uat` gates, runs `tyrion done` on both with `--require-gates=pre-push,uat`.

**Step 5 — coordinator merges the worktree.** No builder is live on main, so: `git merge --no-ff story/overlay-toggle`, full suite on the merged tree (passes), `git worktree remove` + `git branch -d`.

**Coordinator context spent:** three routing decisions, three ≤400-word reports, two browser gates, one merge. Zero files implemented. Everything else is in the ledger.

---

## Why this works

- **RIGOR routing** turns a shaping-time judgment into a spend decision — frontier tokens only where correctness is expensive to recover.
- **The never-builds rule** is what keeps coordinator context low enough to hold the whole epic's arc at the end.
- **The UAT split** matches each check to the agent that can actually perform it — subagent browser claims are the least reliable signal in the system.
- **Clean-room acceptance** is the only doc test that isn't graded by the author.
- **Ledger-as-memory** (Gloria's Law) means a `/clear`, a crash, or a coordinator handoff loses nothing.
