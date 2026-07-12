Feature: Enforcement polish — remaining small transgression fixes
  Closes the small-fix backlog from the three dark-factory runs
  (docs/dogfood-2026-07-10-dark-factory-first-run.md): gate-name coverage,
  first-closer commit-capture ambiguity, the F3 assignment-swallowed-quote
  regex residue, and the day-one tyrion list argument bug.

# RIGOR: build
Scenario: require-gates-at-done
  As a dark-factory close step with no human reviewing gate names
  In order to make protocol gate coverage mechanical instead of prose
  I want tyrion done to refuse when named required gates are missing

  Given a story closed with tyrion done <slug> "summary" --require-gates=pre-push,uat
  When any named gate has no recorded gate note on the story
  Then the close refuses with exit 1 and stderr names each missing gate
  And the close succeeds when every named gate has at least one recorded note
  And tyrion done without the flag behaves exactly as before
  And the dark-factory close step in the tyrion-implement skill passes --require-gates=pre-push,uat

# RIGOR: build
Scenario: commit-capture-ambiguity-flag
  As an auditor reading a story's commit note from a shared-branch parallel run
  In order to know when captured commits may belong to a concurrent lane
  I want capture to annotate commits recorded while sibling stories were in flight

  Given a story closing while another story in the same project is in_progress
  When tyrion done auto-captures commits
  Then the commit note includes a shared-branch caveat line naming the concurrent story count
  And a close with no concurrent in_progress siblings produces a commit note with no caveat

# RIGOR: build
Scenario: list-epic-arg
  As a user running tyrion list with an explicit epic slug
  In order to inspect a non-active epic without switching my active epic
  I want the epic argument honored instead of silently ignored

  Given an epic slug passed to tyrion list that differs from the active epic
  When the command runs
  Then the output lists the named epic's stories rather than the active epic's
  And tyrion list with no argument still lists the active epic
  And an unknown epic slug exits 1 naming the slug

# RIGOR: build
Scenario: hook-assignment-quote-regex
  As an orchestrator whose Bash commands embed gated-verb text inside quoted assignments
  In order to stop the claim gate matching text that is not a command
  I want the env-assignment prefix pattern to stop at quote characters

  Given a command line where a shell assignment value contains quoted text mentioning a tyrion gated verb
  When the claim-gate hook evaluates it
  Then the hook exits 0 because the assignment-swallowed quote no longer reads as command position
  And genuine gated invocations with unquoted VAR=value prefixes still match as before
