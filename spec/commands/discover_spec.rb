# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'tyrion discover' do
  let(:ctx) do
    tyrion_worktree(
      git_branch:    'feature/auth-flow',
      dirty_count:   2,
      last_commit:   'deadbeef',
      touched_files: ['lib/tyrion/commands.rb', 'lib/tyrion/repo.rb']
    )
  end
  let(:store) { ctx.store }

  describe 'happy path' do
    it 'persists the discovery with correct fields and prints findings_ready' do
      input  = StringIO.new("testing authentication flow\nJWT expiry not refreshed on activity\nlater\n")
      output = StringIO.new
      Tyrion::Commands.cmd_discover([], store, input: input, output: output)
      out = output.string

      expect(out).to match(/\[findings_ready\] disc-\d+/)

      disc_id = out.match(/\[findings_ready\] (disc-\d+)/)[1]
      disc = store.find_discovery(disc_id)
      expect(disc).not_to be_nil

      expect(disc['status']).to eq 'findings_ready'
      expect(disc['question']).to eq 'testing authentication flow'
      expect(disc['finding']).to eq 'JWT expiry not refreshed on activity'

      git_ctx = JSON.parse(disc['git_context'])
      expect(git_ctx['branch']).to eq 'feature/auth-flow'
      expect(git_ctx['dirty_files']).to eq 2
      expect(git_ctx['last_commit']).to eq 'deadbeef'
      expect(git_ctx['touched_files']).to eq ['lib/tyrion/commands.rb', 'lib/tyrion/repo.rb']
    end
  end

  context 'when no active project is set' do
    before do
      ctx  # materialise worktree stubs first
      stub_repo(active_project: nil)
    end

    it 'exits and creates no discoveries' do
      expect { Tyrion::Commands.cmd_discover([], store) }.to raise_error(SystemExit)
      expect(store.list_discoveries(project_id: ctx.project['id'])).to be_empty
    end
  end

  describe 'promote hint' do
    it 'prints the promote hint when user answers y' do
      input  = StringIO.new("what am I building?\nfound the answer\ny\n")
      output = StringIO.new
      Tyrion::Commands.cmd_discover([], store, input: input, output: output)
      out = output.string

      disc_id = out.match(/\[findings_ready\] (disc-\d+)/)[1]
      expect(out).to match(/tyrion spike promote #{disc_id}/)
    end

    it 'does not print the promote hint when user answers later' do
      input  = StringIO.new("exploring\nfound something\nlater\n")
      output = StringIO.new
      Tyrion::Commands.cmd_discover([], store, input: input, output: output)
      out = output.string

      expect(out).not_to match(/tyrion spike promote/)
    end
  end
end
