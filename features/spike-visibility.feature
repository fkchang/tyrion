Feature: Spike Visibility — verdict, mark linkage, and a discoveries show view
  Discovery-heavy projects (pure SDRD spike work, no epics) currently read as fully idle in
  Tyrion's web UI, and the Discoveries page itself is a flat, un-rendered list with no verdict
  signal. This epic is v1 of a two-stage plan (see the spike-visibility-plan agent-drop and this
  epic's context.md): the surgical bug fixes plus the one data-model axis (verdict) that would be
  expensive to retrofit later, deliberately deferring dependency/batch-promote/Spike-Board modeling
  to a future v2 epic once a second spike-heavy project confirms that shape is actually needed.

  Background:
    Given a project can be 100% spike/discovery work with zero epics (e.g. crimson-maestro)
    And Tyrion's Global View, sidebar, and Discoveries page currently assume every project has epics and stories

  Scenario: global-view-discovery-momentum
    As Forrest glancing at the Global View across all projects
    In order to tell that a spike-only project did real work instead of reading it as idle
    I want each project card's status to factor in discovery/spike activity, not just story counts

    # Intent: fix load_global_view's blindness to the discoveries table -- root cause of "crimson-maestro looks idle"
    # RIGOR: strict — status precedence between story activity and discovery activity is exactly the logic that silently misrepresented state before; wrong precedence recreates the bug
    Given a project with zero epics but discoveries in mark, active_spike, or findings_ready status
    When the Global View loads that project's card
    Then the card shows a discovery-derived status instead of "idle" and a one-line summary of discovery counts/verdicts
    And a project with real epic/story activity still shows story-derived status as it does today

  Scenario: sidebar-epic-gating-fix
    As Forrest or an agent viewing any page of a spike-only project
    In order to trust what the sidebar tells me about the project's state
    I want the sidebar to say "no active epic" with the discovery strip still shown, instead of the false "No active project"

    # Intent: fix render_sidebar / load_sidebar_data hard-gating on project && epic
    # RIGOR: loose — conditional restructuring of existing Phlex rendering, no new algorithmic logic
    Given a project exists but has no active epic
    When any page renders the sidebar
    Then the sidebar shows the project name and the discovery strip (spike/ready/marks counts)
    And it does not render "No active project"
    And the epic-scoped stories list section is simply omitted, not replaced by an error state

  Scenario: discovery-verdict-field
    As Forrest deciding whether to promote a findings_ready spike
    In order to tell a falsified hypothesis apart from a confirmed one at a glance
    I want a verdict axis on discoveries that is separate from lifecycle status

    # Intent: add discoveries.verdict (confirmed/falsified/falsified_alternative/partial), nullable, orthogonal to status -- the axis both peer sessions called the expensive-to-retrofit one
    # RIGOR: loose — schema migration + flag-threading follows the existing MIGRATIONS/consume_auto_flag idiom exactly
    Given a findings_ready discovery
    When it is closed via "tyrion spike done --verdict <confirmed|falsified|falsified_alternative|partial>"
    Then the discovery's verdict column stores that value, independent of its status
    And a discovery closed without --verdict keeps verdict nil (unscored), not defaulted to "confirmed"
    And "tyrion discovery show" and the web Discoveries views render the verdict distinctly from status

  Scenario: mark-parent-spike-linkage
    As anyone reviewing a session's spike work after the fact
    In order to see which marks were breadcrumbs of which spike instead of 9 unrelated rows
    I want marks filed while a spike is active to be linked to that spike automatically

    # Intent: add discoveries.parent_spike_id, auto-populated from the project's active_spike at tyrion mark creation time -- the seed data a future dependency view (v2) would consume
    # RIGOR: loose — a lookup at mark-creation time, mechanical
    Given a project has an active_spike when "tyrion mark" is run
    When the mark is created
    Then its parent_spike_id is set to that active_spike's discovery id, with no new flag required
    And a mark created with no active_spike in flight has parent_spike_id nil, same as today

  Scenario: discovery-show-view
    As Forrest reviewing one specific spike or mark
    In order to see its full detail without piecing it together from a flat list
    I want a per-discovery show page

    # Intent: add GET /discoveries/<id> -- question/hypothesis/exit_criteria/finding/confidence/recommendation/verdict, plus nested child marks via parent_spike_id
    # RIGOR: loose — new Phlex view following the existing show-page pattern (web/views/active_story.rb)
    Given a discovery disc-NNN, possibly with child marks linked via parent_spike_id
    When I visit /discoveries/disc-NNN
    Then I see every field of that discovery rendered in full, with markdown interpreted
    And any marks whose parent_spike_id is disc-NNN are listed nested under it, not on the flat index

  Scenario: discoveries-markdown-rendering
    As anyone reading finding, recommendation, or hypothesis text on the Discoveries pages
    In order to actually read formatted text instead of literal asterisks and backticks
    I want that text rendered as markdown

    # Intent: replace plain(...) calls in discoveries.rb (index) and the new show view with a markdown-rendering helper
    # RIGOR: loose — swap-in of a rendering helper, low invention once a markdown approach is chosen
    Given a discovery whose finding text contains markdown (bold, inline code, lists)
    When it renders on the Discoveries index or show page
    Then the markdown is interpreted (bold, code, and lists render as such), not shown as literal syntax

  Scenario: mark-flag-parsing-fix
    As anyone typing a tyrion mark command
    In order to get a real usage error instead of a garbage mark row when I mistype a flag
    I want tyrion mark to reject unrecognized --flags

    # Intent: root-cause fix for disc-026 ("--list") -- tyrion mark --list was folded into free-text content instead of erroring
    # RIGOR: strict — CLI arg-parsing edge cases are exactly the kind of logic that can look right and be silently wrong (e.g. legitimate mark text that happens to start with a dash)
    Given "tyrion mark" is invoked with an unrecognized --something flag
    When the command runs
    Then it exits with a usage error on stderr and creates no discovery row
    And "tyrion mark --auto \"real text\"" — a recognized flag — still works exactly as before
    And free-text mark content that is not flag-shaped is still accepted unchanged

  Scenario: discovery-delete-command
    As Forrest cleaning up a spurious discovery like disc-026
    In order to remove a row that should never have existed, not just mark it deferred
    I want a real delete command

    # Intent: disc-026 cleanup needs removal, not defer (a status flip); currently no delete path exists at all
    # RIGOR: loose — Store method + CLI command following the existing defer/close pattern
    Given a discovery disc-NNN that should not exist (e.g. a CLI-parsing accident)
    When I run "tyrion discovery delete disc-NNN"
    Then the row is permanently removed from the discoveries table
    And deleting a discovery that has been promoted to a story is refused, with a clear error naming the story

  Scenario: discoveries-live-poll
    As crimson-maestro-spikes mid-queue, filing marks and closing spikes one after another
    In order to see the Discoveries page reflect each mark/close without re-running CLI commands or manually reloading
    I want the Discoveries page to poll and repaint like Active Story and Ambient already do

    # Intent: extend the existing /api/poll pattern (active_story.rb, ambient.rb) to the Discoveries page -- answers the CLI-polling-loop complaint
    # RIGOR: loose — reuse of an established poll/repaint pattern already proven twice in this codebase
    Given the Discoveries page is open in a browser
    When a new mark is filed or a spike is closed for that project
    Then the page's discovery lists update within one poll interval, without a manual reload
