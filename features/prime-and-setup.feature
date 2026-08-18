Feature: Auto-Engagement: Prime & Setup
  Tyrion engages autonomously in any Claude Code session on a tracked project: a lean,
  tiered `tyrion prime` payload injected via SessionStart/PreCompact hooks, installed
  into a target repo in one command. Beads parity on the wiring; leaner than beads on
  the payload — inject state and pointers, not manuals, because the skills registry
  already carries the how. Design record: docs/auto-engagement-options.md (Option C,
  layers L1+L2). Codex-reviewed 2026-07-22; review deltas folded in (read-only prime,
  thin-shim gate install, atomic setup, marker edge cases).

  Scenario: tyrion-prime-command
    As a Claude Code session opening on a Tyrion-tracked project
    In order to know the project state without anyone typing /tyrion-orient
    I want tyrion prime to emit a tiered, lane-aware briefing sized to the current state

    # RIGOR: strict — tier selection across lane tokens could silently pick the wrong tier
    Given a Tyrion dev checkout with lane-token infrastructure available
    When tyrion prime runs in each cell of its state matrix
    Then a directory with no .tyrion/marker exits 0 with zero output
    And a tracked project with no in-progress story on the caller's lane prints a Tier-1 briefing of 15 lines or fewer: north star, active epic with done/total, the claim-next pointer, and a "full context: tyrion resume" pointer
    And a lane owning an in_progress story prints a Tier-2 briefing: the pocket checklist plus next_action and any staleness warning
    And the same command serves both SessionStart and PreCompact — the tier matrix is the whole contract, and no tier ever invents story state
    And two lanes with different in_progress stories each receive their own lane's briefing, never the other lane's
    And both tiers end with an imperative rules block of 5 lines or fewer (claim before code; evidence via tyrion note/check)
    And prime is provably read-only: no DB writes, no lane adoption or claim during story resolution, no .tyrion file writes — DB and .tyrion snapshots are byte-identical before and after
    And any internal error, missing or corrupt DB, or timeout exits 0 with warnings on stderr only — prime never blocks session start or compaction

  Scenario: setup-claude-command
    As Forrest installing Tyrion into a target repo
    In order to get auto-engagement without the manual 4-step hook install that caused the F2 silent fail-open
    I want tyrion setup claude to wire hooks, claim-gate, and whitelist in one idempotent, atomic command

    # RIGOR: strict — merging JSON settings and shell shims can silently clobber or fail-open
    Given a target repo with or without an existing .claude/settings.json
    When tyrion setup claude runs
    Then settings.json gains SessionStart and PreCompact hooks invoking tyrion prime through a fail-open shim: missing tyrion binary means silent no-op, and a timeout warns on stderr and continues
    And pre-existing hooks, permissions, unknown keys, and their order are preserved — merge, never clobber
    And malformed JSON or type-invalid hooks/permissions structures cause a refusal with zero writes
    And the claim-gate is installed as a versioned thin shim invoking tyrion hook claim-gate — enforcement logic stays in the tyrion install so upgrades propagate — and post-install the gate's --check reports armed
    And tyrion whitelist permissions are merged via the existing whitelist machinery
    And all writes are atomic (build complete, then rename): a failed run never leaves a partial install
    And re-running is idempotent: exactly one canonical tyrion entry per surface, stale tyrion-owned entries replaced, foreign entries untouched, second run changes zero bytes
    And tyrion setup claude --check writes nothing, reports each surface independently (hooks, gate shim + version, whitelist, CLAUDE.md block), and distinguishes current vs drift vs fail-open vs partial install via exit codes

  Scenario: claude-md-managed-block
    As a future setup run detecting drift
    In order to keep the target repo's CLAUDE.md guidance current without clobbering user content
    I want a versioned, hash-checked TYRION INTEGRATION block managed between markers

    # RIGOR: strict — marker-delimited replacement inside a user-owned file
    Given a target repo with arbitrary CLAUDE.md content, or none at all
    When tyrion setup claude writes the managed block
    Then a marker-delimited block is created carrying a version and a content hash computed over the block body bytes excluding the marker lines themselves, containing the mandate rules and a pointer at tyrion prime — no static command-reference dump
    And re-running replaces only the single well-formed owned block; every byte outside the markers is untouched
    And ambiguous marker states — duplicate, nested, reversed, or unpaired markers — cause a refusal with zero writes; only "no block present" appends a fresh one
    And tyrion setup claude --check reports current vs drifted via hash comparison
    And a repo with no CLAUDE.md gets one created containing just the block
