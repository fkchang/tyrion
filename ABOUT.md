# Tyrion

SQLite-backed resumability ledger for AI-assisted development. Answers: what was I
building, what's done, and what does the next agent do first? See README.md for
usage and docs/for_llms.md for agent orientation.

## Timeline

- 2026-07-10 | enforcement-mechanisms shipped (5/5) | review: first full dark-factory orchestration run — gates held (10/10 pass, no force-closes), SHARPEN gate bypassed on planted vague story, complete_story erases lane provenance at close | spawned: enforcement-hardening
- 2026-07-10 | enforcement-hardening shipped (4/4) | review: second dark-factory run — completed_by provenance survived close for all 4 lanes, hook now allows orchestrator notes on done/blocked stories + command-position matching fixed 3x-live false positive, criteria lint + lane-aware commit capture landed; concurrent non-lane session commit (2730a65) swept lane-6's in-flight edits — worktree isolation still open | spawned: none
