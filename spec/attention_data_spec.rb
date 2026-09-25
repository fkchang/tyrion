# frozen_string_literal: true

require 'spec_helper'
require 'phlex'
require_relative '../web/lib/tyrion_web/data'
require_relative '../web/lib/tyrion_web/presenter'
Dir.glob(File.expand_path('../web/views/**/*.rb', __dir__)).sort.each { |f| require f }

# fleet-visibility/tyrion-attention: the web "Needs your attention" view is a
# thin wrapper over the exact same Tyrion::Attention fold `tyrion attention
# --json` calls -- never re-derived here.
RSpec.describe 'TyrionWeb::Data.load_attention_view and Views::Attention' do
  let(:ctx)     { tyrion_worktree(project_slug: 'at-proj', project_name: 'AT Test', epic_slug: 'stalled-epic', epic_name: 'Stalled Epic') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }
  let(:epic)    { ctx.epic }

  before do
    allow(TyrionWeb::Data).to receive(:store).and_return(store)
    Tyrion::Liveness::Snapshot.reset!
  end
  after { Tyrion::Liveness::Snapshot.reset! }

  def backdate_epic(epic_id, days_ago)
    t = (Time.now.utc - (days_ago * 86_400)).iso8601(6)
    store.send(:with_db) do |db|
      db.execute(
        'UPDATE stories SET updated_at = ?, completed_at = CASE WHEN completed_at IS NOT NULL THEN ? ELSE completed_at END WHERE epic_id = ?',
        [t, t, epic_id]
      )
    end
  end

  describe '.load_attention_view' do
    it 'delegates to Tyrion::Attention.build over Tyrion::Attention.gather and the current snapshot' do
      s1 = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      store.create_story(epic_id: epic['id'], slug: 's2', title: 'S2')
      store.complete_story(s1['id'], 'done')
      backdate_epic(epic['id'], 10)

      report = TyrionWeb::Data.load_attention_view
      row = report['epics'].find { |e| e['epic_slug'] == 'stalled-epic' }
      expect(row['category']).to eq 'stalled'
      expect(row['idle_days']).to eq 10
    end

    it 'threads stale_days and project_slug through to the fold' do
      store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      store.update_epic(epic['id'], 'status' => 'paused')

      scoped_out = TyrionWeb::Data.load_attention_view(project_slug: 'nonexistent')
      expect(scoped_out['epics']).to eq []

      scoped_in = TyrionWeb::Data.load_attention_view(project_slug: 'at-proj')
      expect(scoped_in['epics'].map { |e| e['epic_slug'] }).to include 'stalled-epic'
    end
  end

  describe '.attention_poll_token' do
    it 'changes when a fold-relevant field changes and stays stable otherwise' do
      store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      store.update_epic(epic['id'], 'status' => 'paused')

      report = TyrionWeb::Data.load_attention_view
      token_a = TyrionWeb::Data.attention_poll_token(report)
      token_b = TyrionWeb::Data.attention_poll_token(TyrionWeb::Data.load_attention_view)
      expect(token_b).to eq token_a

      store.block_story(store.find_story(epic['id'], 's1')['id'], blocked_on: 'new block')
      token_c = TyrionWeb::Data.attention_poll_token(TyrionWeb::Data.load_attention_view)
      expect(token_c).not_to eq token_a
    end
  end

  describe 'Views::Attention render' do
    it 'renders the Cold Open purpose line, the threshold, and each stalled epic' do
      s1 = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      store.create_story(epic_id: epic['id'], slug: 's2', title: 'S2')
      store.complete_story(s1['id'], 'done')
      backdate_epic(epic['id'], 10)

      report = TyrionWeb::Data.load_attention_view
      html = Views::Attention.new(
        report: report, project: project, epic: epic, stories: [], disc_summary: {}
      ).call

      expect(html).to include('Needs Your Attention')
      expect(html).to include('longer than 7 days')
      expect(html).to include('at-proj / stalled-epic')
      expect(html).to include('1/2 done')
    end

    it 'renders nothing for the STALLED section when there is nothing stalled' do
      store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      report = TyrionWeb::Data.load_attention_view
      html = Views::Attention.new(
        report: report, project: project, epic: epic, stories: [], disc_summary: {}
      ).call

      expect(html).not_to include('STALLED (')
    end
  end
end
