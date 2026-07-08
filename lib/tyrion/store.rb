# frozen_string_literal: true

require 'sqlite3'
require 'securerandom'
require 'fileutils'
require 'time'
require 'digest'
require 'json'
require 'set'

module Tyrion
  # Store — SQLite-backed resumability ledger.
  # Mirrors conventions from lib/cultiv_cabinet/utf/sqlite_store.rb:
  #   frozen heredoc DDL, with_db block, WAL+FK, UUID ids, iso8601(6) timestamps.
  class Store
    DB_PATH = ENV.fetch('TYRION_DB_PATH', File.expand_path('~/.tyrion/tyrion.db'))

    ALLOWED_FILTER_COLS = %w[project_id epic_id status slug].freeze

    DDL = <<~SQL.freeze
      CREATE TABLE IF NOT EXISTS projects (
        id                     TEXT PRIMARY KEY,
        slug                   TEXT UNIQUE NOT NULL,
        name                   TEXT NOT NULL,
        about_md               TEXT,
        primary_repo_identity  TEXT,
        status                 TEXT NOT NULL DEFAULT 'active'
                                 CHECK(status IN ('active','paused','done','abandoned')),
        created_at             TEXT NOT NULL,
        updated_at             TEXT NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_projects_repo ON projects(primary_repo_identity);

      CREATE TABLE IF NOT EXISTS epics (
        id                   TEXT PRIMARY KEY,
        project_id           TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        slug                 TEXT NOT NULL,
        name                 TEXT NOT NULL,
        intent               TEXT,
        context_md           TEXT,
        status               TEXT NOT NULL DEFAULT 'active'
                               CHECK(status IN ('active','paused','done','abandoned')),
        feature_source_path  TEXT,
        feature_source_hash  TEXT,
        context_source_hash  TEXT,
        created_at           TEXT NOT NULL,
        updated_at           TEXT NOT NULL,
        UNIQUE(project_id, slug)
      );

      CREATE INDEX IF NOT EXISTS idx_epics_project_status ON epics(project_id, status);

      CREATE TABLE IF NOT EXISTS stories (
        id                   TEXT PRIMARY KEY,
        epic_id              TEXT NOT NULL REFERENCES epics(id) ON DELETE CASCADE,
        sequence             INTEGER NOT NULL,
        slug                 TEXT NOT NULL,
        title                TEXT NOT NULL,
        intent               TEXT,
        current_context      TEXT,
        next_action          TEXT,
        status               TEXT NOT NULL DEFAULT 'pending'
                               CHECK(status IN ('pending','in_progress','blocked','done','abandoned')),
        started_at           TEXT,
        completed_at         TEXT,
        last_note_at         TEXT,
        born_from_discovery  TEXT REFERENCES discoveries(id) ON DELETE SET NULL,
        blocked_on           TEXT,
        blocked_on_discovery TEXT,
        claimed_by           TEXT,
        claimed_at           TEXT,
        created_at           TEXT NOT NULL,
        updated_at           TEXT NOT NULL,
        UNIQUE(epic_id, slug),
        UNIQUE(epic_id, sequence)
      );

      CREATE INDEX IF NOT EXISTS idx_stories_epic_status ON stories(epic_id, status);

      CREATE TABLE IF NOT EXISTS criteria (
        id            TEXT PRIMARY KEY,
        story_id      TEXT NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
        position      INTEGER NOT NULL,
        keyword       TEXT NOT NULL
                        CHECK(keyword IN ('Given','When','Then','And','But','*')),
        semantic_kind TEXT NOT NULL
                        CHECK(semantic_kind IN ('given','when','then')),
        text          TEXT NOT NULL,
        status        TEXT NOT NULL DEFAULT 'pending'
                        CHECK(status IN ('pending','met','not_applicable')),
        evidence      TEXT,
        checked_at    TEXT,
        created_at    TEXT NOT NULL,
        updated_at    TEXT NOT NULL,
        UNIQUE(story_id, position)
      );

      CREATE TABLE IF NOT EXISTS story_notes (
        id          TEXT PRIMARY KEY,
        story_id    TEXT NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
        kind        TEXT NOT NULL
                      CHECK(kind IN ('plan','progress','decision','blocker','test','handoff','recovery','session','followup','observation','gate','commit')),
        body        TEXT NOT NULL,
        metadata    TEXT,
        created_at  TEXT NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_notes_story_created ON story_notes(story_id, created_at);

      CREATE TABLE IF NOT EXISTS discoveries (
        id              TEXT PRIMARY KEY,
        project_id      TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        epic_id         TEXT REFERENCES epics(id) ON DELETE SET NULL,
        story_id        TEXT REFERENCES stories(id) ON DELETE SET NULL,
        status          TEXT NOT NULL
                          CHECK(status IN ('mark','capturing','active_spike','findings_ready','promoted_to_story','deferred','invalidated')),
        question        TEXT,
        hypothesis      TEXT,
        exit_criteria   TEXT,
        finding         TEXT,
        confidence      TEXT
                          CHECK(confidence IN ('high','medium','low')),
        recommendation  TEXT,
        git_context     TEXT,
        created_at      TEXT NOT NULL,
        updated_at      TEXT NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_discoveries_project_status ON discoveries(project_id, status);

      CREATE UNIQUE INDEX IF NOT EXISTS idx_one_active_spike_per_project
        ON discoveries(project_id)
        WHERE status = 'active_spike';
    SQL

    def initialize(db_path: DB_PATH)
      @db_path = db_path
      FileUtils.mkdir_p(File.dirname(@db_path))
      setup_db
    end

    # ── Projects ───────────────────────────────────────────────────────────

    def create_project(slug:, name:, about_md: nil, repo_identity: nil)
      t = now
      id = uuid
      with_db do |db|
        db.execute(
          'INSERT INTO projects (id, slug, name, about_md, primary_repo_identity, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [id, slug, name, about_md, repo_identity, 'active', t, t]
        )
        db.get_first_row('SELECT * FROM projects WHERE id = ?', [id])
      end
    end

    def update_project(id, attrs)
      set_clauses = attrs.keys.map { |k| "#{k} = ?" }
      set_clauses << 'updated_at = ?'
      binds = attrs.values + [now, id]
      with_db do |db|
        db.execute("UPDATE projects SET #{set_clauses.join(', ')} WHERE id = ?", binds)
        db.get_first_row('SELECT * FROM projects WHERE id = ?', [id])
      end
    end

    def find_project_by_slug(slug)
      with_db { |db| db.get_first_row('SELECT * FROM projects WHERE slug = ?', [slug]) }
    end

    def find_project_by_id(id)
      with_db { |db| db.get_first_row('SELECT * FROM projects WHERE id = ?', [id]) }
    end

    def find_project_by_repo(repo_identity)
      with_db { |db| db.get_first_row('SELECT * FROM projects WHERE primary_repo_identity = ?', [repo_identity]) }
    end

    def list_projects
      with_db { |db| db.execute('SELECT * FROM projects ORDER BY updated_at DESC') }
    end

    # ── Epics ──────────────────────────────────────────────────────────────

    def create_epic(project_id:, slug:, name:, intent: nil, context_md: nil,
                    feature_source_path: nil, feature_source_hash: nil, context_source_hash: nil)
      t = now
      id = uuid
      with_db do |db|
        db.execute(
          'INSERT INTO epics (id, project_id, slug, name, intent, context_md, status, feature_source_path, feature_source_hash, context_source_hash, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [id, project_id, slug, name, intent, context_md, 'active', feature_source_path, feature_source_hash, context_source_hash, t, t]
        )
        db.get_first_row('SELECT * FROM epics WHERE id = ?', [id])
      end
    end

    def update_epic(id, attrs)
      set_clauses = attrs.keys.map { |k| "#{k} = ?" }
      set_clauses << 'updated_at = ?'
      binds = attrs.values + [now, id]
      with_db do |db|
        db.execute("UPDATE epics SET #{set_clauses.join(', ')} WHERE id = ?", binds)
        db.get_first_row('SELECT * FROM epics WHERE id = ?', [id])
      end
    end

    def find_epic(project_id, epic_slug)
      with_db { |db| db.get_first_row('SELECT * FROM epics WHERE project_id = ? AND slug = ?', [project_id, epic_slug]) }
    end

    # True only when an epic has at least one story and every story is done.
    def all_stories_done?(epic_id)
      with_db do |db|
        total = db.get_first_value('SELECT COUNT(*) FROM stories WHERE epic_id = ?', [epic_id]).to_i
        return false if total.zero?
        db.get_first_value("SELECT COUNT(*) FROM stories WHERE epic_id = ? AND status != 'done'", [epic_id]).to_i.zero?
      end
    end

    def find_epic_by_id(epic_id)
      with_db { |db| db.get_first_row('SELECT * FROM epics WHERE id = ?', [epic_id]) }
    end

    def seal_epic(epic_id, force: false)
      unless force || all_stories_done?(epic_id)
        stories = stories_for_epic(epic_id)
        undone  = stories.reject { |s| s['status'] == 'done' }
        raise "Epic has no stories — nothing to seal." if stories.empty?
        raise "#{undone.length} story/stories not done: #{undone.map { |s| s['slug'] }.join(', ')}"
      end
      update_epic(epic_id, 'status' => 'done')
    end

    def archive_epic(epic_id)
      update_epic(epic_id, 'archived_at' => now)
    end

    def unarchive_epic(epic_id)
      update_epic(epic_id, 'archived_at' => nil)
    end

    def list_epics(project_id)
      with_db { |db| db.execute('SELECT * FROM epics WHERE project_id = ? ORDER BY created_at', [project_id]) }
    end

    # The earliest-created epic (optionally excluding one) that still has at least
    # one pending story. Skips done/abandoned and archived epics. Returns nil when
    # nothing qualifies — the caller renders "All epics complete". `IS NOT ?` is
    # NULL-safe so a nil exclude_epic_id matches every epic.
    def next_pending_epic(project_id, exclude_epic_id: nil)
      with_db do |db|
        db.get_first_row(<<~SQL, [project_id, exclude_epic_id])
          SELECT e.* FROM epics e
          WHERE e.project_id = ?
            AND e.id IS NOT ?
            AND e.status NOT IN ('done', 'abandoned')
            AND e.archived_at IS NULL
            AND EXISTS (
              SELECT 1 FROM stories s
              WHERE s.epic_id = e.id AND s.status = 'pending'
            )
          ORDER BY e.created_at, e.rowid
          LIMIT 1
        SQL
      end
    end

    # ── Stories ────────────────────────────────────────────────────────────

    def create_story(epic_id:, slug:, title:, sequence: nil, intent: nil, born_from_discovery: nil)
      t = now
      id = uuid
      with_db do |db|
        # transaction(:immediate) makes the MAX(sequence)+1 read-then-write atomic;
        # concurrent imports cannot collide on UNIQUE(epic_id, sequence).
        db.transaction(:immediate) do
          seq = sequence || db.get_first_value('SELECT COALESCE(MAX(sequence), 0) + 1 FROM stories WHERE epic_id = ?', [epic_id])
          db.execute(
            'INSERT INTO stories (id, epic_id, sequence, slug, title, intent, status, born_from_discovery, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [id, epic_id, seq, slug, title, intent, 'pending', born_from_discovery, t, t]
          )
        end
        db.get_first_row('SELECT * FROM stories WHERE id = ?', [id])
      end
    end

    def find_story(epic_id, story_slug)
      with_db do |db|
        row = db.get_first_row('SELECT * FROM stories WHERE epic_id = ? AND slug = ?', [epic_id, story_slug])
        next nil unless row
        row.merge('wave_source' => row['wave_override'] ? 'user' : 'inferred')
      end
    end

    def find_story_by_id(story_id)
      with_db { |db| db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id]) }
    end

    def stories_for_epic(epic_id)
      with_db { |db| db.execute('SELECT * FROM stories WHERE epic_id = ? ORDER BY sequence', [epic_id]) }
    end

    def update_story_depends_on(story_id, deps_array)
      with_db do |db|
        db.transaction(:immediate) do
          t = now
          db.execute(
            'UPDATE stories SET depends_on = ?, updated_at = ? WHERE id = ?',
            [deps_array.empty? ? nil : JSON.dump(deps_array), t, story_id]
          )
        end
      end
    end

    def set_wave_override(story_id, wave_num, rationale = nil)
      with_db do |db|
        db.transaction(:immediate) do
          t = now
          stripped = rationale&.strip
          stored_rationale = (stripped.nil? || stripped.empty?) ? nil : stripped
          db.execute(
            'UPDATE stories SET wave_override = ?, wave_rationale = ?, updated_at = ? WHERE id = ?',
            [wave_num, stored_rationale, t, story_id]
          )
        end
      end
    end

    # Returns { wave_number => [slug, ...] } computed by topological layering.
    # Stories with unknown/missing deps are treated as if the dep doesn't exist.
    # Cycles are surfaced under the :cycle key rather than silently dropped.
    # Stories with wave_override set are moved to their override wave after topo sort.
    def wave_plan(epic_id)
      stories = stories_for_epic(epic_id)
      deps = stories.to_h { |s| [s['slug'], JSON.parse(s['depends_on'] || '[]')] }
      overrides = stories.filter_map { |s| [s['slug'], s['wave_override']] if s['wave_override'] }.to_h
      known = deps.keys.to_set
      dependents = Hash.new { |h, k| h[k] = [] }
      in_degree  = Hash.new(0)

      deps.each do |slug, prereqs|
        prereqs.each do |prereq|
          next unless known.include?(prereq)
          dependents[prereq] << slug
          in_degree[slug]    += 1
        end
      end

      waves = {}
      wave  = 1
      queue = known.select { |s| in_degree[s].zero? }.sort
      until queue.empty?
        waves[wave] = queue
        queue = queue.flat_map { |s| dependents[s] }
                     .select { |d| (in_degree[d] -= 1).zero? }
                     .sort
        wave += 1
      end

      assigned = waves.values.flatten.to_set
      cycled = known.reject { |s| assigned.include?(s) }
      waves[:cycle] = cycled.sort unless cycled.empty?

      unless overrides.empty?
        overrides.each do |slug, override_wave|
          waves.each { |wn, slugs| slugs.delete(slug) unless wn == :cycle }
          waves[override_wave] ||= []
          waves[override_wave] << slug unless waves[override_wave].include?(slug)
          waves[override_wave].sort!
        end
        waves.reject! { |k, v| k != :cycle && v.empty? }
      end

      waves
    end

    # Single-lane / legacy callers: the first in_progress story in the epic.
    # In a multi-lane epic this hides the other lanes' active work — prefer
    # in_progress_stories (all lanes) or in_progress_story_for (a named lane).
    def in_progress_story(epic_id)
      with_db { |db| db.get_first_row("SELECT * FROM stories WHERE epic_id = ? AND status = 'in_progress' ORDER BY sequence", [epic_id]) }
    end

    # Every in_progress story in the epic — one per active lane. Ordered so
    # unclaimed (legacy, claimed_by NULL) sorts first, then by lane token, so
    # the lane list renders stably.
    def in_progress_stories(epic_id)
      with_db do |db|
        db.execute(
          "SELECT * FROM stories WHERE epic_id = ? AND status = 'in_progress' " \
          "ORDER BY claimed_by IS NOT NULL, claimed_by, sequence",
          [epic_id]
        )
      end
    end

    # The in_progress story owned by this exact lane token (nil if that lane
    # holds nothing). Also the story-resolver rung-2 lookup.
    def in_progress_story_for(epic_id, token)
      with_db { |db| db.get_first_row("SELECT * FROM stories WHERE epic_id = ? AND status = 'in_progress' AND claimed_by = ?", [epic_id, token]) }
    end
    alias_method :story_in_progress_for_token, :in_progress_story_for

    # Rung 3: find a story (any status) whose claimed_by is the pre-claim placeholder.
    def story_with_pre_claim(epic_id, assigned_label)
      with_db { |db| db.get_first_row("SELECT * FROM stories WHERE epic_id = ? AND claimed_by = ?", [epic_id, assigned_label]) }
    end

    # Rung 5: find the sole unclaimed in_progress story (claimed_by IS NULL).
    def story_in_progress_unclaimed(epic_id)
      with_db { |db| db.get_first_row("SELECT * FROM stories WHERE epic_id = ? AND status = 'in_progress' AND claimed_by IS NULL", [epic_id]) }
    end

    # Write the "assigned:<lane>" pre-claim placeholder without changing status.
    def assign_story(story_id, lane)
      t = Time.now.utc.iso8601(6)
      with_db do |db|
        db.transaction(:immediate) do
          story = db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
          raise "Story not found: #{story_id}" unless story
          raise "Story is not pending (status: #{story['status']})" unless story['status'] == 'pending'
          db.execute('UPDATE stories SET claimed_by=?, updated_at=? WHERE id=?', ["assigned:#{lane}", t, story_id])
          db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
        end
      end
    end

    # Transactional claim — refuses if any story in epic is already in_progress.
    def start_story(story_id, claimed_by: nil)
      with_db do |db|
        db.transaction(:immediate) do
          story = db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
          raise "Story not found: #{story_id}" unless story
          raise "Story is not pending (status: #{story['status']})" unless story['status'] == 'pending'

          claim_row!(db, story_id, claimed_by)
        end
        db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
      end
    rescue SQLite3::ConstraintException
      raise "Another story in this epic is already in_progress. Use `tyrion status` to see which."
    end

    # Transactional claim of lowest-sequence pending story.
    def claim_next_story(epic_id, claimed_by: nil)
      with_db do |db|
        db.transaction(:immediate) do
          next_story = db.get_first_row(
            "SELECT * FROM stories WHERE epic_id = ? AND status = 'pending' ORDER BY sequence LIMIT 1",
            [epic_id]
          )
          raise "No pending stories in this epic" unless next_story

          claim_row!(db, next_story['id'], claimed_by)
          db.get_first_row('SELECT * FROM stories WHERE id = ?', [next_story['id']])
        end
      end
    rescue SQLite3::ConstraintException
      raise "Another story in this epic is already in_progress. Use `tyrion status` to see which."
    end

    def update_story(story_id, attrs)
      t = now
      set_clauses = attrs.keys.map { |k| "#{k} = ?" }
      set_clauses << 'updated_at = ?'
      binds = attrs.values + [t, story_id]
      with_db do |db|
        db.execute("UPDATE stories SET #{set_clauses.join(', ')} WHERE id = ?", binds)
        db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
      end
    end

    def add_note(story_id, kind, body, metadata: nil)
      t = now
      id = uuid
      with_db do |db|
        db.execute(
          'INSERT INTO story_notes (id, story_id, kind, body, metadata, created_at) VALUES (?, ?, ?, ?, ?, ?)',
          [id, story_id, kind, body, metadata, t]
        )
        db.execute('UPDATE stories SET last_note_at=?, updated_at=? WHERE id=?', [t, t, story_id])
        db.get_first_row('SELECT * FROM story_notes WHERE id = ?', [id])
      end
    end

    def notes_for_story(story_id, limit: 10)
      with_db do |db|
        db.execute(
          'SELECT * FROM story_notes WHERE story_id = ? ORDER BY created_at DESC LIMIT ?',
          [story_id, limit]
        )
      end
    end

    # Gate/commit notes for a story, oldest first — the traceability trail rendered
    # by the Gates: section in tyrion show / tyrion resume.
    def gate_notes_for_story(story_id)
      with_db do |db|
        db.execute(
          "SELECT * FROM story_notes WHERE story_id = ? AND kind IN ('gate','commit') ORDER BY created_at ASC",
          [story_id]
        )
      end
    end

    def done_stories_with_followup_notes(project_id)
      with_db do |db|
        db.execute(<<~SQL, [project_id])
          SELECT s.*, (
            SELECT body FROM story_notes
            WHERE story_id = s.id AND kind = 'followup' AND resolved_at IS NULL
            ORDER BY created_at DESC LIMIT 1
          ) AS followup_body
          FROM stories s
          JOIN epics e ON s.epic_id = e.id
          WHERE e.project_id = ?
            AND s.status = 'done'
            AND EXISTS (
              SELECT 1 FROM story_notes n
              WHERE n.story_id = s.id AND n.kind = 'followup' AND n.resolved_at IS NULL
            )
          ORDER BY s.completed_at DESC
        SQL
      end
    end

    def followup_notes(story_id)
      with_db do |db|
        db.execute(
          "SELECT * FROM story_notes WHERE story_id = ? AND kind = 'followup' ORDER BY created_at ASC",
          [story_id]
        )
      end
    end

    def resolve_followup_note(note_id)
      t = now
      with_db do |db|
        db.execute('UPDATE story_notes SET resolved_at = ? WHERE id = ?', [t, note_id])
      end
    end

    def update_context(story_id, text)
      t = now
      with_db do |db|
        db.execute('UPDATE stories SET current_context=?, updated_at=? WHERE id=?', [text, t, story_id])
      end
    end

    def update_next_action(story_id, text)
      t = now
      with_db do |db|
        db.execute('UPDATE stories SET next_action=?, updated_at=? WHERE id=?', [text, t, story_id])
      end
    end

    def reconcile_story(story_id, context:, next_action:, note:, checks: [])
      t = now
      with_db do |db|
        db.transaction(:immediate) do
          db.execute(
            'UPDATE stories SET current_context=?, next_action=?, last_note_at=?, updated_at=? WHERE id=?',
            [context, next_action, t, t, story_id]
          )
          db.execute(
            "INSERT INTO story_notes (id, story_id, kind, body, created_at) VALUES (?, ?, 'decision', ?, ?)",
            [uuid, story_id, note, t]
          )
          checks.each { |position, evidence| mark_criterion_met!(db, story_id, position, evidence, t) }
        end
      end
    end

    def block_story(story_id, blocked_on:, blocked_on_discovery: nil)
      with_db do |db|
        db.transaction(:immediate) do
          story = db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
          raise "Story not found: #{story_id}" unless story
          raise "Cannot block a done story" if story['status'] == 'done'

          t = now
          db.execute(
            'UPDATE stories SET status=?, blocked_on=?, blocked_on_discovery=?, claimed_by=NULL, claimed_at=NULL, updated_at=? WHERE id=?',
            ['blocked', blocked_on, blocked_on_discovery, t, story_id]
          )
          reopen_epic_if_done!(db, story['epic_id'])
        end
        db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
      end
    end

    def unblock_story(story_id)
      with_db do |db|
        db.transaction(:immediate) do
          story = db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
          raise "Story not found: #{story_id}" unless story
          raise "Story is not blocked (status: #{story['status']})" unless story['status'] == 'blocked'

          t = now
          db.execute(
            'UPDATE stories SET status=?, blocked_on=NULL, blocked_on_discovery=NULL, updated_at=? WHERE id=?',
            ['pending', t, story_id]
          )
        end
        db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
      end
    end

    def complete_story(story_id, summary, force: false)
      with_db do |db|
        unless force
          pending_count = db.get_first_value(
            "SELECT COUNT(*) FROM criteria WHERE story_id = ? AND status = 'pending'",
            [story_id]
          ).to_i
          raise "#{pending_count} criteria still pending. Use --force to override." if pending_count > 0
        end
        t = now
        db.execute(
          'UPDATE stories SET status=?, completed_at=?, claimed_by=NULL, claimed_at=NULL, updated_at=? WHERE id=?',
          ['done', t, t, story_id]
        )
        db.execute(
          "INSERT INTO story_notes (id, story_id, kind, body, created_at) VALUES (?, ?, 'handoff', ?, ?)",
          [uuid, story_id, summary, t]
        )
        db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
      end
    end

    def unstart_story(story_id, note: 'Story reset to pending via tyrion unstart')
      t = now
      with_db do |db|
        db.execute('UPDATE stories SET status=?, claimed_by=NULL, claimed_at=NULL, updated_at=? WHERE id=?', ['pending', t, story_id])
        db.execute(
          "INSERT INTO story_notes (id, story_id, kind, body, created_at) VALUES (?, ?, 'recovery', ?, ?)",
          [uuid, story_id, note, t]
        )
        db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
      end
    end

    def backfill_story(story_id, status, summary)
      t = now
      with_db do |db|
        db.execute(
          'UPDATE stories SET status=?, completed_at=?, started_at=COALESCE(started_at,?), updated_at=? WHERE id=?',
          [status, t, t, t, story_id]
        )
        db.execute(
          "INSERT INTO story_notes (id, story_id, kind, body, created_at) VALUES (?, ?, 'handoff', ?, ?)",
          [uuid, story_id, summary, t]
        )
        db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
      end
    end

    # ── Criteria ───────────────────────────────────────────────────────────

    def add_criteria(story_id, clauses)
      with_db do |db|
        max_pos = db.get_first_value('SELECT COALESCE(MAX(position), 0) FROM criteria WHERE story_id = ?', [story_id]).to_i
        added = []
        clauses.each_with_index do |clause, i|
          pos = max_pos + i + 1
          id = uuid
          t = now
          db.execute(
            'INSERT INTO criteria (id, story_id, position, keyword, semantic_kind, text, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [id, story_id, pos, clause[:keyword], clause[:semantic_kind], clause[:text], 'pending', t, t]
          )
          added << db.get_first_row('SELECT * FROM criteria WHERE id = ?', [id])
        end
        added
      end
    end

    def criteria_for_story(story_id)
      with_db { |db| db.execute('SELECT * FROM criteria WHERE story_id = ? ORDER BY position', [story_id]) }
    end

    def check_criterion(story_id, position, evidence)
      t = now
      with_db do |db|
        mark_criterion_met!(db, story_id, position.to_i, evidence, t)
        db.get_first_row('SELECT * FROM criteria WHERE story_id = ? AND position = ?', [story_id, position.to_i])
      end
    end

    def delete_pending_criteria(story_id)
      with_db do |db|
        db.execute("DELETE FROM criteria WHERE story_id = ? AND status = 'pending'", [story_id])
      end
    end

    def uncheck_criterion(story_id, position)
      t = now
      with_db do |db|
        db.execute(
          'UPDATE criteria SET status=?, evidence=NULL, checked_at=NULL, updated_at=? WHERE story_id=? AND position=?',
          ['pending', t, story_id, position.to_i]
        )
      end
    end

    # ── Discoveries ────────────────────────────────────────────────────────

    def create_discovery(project_id:, status:, epic_id: nil, story_id: nil,
                         question: nil, hypothesis: nil, exit_criteria: nil,
                         finding: nil, confidence: nil, recommendation: nil, git_context: nil)
      t = now
      with_db do |db|
        db.transaction(:immediate) do
          # Counter is global (no project_id filter) — disc-NNN is the table
          # primary key and must be globally unique, not just per-project.
          seq = db.get_first_value(
            'SELECT COALESCE(MAX(CAST(SUBSTR(id, 6) AS INTEGER)), 0) + 1 FROM discoveries WHERE id LIKE ?',
            ['disc-%']
          )
          id = format('disc-%03d', seq)
          db.execute(
            'INSERT INTO discoveries (id, project_id, epic_id, story_id, status, question, hypothesis, exit_criteria, finding, confidence, recommendation, git_context, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [id, project_id, epic_id, story_id, status, question, hypothesis, exit_criteria, finding, confidence, recommendation, git_context, t, t]
          )
          db.get_first_row('SELECT * FROM discoveries WHERE id = ?', [id])
        end
      end
    end

    def find_discovery(id)
      with_db { |db| db.get_first_row('SELECT * FROM discoveries WHERE id = ?', [id]) }
    end

    def list_discoveries(project_id:, status: nil)
      with_db do |db|
        if status
          db.execute(
            'SELECT * FROM discoveries WHERE project_id = ? AND status = ? ORDER BY created_at',
            [project_id, status]
          )
        else
          db.execute(
            'SELECT * FROM discoveries WHERE project_id = ? ORDER BY created_at',
            [project_id]
          )
        end
      end
    end

    def active_spike_for(project_id)
      with_db do |db|
        db.get_first_row(
          "SELECT * FROM discoveries WHERE project_id = ? AND status = 'active_spike' LIMIT 1",
          [project_id]
        )
      end
    end

    def close_spike(id, finding:, confidence:, recommendation:)
      with_db do |db|
        db.transaction(:immediate) do
          disc = db.get_first_row('SELECT * FROM discoveries WHERE id = ?', [id])
          raise "Discovery not found: #{id}" unless disc
          raise "Discovery is not an active spike (status: #{disc['status']})" unless disc['status'] == 'active_spike'

          t = now
          db.execute(
            "UPDATE discoveries SET status='findings_ready', finding=?, confidence=?, recommendation=?, updated_at=? WHERE id=?",
            [finding, confidence, recommendation, t, id]
          )
          db.get_first_row('SELECT * FROM discoveries WHERE id = ?', [id])
        end
      end
    end

    def promote_discovery_to_story(disc_id, epic_id:, slug:, title:, intent:)
      with_db do |db|
        db.transaction(:immediate) do
          disc = db.get_first_row('SELECT * FROM discoveries WHERE id = ?', [disc_id])
          raise "Discovery not found: #{disc_id}" unless disc
          raise "Discovery is not findings_ready (status: #{disc['status']})" unless disc['status'] == 'findings_ready'

          t       = now
          story_id = uuid
          seq     = db.get_first_value('SELECT COALESCE(MAX(sequence), 0) + 1 FROM stories WHERE epic_id = ?', [epic_id])

          db.execute(
            'INSERT INTO stories (id, epic_id, sequence, slug, title, intent, status, born_from_discovery, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [story_id, epic_id, seq, slug, title, intent, 'pending', disc_id, t, t]
          )
          db.execute(
            "UPDATE discoveries SET status='promoted_to_story', story_id=?, updated_at=? WHERE id=?",
            [story_id, t, disc_id]
          )
          db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
        end
      end
    end

    # ── Lessons ────────────────────────────────────────────────────────────

    def create_lesson(project_id:, trigger:, text:, epic_id: nil, story_id: nil, source: 'manual')
      t = now
      with_db do |db|
        db.transaction(:immediate) do
          # Counter is global (no project_id filter) — lesson-NNN is the table
          # primary key and must be globally unique, not just per-project.
          seq = db.get_first_value(
            'SELECT COALESCE(MAX(CAST(SUBSTR(id, 8) AS INTEGER)), 0) + 1 FROM lessons WHERE id LIKE ?',
            ['lesson-%']
          )
          id = format('lesson-%03d', seq)
          db.execute(
            'INSERT INTO lessons (id, project_id, epic_id, story_id, trigger, text, source, status, created_at, updated_at, origin_project_id, origin_epic_id, origin_story_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [id, project_id, epic_id, story_id, trigger, text, source, 'active', t, t, project_id, epic_id, story_id]
          )
          db.get_first_row('SELECT * FROM lessons WHERE id = ?', [id])
        end
      end
    end

    # epic_id: nil means "don't filter by epic" (returns lessons regardless of
    # their own epic_id, including project-wide rows) — not "match NULL". When
    # given, it's an exact match, not a project-wide-union of relevant lessons.
    def list_lessons(project_id:, trigger: nil, epic_id: nil, status: 'active')
      conditions = ['(lessons.project_id = ? OR lessons.project_id IS NULL)']
      params     = [project_id]
      { trigger:, epic_id:, status: }.compact.each do |col, val|
        conditions << "lessons.#{col} = ?"
        params << val
      end
      with_db do |db|
        db.execute(<<~SQL, params)
          SELECT lessons.*, epics.name AS epic_name
          FROM lessons
          LEFT JOIN epics ON lessons.epic_id = epics.id
          WHERE #{conditions.join(' AND ')}
          ORDER BY lessons.created_at
        SQL
      end
    end

    def find_lesson(id)
      with_db { |db| db.get_first_row('SELECT * FROM lessons WHERE id = ?', [id]) }
    end

    def promote_lesson(id)
      with_db do |db|
        db.transaction(:immediate) do
          lesson = db.get_first_row('SELECT * FROM lessons WHERE id = ?', [id])
          raise "Lesson not found: #{id}" unless lesson

          column = %w[story_id epic_id project_id].find { |c| lesson[c] }
          raise "Lesson #{id} is already global — nothing to promote to" unless column

          db.execute("UPDATE lessons SET #{column} = NULL, updated_at = ? WHERE id = ?", [now, id])
          db.get_first_row('SELECT * FROM lessons WHERE id = ?', [id])
        end
      end
    end

    # One-step jump straight back to the lesson's original creation-time scope
    # (via origin_project_id/origin_epic_id/origin_story_id), not a symmetric
    # one-rung undo of promote_lesson. Restoring from a wider level also
    # restores every more-specific field recorded below it in the same call.
    DEMOTE_RESTORE_COLUMNS = [%w[project_id epic_id story_id], %w[epic_id story_id], %w[story_id]].freeze

    def demote_lesson(id)
      with_db do |db|
        db.transaction(:immediate) do
          lesson = db.get_first_row('SELECT * FROM lessons WHERE id = ?', [id])
          raise "Lesson not found: #{id}" unless lesson

          cols = DEMOTE_RESTORE_COLUMNS.find { |head,| lesson[head].nil? && lesson["origin_#{head}"] }
          raise "Lesson #{id} is already at its original scope — nothing to demote" unless cols

          set   = cols.map { |c| "#{c} = ?" }.join(', ')
          binds = cols.map { |c| lesson["origin_#{c}"] } + [now, id]
          db.execute("UPDATE lessons SET #{set}, updated_at = ? WHERE id = ?", binds)

          db.get_first_row('SELECT * FROM lessons WHERE id = ?', [id])
        end
      end
    end

    def retire_lesson(id)
      with_db do |db|
        db.transaction(:immediate) do
          lesson = db.get_first_row('SELECT * FROM lessons WHERE id = ?', [id])
          raise "Lesson not found: #{id}" unless lesson

          db.execute("UPDATE lessons SET status='retired', updated_at=? WHERE id=?", [now, id])
          db.get_first_row('SELECT * FROM lessons WHERE id = ?', [id])
        end
      end
    end

    # ── Import helpers ─────────────────────────────────────────────────────

    def upsert_project(slug:, name:, repo_identity: nil, about_md: nil)
      existing = find_project_by_slug(slug)
      if existing
        attrs = {}
        attrs['name'] = name if name != existing['name']
        attrs['about_md'] = about_md if about_md && about_md != existing['about_md']
        attrs['primary_repo_identity'] = repo_identity if repo_identity && repo_identity != existing['primary_repo_identity']
        update_project(existing['id'], attrs) unless attrs.empty?
        find_project_by_slug(slug)
      else
        create_project(slug: slug, name: name, about_md: about_md, repo_identity: repo_identity)
      end
    end

    def upsert_epic(project_id:, slug:, name:, intent: nil, context_md: nil,
                    feature_source_path: nil, feature_source_hash: nil,
                    context_source_hash: nil)
      existing = find_epic(project_id, slug)
      if existing
        attrs = {}
        attrs['intent']               = intent if intent
        # Unconditional — nil must propagate so deleting the .context.md file clears the DB column.
        attrs['context_md']           = context_md
        attrs['context_source_hash']  = context_source_hash
        attrs['feature_source_path']  = feature_source_path if feature_source_path
        attrs['feature_source_hash']  = feature_source_hash if feature_source_hash
        update_epic(existing['id'], attrs)
        find_epic(project_id, slug)
      else
        create_epic(project_id: project_id, slug: slug, name: name, intent: intent,
                    context_md: context_md, feature_source_path: feature_source_path,
                    feature_source_hash: feature_source_hash,
                    context_source_hash: context_source_hash)
      end
    end

    def upsert_story(epic_id:, slug:, title:, sequence: nil, intent: nil)
      existing = find_story(epic_id, slug)
      if existing
        update_story(existing['id'], 'title' => title, 'intent' => intent) if title != existing['title'] || intent
        find_story(epic_id, slug)
      else
        create_story(epic_id: epic_id, slug: slug, title: title, sequence: sequence, intent: intent)
      end
    end

    # File hash for idempotent import
    def self.file_hash(path)
      Digest::SHA256.file(path).hexdigest
    end

    # Atomically upsert all stories + criteria for an epic in one transaction.
    # Returns [{slug:, criteria_count:}] for caller to print progress.
    # Sequence is assigned MAX+1 per insertion order (file order is preserved
    # because scenarios are passed in file order and INSERTs happen serially).
    # Policy: sequence = stable ledger order; re-importing does NOT renumber
    # existing stories — it appends new ones after the current max.
    def import_stories_for_epic(epic_id:, scenarios:)
      results = []
      t = now
      inserted_new = false
      with_db do |db|
        db.transaction(:immediate) do
          scenarios.each do |scenario|
            existing = db.get_first_row(
              'SELECT * FROM stories WHERE epic_id = ? AND slug = ?', [epic_id, scenario[:slug]]
            )
            story_id = if existing
              if scenario[:title] != existing['title'] || scenario[:intent]
                db.execute('UPDATE stories SET title = ?, intent = ?, updated_at = ? WHERE id = ?',
                           [scenario[:title], scenario[:intent] || existing['intent'], t, existing['id']])
              end
              existing['id']
            else
              sid = uuid
              seq = db.get_first_value('SELECT COALESCE(MAX(sequence), 0) + 1 FROM stories WHERE epic_id = ?', [epic_id])
              db.execute(
                'INSERT INTO stories (id, epic_id, sequence, slug, title, intent, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
                [sid, epic_id, seq, scenario[:slug], scenario[:title], scenario[:intent], 'pending', t, t]
              )
              inserted_new = true
              sid
            end

            unless scenario[:criteria].empty?
              db.execute("DELETE FROM criteria WHERE story_id = ? AND status = 'pending'", [story_id])
              max_pos = db.get_first_value('SELECT COALESCE(MAX(position), 0) FROM criteria WHERE story_id = ?', [story_id]).to_i
              scenario[:criteria].each_with_index do |clause, i|
                pos = max_pos + i + 1
                crit_id = uuid
                ct = now
                db.execute(
                  'INSERT INTO criteria (id, story_id, position, keyword, semantic_kind, text, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
                  [crit_id, story_id, pos, clause[:keyword], clause[:semantic_kind], clause[:text], 'pending', ct, ct]
                )
              end
            end

            results << { slug: scenario[:slug], criteria_count: scenario[:criteria].length }
          end
          reopen_epic_if_done!(db, epic_id) if inserted_new
        end
      end
      results
    end

    private

    # claimed_at tracks claimed_by: both set together, or both NULL for an unclaimed claim.
    def claim_row!(db, story_id, claimed_by)
      t = now
      claimed_at = claimed_by && t
      db.execute(
        'UPDATE stories SET status=?, started_at=?, last_note_at=?, claimed_by=?, claimed_at=?, updated_at=? WHERE id=?',
        ['in_progress', t, t, claimed_by, claimed_at, t, story_id]
      )
      epic_id = db.get_first_value('SELECT epic_id FROM stories WHERE id = ?', [story_id])
      reopen_epic_if_done!(db, epic_id)
    end

    # Honesty flip: a sealed epic that gains a non-done story is no longer done.
    def reopen_epic_if_done!(db, epic_id)
      return unless db.get_first_value('SELECT status FROM epics WHERE id = ?', [epic_id]) == 'done'
      db.execute('UPDATE epics SET status=?, updated_at=? WHERE id=?', ['active', now, epic_id])
    end

    # busy_timeout MUST be set before journal_mode=WAL — switching to WAL
    # acquires a brief exclusive lock; without a timeout already applied that
    # first PRAGMA can raise BusyException under concurrent writers.
    def with_db
      attempt = 0
      begin
        db = SQLite3::Database.new(@db_path)
        db.results_as_hash = true
        db.execute('PRAGMA busy_timeout=5000')
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('PRAGMA foreign_keys=ON')
        db.execute('PRAGMA synchronous=NORMAL')
        yield db
      rescue SQLite3::BusyException
        db&.close
        db = nil
        attempt += 1
        raise if attempt >= 5
        sleep(0.05 * (2**attempt))  # 100ms, 200ms, 400ms, 800ms
        retry
      ensure
        db&.close
      end
    end

    MIGRATIONS = [
      ['add_born_from_discovery_to_stories', lambda { |db|
        cols = db.execute('PRAGMA table_info(stories)').map { |r| r['name'] }
        db.execute('ALTER TABLE stories ADD COLUMN born_from_discovery TEXT REFERENCES discoveries(id) ON DELETE SET NULL') unless cols.include?('born_from_discovery')
      }],
      ['add_session_to_story_notes_kind_check', lambda { |db|
        # SQLite can't ALTER a CHECK constraint — recreate the table with the new allowed values
        existing = db.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name='story_notes'").first&.fetch('sql', '')
        next if existing.to_s.include?("'session'")
        db.execute_batch(<<~SQL)
          PRAGMA foreign_keys = OFF;
          ALTER TABLE story_notes RENAME TO story_notes_old;
          CREATE TABLE story_notes (
            id          TEXT PRIMARY KEY,
            story_id    TEXT NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
            kind        TEXT NOT NULL
                          CHECK(kind IN ('plan','progress','decision','blocker','test','handoff','recovery','session')),
            body        TEXT NOT NULL,
            metadata    TEXT,
            created_at  TEXT NOT NULL
          );
          INSERT INTO story_notes (id, story_id, kind, body, metadata, created_at) SELECT id, story_id, kind, body, metadata, created_at FROM story_notes_old;
          DROP TABLE story_notes_old;
          CREATE INDEX IF NOT EXISTS idx_notes_story_created ON story_notes(story_id, created_at);
          PRAGMA foreign_keys = ON;
        SQL
      }],
      ['add_blocked_on_to_stories', lambda { |db|
        cols = db.execute('PRAGMA table_info(stories)').map { |r| r['name'] }
        db.execute('ALTER TABLE stories ADD COLUMN blocked_on TEXT') unless cols.include?('blocked_on')
      }],
      ['add_blocked_on_discovery_to_stories', lambda { |db|
        cols = db.execute('PRAGMA table_info(stories)').map { |r| r['name'] }
        db.execute('ALTER TABLE stories ADD COLUMN blocked_on_discovery TEXT') unless cols.include?('blocked_on_discovery')
      }],
      ['add_followup_to_story_notes_kind_check', lambda { |db|
        existing = db.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name='story_notes'").first&.fetch('sql', '')
        next if existing.to_s.include?("'followup'")
        db.execute_batch(<<~SQL)
          PRAGMA foreign_keys = OFF;
          ALTER TABLE story_notes RENAME TO story_notes_old;
          CREATE TABLE story_notes (
            id          TEXT PRIMARY KEY,
            story_id    TEXT NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
            kind        TEXT NOT NULL
                          CHECK(kind IN ('plan','progress','decision','blocker','test','handoff','recovery','session','followup')),
            body        TEXT NOT NULL,
            metadata    TEXT,
            created_at  TEXT NOT NULL
          );
          INSERT INTO story_notes (id, story_id, kind, body, metadata, created_at) SELECT id, story_id, kind, body, metadata, created_at FROM story_notes_old;
          DROP TABLE story_notes_old;
          CREATE INDEX IF NOT EXISTS idx_notes_story_created ON story_notes(story_id, created_at);
          PRAGMA foreign_keys = ON;
        SQL
      }],
      # Convention: all future story_notes rebuilds must use explicit column lists
      # (not SELECT *) so adding columns does not break them.
      ['add_observation_to_story_notes_kind_check', lambda { |db|
        existing = db.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name='story_notes'").first&.fetch('sql', '')
        next if existing.to_s.include?("'observation'")
        db.execute_batch(<<~SQL)
          PRAGMA foreign_keys = OFF;
          ALTER TABLE story_notes RENAME TO story_notes_old;
          CREATE TABLE story_notes (
            id          TEXT PRIMARY KEY,
            story_id    TEXT NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
            kind        TEXT NOT NULL
                          CHECK(kind IN ('plan','progress','decision','blocker','test','handoff','recovery','session','followup','observation')),
            body        TEXT NOT NULL,
            metadata    TEXT,
            created_at  TEXT NOT NULL
          );
          INSERT INTO story_notes (id, story_id, kind, body, metadata, created_at) SELECT id, story_id, kind, body, metadata, created_at FROM story_notes_old;
          DROP TABLE story_notes_old;
          CREATE INDEX IF NOT EXISTS idx_notes_story_created ON story_notes(story_id, created_at);
          PRAGMA foreign_keys = ON;
        SQL
      }],
      ['add_resolved_at_to_story_notes', lambda { |db|
        cols = db.execute('PRAGMA table_info(story_notes)').map { |r| r['name'] }
        db.execute('ALTER TABLE story_notes ADD COLUMN resolved_at TEXT') unless cols.include?('resolved_at')
      }],
      ['parallel_story_execution_schema', lambda { |db|
        # Two partial uniques replace the old single in_progress-per-epic rule:
        #   per lane: at most one in_progress story per (epic, claimed_by) when non-NULL
        #   unclaimed: at most one in_progress story with NULL claimed_by per epic
        cols = db.execute('PRAGMA table_info(stories)').map { |r| r['name'] }
        db.execute('ALTER TABLE stories ADD COLUMN claimed_by TEXT') unless cols.include?('claimed_by')
        db.execute('ALTER TABLE stories ADD COLUMN claimed_at TEXT') unless cols.include?('claimed_at')
        db.execute('DROP INDEX IF EXISTS idx_one_in_progress_story_per_epic')
        db.execute(<<~SQL)
          CREATE UNIQUE INDEX IF NOT EXISTS idx_one_in_progress_story_per_lane
            ON stories(epic_id, claimed_by)
            WHERE status = 'in_progress' AND claimed_by IS NOT NULL
        SQL
        db.execute(<<~SQL)
          CREATE UNIQUE INDEX IF NOT EXISTS idx_one_unclaimed_in_progress_story_per_epic
            ON stories(epic_id)
            WHERE status = 'in_progress' AND claimed_by IS NULL
        SQL
      }],
      ['add_depends_on_to_stories', lambda { |db|
        cols = db.execute('PRAGMA table_info(stories)').map { |r| r['name'] }
        db.execute('ALTER TABLE stories ADD COLUMN depends_on TEXT') unless cols.include?('depends_on')
      }],
      ['add_wave_override_to_stories', lambda { |db|
        cols = db.execute('PRAGMA table_info(stories)').map { |r| r['name'] }
        db.execute('ALTER TABLE stories ADD COLUMN wave_override INTEGER') unless cols.include?('wave_override')
        db.execute('ALTER TABLE stories ADD COLUMN wave_rationale TEXT') unless cols.include?('wave_rationale')
      }],
      ['create_lessons_table', lambda { |db|
        db.execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS lessons (
            id          TEXT PRIMARY KEY,
            project_id  TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            epic_id     TEXT REFERENCES epics(id) ON DELETE SET NULL,
            story_id    TEXT REFERENCES stories(id) ON DELETE SET NULL,
            trigger     TEXT NOT NULL,
            text        TEXT NOT NULL,
            source      TEXT NOT NULL DEFAULT 'manual',
            status      TEXT NOT NULL CHECK(status IN ('active','retired')) DEFAULT 'active',
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL
          );
          CREATE INDEX IF NOT EXISTS idx_lessons_project_trigger ON lessons(project_id, trigger);
        SQL
      }],
      ['make_lessons_project_id_nullable', lambda { |db|
        # WARNING: any future migration adding columns to 'lessons' (e.g. 'add_lesson_origin_columns')
        # MUST run AFTER this one — this rebuild uses an explicit column list below and will silently
        # DROP any columns not listed there if it runs after they've been added.
        existing = db.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name='lessons'").first&.fetch('sql', '')
        next unless existing.to_s.match?(/project_id\s+TEXT\s+NOT\s+NULL/)

        db.execute_batch(<<~SQL)
          PRAGMA foreign_keys = OFF;
          ALTER TABLE lessons RENAME TO lessons_old;
          CREATE TABLE lessons (
            id          TEXT PRIMARY KEY,
            project_id  TEXT REFERENCES projects(id) ON DELETE CASCADE,
            epic_id     TEXT REFERENCES epics(id) ON DELETE SET NULL,
            story_id    TEXT REFERENCES stories(id) ON DELETE SET NULL,
            trigger     TEXT NOT NULL,
            text        TEXT NOT NULL,
            source      TEXT NOT NULL DEFAULT 'manual',
            status      TEXT NOT NULL CHECK(status IN ('active','retired')) DEFAULT 'active',
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL
          );
          INSERT INTO lessons (id, project_id, epic_id, story_id, trigger, text, source, status, created_at, updated_at)
            SELECT id, project_id, epic_id, story_id, trigger, text, source, status, created_at, updated_at
            FROM lessons_old;
          DROP TABLE lessons_old;
          CREATE INDEX IF NOT EXISTS idx_lessons_project_trigger ON lessons(project_id, trigger);
          PRAGMA foreign_keys = ON;
        SQL
      }],
      ['add_lesson_origin_columns', lambda { |db|
        # MUST run after 'make_lessons_project_id_nullable' in the MIGRATIONS array. That migration's
        # rebuild uses an explicit column list (INSERT INTO lessons (id, project_id, ...) SELECT ...) —
        # if this migration ran first, the rebuild would silently DROP these columns and any data in
        # them. This is a hard ordering requirement, not a readability preference.
        cols = db.execute('PRAGMA table_info(lessons)').map { |r| r['name'] }
        db.execute('ALTER TABLE lessons ADD COLUMN origin_project_id TEXT REFERENCES projects(id) ON DELETE SET NULL') unless cols.include?('origin_project_id')
        db.execute('ALTER TABLE lessons ADD COLUMN origin_epic_id TEXT REFERENCES epics(id) ON DELETE SET NULL') unless cols.include?('origin_epic_id')
        db.execute('ALTER TABLE lessons ADD COLUMN origin_story_id TEXT REFERENCES stories(id) ON DELETE SET NULL') unless cols.include?('origin_story_id')
      }],
      ['add_archived_at_to_epics', lambda { |db|
        cols = db.execute('PRAGMA table_info(epics)').map { |r| r['name'] }
        db.execute('ALTER TABLE epics ADD COLUMN archived_at TEXT') unless cols.include?('archived_at')
      }],
      ['add_gate_and_commit_to_story_notes_kind_check', lambda { |db|
        # Runs after add_resolved_at_to_story_notes, so the live table has resolved_at —
        # the explicit column list below MUST include it or the rebuild would drop it.
        existing = db.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name='story_notes'").first&.fetch('sql', '')
        next if existing.to_s.include?("'gate'")
        db.execute_batch(<<~SQL)
          PRAGMA foreign_keys = OFF;
          ALTER TABLE story_notes RENAME TO story_notes_old;
          CREATE TABLE story_notes (
            id          TEXT PRIMARY KEY,
            story_id    TEXT NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
            kind        TEXT NOT NULL
                          CHECK(kind IN ('plan','progress','decision','blocker','test','handoff','recovery','session','followup','observation','gate','commit')),
            body        TEXT NOT NULL,
            metadata    TEXT,
            created_at  TEXT NOT NULL,
            resolved_at TEXT
          );
          INSERT INTO story_notes (id, story_id, kind, body, metadata, created_at, resolved_at) SELECT id, story_id, kind, body, metadata, created_at, resolved_at FROM story_notes_old;
          DROP TABLE story_notes_old;
          CREATE INDEX IF NOT EXISTS idx_notes_story_created ON story_notes(story_id, created_at);
          PRAGMA foreign_keys = ON;
        SQL
      }]
    ].freeze

    def mark_criterion_met!(db, story_id, position, evidence, t)
      criterion = db.get_first_row('SELECT * FROM criteria WHERE story_id = ? AND position = ?', [story_id, position.to_i])
      raise "Criterion #{position} not found" unless criterion
      db.execute(
        'UPDATE criteria SET status=?, evidence=?, checked_at=?, updated_at=? WHERE story_id=? AND position=?',
        ['met', evidence, t, t, story_id, position.to_i]
      )
    end

    def setup_db
      with_db do |db|
        DDL.split(';').each do |stmt|
          s = stmt.strip
          db.execute(s) unless s.empty?
        end
        MIGRATIONS.each { |_name, fn| fn.call(db) }
      end
    end

    def now  = Time.now.utc.iso8601(6)
    def uuid = SecureRandom.uuid
  end
end
