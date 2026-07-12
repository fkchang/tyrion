# Tyrion

SQLite-backed resumability ledger for AI-assisted development. Answers: what was I
building, what's done, and what does the next agent do first? See README.md for
usage and docs/for_llms.md for agent orientation.

## Timeline

- 2026-07-10 | enforcement-mechanisms shipped (5/5) | review: first full dark-factory orchestration run — gates held (10/10 pass, no force-closes), SHARPEN gate bypassed on planted vague story, complete_story erases lane provenance at close | spawned: enforcement-hardening
- 2026-07-10 | enforcement-hardening shipped (4/4) | review: second dark-factory run — completed_by provenance survived close for all 4 lanes, hook now allows orchestrator notes on done/blocked stories + command-position matching fixed 3x-live false positive, criteria lint + lane-aware commit capture landed; concurrent non-lane session commit (2730a65) swept lane-6's in-flight edits — worktree isolation still open | spawned: hook-hardening-2
- 2026-07-11 | hook-hardening-2 shipped (4/4) | review: third dark-factory run — F1/F2/F4/F5 closed (quote-safe lanes, close warnings, cd-target resolution, --check armed reporting); new soft spots: first-closer commit bleed, gate-name coverage unchecked (lane-12 recorded 'rspec' not pre-push+uat) | spawned: enforcement-polish, worktree-lanes
- 2026-07-12 | enforcement-polish shipped (4/4) | review: fourth dark-factory run, fully serial, zero violations — --require-gates coverage enforcement (self-applied from wave 2 onward), shared-branch capture caveat, list epic-arg fix, F3 regex closed; micro-artifact: duplicate empty commits-since line in one Gates render | spawned: worktree-lanes execution
- 2026-07-12 | worktree-lanes shipped (1/1) | review: attended design session, Codex vet RETHINK→SIMPLIFY→SHIP IT (caught marker-file seed bug, forced merge-ready ledger gate + integration validation); live 2-story dry run 5/5 criteria — root fix for all shared-branch findings; dry run caught seed-aware cleanup gap live | spawned: none — validation campaign complete
