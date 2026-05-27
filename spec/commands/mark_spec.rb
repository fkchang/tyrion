# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'tyrion mark' do
  let(:ctx)   { tyrion_worktree(git_branch: 'feature/test-branch', dirty_count: 3, last_commit: 'abc1234') }
  let(:store) { ctx.store }

  describe 'happy path' do
    it 'prints a disc-id and persists the discovery with correct fields' do
      out, = capture_io do
        Tyrion::Commands.cmd_mark(['test description'], store)
      end

      expect(out).to match(/\[mark\] disc-\d+/)

      disc_id = out.match(/\[mark\] (disc-\d+)/)[1]
      disc = store.find_discovery(disc_id)
      expect(disc).not_to be_nil

      expect(disc['status']).to eq 'mark'
      expect(disc['question']).to eq 'test description'

      git_ctx = JSON.parse(disc['git_context'])
      expect(git_ctx['branch']).to eq 'feature/test-branch'
      expect(git_ctx['dirty_files']).to eq 3
      expect(git_ctx['last_commit']).to eq 'abc1234'
    end
  end

  describe 'unique ids' do
    it 'assigns a different disc-id for each call' do
      out1, = capture_io { Tyrion::Commands.cmd_mark(['first'], store) }
      out2, = capture_io { Tyrion::Commands.cmd_mark(['second'], store) }

      id1 = out1.match(/\[mark\] (disc-\d+)/)[1]
      id2 = out2.match(/\[mark\] (disc-\d+)/)[1]

      expect(id1).not_to eq id2
    end
  end

  context 'when no active project is set' do
    before do
      ctx  # materialise worktree stubs first
      stub_repo(active_project: nil)
    end

    it 'prints an error and creates no discoveries' do
      expect { Tyrion::Commands.cmd_mark(['anything'], store) }.to output(/no active project/i).to_stdout
      expect(store.list_discoveries(project_id: ctx.project['id'])).to be_empty
    end
  end
end
