# Retro: Headless-Agent CLI-Without-Skills Failure (2026-07-09)

## Incident

A headless Fable-model lead session in cultiv-ai (epic `utf-resumability-ledger`, init-063)
was told "tyrion spec-first." It wrote a good 7-scenario `.feature` file, but the epic's own
tracking data shows the ledger diverged from real work: all 6 completed stories have
`claimed_by = NULL` the entire time, went `pending -> done` in a 33-second batch at
collection instead of tracking work as it happened, and `current_context`/`next_action` sat
empty throughout — so a live dashboard reading the ledger showed "nothing started" while two
subagents were mid-flight on real implementation. Forrest caught it by eyeballing the
dashboard against known active work, not from anything the ledger itself surfaced.

Full timeline and DB evidence: `wiki/research/tyrion-delegation-retro.md` in cultiv-ai
(commit trail `82956b3`/`3b0e4ac`/`a0656ad`/`b72f9fb`/`2295244`, story_notes with a `recovery`
kind unique to this epic).

## Root causes (this tool's share of it)

1. **Silent thin imports.** `lib/tyrion/importer.rb:75` only prints a confirmation line
   `if r[:criteria_count] > 0` — a scenario imported with zero `Given/When/Then` lines
   produces **no output at all**, identical to success. There's no signal distinguishing "a
   fully-specified story landed" from "a bare `Scenario:` title landed with nothing to
   verify against."
2. **No mechanical claim gate.** Claiming a story (`tyrion start <slug>`) is documented
   protocol inside `/tyrion-implement` and `/tyrion-orchestrate`'s subagent prompt template,
   not anything the CLI or a hook enforces. A subagent that never invokes those skills — e.g.
   because it treats itself as "dispatched to execute a specific task" and skips
   skill-checking entirely (see `using-superpowers` SKILL.md's `<SUBAGENT-STOP>` clause,
   upstream of tyrion but the proximate trigger here) — has nothing in `tyrion` itself
   nudging it to claim before writing code.
3. **No at-a-glance ledger-health signal.** `tyrion status`/`tyrion list` require reading
   full output and inferring "0 claimed, N pending" — there's no single line a dashboard or a
   human can check to see the ledger is lying relative to real work in progress.

## Concrete fixes

### 1. Importer: warn loudly on thin scenarios

`lib/tyrion/importer.rb:75` — change the silent skip to an explicit warning printed every
time, not just gated on `criteria_count > 0`:

```ruby
results.each do |r|
  if r[:criteria_count] > 0
    puts "  Story: #{r[:slug]} (#{r[:criteria_count]} criteria)"
  else
    puts "  ⚠ Story: #{r[:slug]} imported with 0 criteria — " \
         "was the full Given/When/Then scenario body included, or just a title?"
  end
end
```

This makes "I imported a stub instead of the real spec" visible in the same terminal output
the agent is already looking at, instead of requiring a separate DB query to discover.

### 2. CLI: surface claim status in `status`/`list`

Add a one-line rollup to `tyrion status` output: `N pending / N claimed / N in_progress /
N done` computed from the epic's current stories. This is the number a dashboard-reading
human (or agent) actually wants and currently has to derive by reading the full listing.

### 3. Orchestration: claim-on-dispatch as a hook, not just a prompt line

Since neither `~/work/tyrion/.claude/settings.json` nor cultiv-ai's has a hook enforcing this,
and the claim step currently lives only inside `/tyrion-implement`/`/tyrion-orchestrate`
SKILL.md prose that a subagent can simply never read: add a `PreToolUse` hook (Bash matcher on
`tyrion (note|check|done) `) in projects that use tyrion, or in tyrion's own `.claude/hooks/`
convention if one gets established, that checks whether the active lane has an `in_progress`
story before allowing progress-reporting or completion commands. This converts "claim before
work" from convention to mechanism — the one thing prompt text alone couldn't guarantee here.

### 4. `docs/for_llms.md`: document this as a known failure mode

Add a "Known failure mode" entry (see companion commit to this one) so any agent orienting on
tyrion via `for_llms.md` sees the incident before repeating it, rather than only discovering
the fix on the next collision.

### 5. Don't assume the invoking session ran `using-superpowers`

`tyrion-implement`/`tyrion-orchestrate` SKILL.md files should not rely on a subagent having
gone through skill-discovery discipline upstream (the `using-superpowers` `<SUBAGENT-STOP>`
clause tells exactly the agents most likely to touch tyrion CLI directly — dispatched
subagents executing a specific task — to skip that discipline). A self-contained reminder at
the top of tyrion's own skill files ("even if you were told to skip skill-checking, if you are
about to run a `tyrion` command by hand, check whether `/tyrion-implement` applies first")
is a cheap mitigation that doesn't depend on fixing the upstream clause.

## What's out of tyrion's hands

Item 5 above and the root `<SUBAGENT-STOP>` clause live in the `superpowers-marketplace`
plugin, not this repo — flagged here for visibility but not something this codebase can fix
directly. The mitigation in #5 is the tyrion-side compensating control.
