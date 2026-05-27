# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'tyrion spike start' do
  let(:ctx) do
    tyrion_worktree(
      git_branch:    'feature/scan-worker',
      dirty_count:   3,
      last_commit:   'cafebabe',
      touched_files: ['lib/tyrion/store.rb', 'lib/tyrion/commands.rb']
    )
  end
  let(:store) { ctx.store }

  # Criterion 1 — happy path
  describe 'happy path' do
    it 'persists the spike with correct fields and prints active_spike id' do
      input  = StringIO.new("Yes, if two workers read\nReproducing test case showing duplicates\n")
      output = StringIO.new

      Tyrion::Commands.cmd_spike_start(
        ['Can concurrent writes cause scan duplication?'],
        store,
        input: input,
        output: output
      )

      out = output.string
      expect(out).to match(/\[active_spike\] disc-\d+/)

      disc_id = out.match(/\[active_spike\] (disc-\d+)/)[1]
      disc = store.find_discovery(disc_id)
      expect(disc).not_to be_nil

      expect(disc['status']).to eq 'active_spike'
      expect(disc['question']).to eq 'Can concurrent writes cause scan duplication?'
      expect(disc['hypothesis']).to eq 'Yes, if two workers read'
      expect(disc['exit_criteria']).to eq 'Reproducing test case showing duplicates'

      git_ctx = JSON.parse(disc['git_context'])
      expect(git_ctx['branch']).to eq 'feature/scan-worker'
      expect(git_ctx['dirty_files']).to eq 3
      expect(git_ctx['last_commit']).to eq 'cafebabe'
      expect(git_ctx['touched_files']).to eq ['lib/tyrion/store.rb', 'lib/tyrion/commands.rb']
    end
  end

  # Criterion 2 — one active spike enforced
  describe 'one active spike enforced' do
    it 'exits with an error referencing the existing spike when one is already active' do
      existing = store.create_discovery(
        project_id: ctx.project['id'],
        status:     'active_spike',
        question:   'existing question about concurrency'
      )

      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_spike_start(['another question'], store) }.to raise_error(SystemExit)
      end

      expect(err).to match(/#{existing['id']}/)
      expect(err).to match(/existing question about concurrency/)

      # No new row created — still only 1 active_spike
      spikes = store.list_discoveries(project_id: ctx.project['id'], status: 'active_spike')
      expect(spikes.length).to eq 1
    end
  end

  # Criterion 3 — blank inputs store nil
  describe 'blank inputs' do
    it 'stores nil for hypothesis and exit_criteria when inputs are blank' do
      input  = StringIO.new("\n\n")
      output = StringIO.new

      Tyrion::Commands.cmd_spike_start(
        ['question'],
        store,
        input: input,
        output: output
      )

      out = output.string
      expect(out).to match(/\[active_spike\] disc-\d+/)

      disc_id = out.match(/\[active_spike\] (disc-\d+)/)[1]
      disc = store.find_discovery(disc_id)
      expect(disc).not_to be_nil

      expect(disc['status']).to eq 'active_spike'
      expect(disc['question']).to eq 'question'
      expect(disc['hypothesis']).to be_nil
      expect(disc['exit_criteria']).to be_nil
    end
  end
end
