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
end
