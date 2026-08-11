# frozen_string_literal: true

require 'spec_helper'
require_relative '../web/lib/tyrion_web/data'

# Criterion 5: the web War Room / data layer shows ALL lanes (an "N active"
# badge) and never auto-picks "mine" — the web has no process identity, so it
# must present every in_progress lane, not single one out.
RSpec.describe 'TyrionWeb::Data.load_war_room_view — multi-lane' do
  let(:ctx)     { tyrion_worktree(project_slug: 'wr-proj', project_name: 'WR Test') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }
  let(:epic)    { store.create_epic(project_id: project['id'], slug: 'ep-a', name: 'Epic A') }

  before do
    TyrionWeb::Data.instance_variable_set(:@store, store)
    allow(TyrionWeb::Data).to receive(:resolve_active_epic).and_return(nil)
  end

  after { TyrionWeb::Data.instance_variable_set(:@store, nil) }

  subject(:result) { TyrionWeb::Data.load_war_room_view(project_slug: 'wr-proj') }

  def start_lane(slug, seq, claimed_by:)
    s = store.create_story(epic_id: epic['id'], slug: slug, title: slug, sequence: seq)
    store.start_story(s['id'], claimed_by: claimed_by)
  end

  context 'with two active lanes' do
    before do
      start_lane('lane-one', 1, claimed_by: 'claude:111:a')
      start_lane('lane-two', 2, claimed_by: 'claude:222:b')
    end

    it 'includes every in_progress story in :active (no lane hidden)' do
      slugs = result[:active].map { |s| s['slug'] }
      expect(slugs).to contain_exactly('lane-one', 'lane-two')
    end

    it 'exposes an :active_count badge equal to the number of active lanes' do
      expect(result[:active_count]).to eq 2
    end

    it 'does not auto-pick a single "mine"/current active story' do
      # No key should single out one lane as THE active story — the web has no
      # process identity to decide which lane is "mine".
      expect(result).not_to have_key(:active_story)
      expect(result).not_to have_key(:mine)
    end
  end

  context 'with no active lanes' do
    before { store.create_story(epic_id: epic['id'], slug: 'pending-one', title: 'P', sequence: 1) }

    it 'reports active_count 0 and an empty active list' do
      expect(result[:active_count]).to eq 0
      expect(result[:active]).to eq []
    end
  end
end

# Criterion warroom-scope-to-epic: an explicit epic_slug: narrows the board to
# only that epic's stories, so the Queue and sidebar tell the same story.
RSpec.describe 'TyrionWeb::Data.load_war_room_view — scoped to a single epic' do
  let(:ctx)     { tyrion_worktree(project_slug: 'wr-proj', project_name: 'WR Test') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }
  let(:epic_a)  { store.create_epic(project_id: project['id'], slug: 'ep-a', name: 'Epic A') }
  let(:epic_b)  { store.create_epic(project_id: project['id'], slug: 'ep-b', name: 'Epic B') }

  before do
    TyrionWeb::Data.instance_variable_set(:@store, store)
    store.create_story(epic_id: epic_a['id'], slug: 'a-one', title: 'A1', sequence: 1)
    store.create_story(epic_id: epic_b['id'], slug: 'b-one', title: 'B1', sequence: 1)
  end

  after { TyrionWeb::Data.instance_variable_set(:@store, nil) }

  it 'includes only the scoped epic\'s stories, excluding sibling epics' do
    result = TyrionWeb::Data.load_war_room_view(project_slug: 'wr-proj', epic_slug: 'ep-a')
    slugs  = result[:queue].map { |s| s['slug'] }
    expect(slugs).to contain_exactly('a-one')
    expect(result[:epic]['slug']).to eq 'ep-a'
  end

  it 'returns an empty board for an unknown epic_slug rather than falling back to the cross-epic view' do
    result = TyrionWeb::Data.load_war_room_view(project_slug: 'wr-proj', epic_slug: 'no-such-epic')
    expect(result[:epic]).to be_nil
    expect(result[:queue]).to eq []
  end
end

# Traceability: the Blocked lane card needs the block reason to display it, so
# the story hash reaching the view must carry blocked_on.
RSpec.describe 'TyrionWeb::Data.load_war_room_view — blocked_on on blocked cards' do
  let(:ctx)     { tyrion_worktree(project_slug: 'wr-proj', project_name: 'WR Test') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }
  let(:epic)    { store.create_epic(project_id: project['id'], slug: 'ep-a', name: 'Epic A') }

  before do
    TyrionWeb::Data.instance_variable_set(:@store, store)
    allow(TyrionWeb::Data).to receive(:resolve_active_epic).and_return(nil)
  end

  after { TyrionWeb::Data.instance_variable_set(:@store, nil) }

  it 'includes blocked_on in the blocked story hash' do
    story = store.create_story(epic_id: epic['id'], slug: 'blocked-one', title: 'B1', sequence: 1)
    store.block_story(story['id'], blocked_on: 'waiting on Finance approval')

    result = TyrionWeb::Data.load_war_room_view(project_slug: 'wr-proj')
    card = result[:blocked].find { |s| s['slug'] == 'blocked-one' }
    expect(card['blocked_on']).to eq 'waiting on Finance approval'
  end
end

# Criteria progress: each story card carries met/total acceptance-criteria
# counts so the war room shows movement within a story, not just its status.
RSpec.describe 'TyrionWeb::Data.load_war_room_view — criteria progress' do
  let(:ctx)     { tyrion_worktree(project_slug: 'wr-proj', project_name: 'WR Test') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }
  let(:epic)    { store.create_epic(project_id: project['id'], slug: 'ep-a', name: 'Epic A') }

  before do
    TyrionWeb::Data.instance_variable_set(:@store, store)
    allow(TyrionWeb::Data).to receive(:resolve_active_epic).and_return(nil)
  end

  after { TyrionWeb::Data.instance_variable_set(:@store, nil) }

  it 'reports met/total criteria counts for a story that has criteria' do
    story = store.create_story(epic_id: epic['id'], slug: 'has-criteria', title: 'HC', sequence: 1)
    store.add_criteria(story['id'], [
      { keyword: 'Then', semantic_kind: 'then', text: 'a' },
      { keyword: 'Then', semantic_kind: 'then', text: 'b' }
    ])
    store.check_criterion(story['id'], 1, 'done')

    result = TyrionWeb::Data.load_war_room_view(project_slug: 'wr-proj')
    card = result[:queue].find { |s| s['slug'] == 'has-criteria' }
    expect(card['criteria_met']).to eq 1
    expect(card['criteria_total']).to eq 2
  end

  it 'reports zero total for a story with no criteria' do
    store.create_story(epic_id: epic['id'], slug: 'no-criteria', title: 'NC', sequence: 1)

    result = TyrionWeb::Data.load_war_room_view(project_slug: 'wr-proj')
    card = result[:queue].find { |s| s['slug'] == 'no-criteria' }
    expect(card['criteria_total']).to eq 0
  end
end
