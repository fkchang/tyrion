# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Tyrion::Commands.cmd_spike_promote' do
  let(:ctx) do
    tyrion_worktree(
      epic_slug:  'discovery-layer',
      git_branch: 'feature/spike-promote'
    )
  end
  let(:store) { ctx.store }

  context 'criterion 1 — findings_ready discovery exists, title provided' do
    let(:output) { StringIO.new }
    let(:disc_id) do
      disc = store.create_discovery(
        project_id:     ctx.project['id'],
        status:         'findings_ready',
        question:       'Q?',
        recommendation: 'Use mutex',
        finding:        'Concurrent writes conflict'
      )
      disc['id']
    end

    before do
      input = StringIO.new("Concurrent Write Safety\n")
      Tyrion::Commands.cmd_spike_promote([disc_id], store, input: input, output: output)
    end

    it "prints '[promoted] <slug> <- disc-NNN'" do
      expect(output.string).to match(/\[promoted\] \S+ <- #{Regexp.escape(disc_id)}/)
    end

    it "includes 'tyrion criteria add' in output" do
      expect(output.string).to include('tyrion criteria add')
    end

    it 'includes the finding text in output' do
      expect(output.string).to include('Concurrent writes conflict')
    end

    it "updates discovery status to 'promoted_to_story'" do
      expect(store.find_discovery(disc_id)['status']).to eq 'promoted_to_story'
    end

    it 'creates a story with correct born_from_discovery, title, and intent' do
      slug = output.string.match(/\[promoted\] (\S+) <-/)[1]
      story = store.find_story(ctx.epic['id'], slug)
      expect(story).not_to be_nil
      expect(story['born_from_discovery']).to eq disc_id
      expect(story['title']).to eq 'Concurrent Write Safety'
      expect(story['intent']).to include('Use mutex')
    end
  end

  context 'criterion 2 — blank title input defaults to discovery question' do
    let(:output) { StringIO.new }
    let(:disc_id) do
      disc = store.create_discovery(
        project_id:     ctx.project['id'],
        status:         'findings_ready',
        question:       'What causes the duplication?',
        recommendation: 'Some rec'
      )
      disc['id']
    end

    before do
      input = StringIO.new("\n")
      Tyrion::Commands.cmd_spike_promote([disc_id], store, input: input, output: output)
    end

    it "prints '[promoted] <slug> <- disc-NNN'" do
      expect(output.string).to match(/\[promoted\] \S+ <- disc-\d+/)
    end

    it 'creates a story whose title equals the discovery question' do
      slug = output.string.match(/\[promoted\] (\S+) <-/)[1]
      story = store.find_story(ctx.epic['id'], slug)
      expect(story).not_to be_nil
      expect(story['title']).to eq 'What causes the duplication?'
    end
  end

  context "criterion 3 — discovery status is 'active_spike' (not findings_ready)" do
    let(:disc_id) do
      disc = store.create_discovery(
        project_id: ctx.project['id'],
        status:     'active_spike',
        question:   'some question'
      )
      disc['id']
    end

    it 'exits 1 with an error containing the disc-id and findings_ready' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_spike_promote([disc_id], store) }.to raise_error(SystemExit)
      end
      expect(err).to match(/#{Regexp.escape(disc_id)}/)
      expect(err).to include('findings_ready')
    end

    it 'creates no story in the active epic' do
      capture_io { expect { Tyrion::Commands.cmd_spike_promote([disc_id], store) }.to raise_error(SystemExit) }
      expect(store.stories_for_epic(ctx.epic['id'])).to be_empty
    end
  end

  context 'criterion 4 — disc-id does not exist in the DB' do
    it 'exits 1 with stderr containing disc-999 and not found' do
      _out, err = capture_io do
        expect { Tyrion::Commands.cmd_spike_promote(['disc-999'], store) }.to raise_error(SystemExit)
      end
      expect(err).to include('disc-999')
      expect(err).to match(/not found/i)
    end

    it 'creates no story in the active epic' do
      capture_io { expect { Tyrion::Commands.cmd_spike_promote(['disc-999'], store) }.to raise_error(SystemExit) }
      expect(store.stories_for_epic(ctx.epic['id'])).to be_empty
    end
  end
end
