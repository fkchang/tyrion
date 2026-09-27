Feature: Fleet to live workspace pilot
  Use this initiative's own implementation to prove that Tyrion removes terminal hunting.

  Scenario: open-bound-lane-workspace
    # RIGOR: strict — scope and connection lifetime must survive UI updates
    # Intent: Enter a live worker from Fleet with the work context already beside it.
    As a developer inspecting parallel projects
    In order to act on the work I selected
    I want a lane workspace with its live terminal and Tyrion context
    Given a Fleet lane has a verified worker handle
    When I open that lane
    Then its terminal opens read-only beside its story, next action, and acceptance criteria
    And context refresh preserves terminal connection, draft input, and keyboard focus
    And unmapped, ambiguous, and stale identities remain visible instead of opening another session

  Scenario: dogfood-workspace-on-its-own-worker
    # RIGOR: strict — a real interaction and receipt must witness the outcome
    # Intent: Prove the complete loop on the worker implementing this initiative.
    As the user supervising this initiative
    In order to continue its work without locating terminals manually
    I want to inspect and steer its bound worker from Tyrion
    Given the worker-session launch work is available as a pilot lane
    When I enter from Fleet, inspect context, and explicitly take control to send a bounded instruction
    Then that worker receives the instruction and I can return to Fleet without copying IDs or hunting tabs
    And scoped access and control ownership are verified before input is enabled
    And the trial records remaining friction, identity limits, and evidence without equating agent idle with story done
    And an interrupted-return trial records user-confirmed evidence that the selected work, current state and next action can be recovered without terminal hunting or reconstructing the previous conversation
