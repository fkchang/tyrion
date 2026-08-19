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
tyrion resume        # full context dump: project north-star, epic intent, open threads, story state
```

Read the resume output. It contains the complete agent context in one pass: project north star (first line of about_md), active epic name + intent + done/total count, open threads (other epics with pending stories), and story-level details (current_context, next_action, recent notes, criteria, git branch, worktree path, dirty count).

## Output

After orient, you should know:
- Project north star (first line of about_md) and active project name
- Active epic name, intent, and done/total story count
- Open threads: other epics with pending stories (cross-epic drift is visible at a glance)
- Which story is in_progress (if any) and whether it is stale
- What was the last `next_action` recorded
- How many stories remain in the active epic

## Next steps

- To continue in-progress work: `/tyrion-implement` (no slug needed — it will resume)
- To start the next story: `/tyrion-implement` (no slug — claims next pending)
- To start a specific story: `/tyrion-implement <slug>`
- To see full detail on any story: `tyrion show <slug>`
- To see the epic tree and what's actually ready: `tyrion epic list` (containment + waiting
  reasons) and `tyrion epic waves` (the ready set, grouped by wave). Run these before picking
  a next epic — `tyrion epic list` alone will show an epic as `[active]` with pending stories
  even while it's `waiting` on an unmet prerequisite; `epic waves` is the one view that never
  lists a waiting epic at all, so an agent restoring context is never left to pick one blind.
