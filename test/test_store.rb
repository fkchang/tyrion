# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/tyrion'

class TestStore < Minitest::Test
  def setup
    @tmpdir  = Dir.mktmpdir('tyrion-store-test-')
    @db_path = File.join(@tmpdir, 'test.db')
    @store   = Tyrion::Store.new(db_path: @db_path)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  def make_project(slug: 'proj', name: 'My Project')
    @store.create_project(slug: slug, name: name)
  end

  def make_epic(project_id:, slug: 'epic-one', name: 'Epic One')
    @store.create_epic(project_id: project_id, slug: slug, name: name)
  end

  def make_story(epic_id:, slug: 'story-one', title: 'Story One')
    @store.create_story(epic_id: epic_id, slug: slug, title: title)
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
    @store.add_criteria(story['id'], gwt_clauses)
    story
  end

  # ── create_project ────────────────────────────────────────────────────────

  def test_create_project_returns_hash_with_id_slug_name
    proj = make_project(slug: 'my-proj', name: 'My Project')
    assert_kind_of Hash, proj
    refute_nil proj['id']
    assert_equal 'my-proj',    proj['slug']
    assert_equal 'My Project', proj['name']
  end

  def test_create_project_persists_to_db
    proj = make_project(slug: 'persisted', name: 'Persisted Project')
    found = @store.find_project_by_slug('persisted')
    refute_nil found
    assert_equal proj['id'], found['id']
    assert_equal 'Persisted Project', found['name']
  end

  def test_create_project_sets_active_status
    proj = make_project
    assert_equal 'active', proj['status']
  end

  def test_create_project_unique_id_per_project
    p1 = make_project(slug: 'p1', name: 'P1')
    p2 = make_project(slug: 'p2', name: 'P2')
    refute_equal p1['id'], p2['id']
  end

  # ── create_epic ───────────────────────────────────────────────────────────

  def test_create_epic_returns_hash_with_id_and_project_id
    proj = make_project
    epic = make_epic(project_id: proj['id'])
    refute_nil epic['id']
    assert_equal proj['id'], epic['project_id']
    assert_equal 'epic-one', epic['slug']
    assert_equal 'Epic One', epic['name']
  end

  def test_create_epic_sets_active_status
    proj = make_project
    epic = make_epic(project_id: proj['id'])
    assert_equal 'active', epic['status']
  end

  # ── create_story ──────────────────────────────────────────────────────────

  def test_create_story_returns_hash_with_id_and_epic_id
    proj  = make_project
    epic  = make_epic(project_id: proj['id'])
    story = make_story(epic_id: epic['id'])
    refute_nil story['id']
    assert_equal epic['id'],  story['epic_id']
    assert_equal 'story-one', story['slug']
    assert_equal 'Story One', story['title']
  end

  def test_create_story_sets_pending_status
    assert_equal 'pending', default_story['status']
  end

  def test_create_story_auto_assigns_sequence
    proj = make_project
    epic = make_epic(project_id: proj['id'])
    s1 = make_story(epic_id: epic['id'], slug: 's1', title: 'S1')
    s2 = make_story(epic_id: epic['id'], slug: 's2', title: 'S2')
    assert_equal 1, s1['sequence']
    assert_equal 2, s2['sequence']
  end

  # ── add_criteria ──────────────────────────────────────────────────────────

  def test_add_criteria_returns_array_of_criteria
    added = @store.add_criteria(default_story['id'], gwt_clauses)
    assert_kind_of Array, added
    assert_equal 3, added.length
  end

  def test_add_criteria_assigns_positions_sequentially
    added = @store.add_criteria(default_story['id'], gwt_clauses)
    assert_equal [1, 2, 3], added.map { |c| c['position'] }
  end

  def test_add_criteria_sets_pending_status
    added = @store.add_criteria(default_story['id'], gwt_clauses)
    added.each { |c| assert_equal 'pending', c['status'] }
  end

  def test_add_criteria_stores_keyword_and_text
    added = @store.add_criteria(default_story['id'], gwt_clauses)
    assert_equal 'Given',            added[0]['keyword']
    assert_equal 'a precondition',   added[0]['text']
    assert_equal 'When',             added[1]['keyword']
    assert_equal 'Then',             added[2]['keyword']
  end

  # ── criteria_for_story ────────────────────────────────────────────────────

  def test_criteria_for_story_returns_all_criteria_in_position_order
    story = default_story_with_criteria
    criteria = @store.criteria_for_story(story['id'])
    assert_equal 3, criteria.length
    assert_equal [1, 2, 3], criteria.map { |c| c['position'] }
  end

  def test_criteria_for_story_returns_empty_array_when_none
    assert_equal [], @store.criteria_for_story(default_story['id'])
  end

  def test_criteria_for_story_preserves_texts
    story = default_story_with_criteria
    texts = @store.criteria_for_story(story['id']).map { |c| c['text'] }
    assert_equal ['a precondition', 'an action occurs', 'an outcome is observed'], texts
  end

  # ── check_criterion ───────────────────────────────────────────────────────

  def test_check_criterion_marks_criterion_as_met
    story = default_story_with_criteria
    @store.check_criterion(story['id'], 1, 'precondition verified')
    criteria = @store.criteria_for_story(story['id'])
    assert_equal 'met',                   criteria[0]['status']
    assert_equal 'precondition verified', criteria[0]['evidence']
  end

  def test_check_criterion_does_not_affect_other_criteria
    story = default_story_with_criteria
    @store.check_criterion(story['id'], 1, 'evidence')
    criteria = @store.criteria_for_story(story['id'])
    assert_equal 'pending', criteria[1]['status']
    assert_equal 'pending', criteria[2]['status']
  end

  def test_check_criterion_returns_updated_row
    story  = default_story_with_criteria
    result = @store.check_criterion(story['id'], 2, 'action confirmed')
    assert_equal 'met',              result['status']
    assert_equal 'action confirmed', result['evidence']
    refute_nil result['checked_at']
  end

  def test_check_criterion_raises_on_missing_position
    story = default_story_with_criteria
    assert_raises(RuntimeError) { @store.check_criterion(story['id'], 99, 'no such criterion') }
  end

  # ── delete_pending_criteria ───────────────────────────────────────────────

  def test_delete_pending_criteria_removes_only_pending
    story = default_story_with_criteria
    @store.check_criterion(story['id'], 1, 'met evidence')
    @store.delete_pending_criteria(story['id'])
    remaining = @store.criteria_for_story(story['id'])
    assert_equal 1,     remaining.length
    assert_equal 'met', remaining[0]['status']
    assert_equal 1,     remaining[0]['position']
  end

  def test_delete_pending_criteria_preserves_met_criterion
    story = default_story
    @store.add_criteria(story['id'], [
      { keyword: 'Given', semantic_kind: 'given', text: 'met condition' },
      { keyword: 'Then',  semantic_kind: 'then',  text: 'pending condition' }
    ])
    @store.check_criterion(story['id'], 1, 'evidence')
    @store.delete_pending_criteria(story['id'])
    remaining = @store.criteria_for_story(story['id'])
    assert_equal 1,             remaining.length
    assert_equal 'met condition', remaining[0]['text']
    assert_equal 'met',           remaining[0]['status']
  end

  def test_delete_pending_criteria_removes_all_when_none_met
    story = default_story_with_criteria
    @store.delete_pending_criteria(story['id'])
    assert_equal [], @store.criteria_for_story(story['id'])
  end

  def test_delete_pending_criteria_is_noop_when_all_met
    story = default_story_with_criteria
    @store.check_criterion(story['id'], 1, 'e1')
    @store.check_criterion(story['id'], 2, 'e2')
    @store.check_criterion(story['id'], 3, 'e3')
    @store.delete_pending_criteria(story['id'])
    assert_equal 3, @store.criteria_for_story(story['id']).length
  end

  # ── Discoveries ───────────────────────────────────────────────────────────

  def default_project
    make_project
  end

  def make_discovery(project_id:, status: 'mark', question: 'test question', **opts)
    @store.create_discovery(project_id: project_id, status: status, question: question, **opts)
  end

  def test_create_discovery_returns_hash_with_id_and_status
    disc = make_discovery(project_id: default_project['id'])
    assert_kind_of Hash, disc
    refute_nil disc['id']
    assert_equal 'mark', disc['status']
    refute_nil disc['created_at']
  end

  def test_create_discovery_all_optional_fields_roundtrip
    proj  = default_project
    epic  = make_epic(project_id: proj['id'])
    story = make_story(epic_id: epic['id'])

    disc = @store.create_discovery(
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

    found = @store.find_discovery(disc['id'])
    refute_nil found
    assert_equal disc['id'],        found['id']
    assert_equal proj['id'],        found['project_id']
    assert_equal epic['id'],        found['epic_id']
    assert_equal story['id'],       found['story_id']
    assert_equal 'active_spike',    found['status']
    assert_equal 'Will it blend?',  found['question']
    assert_equal 'Yes, it will blend.', found['hypothesis']
    assert_equal 'Blending observed once.', found['exit_criteria']
    assert_equal 'It blended.',     found['finding']
    assert_equal 'high',            found['confidence']
    assert_equal 'Ship it.',        found['recommendation']
    assert_equal 'abc1234',         found['git_context']
    refute_nil found['created_at']
    refute_nil found['updated_at']
  end

  def test_list_discoveries_returns_all_for_project
    pid = default_project['id']
    make_discovery(project_id: pid, status: 'mark',         question: 'q1')
    make_discovery(project_id: pid, status: 'active_spike', question: 'q2')
    make_discovery(project_id: pid, status: 'deferred',     question: 'q3')
    results = @store.list_discoveries(project_id: pid)
    assert_equal 3, results.length
  end

  def test_list_discoveries_filters_by_status
    pid = default_project['id']
    make_discovery(project_id: pid, status: 'mark',         question: 'q1')
    make_discovery(project_id: pid, status: 'active_spike', question: 'q2')
    make_discovery(project_id: pid, status: 'deferred',     question: 'q3')
    results = @store.list_discoveries(project_id: pid, status: 'active_spike')
    assert_equal 1, results.length
    assert_equal 'active_spike', results[0]['status']
  end

  def test_list_discoveries_returns_empty_for_unknown_project
    results = @store.list_discoveries(project_id: 'nonexistent-id-00000')
    assert_equal [], results
  end
end
