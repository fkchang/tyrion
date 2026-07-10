Feature: Enforcement hardening — provenance, lint, and lane-aware capture
  Follow-ups from the first dark-factory dogfood run
  (docs/dogfood-2026-07-10-dark-factory-first-run.md). Each scenario closes a
  gap the run exposed: provenance erased at close, vague criteria rationalized
  instead of refused, the claim-gate hook blocking legitimate orchestrator
  coordination, and commit capture attributing sibling lanes' work.

# RIGOR: build
Scenario: provenance-preserved-at-close
  As an auditor reconstructing who did what after an orchestrated run
  In order to distinguish a properly-claimed run from the retro's never-claimed failure
  I want the closing lane's identity preserved when a story completes

  Given an in_progress story claimed by a lane token
  When tyrion done closes it
  Then the stories row records the closing lane token in a completed_by column added idempotently via the MIGRATIONS constant
  And tyrion show renders the completing lane for a done story
  And claimed_by and claimed_at still clear at close so the transient-lock semantics are unchanged

# RIGOR: build
Scenario: criteria-lint
  As an agent importing scenarios written by another agent
  In order to catch unverifiable acceptance criteria mechanically before an autonomous agent rationalizes them into proxy evidence
  I want tyrion import to flag criteria containing subjective phrasing

  Given a .feature file whose scenario has a Then criterion containing subjective phrasing such as clearly, helpful, or easy to understand
  When I run tyrion import on the file
  Then the import output prints a per-criterion warning naming the flagged phrase and suggesting an observable rewrite
  And criteria without flagged phrasing produce no warning
  And the story still imports so the lint warns rather than refuses

# RIGOR: build
Scenario: lane-aware-commit-capture
  As an auditor reading a story's commit note after a shared-worktree parallel run
  In order to trust that captured commits belong to this story and not a sibling lane
  I want commit capture at done to exclude commits already recorded by other stories

  Given two stories completed in one repo where a sibling story's commit note already records a commit made after this story started
  When tyrion done auto-captures commits for this story
  Then the captured commit note excludes hashes already present in other stories' commit notes
  And commits not recorded in any other story's commit note are still captured

# RIGOR: build
Scenario: hook-orchestrator-notes
  As an orchestrator session coordinating lanes without claiming a story
  In order to record wave results on stories my subagents completed without weakening the claim gate
  I want the claim-gate hook to permit post-hoc notes while still blocking unclaimed state mutations

  Given the claim-gate hook is live and the invoking lane has no in_progress story
  When tyrion note targets a story whose status is done or blocked
  Then the hook exits 0 and the note is recorded
  And tyrion check and tyrion done from an unclaimed lane still exit 2
  And tyrion note targeting a pending or in_progress story from an unclaimed lane still exits 2
  And a lane with an in_progress story remains unaffected for all three commands
