---
name: tyrion-orient
description: Use when restoring project status before choosing work. Triggered by "/tyrion", "/tyrion-orient", "where are we", "resume project", "tyrion status", or at the start of any session on a Tyrion-tracked project. Fast read-only restore — no mutations.
---

# /tyrion-orient

Restore project + epic status before choosing work. Read-only — never claims or mutates.

## Protocol

```bash
tyrion init          # idempotent — ensures this is a registered worktree
tyrion status        # plan view: project + epic + story progress + git state
```

If `tyrion status` shows an `in_progress` story:

```bash
tyrion resume        # read-only context dump: current_context, next_action, recent notes, criteria
```

Read the resume output. That is the full agent context for the in-progress story — git branch, worktree path, dirty count, last known state.

## Output

After orient, you should know:
- Which project and epic are active
- Which story is in_progress (if any) and whether it is stale
- What was the last `next_action` recorded
- How many stories remain

## Next steps

- To continue in-progress work: `/tyrion-implement` (no slug needed — it will resume)
- To start the next story: `/tyrion-implement` (no slug — claims next pending)
- To start a specific story: `/tyrion-implement <slug>`
- To see full detail on any story: `tyrion show <slug>`
