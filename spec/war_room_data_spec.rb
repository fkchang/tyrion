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
