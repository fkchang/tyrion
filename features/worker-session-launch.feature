Feature: Worker sessions addressable from Tyrion
  Launch a worker from this coordinating task and retain an exact address for follow-up.

  Scenario: launch-herdr-worker-from-any-caller
    # RIGOR: strict — launch routing and side effects need explicit boundaries
    # Intent: Start a Claude worker in Herdr from Codex desktop without terminal hunting.
    As a coordinator outside Herdr
    In order to start work in an addressable terminal
    I want an explicit Herdr launch destination
    Given an approved story, worktree, and available Herdr runtime
    When I request a fresh named Claude worker in Herdr
    Then one new tab starts that worker with its task and explicit Tyrion lane
    And the default caller-based routing remains available
    And missing runtime or startup failure returns an actionable error without reporting success
    And a timeout or lost readiness signal is reported as an unknown outcome
    And retry first reconciles the original launch identity so it cannot create a duplicate worker for the same attempt

  Scenario: return-verified-worker-handle
    # RIGOR: strict — incorrect identity can select another running worker
    # Intent: Associate a worker with its work without guessing from names or directories.
    As a coordinator supervising parallel work
    In order to revisit the correct worker
    I want a verified handle with a readable name
    Given multiple workers may share a directory or display name
    When a worker launch becomes ready
    Then its handle records the exact lane, runtime scope, terminal, process lifetime, and supported actions
    And native conversation identity has explicit provenance and freshness
    And a name collision, stale binding, or missing identity never selects a neighboring worker
    And the worker handoff includes the canonical scenario revision and applicable constraints, not only its scan summary

  Scenario: verify-worker-follow-up-delivery
    # RIGOR: strict — delivery and receipt must remain correlated to the target
    # Intent: Direct the launched worker and distinguish delivery from completed work.
    As a coordinator returning to a worker
    In order to steer its assigned work
    I want a follow-up addressed through its verified handle
    Given a ready bound worker and a bounded follow-up instruction
    When I send that instruction using a supported delivery action
    Then evidence identifies the target worker and confirms receipt or an explicit failure
    And delivery never marks its Tyrion story complete
    And an ambiguous or replaced target refuses delivery without silently retrying elsewhere
