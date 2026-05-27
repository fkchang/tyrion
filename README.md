# Tyrion

![Tyrion — Small. Excellent. Running the realm.](assets/tyrion_hero.png)

> *"I drink and I know things."* — Tyrion Lannister, Hand of the King

**Small. Excellent. Running the realm.**

Most project tools are built for empires — sprawling, political, and staffed by people whose full-time job is updating them. Tyrion is built for the war room. The 20% of project management that does 80% of the work, sharp enough to actually get used.

It answers one question brutally well:

> *What was I building, what's done, and what does the next agent do first?*

---

## When sessions end, context dies

Every coding session ends. Claude compacts. You context-switch. A fresh agent arrives at the gates — no map, no history, no record of what was tried and why it failed.

You end up re-explaining decisions that were already made, rediscovering dead ends, or worse: silently starting over while thinking you're continuing.

The traditional fix is handoff notes. Writing them takes discipline you don't have mid-sprint. Reading them is friction you don't want when you're trying to get back in flow.

Tyrion is the ledger that writes itself. **The Hand always remembers.**

---

## Running the realm

Tyrion gives your project a spine:

- **Projects → Epics → Stories → Criteria** — maps directly to Gherkin feature files. Import a `.feature` file and the stories are created, acceptance criteria and all.
- **Resume state** — every story tracks `current_context` and `next_action`. A new agent runs `tyrion resume` and knows exactly where to start.
- **The war room** — `tyrion status` shows the full plan view: what's pending, what's in flight, what's done, what's being investigated.
- **`tyrion pocket`** — a compact briefing of the current story and next action, made for agent handoff.

---

## Install

```bash
gem install tyrion
```

Or from source:

```bash
git clone https://github.com/fkchang/tyrion
cd tyrion && gem build tyrion.gemspec && gem install tyrion-*.gem
```

Your ledger lives at `~/.tyrion/tyrion.db`. Override with `TYRION_DB_PATH`.

---

## Take the black

```bash
# Register this repo
tyrion init

# Create and activate a project
tyrion project new myapp "My App"
tyrion project activate myapp

# Import your Gherkin feature file → stories + criteria
tyrion import features/myapp.feature

# The war room
tyrion status

# Claim a story and ride
tyrion start my-first-story

# Send ravens as you go
tyrion note my-first-story progress "OAuth flow done, writing tests"
tyrion context my-first-story "Auth implemented. Tests next."
tyrion next my-first-story "Write the integration test"

# Mark criteria done — with evidence, not hearsay
tyrion check my-first-story 1 "oauth_spec.rb:42 — rspec spec/auth → PASSED"

# Hand off to the next agent
tyrion pocket          # compact briefing
tyrion resume          # full context dump

# Close it out — leave a briefing for whoever comes next
tyrion done my-first-story "OAuth done. Next: token refresh."
```

---

## Ravens & reconnaissance

Good campaigns don't travel in straight lines. You're mid-story and spot something that will matter later. You have a known unknown that needs investigation before you can commit to an approach. Tyrion tracks the exploratory layer without making it a court proceeding.

```bash
# Spot something worth remembering — log it instantly
tyrion mark "the N+1 on project list will hurt at scale"

# Frame a known unknown
tyrion spike start "Is SQLite WAL fast enough under concurrent agents?"

# Investigate, then close with findings
tyrion spike done
# → prompts: finding, confidence (low/medium/high), recommendation

# Promote a finding to a tracked story, with full lineage
tyrion spike promote disc-001

# Survey the reconnaissance backlog
tyrion discovery list --status ready
```

Each `spike promote` creates a story with `born_from_discovery` set — full traceability from question to shipped feature.

This is **SDRD** (Spike-Driven Requirements Discovery) made explicit: explore first, formalize what you learned. The discovery layer is that loop with a spine.

---

## The scrolls don't lie

Tyrion imports Gherkin. Write your acceptance criteria as `Given/When/Then` — Tyrion creates the stories and criteria. Reimport any time to sync.

```gherkin
Feature: Auth
  Scenario: user-login
    Given a registered user with valid credentials
    When they POST /auth/login
    Then they receive a JWT and a 200 response
```

```bash
tyrion import features/auth.feature
tyrion status
# → user-login  pending  [0/3 criteria]
```

Criteria require evidence, not assertions:

```bash
tyrion check user-login 1 "auth_spec.rb:42 — rspec spec/auth → PASSED"
```

---

## Key commands

```
tyrion status                    The war room — plan view
tyrion resume [slug]             Full context dump for a story
tyrion pocket                    Compact briefing for agent handoff

tyrion start <slug>              Claim a story
tyrion note <slug> <kind> "..."  Send a raven (kinds: plan|progress|decision|blocker|handoff)
tyrion context <slug> "..."      Update what's currently understood
tyrion next <slug> "..."         Update the next concrete action
tyrion check <slug> <n> "..."    Mark a criterion done with evidence
tyrion done <slug> "summary"     Close the campaign

tyrion mark "desc"               Instant reconnaissance bookmark
tyrion spike start "question"    Frame a known unknown
tyrion spike done                Close with findings
tyrion spike promote <disc-id>   Promote finding → story
```

`tyrion help` for the full scroll.

---

## A Lannister always pays his debts

Tyrion is built on one principle: **if the tool requires discipline to use, it's already lost**.

Most project tracking fails not because developers don't care — but because the tool is in the way when it matters most. Tyrion stays out of the way. The CLI and companion Claude Code skills work together so every common path — claiming a story, logging progress, handing off to a fresh agent — costs the minimum possible friction.

Tyrion was built during a SDRD session, when the handoff-doc problem became painful enough that building the solution was the right next spike. A tool born from its own use case, running the realm it was built for.

---

## License

MIT
