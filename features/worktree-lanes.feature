Feature: Worktree-isolated lanes
  Root fix for the shared-branch findings across all three dark-factory runs:
  the 2730a65 cross-session commit sweep, enforcement config activating for
  all lanes mid-wave (lesson-025), and first-closer commit bleed. Each
  orchestrated lane works in its own git worktree and merges back at wave end.
  NOTE: this story rewires the orchestrator itself — run attended with Codex
  plan vetting, not via dark factory.

# RIGOR: build+vet
Scenario: orchestrate-worktree-dispatch
  As an orchestrator running parallel lanes in one repository
  In order to stop concurrent lanes from sweeping each other's uncommitted work and activating half-built enforcement config repo-wide
  I want each dispatched lane to work in its own git worktree and merge back at wave end

  Given the tyrion-orchestrate skill dispatching a wave of two stories
  When each subagent starts work
  Then each lane operates in its own worktree under .worktrees/<lane> with usable .tyrion state for its project and epic
  And each lane's commits land on a lane branch, not main
  And at wave end the orchestrator merges each completed lane branch back to main, blocking the story instead of merging on conflict
  And after merge-back both stories' commits are reachable from main and no lane's commit contains files owned by the other story
  And .worktrees/ entries for merged lanes are removed
