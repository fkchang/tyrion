# frozen_string_literal: true

require 'spec_helper'
require_relative '../web/lib/tyrion_web/data'
require_relative '../web/lib/tyrion_web/presenter'

# global-view-discovery-momentum: card_status precedence between story activity
# and discovery activity. This is exactly the logic that silently misrepresented
# a spike-only project (zero epics, real discoveries) as :idle -- root cause of
# "crimson-maestro shows idle" (features/spike-visibility.context.md).
RSpec.describe 'TyrionWeb::Data.load_global_view' do
  let(:ctx)     { tyrion_worktree(project_slug: 'gv-proj', project_name: 'GV Test') }
  let(:store)   { ctx.store }
  let(:project) { ctx.project }

  before { TyrionWeb::Data.instance_variable_set(:@store, store) }
  after  { TyrionWeb::Data.instance_variable_set(:@store, nil) }

  def card_for(project)
    TyrionWeb::Data.load_global_view[:project_cards].find { |c| c[:project]['id'] == project['id'] }
  end

  describe 'a project with zero epics but open discoveries' do
    it 'reads :discovery, not :idle, when a mark is filed' do
      store.create_discovery(project_id: project['id'], question: 'noticed something', status: 'mark')

      card = card_for(project)
      expect(card[:status]).to eq :discovery
    end

    it 'reads :discovery when a spike is active' do
      store.create_discovery(project_id: project['id'], question: 'investigating', status: 'active_spike')

      expect(card_for(project)[:status]).to eq :discovery
    end

    it 'reads :discovery when a finding is ready to promote' do
      store.create_discovery(project_id: project['id'], question: 'q', finding: 'f', status: 'findings_ready')

      expect(card_for(project)[:status]).to eq :discovery
    end

    it 'carries the discovery summary counts on the card for the one-line render' do
      store.create_discovery(project_id: project['id'], question: 'q1', finding: 'f1', status: 'findings_ready')
      store.create_discovery(project_id: project['id'], question: 'q2', status: 'mark')
      store.create_discovery(project_id: project['id'], question: 'q3', status: 'mark')

      disc_summary = card_for(project)[:disc_summary]
      expect(disc_summary[:ready_count]).to eq 1
      expect(disc_summary[:mark_count]).to eq 2
    end
  end

  describe 'a project with real epic/story activity' do
    let(:epic) { store.create_epic(project_id: project['id'], slug: 'e1', name: 'E1') }

    it 'still reads :active as it does today, discoveries present or not' do
      story = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      store.start_story(story['id'], claimed_by: 'lane-1')
      store.create_discovery(project_id: project['id'], question: 'noise', status: 'mark')

      expect(card_for(project)[:status]).to eq :active
    end

    it 'still reads :done when every story is done, discoveries present or not' do
      story = store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')
      store.update_story(story['id'], status: 'done')
      store.create_discovery(project_id: project['id'], question: 'noise', status: 'active_spike')

      expect(card_for(project)[:status]).to eq :done
    end

    it 'still reads :idle for a pending-only epic with no discoveries, as it does today' do
      store.create_story(epic_id: epic['id'], slug: 's1', title: 'S1')

      expect(card_for(project)[:status]).to eq :idle
    end
  end

  describe 'a project with neither epic nor discovery activity' do
    it 'still reads :idle' do
      expect(card_for(project)[:status]).to eq :idle
    end
  end
end
