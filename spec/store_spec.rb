# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'

RSpec.describe Tyrion::Store do
  let(:tmpdir) { Dir.mktmpdir('tyrion-store-spec-') }
  let(:store)  { Tyrion::Store.new(db_path: File.join(tmpdir, 'test.db')) }

  after { FileUtils.rm_rf(tmpdir) }

  # ── Helpers ──────────────────────────────────────────────────────────────

  def make_project(slug: 'proj', name: 'My Project')
    store.create_project(slug: slug, name: name)
  end

  def make_epic(project_id:, slug: 'epic-one', name: 'Epic One')
    store.create_epic(project_id: project_id, slug: slug, name: name)
  end

  def make_story(epic_id:, slug: 'story-one', title: 'Story One')
    store.create_story(epic_id: epic_id, slug: slug, title: title)
  end

  def gwt_clauses
    [
      { keyword: 'Given', semantic_kind: 'given', text: 'a precondition' },
      { keyword: 'When',  semantic_kind: 'when',  text: 'an action occurs' },
      { keyword: 'Then',  semantic_kind: 'then',  text: 'an outcome is observed' }
    ]
  end

  def default_story
    proj = make_project
    epic = make_epic(project_id: proj['id'])
    make_story(epic_id: epic['id'])
  end

  def default_story_with_criteria
    story = default_story
    store.add_criteria(story['id'], gwt_clauses)
    story
  end

  def default_project
    make_project
  end

  def make_discovery(project_id:, status: 'mark', question: 'test question', **opts)
    store.create_discovery(project_id: project_id, status: status, question: question, **opts)
  end

  def make_lesson(project_id:, trigger: 'uat', text: 'lesson text', **opts)
    store.create_lesson(project_id: project_id, trigger: trigger, text: text, **opts)
  end

  # ── create_project ────────────────────────────────────────────────────────

  describe '#create_project' do
    it 'returns a hash with id, slug, and name' do
      proj = make_project(slug: 'my-proj', name: 'My Project')
      expect(proj).to be_a(Hash)
      expect(proj['id']).not_to be_nil
      expect(proj['slug']).to eq 'my-proj'
      expect(proj['name']).to eq 'My Project'
    end

    it 'persists to the DB' do
      proj = make_project(slug: 'persisted', name: 'Persisted Project')
      found = store.find_project_by_slug('persisted')
      expect(found).not_to be_nil
      expect(found['id']).to eq proj['id']
      expect(found['name']).to eq 'Persisted Project'
    end

    it 'sets status to active' do
      proj = make_project
      expect(proj['status']).to eq 'active'
    end

    it 'assigns a unique id per project' do
      p1 = make_project(slug: 'p1', name: 'P1')
      p2 = make_project(slug: 'p2', name: 'P2')
      expect(p1['id']).not_to eq p2['id']
    end
  end

  # ── create_epic ───────────────────────────────────────────────────────────

  describe '#create_epic' do
    it 'returns a hash with id and project_id' do
      proj = make_project
      epic = make_epic(project_id: proj['id'])
      expect(epic['id']).not_to be_nil
      expect(epic['project_id']).to eq proj['id']
      expect(epic['slug']).to eq 'epic-one'
      expect(epic['name']).to eq 'Epic One'
    end

    it 'sets status to active' do
      proj = make_project
      epic = make_epic(project_id: proj['id'])
      expect(epic['status']).to eq 'active'
    end
  end

  # ── create_story ──────────────────────────────────────────────────────────

  describe '#create_story' do
    it 'returns a hash with id and epic_id' do
      proj  = make_project
      epic  = make_epic(project_id: proj['id'])
      story = make_story(epic_id: epic['id'])
      expect(story['id']).not_to be_nil
      expect(story['epic_id']).to eq epic['id']
      expect(story['slug']).to eq 'story-one'
      expect(story['title']).to eq 'Story One'
    end

    it 'sets status to pending' do
      expect(default_story['status']).to eq 'pending'
    end

    it 'auto-assigns sequence numbers' do
      proj = make_project
      epic = make_epic(project_id: proj['id'])
      s1 = make_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      s2 = make_story(epic_id: epic['id'], slug: 's2', title: 'S2')
      expect(s1['sequence']).to eq 1
      expect(s2['sequence']).to eq 2
    end
  end

  # ── add_criteria ──────────────────────────────────────────────────────────

  describe '#add_criteria' do
    it 'returns an array of criteria' do
      added = store.add_criteria(default_story['id'], gwt_clauses)
      expect(added).to be_a(Array)
      expect(added.length).to eq 3
    end

    it 'assigns positions sequentially' do
      added = store.add_criteria(default_story['id'], gwt_clauses)
      expect(added.map { |c| c['position'] }).to eq [1, 2, 3]
    end

    it 'sets status to pending for all criteria' do
      added = store.add_criteria(default_story['id'], gwt_clauses)
      added.each { |c| expect(c['status']).to eq 'pending' }
    end

    it 'stores keyword and text for each clause' do
      added = store.add_criteria(default_story['id'], gwt_clauses)
      expect(added[0]['keyword']).to eq 'Given'
      expect(added[0]['text']).to eq 'a precondition'
      expect(added[1]['keyword']).to eq 'When'
      expect(added[2]['keyword']).to eq 'Then'
    end
  end

  # ── criteria_for_story ────────────────────────────────────────────────────

  describe '#criteria_for_story' do
    it 'returns all criteria in position order' do
      story    = default_story_with_criteria
      criteria = store.criteria_for_story(story['id'])
      expect(criteria.length).to eq 3
      expect(criteria.map { |c| c['position'] }).to eq [1, 2, 3]
    end

    it 'returns an empty array when there are no criteria' do
      expect(store.criteria_for_story(default_story['id'])).to eq []
    end

    it 'preserves the original texts' do
      story = default_story_with_criteria
      texts = store.criteria_for_story(story['id']).map { |c| c['text'] }
      expect(texts).to eq ['a precondition', 'an action occurs', 'an outcome is observed']
    end
  end

  # ── check_criterion ───────────────────────────────────────────────────────

  describe '#check_criterion' do
    it 'marks the criterion as met with evidence' do
      story = default_story_with_criteria
      store.check_criterion(story['id'], 1, 'precondition verified')
      criteria = store.criteria_for_story(story['id'])
      expect(criteria[0]['status']).to eq 'met'
      expect(criteria[0]['evidence']).to eq 'precondition verified'
    end

    it 'does not affect other criteria' do
      story = default_story_with_criteria
      store.check_criterion(story['id'], 1, 'evidence')
      criteria = store.criteria_for_story(story['id'])
      expect(criteria[1]['status']).to eq 'pending'
      expect(criteria[2]['status']).to eq 'pending'
    end

    it 'returns the updated row' do
      story  = default_story_with_criteria
      result = store.check_criterion(story['id'], 2, 'action confirmed')
      expect(result['status']).to eq 'met'
      expect(result['evidence']).to eq 'action confirmed'
      expect(result['checked_at']).not_to be_nil
    end

    it 'raises on a missing position' do
      story = default_story_with_criteria
      expect { store.check_criterion(story['id'], 99, 'no such criterion') }.to raise_error(RuntimeError)
    end
  end

  # ── delete_pending_criteria ───────────────────────────────────────────────

  describe '#delete_pending_criteria' do
    it 'removes only pending criteria' do
      story = default_story_with_criteria
      store.check_criterion(story['id'], 1, 'met evidence')
      store.delete_pending_criteria(story['id'])
      remaining = store.criteria_for_story(story['id'])
      expect(remaining.length).to eq 1
      expect(remaining[0]['status']).to eq 'met'
      expect(remaining[0]['position']).to eq 1
    end

    it 'preserves the met criterion' do
      story = default_story
      store.add_criteria(story['id'], [
        { keyword: 'Given', semantic_kind: 'given', text: 'met condition' },
        { keyword: 'Then',  semantic_kind: 'then',  text: 'pending condition' }
      ])
      store.check_criterion(story['id'], 1, 'evidence')
      store.delete_pending_criteria(story['id'])
      remaining = store.criteria_for_story(story['id'])
      expect(remaining.length).to eq 1
      expect(remaining[0]['text']).to eq 'met condition'
      expect(remaining[0]['status']).to eq 'met'
    end

    it 'removes all criteria when none are met' do
      story = default_story_with_criteria
      store.delete_pending_criteria(story['id'])
      expect(store.criteria_for_story(story['id'])).to eq []
    end

    it 'is a no-op when all criteria are already met' do
      story = default_story_with_criteria
      store.check_criterion(story['id'], 1, 'e1')
      store.check_criterion(story['id'], 2, 'e2')
      store.check_criterion(story['id'], 3, 'e3')
      store.delete_pending_criteria(story['id'])
      expect(store.criteria_for_story(story['id']).length).to eq 3
    end
  end

  # ── Discoveries ───────────────────────────────────────────────────────────

  describe '#create_discovery' do
    it 'returns a hash with id and status' do
      disc = make_discovery(project_id: default_project['id'])
      expect(disc).to be_a(Hash)
      expect(disc['id']).not_to be_nil
      expect(disc['status']).to eq 'mark'
      expect(disc['created_at']).not_to be_nil
    end

    it 'round-trips all optional fields' do
      proj  = default_project
      epic  = make_epic(project_id: proj['id'])
      story = make_story(epic_id: epic['id'])

      disc = store.create_discovery(
        project_id:     proj['id'],
        epic_id:        epic['id'],
        story_id:       story['id'],
        status:         'active_spike',
        question:       'Will it blend?',
        hypothesis:     'Yes, it will blend.',
        exit_criteria:  'Blending observed once.',
        finding:        'It blended.',
        confidence:     'high',
        recommendation: 'Ship it.',
        git_context:    'abc1234'
      )

      found = store.find_discovery(disc['id'])
      expect(found).not_to be_nil
      expect(found['id']).to eq disc['id']
      expect(found['project_id']).to eq proj['id']
      expect(found['epic_id']).to eq epic['id']
      expect(found['story_id']).to eq story['id']
      expect(found['status']).to eq 'active_spike'
      expect(found['question']).to eq 'Will it blend?'
      expect(found['hypothesis']).to eq 'Yes, it will blend.'
      expect(found['exit_criteria']).to eq 'Blending observed once.'
      expect(found['finding']).to eq 'It blended.'
      expect(found['confidence']).to eq 'high'
      expect(found['recommendation']).to eq 'Ship it.'
      expect(found['git_context']).to eq 'abc1234'
      expect(found['created_at']).not_to be_nil
      expect(found['updated_at']).not_to be_nil
    end
  end

  describe '#list_discoveries' do
    it 'returns all discoveries for a project' do
      pid = default_project['id']
      make_discovery(project_id: pid, status: 'mark',         question: 'q1')
      make_discovery(project_id: pid, status: 'active_spike', question: 'q2')
      make_discovery(project_id: pid, status: 'deferred',     question: 'q3')
      results = store.list_discoveries(project_id: pid)
      expect(results.length).to eq 3
    end

    it 'filters by status when provided' do
      pid = default_project['id']
      make_discovery(project_id: pid, status: 'mark',         question: 'q1')
      make_discovery(project_id: pid, status: 'active_spike', question: 'q2')
      make_discovery(project_id: pid, status: 'deferred',     question: 'q3')
      results = store.list_discoveries(project_id: pid, status: 'active_spike')
      expect(results.length).to eq 1
      expect(results[0]['status']).to eq 'active_spike'
    end

    it 'returns empty array for an unknown project' do
      results = store.list_discoveries(project_id: 'nonexistent-id-00000')
      expect(results).to eq []
    end
  end

  describe 'MIGRATIONS — create_lessons_table' do
    def lessons_columns
      store.send(:with_db) { |db| db.execute('PRAGMA table_info(lessons)').map { |r| r['name'] } }
    end

    it 'lessons table exists with the expected columns after setup_db' do
      expect(lessons_columns).to match_array(
        %w[id project_id epic_id story_id trigger text source status created_at updated_at origin_project_id origin_epic_id origin_story_id]
      )
    end

    it 'migration is idempotent — setup_db can run twice without error' do
      expect { store.send(:setup_db) }.not_to raise_error
      expect(lessons_columns).to match_array(
        %w[id project_id epic_id story_id trigger text source status created_at updated_at origin_project_id origin_epic_id origin_story_id]
      )
    end
  end

  describe 'MIGRATIONS — make_lessons_project_id_nullable' do
    def build_legacy_db(path)
      db = SQLite3::Database.new(path)
      db.results_as_hash = true
      Tyrion::Store::DDL.split(';').each do |stmt|
        s = stmt.strip
        db.execute(s) unless s.empty?
      end
      Tyrion::Store::MIGRATIONS.each do |name, fn|
        break if name == 'make_lessons_project_id_nullable'
        fn.call(db)
      end
      db
    end

    it 'preserves an existing lesson row verbatim across the migration' do
      path = File.join(tmpdir, 'legacy.db')
      legacy_db = build_legacy_db(path)
      pid = SecureRandom.uuid
      legacy_db.execute(
        'INSERT INTO projects (id, slug, name, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
        [pid, 'legacy-proj', 'Legacy Project', 'active', '2026-01-01T00:00:00.000000Z', '2026-01-01T00:00:00.000000Z']
      )
      legacy_db.execute(
        'INSERT INTO lessons (id, project_id, epic_id, story_id, trigger, text, source, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        ['lesson-001', pid, nil, nil, 'uat', 'legacy lesson text', 'manual', 'active', '2026-01-01T00:00:00.000000Z', '2026-01-01T00:00:00.000000Z']
      )
      legacy_db.close

      migrated_store = Tyrion::Store.new(db_path: path) # runs setup_db -> runs the new migration this time
      row = migrated_store.send(:with_db) { |db| db.get_first_row('SELECT * FROM lessons WHERE id = ?', ['lesson-001']) }

      expect(row).to include(
        'id' => 'lesson-001', 'project_id' => pid, 'epic_id' => nil, 'story_id' => nil,
        'trigger' => 'uat', 'text' => 'legacy lesson text', 'source' => 'manual', 'status' => 'active',
        'created_at' => '2026-01-01T00:00:00.000000Z', 'updated_at' => '2026-01-01T00:00:00.000000Z'
      )
    end

    it 'makes project_id nullable — inserting a row with project_id: nil succeeds afterward' do
      # use `store` (already fully migrated via let) and insert raw SQL with project_id nil
      expect {
        store.send(:with_db) do |db|
          db.execute(
            'INSERT INTO lessons (id, project_id, epic_id, story_id, trigger, text, source, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            ['lesson-999', nil, nil, nil, 'uat', 'global lesson', 'manual', 'active', store.send(:now), store.send(:now)]
          )
        end
      }.not_to raise_error
    end

    it 'is idempotent — running the migration a second time is a no-op' do
      expect { store.send(:setup_db) }.not_to raise_error
      cols = store.send(:with_db) { |db| db.execute('PRAGMA table_info(lessons)').map { |r| r['name'] } }
      expect(cols).to match_array(%w[id project_id epic_id story_id trigger text source status created_at updated_at origin_project_id origin_epic_id origin_story_id])
    end

    it 'runs correctly against a brand-new database (guard fires immediately after create_lessons_table)' do
      # `store` itself is a brand-new db — if project_id were still NOT NULL this insert would raise
      expect {
        store.send(:with_db) do |db|
          db.execute(
            'INSERT INTO lessons (id, project_id, epic_id, story_id, trigger, text, source, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            ['lesson-998', nil, nil, nil, 'uat', 'brand new global lesson', 'manual', 'active', store.send(:now), store.send(:now)]
          )
        end
      }.not_to raise_error
    end
  end

  describe 'MIGRATIONS — add_lesson_origin_columns' do
    def lessons_columns
      store.send(:with_db) { |db| db.execute('PRAGMA table_info(lessons)').map { |r| r['name'] } }
    end

    it 'lessons has origin_project_id, origin_epic_id, origin_story_id columns after setup_db' do
      expect(lessons_columns).to include('origin_project_id', 'origin_epic_id', 'origin_story_id')
    end

    it 'migration is idempotent — setup_db can run twice without error' do
      expect { store.send(:setup_db) }.not_to raise_error
      expect(lessons_columns).to include('origin_project_id', 'origin_epic_id', 'origin_story_id')
    end

    it 'a pre-existing lesson row (created before origin_* existed) reads back NULL for all three origin columns' do
      pid = default_project['id']
      t = store.send(:now)
      store.send(:with_db) do |db|
        db.execute(
          'INSERT INTO lessons (id, project_id, epic_id, story_id, trigger, text, source, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          ['lesson-900', pid, nil, nil, 'uat', 'pre-migration lesson', 'manual', 'active', t, t]
        )
      end

      row = store.send(:with_db) { |db| db.get_first_row('SELECT * FROM lessons WHERE id = ?', ['lesson-900']) }
      expect(row['origin_project_id']).to be_nil
      expect(row['origin_epic_id']).to be_nil
      expect(row['origin_story_id']).to be_nil
    end
  end

  describe '#create_lesson' do
    it 'assigns sequential lesson-NNN ids' do
      pid = default_project['id']
      first  = make_lesson(project_id: pid)
      second = make_lesson(project_id: pid)
      expect(first['id']).to match(/\Alesson-\d{3}\z/)
      expect(second['id']).to match(/\Alesson-\d{3}\z/)
      expect(second['id']).not_to eq first['id']
    end

    it 'assigns ids from a global counter, not a per-project one' do
      proj_a = default_project['id']
      proj_b = make_project(slug: 'other-proj')['id']
      first  = make_lesson(project_id: proj_a)
      second = make_lesson(project_id: proj_b)
      expect(second['id']).not_to eq first['id']
    end

    it 'defaults status to active' do
      lesson = make_lesson(project_id: default_project['id'])
      expect(lesson['status']).to eq 'active'
    end

    it 'returns the inserted row' do
      lesson = make_lesson(project_id: default_project['id'], trigger: 'uat', text: 'lesson text')
      expect(lesson).to be_a(Hash)
      expect(lesson['trigger']).to eq 'uat'
      expect(lesson['text']).to eq 'lesson text'
      expect(lesson['created_at']).not_to be_nil
      expect(lesson['updated_at']).not_to be_nil
    end

    it 'respects passed source, epic_id, and story_id' do
      proj  = default_project
      epic  = make_epic(project_id: proj['id'])
      story = make_story(epic_id: epic['id'])

      lesson = make_lesson(
        project_id: proj['id'],
        epic_id:    epic['id'],
        story_id:   story['id'],
        source:     'auto-extracted'
      )

      expect(lesson['epic_id']).to eq epic['id']
      expect(lesson['story_id']).to eq story['id']
      expect(lesson['source']).to eq 'auto-extracted'
    end

    it 'defaults source to manual when not passed' do
      lesson = make_lesson(project_id: default_project['id'])
      expect(lesson['source']).to eq 'manual'
    end

    it 'captures origin_project_id, origin_epic_id, origin_story_id from the project_id/epic_id/story_id passed in' do
      proj  = default_project
      epic  = make_epic(project_id: proj['id'])
      story = make_story(epic_id: epic['id'])

      lesson = make_lesson(
        project_id: proj['id'],
        epic_id:    epic['id'],
        story_id:   story['id']
      )

      expect(lesson['origin_project_id']).to eq proj['id']
      expect(lesson['origin_epic_id']).to eq epic['id']
      expect(lesson['origin_story_id']).to eq story['id']
    end
  end

  describe '#list_lessons' do
    it 'returns only active lessons scoped to that project' do
      pid       = default_project['id']
      other_pid = make_project(slug: 'other-proj')['id']

      make_lesson(project_id: pid)
      make_lesson(project_id: other_pid)

      results = store.list_lessons(project_id: pid)
      expect(results.length).to eq 1
      expect(results[0]['project_id']).to eq pid
    end

    it 'filters by trigger when provided' do
      pid = default_project['id']
      make_lesson(project_id: pid, trigger: 'uat')
      make_lesson(project_id: pid, trigger: 'commit')

      results = store.list_lessons(project_id: pid, trigger: 'uat')
      expect(results.length).to eq 1
      expect(results[0]['trigger']).to eq 'uat'
    end

    it 'returns lessons for any trigger when trigger is nil' do
      pid = default_project['id']
      make_lesson(project_id: pid, trigger: 'uat')
      make_lesson(project_id: pid, trigger: 'commit')

      results = store.list_lessons(project_id: pid)
      expect(results.length).to eq 2
    end

    it 'filters by epic_id as an exact match when provided' do
      proj  = default_project
      epic  = make_epic(project_id: proj['id'])

      make_lesson(project_id: proj['id'], epic_id: epic['id'])
      make_lesson(project_id: proj['id'], epic_id: nil)

      results = store.list_lessons(project_id: proj['id'], epic_id: epic['id'])
      expect(results.length).to eq 1
      expect(results[0]['epic_id']).to eq epic['id']
    end

    it 'returns all active lessons regardless of epic_id when epic_id is not provided' do
      proj = default_project
      epic = make_epic(project_id: proj['id'])

      make_lesson(project_id: proj['id'], epic_id: epic['id'])
      make_lesson(project_id: proj['id'], epic_id: nil)

      results = store.list_lessons(project_id: proj['id'])
      expect(results.length).to eq 2
    end

    it 'excludes retired lessons by default' do
      pid    = default_project['id']
      lesson = make_lesson(project_id: pid)
      store.retire_lesson(lesson['id'])

      results = store.list_lessons(project_id: pid)
      expect(results).to eq []
    end

    it 'returns empty array for an unknown project' do
      results = store.list_lessons(project_id: 'nonexistent-id-00000')
      expect(results).to eq []
    end

    it 'returns a global lesson (project_id: nil) alongside a project\'s own lessons' do
      pid    = default_project['id']
      global = store.create_lesson(project_id: nil, trigger: 'uat', text: 'global lesson text')

      results = store.list_lessons(project_id: pid)
      expect(results.map { |r| r['id'] }).to include(global['id'])
    end

    it 'returns the same global lesson for a second, different project too' do
      pid1   = default_project['id']
      pid2   = make_project(slug: 'second-proj')['id']
      global = store.create_lesson(project_id: nil, trigger: 'uat', text: 'global lesson text')

      results1 = store.list_lessons(project_id: pid1)
      results2 = store.list_lessons(project_id: pid2)
      expect(results1.map { |r| r['id'] }).to include(global['id'])
      expect(results2.map { |r| r['id'] }).to include(global['id'])
    end

    it 'includes epic_name for an epic-scoped lesson, and nil for project-wide or global lessons' do
      proj = default_project
      epic = make_epic(project_id: proj['id'])

      epic_scoped  = make_lesson(project_id: proj['id'], epic_id: epic['id'])
      proj_wide    = make_lesson(project_id: proj['id'], epic_id: nil)
      global       = store.create_lesson(project_id: nil, trigger: 'uat', text: 'global lesson text')

      results = store.list_lessons(project_id: proj['id'])
      by_id   = results.each_with_object({}) { |r, h| h[r['id']] = r }

      expect(by_id[epic_scoped['id']]['epic_name']).to eq epic['name']
      expect(by_id[proj_wide['id']]['epic_name']).to be_nil
      expect(by_id[global['id']]['epic_name']).to be_nil
    end

    it 'does not raise an ambiguous-column error when all filters are combined' do
      proj = default_project
      epic = make_epic(project_id: proj['id'])
      matching = make_lesson(project_id: proj['id'], trigger: 'uat', epic_id: epic['id'])
      make_lesson(project_id: proj['id'], trigger: 'commit', epic_id: epic['id'])

      results = store.list_lessons(project_id: proj['id'], trigger: 'uat', epic_id: epic['id'], status: 'active')
      expect(results.map { |r| r['id'] }).to eq [matching['id']]
    end
  end

  describe '#retire_lesson' do
    it 'flips status to retired and returns the updated row' do
      lesson  = store.create_lesson(project_id: default_project['id'], trigger: 'uat', text: 'lesson text')
      retired = store.retire_lesson(lesson['id'])

      expect(retired['id']).to eq lesson['id']
      expect(retired['status']).to eq 'retired'
    end

    it 'does not hard-delete the row' do
      lesson = store.create_lesson(project_id: default_project['id'], trigger: 'uat', text: 'lesson text')
      store.retire_lesson(lesson['id'])

      row = store.send(:with_db) { |db| db.get_first_row('SELECT * FROM lessons WHERE id = ?', [lesson['id']]) }
      expect(row).not_to be_nil
      expect(row['status']).to eq 'retired'
    end

    it 'excludes the lesson from default list_lessons results after retiring' do
      pid    = default_project['id']
      lesson = store.create_lesson(project_id: pid, trigger: 'uat', text: 'lesson text')
      store.retire_lesson(lesson['id'])

      results = store.list_lessons(project_id: pid)
      expect(results.map { |r| r['id'] }).not_to include(lesson['id'])
    end

    it 'raises for an unknown id' do
      expect { store.retire_lesson('lesson-999') }.to raise_error(/Lesson not found: lesson-999/)
    end
  end

  describe '#promote_lesson' do
    it 'widens a story-scoped lesson one rung at a time until global, then raises' do
      proj  = make_project
      epic  = make_epic(project_id: proj['id'])
      story = make_story(epic_id: epic['id'])

      lesson = store.create_lesson(
        project_id: proj['id'], epic_id: epic['id'], story_id: story['id'],
        trigger: 'uat', text: 'lesson text'
      )

      epic_scoped = store.promote_lesson(lesson['id'])
      expect(epic_scoped['story_id']).to be_nil
      expect(epic_scoped['epic_id']).to eq epic['id']

      project_wide = store.promote_lesson(lesson['id'])
      expect(project_wide['epic_id']).to be_nil
      expect(project_wide['project_id']).to eq proj['id']

      global = store.promote_lesson(lesson['id'])
      expect(global['project_id']).to be_nil

      expect { store.promote_lesson(lesson['id']) }.to raise_error(/already global/)
    end

    it 'promotes a project-scoped lesson (no epic_id/story_id) straight to global in one call' do
      lesson = make_lesson(project_id: default_project['id'])

      global = store.promote_lesson(lesson['id'])
      expect(global['project_id']).to be_nil
    end

    it 'promotes an epic-scoped lesson to project-wide, not straight to global' do
      proj = make_project
      epic = make_epic(project_id: proj['id'])
      lesson = make_lesson(project_id: proj['id'], epic_id: epic['id'])

      project_wide = store.promote_lesson(lesson['id'])
      expect(project_wide['epic_id']).to be_nil
      expect(project_wide['project_id']).to eq proj['id']
    end

    it 'raises for an unknown id' do
      expect { store.promote_lesson('lesson-999') }.to raise_error(/Lesson not found: lesson-999/)
    end

    it 'returns the freshly updated row, not the pre-mutation one' do
      lesson = make_lesson(project_id: default_project['id'])
      updated = store.promote_lesson(lesson['id'])

      expect(updated['project_id']).to be_nil
      expect(updated['updated_at']).not_to eq lesson['updated_at']
    end

    it 'leaves origin_project_id/origin_epic_id/origin_story_id unchanged across a promote_lesson call' do
      proj  = make_project
      epic  = make_epic(project_id: proj['id'])
      story = make_story(epic_id: epic['id'])

      lesson = store.create_lesson(
        project_id: proj['id'], epic_id: epic['id'], story_id: story['id'],
        trigger: 'uat', text: 'lesson text'
      )

      promoted = store.promote_lesson(lesson['id'])

      expect(promoted['story_id']).to be_nil
      expect(promoted['origin_project_id']).to eq proj['id']
      expect(promoted['origin_epic_id']).to eq epic['id']
      expect(promoted['origin_story_id']).to eq story['id']
    end
  end

  describe '#demote_lesson' do
    it 'jumps a story-scoped lesson promoted all the way to global back to its original story, not epic or project' do
      proj  = make_project
      epic  = make_epic(project_id: proj['id'])
      story = make_story(epic_id: epic['id'])

      lesson = store.create_lesson(
        project_id: proj['id'], epic_id: epic['id'], story_id: story['id'],
        trigger: 'uat', text: 'lesson text'
      )

      store.promote_lesson(lesson['id']) # -> epic
      store.promote_lesson(lesson['id']) # -> project
      store.promote_lesson(lesson['id']) # -> global

      demoted = store.demote_lesson(lesson['id'])
      expect(demoted['project_id']).to eq proj['id']
      expect(demoted['epic_id']).to eq epic['id']
      expect(demoted['story_id']).to eq story['id']
    end

    it 'jumps an epic-scoped lesson promoted to global back to its original epic' do
      proj = make_project
      epic = make_epic(project_id: proj['id'])
      lesson = store.create_lesson(
        project_id: proj['id'], epic_id: epic['id'],
        trigger: 'uat', text: 'lesson text'
      )

      store.promote_lesson(lesson['id']) # -> project
      store.promote_lesson(lesson['id']) # -> global

      demoted = store.demote_lesson(lesson['id'])
      expect(demoted['project_id']).to eq proj['id']
      expect(demoted['epic_id']).to eq epic['id']
      expect(demoted['story_id']).to be_nil
    end

    it 'jumps a lesson that was project-wide at creation back to project-wide, not further' do
      proj = make_project
      lesson = store.create_lesson(
        project_id: proj['id'], epic_id: nil, story_id: nil,
        trigger: 'uat', text: 'lesson text'
      )

      store.promote_lesson(lesson['id']) # -> global

      demoted = store.demote_lesson(lesson['id'])
      expect(demoted['project_id']).to eq proj['id']
      expect(demoted['epic_id']).to be_nil
      expect(demoted['story_id']).to be_nil
    end

    it 'raises "already at its original scope" for a lesson that was never promoted' do
      lesson = make_lesson(project_id: default_project['id'])

      expect { store.demote_lesson(lesson['id']) }.to raise_error(/already at its original scope/)
    end

    it 'raises the same "already at its original scope" message for a pre-migration lesson with NULL origin_* columns' do
      pid = default_project['id']
      t = store.send(:now)
      store.send(:with_db) do |db|
        db.execute(
          'INSERT INTO lessons (id, project_id, epic_id, story_id, trigger, text, source, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          ['lesson-900', pid, nil, nil, 'uat', 'pre-migration lesson', 'manual', 'active', t, t]
        )
      end

      expect { store.demote_lesson('lesson-900') }.to raise_error(/already at its original scope/)
    end

    it 'raises for an unknown id' do
      expect { store.demote_lesson('lesson-999') }.to raise_error(/Lesson not found: lesson-999/)
    end
  end

  describe 'MIGRATIONS — add_resolved_at_to_story_notes' do
    def story_notes_columns
      store.send(:with_db) { |db| db.execute('PRAGMA table_info(story_notes)').map { |r| r['name'] } }
    end

    it 'story_notes has a resolved_at column after setup_db' do
      expect(story_notes_columns).to include('resolved_at')
    end

    it 'migration is idempotent — setup_db can run twice without error' do
      expect { store.send(:setup_db) }.not_to raise_error
      expect(story_notes_columns).to include('resolved_at')
    end

    it 'no story_notes rebuild migration uses SELECT * in its INSERT' do
      src = File.read(File.expand_path('../lib/tyrion/store.rb', __dir__))
      expect(src).not_to match(/INSERT INTO story_notes\b[^(]*?\bSELECT\s+\*/im)
    end
  end

  describe 'MIGRATIONS — add_gate_and_commit_to_story_notes_kind_check' do
    it 'accepts a gate note kind after setup_db' do
      story = default_story
      expect { store.add_note(story['id'], 'gate', 'pre-push: PASS') }.not_to raise_error
    end

    it 'accepts a commit note kind after setup_db' do
      story = default_story
      expect { store.add_note(story['id'], 'commit', 'abc1234 feat: add thing') }.not_to raise_error
    end

    it 'is idempotent — Store.new twice on the same DB path does not raise' do
      path = File.join(tmpdir, 'twice.db')
      Tyrion::Store.new(db_path: path)
      expect { Tyrion::Store.new(db_path: path) }.not_to raise_error
    end

    it 'preserves the resolved_at column after the gate/commit rebuild' do
      cols = store.send(:with_db) { |db| db.execute('PRAGMA table_info(story_notes)').map { |r| r['name'] } }
      expect(cols).to include('resolved_at')
    end
  end

  describe 'MIGRATIONS — parallel_story_execution_schema' do
    def stories_columns
      store.send(:with_db) { |db| db.execute('PRAGMA table_info(stories)').map { |r| r['name'] } }
    end

    def stories_index_names
      store.send(:with_db) { |db| db.execute('PRAGMA index_list(stories)').map { |r| r['name'] } }
    end

    it 'stories has claimed_by column after setup_db' do
      expect(stories_columns).to include('claimed_by')
    end

    it 'stories has claimed_at column after setup_db' do
      expect(stories_columns).to include('claimed_at')
    end

    it 'idx_one_in_progress_story_per_epic is dropped' do
      expect(stories_index_names).not_to include('idx_one_in_progress_story_per_epic')
    end

    it 'idx_one_in_progress_story_per_lane is created' do
      expect(stories_index_names).to include('idx_one_in_progress_story_per_lane')
    end

    it 'idx_one_unclaimed_in_progress_story_per_epic is created' do
      expect(stories_index_names).to include('idx_one_unclaimed_in_progress_story_per_epic')
    end

    it 'two stories with distinct non-null claimed_by tokens can both be in_progress in one epic' do
      proj = make_project
      epic = make_epic(project_id: proj['id'])
      s1 = make_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      s2 = make_story(epic_id: epic['id'], slug: 's2', title: 'S2')
      store.send(:with_db) do |db|
        t = Time.now.utc.iso8601(6)
        db.execute("UPDATE stories SET status='in_progress', claimed_by='lane-A', claimed_at=? WHERE id=?", [t, s1['id']])
        expect {
          db.execute("UPDATE stories SET status='in_progress', claimed_by='lane-B', claimed_at=? WHERE id=?", [t, s2['id']])
        }.not_to raise_error
      end
    end

    it 'two in_progress stories with NULL claimed_by in one epic are rejected' do
      proj = make_project
      epic = make_epic(project_id: proj['id'])
      s1 = make_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      s2 = make_story(epic_id: epic['id'], slug: 's2', title: 'S2')
      store.send(:with_db) do |db|
        t = Time.now.utc.iso8601(6)
        db.execute("UPDATE stories SET status='in_progress', claimed_by=NULL, claimed_at=? WHERE id=?", [t, s1['id']])
        expect {
          db.execute("UPDATE stories SET status='in_progress', claimed_by=NULL, claimed_at=? WHERE id=?", [t, s2['id']])
        }.to raise_error(SQLite3::ConstraintException)
      end
    end

    it 'migration is idempotent — setup_db can run twice without error' do
      expect { store.send(:setup_db) }.not_to raise_error
      expect(stories_columns).to include('claimed_by')
      expect(stories_columns).to include('claimed_at')
      expect(stories_index_names).to include('idx_one_in_progress_story_per_lane')
      expect(stories_index_names).to include('idx_one_unclaimed_in_progress_story_per_epic')
    end
  end

  # ── claim-next-as-pool ────────────────────────────────────────────────────

  describe '#claim_next_story with claimed_by' do
    let(:epic) do
      proj = make_project
      make_epic(project_id: proj['id'])
    end

    it 'sets claimed_by and claimed_at when claimed_by kwarg is provided' do
      make_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      result = store.claim_next_story(epic['id'], claimed_by: 'lane-A')
      expect(result['claimed_by']).to eq 'lane-A'
      expect(result['claimed_at']).not_to be_nil
    end

    it 'two distinct lane tokens can each claim a story in the same epic' do
      make_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      make_story(epic_id: epic['id'], slug: 's2', title: 'S2')
      r1 = store.claim_next_story(epic['id'], claimed_by: 'lane-A')
      r2 = store.claim_next_story(epic['id'], claimed_by: 'lane-B')
      expect(r1['slug']).not_to eq r2['slug']
      expect(r1['claimed_by']).to eq 'lane-A'
      expect(r2['claimed_by']).to eq 'lane-B'
    end

    it 'defaults claimed_by to nil when no kwarg passed (legacy behavior)' do
      make_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      result = store.claim_next_story(epic['id'])
      expect(result['claimed_by']).to be_nil
    end
  end

  describe '#start_story with claimed_by' do
    it 'sets claimed_by and claimed_at when claimed_by kwarg is provided' do
      result = store.start_story(default_story['id'], claimed_by: 'lane-X')
      expect(result['claimed_by']).to eq 'lane-X'
      expect(result['claimed_at']).not_to be_nil
    end

    it 'defaults claimed_by to nil when no kwarg passed (legacy behavior)' do
      result = store.start_story(default_story['id'])
      expect(result['claimed_by']).to be_nil
    end
  end

  describe 'multi-lane in_progress queries' do
    let(:epic) do
      proj = make_project
      make_epic(project_id: proj['id'])
    end

    # Start N in_progress stories, each claimed by a distinct token (or nil for
    # the single legacy unclaimed slot the schema permits per epic).
    def start_lane(slug, seq, claimed_by:)
      s = store.create_story(epic_id: epic['id'], slug: slug, title: slug, sequence: seq)
      store.start_story(s['id'], claimed_by: claimed_by)
      store.find_story(epic['id'], slug)
    end

    describe '#in_progress_story (single row, kept for legacy callers)' do
      it 'returns a single hash, not an array' do
        start_lane('s1', 1, claimed_by: 'lane-A')
        result = store.in_progress_story(epic['id'])
        expect(result).to be_a(Hash)
        expect(result['slug']).to eq 's1'
      end

      it 'returns nil when no story is in_progress' do
        store.create_story(epic_id: epic['id'], slug: 'pending-one', title: 'P', sequence: 1)
        expect(store.in_progress_story(epic['id'])).to be_nil
      end
    end

    describe '#in_progress_stories (all lanes)' do
      it 'returns every in_progress story in the epic — one per active lane' do
        start_lane('s1', 1, claimed_by: 'lane-A')
        start_lane('s2', 2, claimed_by: 'lane-B')
        start_lane('s3', 3, claimed_by: 'lane-C')

        slugs = store.in_progress_stories(epic['id']).map { |s| s['slug'] }
        expect(slugs).to contain_exactly('s1', 's2', 's3')
      end

      it 'returns an empty array when no story is in_progress' do
        store.create_story(epic_id: epic['id'], slug: 'pending-one', title: 'P', sequence: 1)
        expect(store.in_progress_stories(epic['id'])).to eq([])
      end

      it 'sorts the unclaimed (legacy NULL claimed_by) lane first' do
        start_lane('claimed', 1, claimed_by: 'lane-Z')
        start_lane('unclaimed', 2, claimed_by: nil)

        slugs = store.in_progress_stories(epic['id']).map { |s| s['slug'] }
        expect(slugs.first).to eq 'unclaimed'
      end

      it 'excludes stories in other statuses' do
        start_lane('active', 1, claimed_by: 'lane-A')
        done = store.create_story(epic_id: epic['id'], slug: 'finished', title: 'F', sequence: 2)
        store.start_story(done['id'], claimed_by: 'lane-B')
        store.complete_story(done['id'], 'done', force: true)

        slugs = store.in_progress_stories(epic['id']).map { |s| s['slug'] }
        expect(slugs).to eq(['active'])
      end
    end

    describe '#in_progress_story_for (named lane)' do
      it 'returns the story owned by the given lane token' do
        start_lane('mine', 1, claimed_by: 'lane-A')
        start_lane('theirs', 2, claimed_by: 'lane-B')

        result = store.in_progress_story_for(epic['id'], 'lane-A')
        expect(result['slug']).to eq 'mine'
      end

      it 'returns nil when no in_progress story is owned by that token' do
        start_lane('theirs', 1, claimed_by: 'lane-B')
        expect(store.in_progress_story_for(epic['id'], 'lane-A')).to be_nil
      end

      it 'is aliased as story_in_progress_for_token (rung-2 resolver name)' do
        start_lane('mine', 1, claimed_by: 'lane-A')
        expect(store.story_in_progress_for_token(epic['id'], 'lane-A')['slug']).to eq 'mine'
      end
    end
  end

  describe 'claimed_by is nulled on lifecycle transitions' do
    def start_with_lane(story_id, lane: 'lane-A')
      store.start_story(story_id, claimed_by: lane)
    end

    it 'complete_story nulls claimed_by and claimed_at' do
      story = default_story
      start_with_lane(story['id'])
      done = store.complete_story(story['id'], 'summary', force: true)
      expect(done['claimed_by']).to be_nil
      expect(done['claimed_at']).to be_nil
    end

    it 'unstart_story nulls claimed_by and claimed_at' do
      story = default_story
      start_with_lane(story['id'])
      result = store.unstart_story(story['id'])
      expect(result['claimed_by']).to be_nil
      expect(result['claimed_at']).to be_nil
    end

    it 'block_story nulls claimed_by and claimed_at' do
      story = default_story
      start_with_lane(story['id'])
      result = store.block_story(story['id'], blocked_on: 'waiting on dependency')
      expect(result['claimed_by']).to be_nil
      expect(result['claimed_at']).to be_nil
    end
  end

  # ── Epic completion seal ─────────────────────────────────────────────────
  describe 'epic completion seal' do
    let(:project) { make_project }
    let(:epic)    { make_epic(project_id: project['id']) }

    def add_done_story(slug)
      s = store.create_story(epic_id: epic['id'], slug: slug, title: slug)
      store.complete_story(s['id'], 'done', force: true)
      s
    end

    describe '#all_stories_done?' do
      it 'is true when every story is done' do
        add_done_story('a')
        add_done_story('b')
        expect(store.all_stories_done?(epic['id'])).to be(true)
      end

      it 'is false when any story is not done' do
        add_done_story('a')
        store.create_story(epic_id: epic['id'], slug: 'b', title: 'b')
        expect(store.all_stories_done?(epic['id'])).to be(false)
      end

      it 'is false for an epic with no stories' do
        expect(store.all_stories_done?(epic['id'])).to be(false)
      end
    end

    describe 'reverse-flip honesty' do
      def seal!
        store.update_epic(epic['id'], 'status' => 'done')
      end

      it 'flips a done epic back to active when a story is started' do
        s = store.create_story(epic_id: epic['id'], slug: 'reopen', title: 'reopen')
        seal!
        store.start_story(s['id'])
        expect(store.find_epic_by_id(epic['id'])['status']).to eq('active')
      end

      it 'flips a done epic back to active when a story is claimed' do
        store.create_story(epic_id: epic['id'], slug: 'reopen', title: 'reopen')
        seal!
        store.claim_next_story(epic['id'])
        expect(store.find_epic_by_id(epic['id'])['status']).to eq('active')
      end

      it 'flips a done epic back to active when a story is blocked' do
        s = store.create_story(epic_id: epic['id'], slug: 'reopen', title: 'reopen')
        seal!
        store.block_story(s['id'], blocked_on: 'waiting')
        expect(store.find_epic_by_id(epic['id'])['status']).to eq('active')
      end

      it 'flips a done epic back to active when import adds a new pending story' do
        add_done_story('done-one')
        seal!
        store.import_stories_for_epic(
          epic_id: epic['id'],
          scenarios: [{ slug: 'fresh', title: 'Fresh', intent: nil, criteria: [] }]
        )
        expect(store.find_epic_by_id(epic['id'])['status']).to eq('active')
      end

      it 'leaves an active epic active on import' do
        add_done_story('done-one')
        store.import_stories_for_epic(
          epic_id: epic['id'],
          scenarios: [{ slug: 'fresh', title: 'Fresh', intent: nil, criteria: [] }]
        )
        expect(store.find_epic_by_id(epic['id'])['status']).to eq('active')
      end
    end
  end

  describe 'MIGRATIONS — add_epic_relationships' do
    def epics_columns
      store.send(:with_db) { |db| db.execute('PRAGMA table_info(epics)').map { |r| r['name'] } }
    end

    def epics_index_names
      store.send(:with_db) { |db| db.execute('PRAGMA index_list(epics)').map { |r| r['name'] } }
    end

    it 'epics has parent_epic_id and depends_on columns after setup_db' do
      expect(epics_columns).to include('parent_epic_id', 'depends_on')
    end

    it 'idx_epics_parent index exists' do
      expect(epics_index_names).to include('idx_epics_parent')
    end

    it 'migration is idempotent — setup_db can run twice without error' do
      expect { store.send(:setup_db) }.not_to raise_error
      expect(epics_columns).to include('parent_epic_id', 'depends_on')
    end

    it 'preserves a pre-migration epic row across the migration (migration-replay regression)' do
      path = File.join(tmpdir, 'legacy-epics.db')
      legacy_db = SQLite3::Database.new(path)
      legacy_db.results_as_hash = true
      Tyrion::Store::DDL.split(';').each do |stmt|
        s = stmt.strip
        legacy_db.execute(s) unless s.empty?
      end
      Tyrion::Store::MIGRATIONS.each do |name, fn|
        break if name == 'add_epic_relationships'
        fn.call(legacy_db)
      end

      pid = SecureRandom.uuid
      eid = SecureRandom.uuid
      t = '2026-01-01T00:00:00.000000Z'
      legacy_db.execute(
        'INSERT INTO projects (id, slug, name, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
        [pid, 'legacy-proj', 'Legacy Project', 'active', t, t]
      )
      legacy_db.execute(
        'INSERT INTO epics (id, project_id, slug, name, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [eid, pid, 'legacy-epic', 'Legacy Epic', 'active', t, t]
      )
      legacy_db.close

      migrated_store = Tyrion::Store.new(db_path: path) # runs setup_db -> runs add_epic_relationships this time
      row = migrated_store.send(:with_db) { |db| db.get_first_row('SELECT * FROM epics WHERE id = ?', [eid]) }

      expect(row).to include(
        'id' => eid, 'project_id' => pid, 'slug' => 'legacy-epic', 'name' => 'Legacy Epic',
        'status' => 'active', 'created_at' => t, 'updated_at' => t
      )
      expect(row['parent_epic_id']).to be_nil
      expect(row['depends_on']).to be_nil

      expect { migrated_store.set_epic_parent(eid, nil) }.not_to raise_error
    end
  end

  describe '#epic_graph' do
    let(:project) { make_project }

    it 'returns a snapshot with every epic in the project, keyed by id and slug' do
      a = make_epic(project_id: project['id'], slug: 'a', name: 'A')
      b = make_epic(project_id: project['id'], slug: 'b', name: 'B')
      graph = store.epic_graph(project['id'])
      expect(graph[:epics].keys).to match_array([a['id'], b['id']])
      expect(graph[:by_slug]['a']['id']).to eq a['id']
      expect(graph[:by_slug]['b']['id']).to eq b['id']
    end

    it 'excludes epics from other projects' do
      other = make_project(slug: 'other-proj')
      make_epic(project_id: other['id'], slug: 'other-epic')
      a = make_epic(project_id: project['id'], slug: 'a')
      graph = store.epic_graph(project['id'])
      expect(graph[:epics].keys).to eq [a['id']]
    end

    it 'builds a parent -> children map' do
      parent = make_epic(project_id: project['id'], slug: 'parent')
      child  = make_epic(project_id: project['id'], slug: 'child')
      store.set_epic_parent(child['id'], parent['id'])
      graph = store.epic_graph(project['id'])
      expect(graph[:children][parent['id']]).to eq [child['id']]
      expect(graph[:children][child['id']]).to eq []
    end

    it 'parses depends_on into an array keyed by epic id' do
      a = make_epic(project_id: project['id'], slug: 'a')
      make_epic(project_id: project['id'], slug: 'b')
      store.add_epic_dependency(a['id'], 'b')
      graph = store.epic_graph(project['id'])
      expect(graph[:depends_on][a['id']]).to eq ['b']
    end

    it 'treats malformed depends_on JSON as empty and warns on stderr' do
      a = make_epic(project_id: project['id'], slug: 'a')
      store.send(:with_db) { |db| db.execute('UPDATE epics SET depends_on = ? WHERE id = ?', ['not json', a['id']]) }
      graph = nil
      expect { graph = store.epic_graph(project['id']) }.to output(/malformed depends_on/).to_stderr
      expect(graph[:depends_on][a['id']]).to eq []
    end

    it 'computes per-epic story-status aggregates in one snapshot' do
      epic = make_epic(project_id: project['id'], slug: 'e')
      s1 = make_story(epic_id: epic['id'], slug: 's1')
      make_story(epic_id: epic['id'], slug: 's2')
      store.complete_story(s1['id'], 'done', force: true)
      graph = store.epic_graph(project['id'])
      counts = graph[:story_counts][epic['id']]
      expect(counts['total']).to eq 2
      expect(counts['done']).to eq 1
      expect(counts['pending']).to eq 1
    end

    it 'gives a zero-count entry to an epic with no stories' do
      epic = make_epic(project_id: project['id'], slug: 'e')
      graph = store.epic_graph(project['id'])
      expect(graph[:story_counts][epic['id']]).to eq(
        'total' => 0, 'pending' => 0, 'in_progress' => 0, 'blocked' => 0, 'done' => 0, 'abandoned' => 0
      )
    end
  end

  describe '#epic_ancestors and #epic_descendants' do
    let(:project) { make_project }

    it 'walks ancestors up to the root, nearest first' do
      root = make_epic(project_id: project['id'], slug: 'root')
      mid  = make_epic(project_id: project['id'], slug: 'mid')
      leaf = make_epic(project_id: project['id'], slug: 'leaf')
      store.set_epic_parent(mid['id'], root['id'])
      store.set_epic_parent(leaf['id'], mid['id'])
      graph = store.epic_graph(project['id'])
      expect(store.epic_ancestors(leaf['id'], graph)).to eq [mid['id'], root['id']]
      expect(store.epic_ancestors(root['id'], graph)).to eq []
    end

    it 'walks all descendants regardless of depth' do
      root = make_epic(project_id: project['id'], slug: 'root')
      c1   = make_epic(project_id: project['id'], slug: 'c1')
      c2   = make_epic(project_id: project['id'], slug: 'c2')
      gc   = make_epic(project_id: project['id'], slug: 'gc')
      store.set_epic_parent(c1['id'], root['id'])
      store.set_epic_parent(c2['id'], root['id'])
      store.set_epic_parent(gc['id'], c1['id'])
      graph = store.epic_graph(project['id'])
      expect(store.epic_descendants(root['id'], graph)).to match_array([c1['id'], c2['id'], gc['id']])
      expect(store.epic_descendants(gc['id'], graph)).to eq []
    end

    it 'does not hang on cycle residue in a hand-edited DB' do
      a = make_epic(project_id: project['id'], slug: 'a')
      b = make_epic(project_id: project['id'], slug: 'b')
      # set_epic_parent would refuse this — hand-edit the cycle directly, as a
      # corrupted/hand-edited DB might contain.
      store.send(:with_db) do |db|
        db.execute('UPDATE epics SET parent_epic_id = ? WHERE id = ?', [b['id'], a['id']])
        db.execute('UPDATE epics SET parent_epic_id = ? WHERE id = ?', [a['id'], b['id']])
      end
      graph = store.epic_graph(project['id'])
      expect(store.epic_ancestors(a['id'], graph).length).to be <= 2
      expect(store.epic_descendants(a['id'], graph).length).to be <= 2
    end
  end

  describe '#unmet_prereqs' do
    let(:project) { make_project }

    def sealed_epic(slug)
      epic = make_epic(project_id: project['id'], slug: slug)
      s = make_story(epic_id: epic['id'], slug: "#{slug}-story")
      store.complete_story(s['id'], 'done', force: true)
      store.seal_epic(epic['id'])
      store.find_epic_by_id(epic['id'])
    end

    it 'is empty when the epic has no dependencies' do
      epic = make_epic(project_id: project['id'], slug: 'e')
      graph = store.epic_graph(project['id'])
      expect(store.unmet_prereqs(epic, graph)).to eq []
    end

    it 'is empty when every prerequisite is sealed' do
      sealed_epic('prereq')
      dependent = make_epic(project_id: project['id'], slug: 'dependent')
      store.add_epic_dependency(dependent['id'], 'prereq')
      graph = store.epic_graph(project['id'])
      expect(store.unmet_prereqs(store.find_epic_by_id(dependent['id']), graph)).to eq []
    end

    it 'reports :active for an unsealed prerequisite' do
      make_epic(project_id: project['id'], slug: 'prereq')
      dependent = make_epic(project_id: project['id'], slug: 'dependent')
      store.add_epic_dependency(dependent['id'], 'prereq')
      graph = store.epic_graph(project['id'])
      unmet = store.unmet_prereqs(store.find_epic_by_id(dependent['id']), graph)
      expect(unmet).to eq [{ slug: 'prereq', reason: :active }]
    end

    it 'reports :unknown for a dependency slug that resolves to nothing, never silently dropped' do
      dependent = make_epic(project_id: project['id'], slug: 'dependent')
      store.send(:with_db) do |db|
        db.execute('UPDATE epics SET depends_on = ? WHERE id = ?', [JSON.dump(['ghost']), dependent['id']])
      end
      graph = store.epic_graph(project['id'])
      unmet = store.unmet_prereqs(store.find_epic_by_id(dependent['id']), graph)
      expect(unmet).to eq [{ slug: 'ghost', reason: :unknown }]
    end

    it 'reports :archived for an unsealed archived prerequisite' do
      prereq = make_epic(project_id: project['id'], slug: 'prereq')
      store.archive_epic(prereq['id'])
      dependent = make_epic(project_id: project['id'], slug: 'dependent')
      store.add_epic_dependency(dependent['id'], 'prereq')
      graph = store.epic_graph(project['id'])
      unmet = store.unmet_prereqs(store.find_epic_by_id(dependent['id']), graph)
      expect(unmet).to eq [{ slug: 'prereq', reason: :archived }]
    end

    it 'treats a sealed-and-archived prerequisite as met — archived is a display flag, not a completion flag' do
      prereq = sealed_epic('prereq')
      store.archive_epic(prereq['id'])
      dependent = make_epic(project_id: project['id'], slug: 'dependent')
      store.add_epic_dependency(dependent['id'], 'prereq')
      graph = store.epic_graph(project['id'])
      expect(store.unmet_prereqs(store.find_epic_by_id(dependent['id']), graph)).to eq []
    end

    it 'reports :abandoned and :paused for their respective statuses' do
      abandoned = make_epic(project_id: project['id'], slug: 'abandoned-epic')
      store.update_epic(abandoned['id'], 'status' => 'abandoned')
      paused = make_epic(project_id: project['id'], slug: 'paused-epic')
      store.update_epic(paused['id'], 'status' => 'paused')
      dependent = make_epic(project_id: project['id'], slug: 'dependent')
      store.send(:with_db) do |db|
        db.execute('UPDATE epics SET depends_on = ? WHERE id = ?', [JSON.dump(%w[abandoned-epic paused-epic]), dependent['id']])
      end
      graph = store.epic_graph(project['id'])
      unmet = store.unmet_prereqs(store.find_epic_by_id(dependent['id']), graph)
      expect(unmet).to match_array(
        [{ slug: 'abandoned-epic', reason: :abandoned }, { slug: 'paused-epic', reason: :paused }]
      )
    end

    it 'inherits ancestor prerequisites down the tree' do
      make_epic(project_id: project['id'], slug: 'prereq')
      parent = make_epic(project_id: project['id'], slug: 'parent')
      child  = make_epic(project_id: project['id'], slug: 'child')
      store.add_epic_dependency(parent['id'], 'prereq')
      store.set_epic_parent(child['id'], parent['id'])
      graph = store.epic_graph(project['id'])
      unmet = store.unmet_prereqs(store.find_epic_by_id(child['id']), graph)
      expect(unmet).to eq [{ slug: 'prereq', reason: :active }]
    end
  end

  describe '#add_epic_dependency and #remove_epic_dependency' do
    let(:project) { make_project }

    it 'adds a dependency edge, stored as a JSON array of slugs' do
      a = make_epic(project_id: project['id'], slug: 'a')
      make_epic(project_id: project['id'], slug: 'b')
      store.add_epic_dependency(a['id'], 'b')
      row = store.find_epic_by_id(a['id'])
      expect(JSON.parse(row['depends_on'])).to eq ['b']
    end

    it 'is idempotent when the edge already exists' do
      a = make_epic(project_id: project['id'], slug: 'a')
      make_epic(project_id: project['id'], slug: 'b')
      store.add_epic_dependency(a['id'], 'b')
      store.add_epic_dependency(a['id'], 'b')
      row = store.find_epic_by_id(a['id'])
      expect(JSON.parse(row['depends_on'])).to eq ['b']
    end

    it 'raises for an unknown dep slug' do
      a = make_epic(project_id: project['id'], slug: 'a')
      expect { store.add_epic_dependency(a['id'], 'ghost') }.to raise_error(/Epic not found: ghost/)
    end

    it 'raises for a self-dependency' do
      a = make_epic(project_id: project['id'], slug: 'a')
      expect { store.add_epic_dependency(a['id'], 'a') }.to raise_error(/cannot depend on itself/)
    end

    it 'raises for a dep slug that resolves in a different project' do
      other = make_project(slug: 'other-proj')
      make_epic(project_id: other['id'], slug: 'cross')
      a = make_epic(project_id: project['id'], slug: 'a')
      expect { store.add_epic_dependency(a['id'], 'cross') }.to raise_error(/different project/)
    end

    it 'raises for a plain dependency cycle' do
      a = make_epic(project_id: project['id'], slug: 'a')
      b = make_epic(project_id: project['id'], slug: 'b')
      store.add_epic_dependency(a['id'], 'b')
      expect { store.add_epic_dependency(b['id'], 'a') }.to raise_error(/cycle/)
    end

    it 'raises when a descendant would depend on its own ancestor' do
      parent = make_epic(project_id: project['id'], slug: 'parent')
      child  = make_epic(project_id: project['id'], slug: 'child')
      store.set_epic_parent(child['id'], parent['id'])
      expect { store.add_epic_dependency(child['id'], 'parent') }.to raise_error(/ancestor/)
    end

    it 'raises when an ancestor would depend on its own descendant' do
      parent = make_epic(project_id: project['id'], slug: 'parent')
      child  = make_epic(project_id: project['id'], slug: 'child')
      store.set_epic_parent(child['id'], parent['id'])
      expect { store.add_epic_dependency(parent['id'], 'child') }.to raise_error(/descendant/)
    end

    it 'removes an existing dependency edge, storing NULL when the array empties' do
      a = make_epic(project_id: project['id'], slug: 'a')
      make_epic(project_id: project['id'], slug: 'b')
      store.add_epic_dependency(a['id'], 'b')
      store.remove_epic_dependency(a['id'], 'b')
      row = store.find_epic_by_id(a['id'])
      expect(row['depends_on']).to be_nil
    end

    it 'is a no-op removing an edge that does not exist' do
      a = make_epic(project_id: project['id'], slug: 'a')
      expect { store.remove_epic_dependency(a['id'], 'ghost') }.not_to raise_error
    end
  end

  describe '#set_epic_parent' do
    let(:project) { make_project }

    it 'sets containment' do
      parent = make_epic(project_id: project['id'], slug: 'parent')
      child  = make_epic(project_id: project['id'], slug: 'child')
      store.set_epic_parent(child['id'], parent['id'])
      expect(store.find_epic_by_id(child['id'])['parent_epic_id']).to eq parent['id']
    end

    it 'clears containment with nil' do
      parent = make_epic(project_id: project['id'], slug: 'parent')
      child  = make_epic(project_id: project['id'], slug: 'child')
      store.set_epic_parent(child['id'], parent['id'])
      store.set_epic_parent(child['id'], nil)
      expect(store.find_epic_by_id(child['id'])['parent_epic_id']).to be_nil
    end

    it 'raises for self-parenting' do
      a = make_epic(project_id: project['id'], slug: 'a')
      expect { store.set_epic_parent(a['id'], a['id']) }.to raise_error(/own parent/)
    end

    it 'raises for a containment cycle (parenting to a descendant)' do
      parent = make_epic(project_id: project['id'], slug: 'parent')
      child  = make_epic(project_id: project['id'], slug: 'child')
      store.set_epic_parent(child['id'], parent['id'])
      expect { store.set_epic_parent(parent['id'], child['id']) }.to raise_error(/descendant/)
    end

    it 'raises for a parent in a different project' do
      other = make_project(slug: 'other-proj')
      cross = make_epic(project_id: other['id'], slug: 'cross')
      a = make_epic(project_id: project['id'], slug: 'a')
      expect { store.set_epic_parent(a['id'], cross['id']) }.to raise_error(/different project/)
    end

    it 'raises for a cross-relation deadlock — child already depends on the epic being made its parent' do
      child = make_epic(project_id: project['id'], slug: 'child')
      parent = make_epic(project_id: project['id'], slug: 'parent')
      store.add_epic_dependency(child['id'], 'parent')
      expect { store.set_epic_parent(child['id'], parent['id']) }.to raise_error(/would become its ancestor/)
    end

    it 'raises for a cross-relation deadlock — the new parent already depends on the child' do
      child = make_epic(project_id: project['id'], slug: 'child')
      parent = make_epic(project_id: project['id'], slug: 'parent')
      store.add_epic_dependency(parent['id'], 'child')
      expect { store.set_epic_parent(child['id'], parent['id']) }.to raise_error(/would become its descendant/)
    end
  end
end
