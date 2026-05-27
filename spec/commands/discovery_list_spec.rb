# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Tyrion::Commands.cmd_discovery_list' do
  let(:ctx) do
    tyrion_worktree(
      epic_slug:     'discovery-layer',
      git_branch:    'main',
      dirty_count:   0,
      last_commit:   'deadbeef',
      touched_files: []
    )
  end
  let(:store) { ctx.store }

  # Shared setup: three discoveries with different statuses
  let(:disc_mark) do
    store.create_discovery(
      project_id: ctx.project['id'],
      status:     'mark',
      question:   'Is this worth exploring?'
    )
  end
  let(:disc_spike) do
    store.create_discovery(
      project_id: ctx.project['id'],
      status:     'active_spike',
      question:   'Can we cache the results?'
    )
  end
  let(:disc_ready) do
    store.create_discovery(
      project_id:     ctx.project['id'],
      status:         'findings_ready',
      question:       'What is the optimal batch size?',
      finding:        'Batch size of 100 yields best throughput',
      confidence:     'high',
      recommendation: 'Use batch size 100 in production'
    )
  end

  # criterion 1 — --status ready returns only findings_ready discoveries
  context 'criterion 1 — --status ready filter returns only findings_ready discoveries' do
    before do
      disc_mark
      disc_spike
      disc_ready
    end

    it 'includes the findings_ready discovery id and excludes mark and active_spike ids' do
      out, = capture_io { Tyrion::Commands.cmd_discovery_list(['--status', 'ready'], store) }
      expect(out).to match(disc_ready['id'])
      expect(out).not_to match(disc_mark['id'])
      expect(out).not_to match(disc_spike['id'])
    end

    it 'shows the findings_ready status label and question text' do
      out, = capture_io { Tyrion::Commands.cmd_discovery_list(['--status', 'ready'], store) }
      expect(out).to match('findings_ready')
      expect(out).to match('What is the optimal batch size?')
    end
  end

  # criterion 2 — no filter shows all discoveries
  context 'criterion 2 — no --status filter shows all discoveries' do
    before do
      disc_mark
      disc_spike
      disc_ready
    end

    it 'includes all three discovery ids' do
      out, = capture_io { Tyrion::Commands.cmd_discovery_list([], store) }
      expect(out).to match(disc_mark['id'])
      expect(out).to match(disc_spike['id'])
      expect(out).to match(disc_ready['id'])
    end
  end

  # criterion 3 — discovery show displays full detail for findings_ready
  context 'criterion 3 — discovery show displays full detail for a findings_ready discovery' do
    it 'shows id, status, question, finding, confidence, and recommendation' do
      disc_id = disc_ready['id']
      out, = capture_io { Tyrion::Commands.cmd_discovery_show([disc_id], store) }
      expect(out).to match(disc_id)
      expect(out).to match('findings_ready')
      expect(out).to match('What is the optimal batch size?')
      expect(out).to match('Batch size of 100 yields best throughput')
      expect(out).to match('high')
      expect(out).to match('Use batch size 100 in production')
    end
  end

  # criterion 4 — discovery show exits 1 with error for unknown id
  context 'criterion 4 — discovery show exits 1 with error for unknown disc-id' do
    it 'raises SystemExit and prints disc-999 and not found to stderr' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_discovery_show(['disc-999'], store) }.to raise_error(SystemExit)
      end
      expect(err).to match('disc-999')
      expect(err).to match('not found')
    end
  end

  # criterion 5 — invalid --status alias exits 1 with valid aliases listed
  context 'criterion 5 — invalid --status alias exits 1 and lists valid aliases' do
    it 'raises SystemExit and prints the bogus alias plus all valid aliases to stderr' do
      _out, err = capture_io do
        expect do
          Tyrion::Commands.cmd_discovery_list(['--status', 'bogus'], store)
        end.to raise_error(SystemExit)
      end
      expect(err).to match('bogus')
      expect(err).to match('active')
      expect(err).to match('ready')
      expect(err).to match('promoted')
      expect(err).to match('deferred')
      expect(err).to match('all')
    end
  end

  # criterion 6 — dispatch unknown subcommand exits 1 with usage hint
  context 'criterion 6 — dispatching unknown discovery subcommand exits 1 with usage hint' do
    it 'raises SystemExit and prints tyrion discovery to stderr' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_discovery(['bogus'], store) }.to raise_error(SystemExit)
      end
      expect(err).to match('tyrion discovery')
    end
  end
end
