# frozen_string_literal: true

require 'sqlite3'
require 'securerandom'
require 'fileutils'
require 'time'
require 'digest'

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
        created_at           TEXT NOT NULL,
        updated_at           TEXT NOT NULL,
        UNIQUE(epic_id, slug),
        UNIQUE(epic_id, sequence)
      );

      CREATE INDEX IF NOT EXISTS idx_stories_epic_status ON stories(epic_id, status);

      CREATE UNIQUE INDEX IF NOT EXISTS idx_one_in_progress_story_per_epic
        ON stories(epic_id)
        WHERE status = 'in_progress';

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
                      CHECK(kind IN ('plan','progress','decision','blocker','test','handoff','recovery','session','followup')),
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

    def find_epic_by_id(epic_id)
      with_db { |db| db.get_first_row('SELECT * FROM epics WHERE id = ?', [epic_id]) }
    end

    def list_epics(project_id)
      with_db { |db| db.execute('SELECT * FROM epics WHERE project_id = ? ORDER BY created_at', [project_id]) }
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
      with_db { |db| db.get_first_row('SELECT * FROM stories WHERE epic_id = ? AND slug = ?', [epic_id, story_slug]) }
    end

    def find_story_by_id(story_id)
      with_db { |db| db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id]) }
    end

    def stories_for_epic(epic_id)
      with_db { |db| db.execute('SELECT * FROM stories WHERE epic_id = ? ORDER BY sequence', [epic_id]) }
    end

    def in_progress_story(epic_id)
      with_db { |db| db.get_first_row("SELECT * FROM stories WHERE epic_id = ? AND status = 'in_progress'", [epic_id]) }
    end

    # Transactional claim — refuses if any story in epic is already in_progress.
    def start_story(story_id)
      with_db do |db|
        db.transaction(:immediate) do
          story = db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
          raise "Story not found: #{story_id}" unless story
          raise "Story is not pending (status: #{story['status']})" unless story['status'] == 'pending'

          t = now
          db.execute(
            'UPDATE stories SET status=?, started_at=?, last_note_at=?, updated_at=? WHERE id=?',
            ['in_progress', t, t, t, story_id]
          )
        end
        db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
      end
    rescue SQLite3::ConstraintException
      raise "Another story in this epic is already in_progress. Use `tyrion status` to see which."
    end

    # Transactional claim of lowest-sequence pending story.
    def claim_next_story(epic_id)
      with_db do |db|
        db.transaction(:immediate) do
          next_story = db.get_first_row(
            "SELECT * FROM stories WHERE epic_id = ? AND status = 'pending' ORDER BY sequence LIMIT 1",
            [epic_id]
          )
          raise "No pending stories in this epic" unless next_story

          t = now
          db.execute(
            'UPDATE stories SET status=?, started_at=?, last_note_at=?, updated_at=? WHERE id=?',
            ['in_progress', t, t, t, next_story['id']]
          )
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

    def done_stories_with_followup_notes(project_id)
      with_db do |db|
        db.execute(<<~SQL, [project_id])
          SELECT s.*, (
            SELECT body FROM story_notes
            WHERE story_id = s.id AND kind = 'followup'
            ORDER BY created_at DESC LIMIT 1
          ) AS followup_body
          FROM stories s
          JOIN epics e ON s.epic_id = e.id
          WHERE e.project_id = ?
            AND s.status = 'done'
            AND EXISTS (
              SELECT 1 FROM story_notes n
              WHERE n.story_id = s.id AND n.kind = 'followup'
            )
          ORDER BY s.completed_at DESC
        SQL
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

    def block_story(story_id, blocked_on:, blocked_on_discovery: nil)
      with_db do |db|
        db.transaction(:immediate) do
          story = db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
          raise "Story not found: #{story_id}" unless story
          raise "Cannot block a done story" if story['status'] == 'done'

          t = now
          db.execute(
            'UPDATE stories SET status=?, blocked_on=?, blocked_on_discovery=?, updated_at=? WHERE id=?',
            ['blocked', blocked_on, blocked_on_discovery, t, story_id]
          )
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
          'UPDATE stories SET status=?, completed_at=?, updated_at=? WHERE id=?',
          ['done', t, t, story_id]
        )
        db.execute(
          "INSERT INTO story_notes (id, story_id, kind, body, created_at) VALUES (?, ?, 'handoff', ?, ?)",
          [uuid, story_id, summary, t]
        )
        db.get_first_row('SELECT * FROM stories WHERE id = ?', [story_id])
      end
    end

    def unstart_story(story_id)
      t = now
      with_db do |db|
        db.execute('UPDATE stories SET status=?, updated_at=? WHERE id=?', ['pending', t, story_id])
        db.execute(
          "INSERT INTO story_notes (id, story_id, kind, body, created_at) VALUES (?, ?, 'recovery', ?, ?)",
          [uuid, story_id, 'Story reset to pending via tyrion unstart', t]
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
        criterion = db.get_first_row('SELECT * FROM criteria WHERE story_id = ? AND position = ?', [story_id, position.to_i])
        raise "Criterion #{position} not found" unless criterion

        db.execute(
          'UPDATE criteria SET status=?, evidence=?, checked_at=?, updated_at=? WHERE story_id=? AND position=?',
          ['met', evidence, t, t, story_id, position.to_i]
        )
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
                    feature_source_path: nil, feature_source_hash: nil)
      existing = find_epic(project_id, slug)
      if existing
        attrs = {}
        attrs['intent']               = intent if intent
        attrs['context_md']           = context_md if context_md
        attrs['feature_source_path']  = feature_source_path if feature_source_path
        attrs['feature_source_hash']  = feature_source_hash if feature_source_hash
        update_epic(existing['id'], attrs) unless attrs.empty?
        find_epic(project_id, slug)
      else
        create_epic(project_id: project_id, slug: slug, name: name, intent: intent,
                    context_md: context_md, feature_source_path: feature_source_path,
                    feature_source_hash: feature_source_hash)
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
        end
      end
      results
    end

    private

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
      }]
    ].freeze

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
