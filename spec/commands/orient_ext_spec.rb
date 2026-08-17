# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Tyrion::Commands.cmd_status — discovery section' do
  let(:ctx) do
    tyrion_worktree(
      project_slug: 'oriproj',
      project_name: 'Orient Project',
      epic_slug:    'ori-epic',
      epic_name:    'Orient Epic'
    )
  end
  let(:store)   { ctx.store }
  let(:project) { ctx.project }

  context 'criterion 1 — active_spike discovery shows in DISCOVERIES section' do
    it 'includes DISCOVERIES heading, discovery id, and question text' do
      disc = store.create_discovery(
        project_id: project['id'],
        status:     'active_spike',
        question:   'Can cache be shared?'
      )

      out, = capture_io { Tyrion::Commands.cmd_status([], store) }

      expect(out).to include('DISCOVERIES')
      expect(out).to include(disc['id'])
      expect(out).to include('Can cache be shared?')
    end
  end

  context 'criterion 2 — findings_ready discovery shows tyrion spike promote hint' do
    it 'includes the discovery id and the promote command hint' do
      disc = store.create_discovery(
        project_id: project['id'],
        status:     'findings_ready',
        question:   'Is Redis faster than memcached?'
      )

      out, = capture_io { Tyrion::Commands.cmd_status([], store) }

      expect(out).to include(disc['id'])
      expect(out).to include("tyrion spike promote #{disc['id']}")
    end
  end

  context 'criterion 3 — mark discoveries show their text in status output' do
    it 'lists both mark questions when two mark discoveries exist' do
      2.times do |i|
        store.create_discovery(
          project_id: project['id'],
          status:     'mark',
          question:   "Mark note #{i}"
        )
      end

      out, = capture_io { Tyrion::Commands.cmd_status([], store) }

      expect(out).to include('Mark note 0').and include('Mark note 1')
    end
  end

  context 'criterion 4 — no discoveries means DISCOVERIES section is absent' do
    it 'does not include DISCOVERIES when project has no discoveries' do
      out, = capture_io { Tyrion::Commands.cmd_status([], store) }

      expect(out).not_to include('DISCOVERIES')
    end
  end

  context 'criterion 5 — mixed discovery types all render in status output' do
    it 'shows all discovery ids, questions, promote hint, and mark text' do
      spike_disc = store.create_discovery(
        project_id: project['id'],
        status:     'active_spike',
        question:   'Q1?'
      )
      findings_disc = store.create_discovery(
        project_id: project['id'],
        status:     'findings_ready',
        question:   'Q2?'
      )
      2.times do |i|
        store.create_discovery(
          project_id: project['id'],
          status:     'mark',
          question:   "Mark #{i}"
        )
      end

      out, = capture_io { Tyrion::Commands.cmd_status([], store) }

      expect(out).to include('DISCOVERIES')
      expect(out).to include(spike_disc['id'])
      expect(out).to include('Q1?')
      expect(out).to include(findings_disc['id'])
      expect(out).to include("tyrion spike promote #{findings_disc['id']}")
      expect(out).to include('Mark 0').and include('Mark 1')
    end
  end
end
