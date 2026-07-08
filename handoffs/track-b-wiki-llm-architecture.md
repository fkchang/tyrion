# Handoff: wiki-llm-architecture (Track B)

**Story:** `wiki-llm-architecture` in epic `tyrion-polish`
**Status:** pending — ready to implement
**Run:** `/tyrion-implement wiki-llm-architecture` in a fresh session

---

## Orient fast

```bash
ruby bin/tyrion epic activate tyrion-polish
ruby bin/tyrion resume wiki-llm-architecture
```

The story: create `docs/for_llms.md` — a Karpathy-style architecture wiki an LLM agent reads
once to orient on the Tyrion codebase, plus a freshness mechanism so it never silently drifts
from the code it describes.

**What already exists (do NOT duplicate):**
- `CLAUDE.md` — already covers ~80%: data model, module breakdown (Store/Commands/Repo/Importer/
  Output), web UI section (Sinatra 4 + Phlex, per-file breakdown), discovery layer, key
  conventions, test conventions (RSpec), drift detection, Gherkin format.
- `README.md` — user-facing overview + skill descriptions.
- `DISCOVERY_LAYER.md` — discovery/spike layer design doc.
- No `docs/for_llms.md`, `AGENTS.md`, or `ARCHITECTURE.md` exists — net-new, no collision.

---

## Approved design proposal (implement this exactly)

### Home & form

`docs/for_llms.md` — matches the user's convention across projects. Add one line to the
Architecture section of `CLAUDE.md`: "For architecture detail, data-flow maps, and the command
catalog, read docs/for_llms.md". Never restate CLAUDE.md prose — cross-reference by section name.

### Section outline (implement all 8)

**1. Quick-Orient Index ("start here for task X")** — a router table. ~30 lines.

| Task | Read | Key files |
|---|---|---|
| Add a new CLI command | Module Flow + Command Catalog | `commands.rb`, `store.rb` |
| Change a web view | Web Layer | `app.rb`, `web/views/<name>.rb`, `data.rb` |
| Add a DB column | Data Model + Store | `store.rb` MIGRATIONS constant |
| Add/modify a skill | Skills System | skill file in `skills/` |
| Debug `tyrion status` oddity | Command Catalog → cmd_status | `commands.rb` |
| Trace why a discovery isn't showing | Data Model + Web Layer | `data.rb`, `discoveries.rb` |
| Update the wiki itself | Freshness Manifest section | in-doc manifest block |

**2. Data Model — ER sketch + field notes** (~55 lines)

ER diagram:
```
projects
  └── epics (project_id FK, UNIQUE project_id+slug)
        └── stories (epic_id FK, UNIQUE epic_id+slug, UNIQUE epic_id+sequence)
              ├── criteria (story_id FK, UNIQUE story_id+position)
              └── story_notes (story_id FK, kind enum: plan/progress/decision/blocker/test/handoff/recovery/session/followup)
  └── discoveries (project_id FK; optionally linked to epic_id, story_id)
```

Non-obvious field annotations (not in CLAUDE.md):
- `stories.claimed_by` — the lane token that owns this story in multi-worktree mode; NULL = unclaimed.
- `stories.born_from_discovery` — FK to `discoveries.id`, set by `cmd_spike_promote`.
- `discoveries.status` enum: `mark | capturing | active_spike | findings_ready | promoted_to_story | deferred | invalidated`. UNIQUE partial index on `(project_id) WHERE status = 'active_spike'` enforces one active spike per project.
- `epics.feature_source_hash` / `epics.context_source_hash` — SHA256s used by drift detection.

**3. Module Call / Data-Flow Map** (~80 lines)

Layer diagram:
```
bin/tyrion (ARGV)
  └── Commands.run(argv)
        ├── resolve_project(store)        # Repo.active_project → store.find_project_by_slug
        ├── resolve_project_epic(store)   # adds Repo.active_epic(token: current_lane_token)
        └── cmd_<name>(args, store)
              └── store.<method>(...)     # with_db { |db| db.execute / db.get_first_row }
                    └── SQLite WAL file at TYRION_DB_PATH
```

Write path invariant: every mutating Store method uses `db.transaction(:immediate)` inside `with_db`.

Concrete flows for `cmd_done` (write-heavy, 7 steps) and `cmd_status` (read-heavy, calls drift check).

**4. Per-Command Catalog** (~200 lines)

