# frozen_string_literal: true

require 'spec_helper'
require_relative '../web/lib/tyrion_web/data'

# Criteria 7-9 (multitab-url-scoping): an explicit epic_slug: pins the Active
# Story view to that exact epic's in_progress story only — it must never fall
# back to a sibling epic's in_progress story, since that's how a browser tab
# would appear to jump out from under the developer looking at it.
RSpec.describe 'TyrionWeb::Data.load_active_story_view — epic_slug scoping' do
  let(:ctx)     { tyrion_worktree(project_slug: 'as-proj', project_name: 'AS Test') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }
  let(:epic_a)  { store.create_epic(project_id: project['id'], slug: 'ep-a', name: 'Epic A') }
  let(:epic_b)  { store.create_epic(project_id: project['id'], slug: 'ep-b', name: 'Epic B') }

  before { TyrionWeb::Data.instance_variable_set(:@store, store) }
  after  { TyrionWeb::Data.instance_variable_set(:@store, nil) }

  context 'with an explicit epic_slug and no in_progress story in that epic' do
    before do
      # in_progress story only exists in the sibling epic B
      s = store.create_story(epic_id: epic_b['id'], slug: 'b-one', title: 'B1', sequence: 1)
      store.start_story(s['id'], claimed_by: 'claude:111:a')
      epic_a # ensure epic A exists (empty)
    end

    it 'returns story: nil and does not auto-jump to a sibling epic\'s in_progress story' do
      result = TyrionWeb::Data.load_active_story_view(project_slug: 'as-proj', epic_slug: 'ep-a')
      expect(result[:story]).to be_nil
      expect(result[:epic]['slug']).to eq 'ep-a'
    end
  end

  context 'without epic_slug (fallback across epics)' do
    before do
      epic_a # ensure epic A exists (empty)
      s = store.create_story(epic_id: epic_b['id'], slug: 'b-one', title: 'B1', sequence: 1)
      store.start_story(s['id'], claimed_by: 'claude:111:a')
      allow(TyrionWeb::Data).to receive(:resolve_active_epic).and_return(epic_a)
    end

    it 'still finds the in_progress story via the cross-epic fallback loop' do
      result = TyrionWeb::Data.load_active_story_view(project_slug: 'as-proj')
      expect(result[:story]['slug']).to eq 'b-one'
      expect(result[:epic]['slug']).to eq 'ep-b'
    end
  end
end
