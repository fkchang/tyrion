Feature: Hook hardening 2 — findings from the adversarial tests
  Closes the F-numbered findings from tests 4/4b
  (docs/dogfood-2026-07-10-dark-factory-first-run.md): quoted lane exports
  break lane resolution (F4), done-before-commit and zero-gate closes pass
  silently (F5 + the thrice-seen no-gates soft spot), the hook fail-opens
  silently when the tyrion lib is unloadable (F2), and it judges the session
  project's ledger rather than the command's target project (F1).

# RIGOR: build
Scenario: hook-lane-quote-fix
  As an agent exporting TYRION_LANE with conventional shell quoting
  In order to have the claim gate resolve the same lane my commands run under
  I want the hook to extract quoted lane tokens without the quote characters

  Given a gated command containing TYRION_LANE="lane-x" or TYRION_LANE='lane-x'
  When the claim-gate hook extracts the lane token
  Then the resolved token is lane-x with no quote characters, matching the unquoted form
  And an unquoted TYRION_LANE=lane-x prefix resolves identically to before

# RIGOR: build
Scenario: done-close-warnings
  As a human auditing a story after an autonomous close
  In order to catch silent evidence gaps at the moment they are created
  I want tyrion done to warn on a dirty working tree and on zero recorded gates

  Given a story being closed while the git working tree has uncommitted changes
  When tyrion done runs
  Then the close succeeds and the output includes a warning that uncommitted work will be missing from the commit record
  And closing a story that has zero gate notes prints a warning naming the gate command to record one
  And closing a clean-tree story with at least one gate note prints neither warning

# RIGOR: build
Scenario: hook-target-project-resolution
  As an orchestrator whose session project differs from the command's target project
  In order to have the gate judge the ledger the command actually mutates
  I want the hook to resolve project state from a cd prefix in the gated command segment

  Given a gated command segment of the form cd <dir> && tyrion done <slug>
  When the claim-gate hook evaluates it
  Then lane state is resolved from <dir> rather than the hook's own working directory
  And a gated command without a cd prefix resolves from the hook's working directory as before

# RIGOR: build
Scenario: hook-armed-check
  As a developer installing the claim-gate hook in a foreign repo
  In order to know whether enforcement is armed instead of silently fail-open
  I want a check mode that reports the hook's operational status

  Given the hook installed in a repo
  When I run claim-gate.sh --check from that repo
  Then it prints armed when the tyrion lib loads and a tyrion project is resolvable
  And it prints fail-open with the specific reason when the lib is unloadable or no project resolves
  And the install snippet in docs/for_llms.md includes the RUBYLIB line and the --check verification step