Every `cmd_*` method: what it reads, writes, refuses. Cover all ~40 entry points in `Commands.run`.
Format per entry: `tyrion <verb>` | reads | writes | refuses.
Key entries to get right: `done`, `resume`, `mark`, `spike start/done/promote`, `import`,
`wave next/show/set`, `assign`, `claim-next`, `start`, `block`, `unblock`, `epic complete`.

**5. Web Layer — Routes, Data, Views, Presenter** (~115 lines)

Request/render flow:
```
HTTP request
  └── app.rb route handler
        ├── TyrionWeb::Data.load_*_view(store, ...)   # all DB queries; returns plain Hash
        └── Phlex component.new(data).call             # renders HTML string
              ├── Views::Layout (always wraps) — topbar + sidebar
              └── inner view component
```
POST routes use Post/Redirect/Get with `session[:flash]` + `with_flash` helper.

Route inventory (all GET/POST routes with data loader + view component).

View inventory including the three CLAUDE.md doesn't cover:
- `web/views/war_room.rb` — active story in mission-brief format + blocking discoveries pane.
- `web/views/discoveries.rb` — filterable discovery list grouped by status; links to story when `born_from_discovery` is set.
- `web/views/about.rb` — renders `project.about_md` as HTML; thin Markdown pass-through.
- `web/views/not_found.rb` — 404 page.

Presenter method list (`epic_seal_css`, `epic_seal_glyph`, `status_glyph`, `time_ago`, `stale?`, `story_status_badge_css`).

**6. Skills System** (~80 lines)

Catalog all 10 skills: trigger condition, what it does, chains-to. Include:
- Main chain: `/tyrion-new` or `/tyrion-shape` → `/tyrion-import` → `/tyrion-implement` (loop) → `/tyrion-checkpoint`
- Recovery: `/tyrion-orient` → `/tyrion-implement`
- Orchestration: `/tyrion-orchestrate` fans out subagents each running `/tyrion-implement`

**7. Conventions & Gotchas — by reference** (~30 lines)

Point to CLAUDE.md for die/prompt/presence, lane identity, disc-NNN IDs, MIGRATIONS, test isolation.
Add one thing CLAUDE.md doesn't have: `current_lane_token` reads `ENV['TYRION_LANE']`; all
lane-aware Repo methods accept `token:` and fall back to the legacy path when nil. Tests that
exercise multi-lane behavior must set `ENV['TYRION_LANE']`.

**8. Freshness Manifest** (~50 lines)

The inline manifest block (see Freshness Mechanism below) plus human-readable staleness policy.

---

## Freshness mechanism (implement exactly as designed)

### Manifest format — inline HTML comment at bottom of docs/for_llms.md

```html
<!-- FOR_LLMS_MANIFEST
watched_files:
  lib/tyrion/store.rb:              sha256:<hex>  sections: [data-model, module-flow, command-catalog]
  lib/tyrion/commands.rb:           sha256:<hex>  sections: [module-flow, command-catalog, skills]
  web/app.rb:                       sha256:<hex>  sections: [web-layer]
  web/lib/tyrion_web/data.rb:       sha256:<hex>  sections: [web-layer]
  web/lib/tyrion_web/presenter.rb:  sha256:<hex>  sections: [web-layer]
  web/views/war_room.rb:            sha256:<hex>  sections: [web-layer]
  web/views/active_story.rb:        sha256:<hex>  sections: [web-layer]
  web/views/roadmap.rb:             sha256:<hex>  sections: [web-layer]
  web/views/global_view.rb:         sha256:<hex>  sections: [web-layer]
  web/views/discoveries.rb:         sha256:<hex>  sections: [web-layer]
  web/views/about.rb:               sha256:<hex>  sections: [web-layer]
  web/views/layout.rb:              sha256:<hex>  sections: [web-layer]
  README.md:                        sha256:<hex>  sections: [skills]
stamped_at: <ISO8601 timestamp>
-->
```

Inline (not sidecar) keeps the wiki self-contained — one file to read and ship.

### Always-on detection 1: git pre-commit hook

File: `.git/hooks/pre-commit` (executable). Pure shell, milliseconds. On every commit:
- Extracts the manifest block from `docs/for_llms.md`
- Recomputes SHA256 for each watched file
- Prints a yellow warning to stderr if any drift
- **Warning only — commit proceeds. Does not spawn an agent.**

