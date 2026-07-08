Feature: web-epics-multitab — Web: epics view, multi-tab scoping, epic switcher

  The Roadmap lies (0 of 4 epics done despite tier1 being 9/9 complete), the War Room
  mixes all epics in its Queue while the sidebar shows only one, and there is no way to
  switch epics from the web. Forrest runs the GEA pattern (many concurrent browser tabs
  tracking different projects or epics), which exposed that "active epic" conflates two
  concepts: the execution pointer (.tyrion/active-epic, CLI-owned) vs. per-tab view scope
  (should be 100% URL-driven). Plan: fix the roadmap count, scope War Room to one epic,
  thread ?epic= through all tabs, and add an epic switcher dropdown with a distinct
  "Set as agent focus" button that writes the execution pointer.

  Plan file: /Users/fkchang/.claude/plans/is-there-an-epics-glowing-waterfall.md

  Scenario: roadmap-epics-done-fix
    As a developer who just finished all stories in an epic
    In order to get the dopamine payoff of completion and see accurate campaign progress
    I want the Roadmap to show completed epics with a ✓ seal and a correct "N done" count

    Given the tyrion project has an epic where all stories are status=done (e.g. scott-feedback-tier1 9/9)
    When I visit /roadmap?project=tyrion
    Then the progress header reads "1 of 4 epics done" (not "0 of 4")
    And the tier1 epic row shows a ✓ seal glyph (not ◇ or ⚑)
    And the tier1 progress bar is fully filled
    And the change is computed from stories, not from epic.status (no DB write needed)

  Scenario: warroom-scope-to-epic
    As a developer focused on one epic's campaign board
    In order to see a coherent board where Queue and sidebar tell the same story
    I want the War Room Queue and board to show only the selected epic's stories

    Given I visit /warroom?project=tyrion&epic=scott-feedback-tier2
    Then the Queue shows only tier2's stories (not all 13 cross-epic pending stories)
    And the sidebar story list shows the same stories as the Queue
    When I visit /warroom?project=tyrion&epic=scott-feedback-tier3
    Then the Queue shows only tier3's stories

  Scenario: multitab-url-scoping
    As a developer with multiple browser tabs each tracking a different epic
    In order to have each tab stay scoped to its own epic without interfering with others
    I want every nav link to carry ?project= and ?epic= so scope is fully URL-driven

    Given I am viewing /?project=tyrion&epic=scott-feedback-tier2
    When I click the War Room nav tab
    Then I navigate to /warroom?project=tyrion&epic=scott-feedback-tier2

    Given I am viewing /warroom?project=tyrion&epic=scott-feedback-tier3
    When I click the Roadmap nav tab
    Then I navigate to /roadmap?project=tyrion&epic=scott-feedback-tier3

    Given I visit /?project=tyrion&epic=scott-feedback-tier3
    When the page loads
    Then the Active Story view is scoped to tier3 (not auto-jumped to another epic's in_progress story)

    Given I open / with no ?project= param and TYRION_PROJECT env is unset
    When the page loads
    Then I am redirected to /global (the project picker landing page)

  Scenario: epic-switcher-dropdown
    As a developer wanting to plan or browse a different epic without leaving the web UI
    In order to quickly switch my tab's view without touching the agent's execution pointer
    I want the epic breadcrumb in the topbar to be a dropdown of all epics for the project

    Given I am viewing any page with ?project=tyrion&epic=scott-feedback-tier2
    When I open the epic breadcrumb dropdown in the topbar
    Then I see all epics for the tyrion project with done/total story counts
    And completed epics (all stories done) show a ✓ badge
    And the CLI-active epic (from .tyrion/active-epic) shows a ⚑ badge
    When I select a different epic from the dropdown
    Then the URL updates to include ?epic=<selected-slug> (per-tab view change only)
    And the .tyrion/active-epic file is NOT modified (no side effect on execution pointer)

  Scenario: tyrion-worktrees-command
    As a developer managing parallel work across multiple git worktrees
    In order to know which worktree owns which epic and story without relying on memory
    I want tyrion worktrees to surface all git worktrees with their active epics and in-progress stories

    Given the project has multiple git worktrees (e.g. ~/work/tyrion and ~/work/tyrion-web-epics)
    When I run tyrion worktrees
    Then output shows one row per worktree with: path, branch, active epic slug, and in-progress story slug (or none)
    And the worktree where the command is run is marked as current

    Given tyrion worktrees output is available
    When tyrion-implement ORIENT runs with an explicit slug (e.g. warroom-scope-to-epic)
    Then it reads tyrion worktrees to find which worktree has that story's epic active
    And all subsequent tyrion commands in that session run from that worktree directory

    Given tyrion-implement ORIENT runs with no slug after a /clear
    When exactly one worktree has an in_progress story
    Then it automatically navigates to that worktree and uses that story's slug

  Scenario: set-as-agent-focus
    As a developer ready to direct the agent to start a different epic
    In order to set the agent's execution pointer from the web without running CLI
    I want a "Set as agent focus" button that writes .tyrion/active-epic for the project

    Given I am viewing a page with ?epic=scott-feedback-tier3
    And the current .tyrion/active-epic contains scott-feedback-tier2
    When I click "Set as agent focus"
    Then .tyrion/active-epic is updated to scott-feedback-tier3
    And running tyrion status in the terminal shows tier3 as the active epic
    And the ⚑ badge in the epic dropdown moves to tier3

    Given the project's worktree root cannot be resolved
    When I click "Set as agent focus"
    Then a flash message shows the CLI fallback: "tyrion epic activate <slug>"
    And .tyrion/active-epic is NOT written
