---
name: tyrion-spike
description: Full SDRD spike lifecycle in one skill — start, investigate, close with findings, optionally promote to story. Triggered by "/tyrion-spike", "start a spike", "investigate X", "I want to explore", "run a spike on", "spike this". Handles both starting a new spike and closing an in-flight one based on current state.
---

# /tyrion-spike

SDRD spike lifecycle from question to findings — friction-free. One skill handles the whole loop.

## When to use

- "I want to investigate whether X"
- "Spike: is Y approach viable?"
- "I have a known unknown I need to explore before committing"
- Already mid-spike and ready to close with findings

---

## Step 1: Orient

```bash
tyrion status
tyrion discovery list --status active
```

Read both outputs. Two cases:

**Case A — no active spike:** proceed to Step 2 (Start).

**Case B — active spike exists:** skip to Step 4 (Close). Show the user the existing spike question and ask: "There's an active spike: [question]. Close this one with findings, or abandon it to start a new one?"

---

## Step 2: Frame the question (Start)

If the user provided a topic/question with the invocation, use it directly. Otherwise ask:

> "What's the known unknown? One sentence — what are you trying to find out?"

Good spike questions:
- "Is SQLite WAL fast enough under concurrent agent writes?"
- "Does the N+1 on project list matter at 10k rows?"
- "Can we reuse the existing auth token or do we need a new flow?"

Then:

```bash
tyrion spike start "<question>"
```

The CLI will prompt for hypothesis and exit criteria. Let the user answer those interactively, or suggest sensible defaults based on the question:
- **Hypothesis**: what you currently believe the answer is (can be blank)
- **Exit criteria**: what observable output proves you've answered the question ("running the benchmark shows < 5ms p99" or "the spec passes under 20 concurrent connections")

---

## Step 3: Investigate

This is the actual SDRD work. Do it.

**Log intermediate findings as you go:**

```bash
tyrion mark "<full observation, as much detail as you need>" --headline "<short, actionable summary>" --auto
```

Use `tyrion mark` freely during investigation — each one is a breadcrumb. Better to over-mark than forget a finding. Two things matter on every one of these:

- **`--auto`, always.** You (the agent) are the one filing it — omitting the flag mislabels it `[human]` in the origin tag, which defeats the whole point of that column (telling a human what they decided to track apart from what an agent noticed).
- **Always pass `--headline`.** It's the field every glance surface (ambient pane, `tyrion status`'s DISCOVERIES lane, `discovery list`) actually renders — `question` can hold all the investigation context you want, but a human skimming cold needs the short, actionable version, not a truncated fragment of your notes. "finding: computed WCAG contrast ratios against --am-bg (#0D0A07). --am-t…" tells them nothing; a headline like "meta text fails WCAG AA, 2.66:1" does.

**Investigation approaches** (pick what fits):
- Read the relevant code paths
- Write a minimal script or benchmark
- Check existing tests for coverage gaps
- Grep for existing usage patterns
- Ask the user what they've already tried

When you have enough to answer the question, move to Step 4.

---

## Step 4: Close with findings

```bash
tyrion spike done
```

The CLI prompts for three things. Fill them in from what you learned:

- **Finding**: what you actually discovered (one paragraph, concrete, no hedging)
- **Confidence**: `high` / `medium` / `low` — how certain are you the finding generalizes?
- **Recommendation**: what should be done with this finding

**High-quality findings:**
- Specific, not vague: "SQLite WAL handles 20 concurrent reads at < 2ms p99 on the test fixture" not "SQLite seems fast enough"
- Includes the evidence: "benchmark script in tmp/bench.rb shows..." or "spec at spec/store_spec.rb:47 confirms..."
- States limits: "only tested with the current schema — may differ at 100k rows"

**Clean up your own breadcrumbs.** Every intermediate mark from Step 3 is now redundant — its content is folded into the finding you just wrote. Left open, they sit in `mark` status forever, permanently crowding the ambient pane and `tyrion status`'s DISCOVERIES lane with duplicated investigation exhaust instead of real signal. Defer each one, citing the spike that closed it:

```bash
tyrion discovery defer <breadcrumb-disc-id> "captured in <spike-disc-id>'s finding"
```

---

## Step 5: Promote decision

After `tyrion spike done`, show the disc-id and findings summary. Ask:

> "Findings are ready as [disc-NNN]. Promote to a tracked story now, or leave as findings_ready to promote later?"

**If promote now:**

```bash
tyrion spike promote <disc-id>
```

The CLI prompts for a story title (Enter to use the question as title). After promotion:

```bash
tyrion status
```

Show the new story slug. Offer: "Run `/tyrion-implement <slug>` to build it."

**If leave as findings_ready:**

```bash
tyrion discovery list --status ready
```

Show the discovery in the list. Remind: `tyrion spike promote <disc-id>` when ready.

---

## Blocker handling

If the investigation hits a wall (can't get an answer without external input, dependency blocked, or the question itself is wrong):

```bash
tyrion mark "<what's blocking the investigation, full detail>" --headline "Blocked: <short reason>" --auto
```

Then either:
- Adjust the question and continue investigating
- Close the spike with a partial finding and `confidence: low`
- Leave the spike open and note the blocker explicitly

Don't abandon a spike without capturing what was learned. Even a negative result is a finding.

---

## The tight loop

The full lifecycle in one session looks like:

```bash
# Frame
tyrion spike start "Is X viable?"

# Investigate — mark as you go, --headline + --auto every time
tyrion mark "observed Y when doing Z under condition C" --headline "Y happens under Z" --auto
tyrion mark "X fails specifically when W, traced to ..." --headline "X fails under condition W" --auto

# Close
tyrion spike done
# → finding: "X is viable under P but not Q"
# → confidence: medium
# → recommendation: "Use X for the common case, fall back to Y when Q"

# Clean up the breadcrumbs — their content is now in the finding above
tyrion discovery defer <breadcrumb-1> "captured in disc-NNN's finding"
tyrion discovery defer <breadcrumb-2> "captured in disc-NNN's finding"

# Promote (if it earned a story)
tyrion spike promote disc-NNN
# → new story: "implement-x-for-common-case"
```

Total friction: name the question, do the work, close with facts, promote if warranted. No ceremony.
