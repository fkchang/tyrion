# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Tyrion::Commands.cmd_spike_done' do
  let(:ctx) do
    tyrion_worktree(git_branch: 'feature/scan-worker')
  end
  let(:store) { ctx.store }

  before do
    store.create_discovery(
      project_id: ctx.project['id'],
      status:     'active_spike',
      question:   'Can concurrent writes cause scan duplication?'
    )
  end

  context 'criterion 1 — active_spike exists, valid inputs provided' do
    let(:output) { StringIO.new }

    before do
      input = StringIO.new("Concurrent writes do cause duplication\nhigh\nUse a mutex\n")
      Tyrion::Commands.cmd_spike_done([], store, input: input, output: output)
    end

    let(:disc_id) { output.string[/\[findings_ready\] (disc-\d+)/, 1] }

    it 'prints [findings_ready] disc-NNN' do
      expect(output.string).to match(/\[findings_ready\] disc-\d+/)
    end

    it 'updates the discovery to findings_ready with correct fields' do
      disc = store.find_discovery(disc_id)
      expect(disc).not_to be_nil
      expect(disc['status']).to eq 'findings_ready'
      expect(disc['finding']).to eq 'Concurrent writes do cause duplication'
      expect(disc['confidence']).to eq 'high'
      expect(disc['recommendation']).to eq 'Use a mutex'
    end
  end

  context 'criterion 2 — no active_spike exists for the active project' do
    let(:other) { store.create_project(slug: 'other', name: 'Other') }

    before do
      other
      stub_repo(active_project: 'other', active_epic: nil)
    end

    it 'exits with an error message indicating no active spike and creates no findings_ready row' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_spike_done([], store) }.to raise_error(SystemExit)
      end
      expect(err).to match(/[Nn]o active spike/)
      expect(store.list_discoveries(project_id: ctx.project['id'], status: 'findings_ready')).to eq []
    end
  end

  context 'criterion 4 — closed with --verdict' do
    let(:output) { StringIO.new }

    before do
      input = StringIO.new("finding text\nhigh\nrec text\n")
      Tyrion::Commands.cmd_spike_done(['--verdict', 'falsified_alternative'], store, input: input, output: output)
    end

    let(:disc_id) { output.string[/\[findings_ready\] (disc-\d+)/, 1] }

    it 'stores the verdict independent of status' do
      disc = store.find_discovery(disc_id)
      expect(disc['status']).to eq 'findings_ready'
      expect(disc['verdict']).to eq 'falsified_alternative'
    end
  end

  context 'criterion 4 — closed without --verdict' do
    let(:output) { StringIO.new }

    before do
      input = StringIO.new("finding text\nhigh\nrec text\n")
      Tyrion::Commands.cmd_spike_done([], store, input: input, output: output)
    end

    let(:disc_id) { output.string[/\[findings_ready\] (disc-\d+)/, 1] }

    it 'leaves verdict nil rather than defaulting to confirmed' do
      disc = store.find_discovery(disc_id)
      expect(disc['verdict']).to be_nil
    end
  end

  context 'criterion 4 — invalid --verdict value' do
    it 'exits with an error and does not close the spike' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_spike_done(['--verdict', 'bogus'], store) }.to raise_error(SystemExit)
      end
      expect(err).to match(/[Uu]nknown verdict/)
      expect(store.active_spike_for(ctx.project['id'])).not_to be_nil
    end
  end

  context 'criterion 3 — invalid confidence values are re-prompted until valid' do
    let(:output) { StringIO.new }

    before do
      input = StringIO.new("finding text\nbadvalue\nalsobad\nmedium\nrec text\n")
      Tyrion::Commands.cmd_spike_done([], store, input: input, output: output)
    end

    let(:disc_id) { output.string[/\[findings_ready\] (disc-\d+)/, 1] }

    it 'prints [findings_ready] disc-NNN after accepting valid confidence' do
      expect(output.string).to match(/\[findings_ready\] disc-\d+/)
    end

    it 'stores the valid confidence and other fields correctly' do
      disc = store.find_discovery(disc_id)
      expect(disc).not_to be_nil
      expect(disc['status']).to eq 'findings_ready'
      expect(disc['confidence']).to eq 'medium'
      expect(disc['finding']).to eq 'finding text'
      expect(disc['recommendation']).to eq 'rec text'
    end
  end
end
