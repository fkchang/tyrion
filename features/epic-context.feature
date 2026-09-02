Feature: Epic Context as a first-class object
  Section J item (a) of the orgkit roadmap (ruling 10, 2026-09-02): the per-epic
  knowledge file (`features/<epic>.context.{org,md}`) stops being a convention that
  builders read by hand and becomes a Tyrion object with its own verbs, backed by
  the orgkit gem. New epics get a real `.org` context file from shape time onward;
  existing `.context.md` files keep working read-only. The commands must resolve the
  file by ABSOLUTE path in the MAIN checkout so a builder in a git worktree (which
  branches from origin/main and usually lacks the file) still reads and appends to
  the one true copy. Protocol source: cultiv_dev zulip/13 sections 4-5; design:
  cultiv-ai wiki org-mode-knowledge-management-for-ukf-2026-09-01.md sections F, J, K.
  The existing `tyrion context <story> "text"` (story current_context) is untouched.

  Scenario: main-root-and-context-path
    As a builder running tyrion inside a git worktree that does not contain the epic's context file
    In order to read and write the one true epic wiki instead of a missing or stale worktree copy
    I want tyrion to resolve the context file by absolute path in the main checkout, preferring .org over .md

    # RIGOR: strict — path resolution feeds every write in this epic; a wrong root silently forks the wiki
    # LANE: B
    Given a repo with a main checkout and a linked git worktree
    When Tyrion::Repo.main_root(path) is called from inside the worktree
    Then it returns the absolute path of the main checkout, derived from git rev-parse --git-common-dir via the bounded Repo.git_capture seam, and returns the same path when called from the main checkout itself
    And a non-git directory or a git timeout yields nil rather than raising, so callers fall back to worktree_root
    And Commands.epic_context_path(epic_slug, root:) returns features/<slug>.context.org under the main root when that file exists, else features/<slug>.context.md when that exists, else nil — .org wins whenever both are present
    And the Importer picks up a sibling <slug>.context.org with precedence over <slug>.context.md into epics.context_md/context_source_hash, and its idempotency covers the .org file's hash exactly as it did for .md
    And a spec covers each of: worktree resolution, main-checkout resolution, nil on non-git, .org-over-.md precedence, and .org import

  Scenario: epic-context-show
    As a builder about to start a story
    In order to get the epic-wide facts plus only my story's learnings without reading the whole wiki
    I want tyrion epic-context show to print my slice, defaulting to the active epic

    # RIGOR: loose — read-only shell-out; the slicing semantics live in orgkit
    # LANE: B
    Given an active epic whose context file is features/<epic>.context.org
    When tyrion epic-context show runs with no arguments
    Then it prints the absolute context path on the first line and then the whole file
    And tyrion epic-context show --story s1-2 shells to orgkit sections <abs-path> --tag s1_2 --include-untagged (story slug mapped hyphen to underscore, because org tags cannot contain hyphens) and prints its output verbatim after the path line
    And --epic <slug> selects a different epic than the active one, and an unknown slug or an epic with no context file exits 1 via die with a clear message
    And when the context file is .context.md the whole file is printed and a --story request prints a one-line note that story slicing needs an .org context file instead of failing
    And orgkit is invoked through a single seam (Tyrion::Orgkit.run or equivalent) that specs stub, with a real-binary integration spec that is skipped when orgkit is not on PATH
    And tyrion context <story> "text" still updates the story's current_context exactly as before

  Scenario: epic-context-append
    As a builder who just paid for a fact the wiki did not have
    In order to record it as a tagged learning the next builder's slice will retrieve
    I want tyrion epic-context append to write it through orgkit capture into the main checkout's file and refresh the ledger's snapshot

    # RIGOR: strict — the only write path into the wiki; the DB snapshot must never become a competing copy
    # LANE: B
    Given an active epic whose context file is features/<epic>.context.org
    When tyrion epic-context append --story s1-2 "text" [--tags a,b] runs
    Then it shells to orgkit capture <abs-main-checkout-path> "text" --under Learnings --tags s1_2[,a,b] and prints orgkit's confirmation
    And with --story omitted it defaults to this lane's own in_progress story via the read-only prime_story_for lookup (never resolve_my_story), and with no resolvable story it writes the learning with only the extra tags
    And after a successful capture the epic row's context_md and context_source_hash are refreshed from the file on disk, so tyrion drift and epic show see the new content and the DB never holds a stale competing copy
    And a .context.md file is refused with a message naming orgkit import as the conversion path; a non-zero orgkit exit propagates its stderr and exits 1; nothing is written to the DB on failure
    And running it from inside a linked git worktree appends to the main checkout's file, proven by a spec that builds a real worktree and asserts the worktree copy is untouched

  Scenario: epic-context-promote
    As a lead at a gate who finds a learning that is true beyond this epic
    In order to move it up one scope with provenance instead of copying it
    I want tyrion epic-context promote to refile the headline into a parent epic wiki or a system doc

    # RIGOR: loose — thin shell over orgkit refile; the move semantics are orgkit's
    # LANE: B
    Given an active epic with a Learnings headline to promote
    When tyrion epic-context promote "<heading>" --to <parent-epic-slug> [--under Learnings] runs
    Then it shells to orgkit refile <src-abs> "<heading>" "<dest-abs>::<under>" --materialize-inherited-tags --stamp promoted_from=<epic-slug>, where <dest-abs> is features/<parent-slug>.context.org in the main checkout
    And --to accepting a path (contains a slash or ends in .org) refiles into that file, resolved relative to the main checkout when not absolute; a destination that does not exist or is not .org exits 1 with a clear message
    And after success the source epic's context snapshot is refreshed in the DB, and so is the destination's when it is a tracked epic
    And orgkit refusal (exit 3, e.g. ambiguous heading) propagates its message and exit code 1 without touching the DB

  Scenario: shape-seeds-org-context
    As a lead shaping a new epic
    In order to start every new epic on the org format the rulings chose
    I want tyrion-shape to seed a .context.org wiki and the builder skills to read it through epic-context show

    # RIGOR: trivial — skill markdown and one seed template; no runtime code
    # LANE: B
    Given the tyrion-shape, tyrion-implement, tyrion-conduct and tyrion-orchestrate skills
    When their epic-context instructions are updated
    Then tyrion-shape writes features/<epic>.context.org (not .md) seeded with exactly these level-1 headlines in order: Where the knowledge already is, Verified facts, Gotchas already paid for, Lanes, Instrument, Learnings — with a one-line comment under Learnings stating the capture command
    And tyrion-implement's read-first step and tyrion-conduct's builder-preamble step both say to run tyrion epic-context show --story <slug> and to record learnings with tyrion epic-context append, replacing any instruction to read or edit the context file directly
    And tyrion-orchestrate no longer needs the agent to cd-prefix a <main-checkout> for context reads because epic-context resolves the main root itself; its text says so
    And tyrion help lists epic-context show|append|promote in one line each
