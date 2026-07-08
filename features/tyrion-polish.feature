Feature: Tyrion Polish — Epic Seal + LLM Architecture Wiki
  Two independent improvements: making completed epics visible as done,
  and a fast-orient architecture reference for LLM agents.

  Scenario: epic-completion-seal
    As a developer who just finished the last story in an epic
    In order to see the win clearly and trust the web UI at a glance
    I want completed epics to read as DONE on every surface

    Given all stories in an epic are done
    When I run tyrion done on the last story
    Then I am prompted "All N stories done. Seal epic <slug> as complete? [y/N]"
    And answering y sets the epic status to done and shows a green ✓ seal in the web roadmap
    And answering n leaves the epic active and prints the manual command hint

    Given an epic with status done
    When I run tyrion epic complete <slug>
    Then the epic status is set to done

    Given an epic with status done
    When a story in that epic is started or claimed
    Then the epic status is flipped back to active

    Given an epic with status done
    When tyrion import adds a new pending story to that epic
    Then the epic status is flipped back to active

  Scenario: wiki-llm-architecture
    As an LLM agent starting a new session on the Tyrion codebase
    In order to orient in seconds instead of minutes of file exploration
    I want a navigational architecture reference I can read once and then jump directly to the right code

    Given docs/for_llms.md does not exist
    When I write the LLM architecture wiki per the approved design proposal
    Then docs/for_llms.md exists with sections: quick-orient index, data model ER sketch,
      module call/data-flow map, per-command catalog (all cmd_* methods),
      web layer route+view inventory, skills system catalog, conventions by reference,
      and a freshness manifest block

    Given docs/for_llms.md exists with a freshness manifest
    When a watched source file changes
    Then the git pre-commit hook prints a staleness warning
    And tyrion status shows a one-line yellow wiki-stale warning (same pattern as drift warning)

    Given docs/for_llms.md is stale
    When /pre-push runs
    Then the wiki-freshness step detects staleness and kicks a scoped regen subagent
    And the subagent updates only the sections whose watched files changed
    And re-stamps the manifest with fresh hashes