```sh
#!/usr/bin/env bash
WIKI="docs/for_llms.md"
if [ ! -f "$WIKI" ]; then exit 0; fi
manifest=$(sed -n '/FOR_LLMS_MANIFEST/,/-->/p' "$WIKI")
stale=()
while IFS= read -r line; do
  file=$(echo "$line" | grep -oP '^\s+\K[^:]+(?=:)')
  stored=$(echo "$line" | grep -oP 'sha256:\K[0-9a-f]{64}')
  [ -z "$file" ] || [ -z "$stored" ] && continue
  [ ! -f "$file" ] && continue
  actual=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1 \
           || shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1)
  if [ "$actual" != "$stored" ]; then stale+=("$file"); fi
done <<< "$manifest"
if [ ${#stale[@]} -gt 0 ]; then
  echo "⚠  docs/for_llms.md may be stale. Changed: ${stale[*]}" >&2
  echo "   Run: /tyrion-doc-sync  or push to trigger regen" >&2
fi
exit 0
```

### Always-on detection 2: tyrion status surface

Add `wiki_drift_warning` private helper to `Commands` (`lib/tyrion/commands.rb`), called from
`cmd_status` right after the epic drift check:

```ruby
def self.wiki_drift_warning(root = nil)
  root ||= Repo.worktree_root
  wiki = File.join(root, 'docs', 'for_llms.md')
  return unless File.exist?(wiki)
  content = File.read(wiki)
  manifest_block = content[/<!--\s*FOR_LLMS_MANIFEST.*?-->/m]
  return unless manifest_block
  stale = []
  manifest_block.scan(/^\s+(\S+):\s+sha256:([0-9a-f]{64})/) do |file, stored|
    full = File.join(root, file)
    next unless File.exist?(full)
    stale << file if Digest::SHA256.file(full).hexdigest != stored
  end
  return if stale.empty?
  puts Output.yellow("⚠  docs/for_llms.md may be stale (#{stale.length} changed source file(s))")
  puts Output.yellow("   Changed: #{stale.join(', ')}")
end
```

### Pre-push regen step

Add to `.claude/config/overrides.json`:

```json
"wiki-freshness": {
  "command": "bin/check_wiki_freshness.sh",
  "name": "Wiki freshness check",
  "required": false
}
```

Write `bin/check_wiki_freshness.sh` (same logic as pre-commit hook, but exits non-zero when stale).
When the pre-push harness sees non-zero, it kicks a scoped regen subagent with this prompt template:

```
docs/for_llms.md is stale. Changed files: <list>
Update ONLY the sections whose sections: annotation includes these files.
Re-resolve all anchor table entries for changed files by grepping "def <symbol>".
Re-stamp the manifest with fresh SHA256 hashes and current timestamp.
Do not touch sections whose source files are unchanged.
```

`required: false` means a stale wiki doesn't block push — it triggers regen as a side effect.

### File:line anchoring strategy

Prose uses symbolic references only (`update_epic` in `Store`, `store.rb`) — never raw line numbers
in prose. An anchor table at the bottom of the wiki maps symbol → file:line. The regen step
re-greps all symbols from changed files before re-stamping. One stale table row, not scattered
through 600 lines of prose.

---

## Critical files to read before writing

- `/Users/fkchang/work/tyrion/CLAUDE.md` — full, understand what's already there
- `/Users/fkchang/work/tyrion/lib/tyrion/commands.rb` — full command catalog source
- `/Users/fkchang/work/tyrion/lib/tyrion/store.rb` — schema + all Store methods
- `/Users/fkchang/work/tyrion/web/app.rb` — all routes
- `/Users/fkchang/work/tyrion/web/lib/tyrion_web/data.rb` — data loaders
- `/Users/fkchang/work/tyrion/web/lib/tyrion_web/presenter.rb` — presenter methods
- All files under `web/views/`
- All `skills/*/SKILL.md` files

## Verification

- `docs/for_llms.md` exists with all 8 sections
- Freshness manifest block present at bottom with correct SHA256s for all watched files
- `.git/hooks/pre-commit` exists and is executable
- `bin/check_wiki_freshness.sh` exists and exits 0 (clean) or non-zero (stale)
- `tyrion status` shows no wiki-stale warning (fresh)
- Edit `store.rb`, run `git commit` → warning fires; run `tyrion status` → warning fires
- `.claude/config/overrides.json` has `wiki-freshness` step
- `CLAUDE.md` has one-line pointer to `docs/for_llms.md`

---

## Start here

```
/tyrion-implement wiki-llm-architecture
```

The implementation plan is in this file. The criteria in the feature file are the acceptance gate.
```
