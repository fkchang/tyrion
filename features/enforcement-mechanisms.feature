Feature: Enforcement mechanisms — constraints, not lessons
  Convert Tyrion's honor-system protocol into mechanical enforcement.
  Born from docs/retro-2026-07-09-llm-delegation.md: a headless agent bypassed
  claim/close protocol because it lived only in SKILL.md prose. Each scenario
  turns one rule into a mechanism the CLI or harness enforces.

# RIGOR: build
Scenario: done-gate-refusal
  As an unattended dark-factory agent closing a story
  In order to make "never close over a failing gate" a mechanism instead of skill prose
  I want tyrion done to refuse when any gate's latest result is fail

  Given a story with gate notes whose latest result for at least one gate is fail
  When I run tyrion done <slug> "summary" without --force
  Then the command exits 1 and stderr lists each gate whose latest result is fail
  And tyrion done <slug> "summary" --force closes the story and records a force-close gate note that renders in tyrion show's Gates section
  And a story whose gate failed but was later re-recorded as pass closes normally without --force
  And a story with no gate notes closes normally

# RIGOR: build
Scenario: importer-thin-warning
  As an agent importing a .feature file written by another agent
  In order to see immediately when a scenario landed as a bare title with nothing to verify against
  I want tyrion import to warn loudly on zero-criteria stories instead of staying silent

  Given a .feature file containing one scenario with criteria and one scenario with a bare title and zero Given/When/Then lines
  When I run tyrion import on the file
  Then the import output prints a visible warning line for the zero-criteria story asking whether the full scenario body was included
  And the story with criteria still prints the normal Story line with its criteria count

# RIGOR: build
Scenario: status-claim-rollup
  As a human or dashboard glancing at tyrion status
  In order to spot when the ledger is lying relative to real work in progress
  I want the counts line to always show in_progress and surface pre-claims

  Given an epic containing pending, pre-claimed, in_progress, and done stories
  When I run tyrion status
  Then the counts line shows the in_progress count even when it is zero
  And the counts line shows a pre-claimed count when any pending story has a claimed_by starting with assigned:
  And the counts line omits the pre-claimed segment when no story is pre-claimed

# RIGOR: build
Scenario: claim-gate-hook
  As a lead session dispatching subagents that may skip skill discipline
  In order to convert "claim before work" from convention to mechanism
  I want a PreToolUse hook that blocks tyrion note/check/done when the active lane has no in_progress story

  Given the claim-gate hook script at hooks/claim-gate.sh wired into a checked-in .claude/settings.json
  When hook JSON for a Bash command matching tyrion note/check/done is piped to the script with no in_progress story in the active lane
  Then the script exits 2 and its output tells the agent to claim a story first via tyrion start
  And the same JSON with an in_progress story in the active lane exits 0
  And hook JSON for a non-tyrion Bash command exits 0 regardless of lane state
  And running the script outside a Tyrion project exits 0 fail-open
  And docs/for_llms.md documents the hook convention with an install snippet

# RIGOR: build
Scenario: forllms-known-failure-doc
  As an agent orienting on tyrion via docs/for_llms.md
  In order to avoid repeating the headless-agent ledger-bypass incident
  I want the known failure mode documented

  Given the retro at docs/retro-2026-07-09-llm-delegation.md
  When an agent reads docs/for_llms.md
  Then the documentation clearly explains the known failure mode
  And readers find the guidance helpful and easy to understand
