# Discovery Layer — Context

Source: 2026-05-25 ultrathink session (secretary/research + creator discussion)

## State Machine

```
mark  →  findings_ready
capturing  →  active_spike  →  findings_ready
                                    ↓
                       promoted_to_story | deferred | invalidated
```

- Organic entry (`tyrion mark`, `tyrion discover`): starts at `capturing` or goes directly to `findings_ready`
- Intentional entry (`tyrion spike start`): starts at `active_spike`
- Both converge at `findings_ready`
- `tyrion spike promote` transitions to `promoted_to_story` and creates a linked story

## Schema

```sql
CREATE TABLE discoveries (
  id              TEXT PRIMARY KEY,   -- disc-NNN auto-generated
  project_id      TEXT NOT NULL,
  epic_id         TEXT,               -- optional link to parent epic
  story_id        TEXT,               -- set when promoted
  status          TEXT NOT NULL,      -- mark|capturing|active_spike|findings_ready|promoted_to_story|deferred|invalidated
  question        TEXT,               -- "What do I need to learn?"
  hypothesis      TEXT,
  exit_criteria   TEXT,               -- what success produces
  finding         TEXT,               -- the key finding
  confidence      TEXT,               -- high|medium|low
  recommendation  TEXT,
  git_context     TEXT,               -- JSON: branch, dirty_files, last_commit
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
);
```

## Command Details

### `tyrion mark "brief description"`
- Takes 5 seconds, no further interaction
- Auto-captures: git branch, dirty file count, last commit, timestamp
- Status: `mark` (unformalized — surfaced by checkpoint)

### `tyrion discover`
- Interactive, ~30 seconds
- Prompts: "What were you trying to do?" + "What did you find?"
- Auto-captures: git context, recently-touched files
- Status: `findings_ready` immediately (user already knows the finding)
- Ends with: "Spec this out now? (y/later/no)"

### `tyrion spike start "question"`
- Prompts: hypothesis (optional), exit criteria ("what does success produce?")
- Status: `active_spike`
- Constraint: only one active spike per project — reject with error if one exists

### `tyrion spike done`
- Prompts: key finding (one paragraph max), confidence (high/medium/low), recommendation
- Transitions: `active_spike` → `findings_ready`

### `tyrion spike promote [--story "title"]`
- Works from `findings_ready` (either track)
- Shows finding summary
- Prompts: "Based on this, what should be built?" (one sentence)
- Generates draft acceptance criteria (LLM-assisted via agent call or structured prompt)
- Shows criteria draft: "Accept/edit?"
- Creates story with `born_from_discovery: disc-NNN` traceability field
- Status: `promoted_to_story`

### `tyrion discovery list [--status active|ready|promoted|deferred|all]`
### `tyrion discovery show <id>`

## orient Extension

New DISCOVERIES section in `tyrion status`:

```
=== DISCOVERIES ===
[active_spike]   disc-042  "Can concurrent writes cause scan duplication?" (2h ago)
[findings_ready] disc-039  "Memoizing scan results reduces render time 80%" → promote?
[mark]           2 unformalized marks this session → formalize at checkpoint
```

Only shown when at least one discovery exists for the active project.

## /tyrion-checkpoint Extension

`/tyrion-checkpoint` runs at session end. Extend to surface:
- Unformalized marks: "You have N marks this session. Formalize now? (y/n)"
- Active spikes: "disc-042 spike is still open. Close it? (y/n)"
- Findings ready: "disc-039 has findings. Promote to story? (y/later)"

## Phase 2 — DEFERRED

Do not implement in this epic:

### `tyrion note --spike "question"` (mid-implement blocker)
Used inside `/tyrion-implement` when implementation reveals a gap. Creates child spike linked to current story (`parent_story: story_slug`). Marks story as `blocked_on_discovery: disc-id`. When spike resolves, story surfaces as unblocked in orient.

### UTF auto-create on promote
When `tyrion spike promote` creates a story, optionally create UTF task:
`cultiv-cabinet utf create --title "..." --assignee user --initiative init-NNN`

## New Skills (separate from this epic)

- `/tyrion-spike` — lightweight skill for intentional spike workflow (frame → investigate → close → promote)
- `/tyrion-discover` — even lighter retroactive capture protocol (mark in-flow → discover → promote)

These skill files are separate deliverables, not part of this epic's story scope.

## What's Already Done (substrate — do not reimplement)

- SQLite store: `lib/tyrion/store.rb` (dispatcher, with_db, migration pattern)
- Commands: `lib/tyrion/commands.rb` (dispatcher pattern — add new `when 'discovery'` etc. here)
- CLI entry: `bin/tyrion`
- Output helpers: `lib/tyrion/output.rb`
- Skills: `tyrion-implement`, `tyrion-orient`, `tyrion-checkpoint`, `tyrion-shape`, `tyrion-import`
