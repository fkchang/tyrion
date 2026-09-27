Feature: Intent assurance from brief through implementation
  Keep stories scannable while preserving full behavior, and review whether design and implementation deliver it.

  Scenario: show-summary-and-canonical-scenario
    # RIGOR: strict — source preservation and revision accuracy can fail silently
    # Intent: Scan a short brief and inspect the full behavior without searching old notes.
    As a reader inspecting a story
    In order to understand both its purpose and behavioral contract
    I want a short summary and its complete imported scenario
    Given a story has a narrative, Gherkin steps, and any applicable Background
    When I inspect its Mission Brief
    Then the summary and full scenario are both available with narrative and step keywords preserved
    And missing or changed source is labeled honestly rather than reconstructed as an exact original

  Scenario: review-design-against-intent
    # RIGOR: strict — coverage and verdict validity require evidence
    # Intent: Catch a plausible design that leaves out an intended user outcome.
    As a designer preparing implementation
    In order to catch intent gaps before building
    I want an intent-design gate tied to the current brief and design
    Given the story's current scenario and a proposed design
    When the design-intent review runs
    Then each intended outcome maps to a design decision or an explicit gap, ambiguity, or approved exclusion
    And the gate records its verdict, reviewer, source and design revisions, and unresolved judgments
    And missing coverage or a changed reviewed revision cannot count as a current pass

  Scenario: resolve-review-policy-by-rigor
    # RIGOR: strict — policy resolution determines which checks may be skipped
    # Intent: Select review depth and tools by an explicit policy rather than agent discretion.
    As a coordinator choosing the verification process
    In order to spend review effort in proportion to the work
    I want a recorded phase-by-rigor review policy
    Given a story has an explicit rigor level and execution mode
    When its review policy is resolved before implementation
    Then additional intent gates are optional at trivial and loose rigor and required with deeper independent review at strict rigor
    And selected review capabilities map to named available tools with their versions and required evidence
    And existing mandatory tests, pre-push and UAT requirements are not weakened
    And a required review cannot silently disappear because a tool is unavailable or an agent changes flags

  Scenario: require-user-approved-dark-factory-spec
    # RIGOR: strict — autonomy must not manufacture approval of its own scope
    # Intent: Automate execution only within a specification the user has approved.
    As the user authorizing unattended work
    In order to retain control over what is built
    I want dark-factory dispatch bound to my approved specification
    Given an epic or story is selected for dark-factory execution at any rigor
    When unattended dispatch is requested
    Then it requires recorded explicit user approval of the applicable scope, narrative, scenarios and acceptance baseline
    And missing approval or a material change to that baseline stops affected dispatch until renewed user approval
    And an agent review or inferred approval cannot substitute for that user decision
    And ordinary implementation decisions within the approved baseline do not require repeated user approval
    And the approved baseline identifies outcomes needing a human witness and whether dependent work may proceed before that witness
    And a required unwitnessed outcome remains visibly pending and prevents story completion rather than becoming an agent-generated pass

  Scenario: review-implementation-against-intent
    # RIGOR: strict — passing tests alone must not manufacture intent coverage
    # Intent: Require observed behavior to support the claim that the intended outcome was delivered.
    As a reviewer deciding whether work is complete
    In order to verify the intended experience was delivered
    I want an intent-implementation gate with behavioral evidence
    Given a current scenario, applicable design review, and implementation revision
    When implementation-intent review runs for an opted-in story
    Then each intended outcome maps to a test, witnessed interaction, or explicit unresolved judgment
    And uncovered outcomes fail the gate even when the ordinary test suite passes
    And closure requires current passing design and implementation intent evidence for opted-in stories
    And later relevant changes invalidate prior evidence without rewriting its history or reopening unrelated legacy work
