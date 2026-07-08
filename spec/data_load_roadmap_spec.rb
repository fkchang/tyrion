# frozen_string_literal: true

require 'spec_helper'
require_relative '../web/lib/tyrion_web/data'
require_relative '../web/lib/tyrion_web/presenter'

RSpec.describe 'TyrionWeb::Data.load_roadmap_view' do
  let(:ctx)     { tyrion_worktree(project_slug: 'rm-proj', project_name: 'RM Test') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }

  let(:epic_a) { store.create_epic(project_id: project['id'], slug: 'ep-a', name: 'Epic A') }
  let(:epic_b) { store.create_epic(project_id: project['id'], slug: 'ep-b', name: 'Epic B') }

  def make_story(epic_id:, slug:, status: 'pending', last_note_at: nil)
    s = store.create_story(epic_id: epic_id, slug: slug, title: slug)
    attrs = {}
    attrs['status']       = status       if status != 'pending'
    attrs['last_note_at'] = last_note_at if last_note_at
    store.update_story(s['id'], attrs) unless attrs.empty?
    s
  end

  before do
    TyrionWeb::Data.instance_variable_set(:@store, store)
    allow(TyrionWeb::Data).to receive(:resolve_active_epic).and_return(nil)
  end

  after { TyrionWeb::Data.instance_variable_set(:@store, nil) }

  subject(:result)   { TyrionWeb::Data.load_roadmap_view(project_slug: 'rm-proj') }
  let(:all_epics)    { result[:active_epics] + result[:archived_epics] }

  describe 'criterion 1: story_stats per epic' do
    before do
      make_story(epic_id: epic_a['id'], slug: 's1', status: 'done')
      make_story(epic_id: epic_a['id'], slug: 's2', status: 'in_progress')
      make_story(epic_id: epic_a['id'], slug: 's3', status: 'blocked')
      make_story(epic_id: epic_a['id'], slug: 's4', status: 'pending')
      make_story(epic_id: epic_b['id'], slug: 's5', status: 'done')
      make_story(epic_id: epic_b['id'], slug: 's6', status: 'done')
    end

    it 'includes :story_stats hash with all status counts for each epic entry' do
      ea = all_epics.find { |e| e['slug'] == 'ep-a' }
      expect(ea['story_stats']).to include(
        done: 1, in_progress: 1, blocked: 1, pending: 1, total: 4
      )
    end

    it 'counts correctly for a second epic' do
      eb = all_epics.find { |e| e['slug'] == 'ep-b' }
      expect(eb['story_stats']).to include(done: 2, in_progress: 0, blocked: 0, pending: 0, total: 2)
    end
  end

  describe 'criterion 2: max_last_note_at per epic' do
    let(:ts_old) { '2026-06-01T10:00:00Z' }
    let(:ts_new) { '2026-06-30T23:59:59Z' }

    before do
      make_story(epic_id: epic_a['id'], slug: 's1', last_note_at: ts_old)
      make_story(epic_id: epic_a['id'], slug: 's2', last_note_at: ts_new)
      make_story(epic_id: epic_b['id'], slug: 's3')
    end

    it 'sets max_last_note_at to the most recent story timestamp' do
      ea = all_epics.find { |e| e['slug'] == 'ep-a' }
      expect(ea['max_last_note_at']).to eq ts_new
    end

    it 'sets max_last_note_at to nil when no stories have last_note_at set' do
      eb = all_epics.find { |e| e['slug'] == 'ep-b' }
      expect(eb['max_last_note_at']).to be_nil
    end
  end

  describe 'criterion 3: active_epics / archived_epics split' do
    before { epic_a; epic_b }

    context 'when no epics have archived_at' do
      it 'puts all epics in active_epics and archived_epics is empty' do
        expect(result[:active_epics].map { |e| e['slug'] }).to contain_exactly('ep-a', 'ep-b')
        expect(result[:archived_epics]).to be_empty
      end
    end

    context 'when one epic has archived_at set' do
      # Direct SQL update until Store#archive_epic lands in epic-archive-store-cli
      before do
        store.send(:with_db) do |db|
          db.execute("UPDATE epics SET archived_at = '2026-07-01T00:00:00Z' WHERE slug = 'ep-b'")
        end
      end

      it 'routes the archived epic to archived_epics' do
        expect(result[:active_epics].map  { |e| e['slug'] }).to eq ['ep-a']
        expect(result[:archived_epics].map { |e| e['slug'] }).to eq ['ep-b']
      end
    end
  end
end
