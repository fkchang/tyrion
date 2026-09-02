# frozen_string_literal: true

require 'spec_helper'
require 'delegate'

# Bulk liveness read queries (fleet-visibility phase 1).
#
# The load-bearing property these specs guard is "exactly one SQL statement per
# call": the fleet renders every lane in every project on one page, so a method
# that quietly fans out per story reintroduces the N+1 the epic exists to remove.
# SqlSpy wraps the db handle *inside* with_db, after its PRAGMAs have run, so the
# count is of the method's own statements only.
class SqlSpy < SimpleDelegator
  attr_reader :statements

  def initialize(db, statements)
    super(db)
    @statements = statements
  end

  %i[execute execute2 query get_first_row get_first_value].each do |m|
    define_method(m) do |*args, &blk|
      @statements << args.first
      __getobj__.public_send(m, *args, &blk)
    end
  end
end

RSpec.describe 'Store bulk liveness queries' do
  let(:ctx)     { tyrion_worktree(project_slug: 'alpha', project_name: 'Alpha', epic_slug: 'e1') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }
  let(:epic)    { ctx.epic }

  # Wrap every db handle this store yields in a spy and return the statement log.
  def count_sql(store)
    statements = []
    original = store.method(:with_db)
    allow(store).to receive(:with_db) do |&blk|
      original.call { |db| blk.call(SqlSpy.new(db, statements)) }
    end
    statements
  end

  # idx_one_unclaimed_in_progress_story_per_epic forbids two *unclaimed*
  # in_progress stories in one epic, so an in_progress story gets a distinct
  # lane token unless the example deliberately asks for an unclaimed one.
  def make_story(epic_id, slug, sequence, status: 'pending', **attrs)
    story = store.create_story(epic_id: epic_id, slug: slug, title: slug, sequence: sequence)
    attrs = { claimed_by: "lane-#{slug}" }.merge(attrs) if status == 'in_progress'
    store.update_story(story['id'], { status: status }.merge(attrs)) if status != 'pending' || attrs.any?
    store.find_story_by_id(story['id'])
  end

  def then_clause(text) = { keyword: 'Then', semantic_kind: 'then', text: text }

  describe '#in_progress_stories_across_projects' do
    it 'returns one row per in_progress story across every project and epic, joined to epic and project' do
      store.update_project(project['id'], primary_repo_identity: '/repos/alpha')
      other_p = store.create_project(slug: 'beta', name: 'Beta', repo_identity: '/repos/beta')
      other_e = store.create_epic(project_id: other_p['id'], slug: 'e2', name: 'E2')

      a = make_story(epic['id'], 'a', 1, status: 'in_progress', claimed_by: 'claude:1:aa',
                     started_at: '2026-09-01T00:00:00Z', last_note_at: '2026-09-01T01:00:00Z')
      b = make_story(other_e['id'], 'b', 1, status: 'in_progress', claimed_by: nil)

      rows = store.in_progress_stories_across_projects

      expect(rows.map { |r| r['story_id'] }).to contain_exactly(a['id'], b['id'])
      row = rows.find { |r| r['story_id'] == a['id'] }
      expect(row).to include(
        'slug' => 'a', 'status' => 'in_progress', 'claimed_by' => 'claude:1:aa',
        'started_at' => '2026-09-01T00:00:00Z', 'last_note_at' => '2026-09-01T01:00:00Z',
        'epic_id' => epic['id'], 'epic_slug' => 'e1',
        'project_id' => project['id'], 'project_slug' => 'alpha',
        'primary_repo_identity' => '/repos/alpha'
      )
      expect(row['updated_at']).not_to be_nil
      expect(rows.find { |r| r['story_id'] == b['id'] }['primary_repo_identity']).to eq '/repos/beta'
    end

    it 'also returns blocked stories and never returns done, pending or abandoned rows' do
      blocked = make_story(epic['id'], 'blk', 1, status: 'blocked', blocked_on: 'waiting on disc-001')
      make_story(epic['id'], 'dn', 2, status: 'done')
      make_story(epic['id'], 'pd', 3)
      make_story(epic['id'], 'ab', 4, status: 'abandoned')
      live = make_story(epic['id'], 'ip', 5, status: 'in_progress')

      rows = store.in_progress_stories_across_projects

      expect(rows.map { |r| r['story_id'] }).to contain_exactly(blocked['id'], live['id'])
      expect(rows.map { |r| r['status'] }).to contain_exactly('blocked', 'in_progress')
      expect(rows.find { |r| r['status'] == 'blocked' }['blocked_on']).to eq 'waiting on disc-001'
    end

    it 'issues exactly one SQL statement' do
      make_story(epic['id'], 'a', 1, status: 'in_progress')
      statements = count_sql(store)
      store.in_progress_stories_across_projects
      expect(statements.size).to eq 1
    end
  end

  describe '#latest_note_per_story' do
    it 'returns the newest created_at, kind and metadata per story, only for the ids given' do
      a = make_story(epic['id'], 'a', 1, status: 'in_progress')
      b = make_story(epic['id'], 'b', 2, status: 'in_progress')
      c = make_story(epic['id'], 'c', 3, status: 'in_progress')
      store.add_note(a['id'], 'progress', 'older')
      store.add_note(a['id'], 'decision', 'newest', metadata: JSON.dump('why' => 'because'))
      store.add_note(b['id'], 'plan', 'b-note')
      store.add_note(c['id'], 'plan', 'c-note')

      result = store.latest_note_per_story([a['id'], b['id']])

      expect(result.keys).to contain_exactly(a['id'], b['id'])
      expect(result[a['id']]['kind']).to eq 'decision'
      expect(result[a['id']]['body']).to eq 'newest'
      expect(JSON.parse(result[a['id']]['metadata'])).to eq('why' => 'because')
      expect(result[a['id']]['created_at']).not_to be_nil
      expect(result[b['id']]['kind']).to eq 'plan'
    end

    it 'returns empty without issuing SQL for an empty id list' do
      statements = count_sql(store)
      expect(store.latest_note_per_story([])).to eq({})
      expect(statements).to be_empty
    end

    it 'tolerates duplicate ids, whose bind count must still match the placeholders' do
      a = make_story(epic['id'], 'a', 1, status: 'in_progress')
      store.add_note(a['id'], 'progress', 'only')
      expect(store.latest_note_per_story([a['id'], a['id']]).keys).to eq [a['id']]
    end

    it 'issues exactly one SQL statement' do
      a = make_story(epic['id'], 'a', 1, status: 'in_progress')
      store.add_note(a['id'], 'progress', 'x')
      statements = count_sql(store)
      store.latest_note_per_story([a['id']])
      expect(statements.size).to eq 1
    end
  end

  describe '#latest_gate_and_commit_per_story' do
    it 'returns the newest gate note and the newest commit note per story as separate values' do
      a = make_story(epic['id'], 'a', 1, status: 'in_progress')
      b = make_story(epic['id'], 'b', 2, status: 'in_progress')
      store.add_note(a['id'], 'gate', 'pre-push: FAIL', metadata: JSON.dump('gate' => 'pre-push', 'result' => 'fail'))
      store.add_note(a['id'], 'gate', 'pre-push: PASS', metadata: JSON.dump('gate' => 'pre-push', 'result' => 'pass'))
      store.add_note(a['id'], 'commit', 'abc123 feat: thing', metadata: JSON.dump('shas' => ['abc123']))
      store.add_note(a['id'], 'progress', 'noise')
      store.add_note(b['id'], 'commit', 'def456 fix: other', metadata: JSON.dump('shas' => ['def456']))

      result = store.latest_gate_and_commit_per_story([a['id'], b['id']])

      expect(result[a['id']]['gate']['body']).to eq 'pre-push: PASS'
      expect(JSON.parse(result[a['id']]['gate']['metadata'])).to include('result' => 'pass')
      expect(result[a['id']]['commit']['body']).to eq 'abc123 feat: thing'
      expect(result[b['id']]['gate']).to be_nil
      expect(result[b['id']]['commit']['body']).to eq 'def456 fix: other'
    end

    it 'returns empty without issuing SQL for an empty id list' do
      statements = count_sql(store)
      expect(store.latest_gate_and_commit_per_story([])).to eq({})
      expect(statements).to be_empty
    end

    it 'issues exactly one SQL statement' do
      a = make_story(epic['id'], 'a', 1, status: 'in_progress')
      store.add_note(a['id'], 'gate', 'g', metadata: JSON.dump('gate' => 'x', 'result' => 'pass'))
      statements = count_sql(store)
      store.latest_gate_and_commit_per_story([a['id']])
      expect(statements.size).to eq 1
    end
  end

  describe '#latest_criterion_check_per_story' do
    it 'returns MAX(checked_at) plus met and total counts per story' do
      a = make_story(epic['id'], 'a', 1, status: 'in_progress')
      b = make_story(epic['id'], 'b', 2, status: 'in_progress')
      store.add_criteria(a['id'], [then_clause('one'), then_clause('two'), then_clause('three')])
      store.add_criteria(b['id'], [then_clause('only')])
      store.check_criterion(a['id'], 1, 'evidence one')
      newest = store.check_criterion(a['id'], 2, 'evidence two')

      result = store.latest_criterion_check_per_story([a['id'], b['id']])

      expect(result[a['id']]['met']).to eq 2
      expect(result[a['id']]['total']).to eq 3
      expect(result[a['id']]['newest_checked_at']).to eq newest['checked_at']
      expect(result[b['id']]).to include('met' => 0, 'total' => 1, 'newest_checked_at' => nil)
    end

    it 'returns empty without issuing SQL for an empty id list' do
      statements = count_sql(store)
      expect(store.latest_criterion_check_per_story([])).to eq({})
      expect(statements).to be_empty
    end

    it 'issues exactly one SQL statement' do
      a = make_story(epic['id'], 'a', 1, status: 'in_progress')
      store.add_criteria(a['id'], [then_clause('one')])
      statements = count_sql(store)
      store.latest_criterion_check_per_story([a['id']])
      expect(statements.size).to eq 1
    end
  end

  describe '#project_activity' do
    it 'returns the MAX across story, note, criterion and discovery timestamps plus done/total counts' do
      a = make_story(epic['id'], 'a', 1, status: 'done')
      make_story(epic['id'], 'b', 2, status: 'in_progress')
      store.add_criteria(a['id'], [then_clause('one')])
      checked = store.check_criterion(a['id'], 1, 'ev')
      disc = store.create_discovery(project_id: project['id'], status: 'mark', question: 'q')

      result = store.project_activity

      row = result[project['id']]
      expect(row['done']).to eq 1
      expect(row['total']).to eq 2
      expect(row['project_slug']).to eq 'alpha'
      expect(row['activity_at']).to eq [checked['checked_at'], disc['updated_at'],
                                        store.find_story_by_id(a['id'])['updated_at']].max
    end

    it 'aggregates across every story in the project, not just the first' do
      # Guard against a query that reads one story's timestamps and stops: the
      # newest signal here belongs to the SECOND story, via last_note_at.
      a = make_story(epic['id'], 'a', 1, status: 'done')
      store.add_criteria(a['id'], [then_clause('one')])
      store.check_criterion(a['id'], 1, 'ev')
      b = make_story(epic['id'], 'b', 2, status: 'in_progress')
      store.update_story(b['id'], last_note_at: '2099-01-01T00:00:00Z')

      expect(store.project_activity[project['id']]['activity_at']).to eq '2099-01-01T00:00:00Z'
    end

    it 'counts done and total correctly when a project has many criteria and discoveries' do
      # Regression guard: joining stories to criteria and discoveries would
      # multiply rows and inflate these counts.
      a = make_story(epic['id'], 'a', 1, status: 'done')
      make_story(epic['id'], 'b', 2, status: 'done')
      store.add_criteria(a['id'], (1..4).map { |i| then_clause("c#{i}") })
      3.times { |i| store.create_discovery(project_id: project['id'], status: 'mark', question: "q#{i}") }

      row = store.project_activity[project['id']]

      expect(row['done']).to eq 2
      expect(row['total']).to eq 2
    end

    it 'reports a nil activity_at for a project with no stories, criteria or discoveries' do
      empty = store.create_project(slug: 'empty', name: 'Empty')
      row = store.project_activity[empty['id']]
      expect(row['activity_at']).to be_nil
      expect(row).to include('done' => 0, 'total' => 0)
      expect(row['project_updated_at']).to eq empty['updated_at']
    end

    it 'issues exactly one SQL statement' do
      make_story(epic['id'], 'a', 1, status: 'done')
      statements = count_sql(store)
      store.project_activity
      expect(statements.size).to eq 1
    end
  end
end
