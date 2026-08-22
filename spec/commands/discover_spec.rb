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

  describe '--help' do
    it 'prints usage, prompts for nothing, and creates no discovery' do
      output = StringIO.new

      Tyrion::Commands.cmd_discover(['--help'], store, input: StringIO.new, output: output)

      expect(output.string).to eq("#{Tyrion::Commands::DISCOVER_USAGE}\n")
      expect(store.list_discoveries(project_id: ctx.project['id'])).to be_empty
    end

    it 'also recognizes -h, including when a disc-id would otherwise be read as positional' do
      output = StringIO.new

      Tyrion::Commands.cmd_discover(['-h'], store, input: StringIO.new, output: output)

      expect(output.string).to eq("#{Tyrion::Commands::DISCOVER_USAGE}\n")
    end
  end

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

  describe 'non-interactive mark upgrade' do
    # A closed stdin proves the flagged form never prompts — any prompt() call
    # would raise IOError rather than silently reading nil.
    let(:no_input) { StringIO.new('').tap(&:close) }

    def mark(desc = 'the N+1 on project list')
      out, = capture_io { Tyrion::Commands.cmd_mark([desc], store) }
      out[/\[mark\] (disc-\d+)/, 1]
    end

    it 'upgrades the mark in place with question and finding, printing findings_ready' do
      id     = mark
      output = StringIO.new
      Tyrion::Commands.cmd_discover([id, '--question', 'why is list slow?', '--finding', 'missing index'],
                                    store, input: no_input, output: output)

      expect(output.string).to eq "[findings_ready] #{id}\n"
      disc = store.find_discovery(id)
      expect(disc['status']).to eq 'findings_ready'
      expect(disc['question']).to eq 'why is list slow?'
      expect(disc['finding']).to eq 'missing index'
    end

    it 'keeps the original question when --question is omitted' do
      id = mark('the N+1 on project list')
      Tyrion::Commands.cmd_discover([id, '--finding', 'missing index'],
                                    store, input: no_input, output: StringIO.new)

      disc = store.find_discovery(id)
      expect(disc['question']).to eq 'the N+1 on project list'
      expect(disc['finding']).to eq 'missing index'
    end

    it 'records origin=agent with --auto and preserves the stored origin without it' do
      auto_id = mark('agent-filed')
      Tyrion::Commands.cmd_discover([auto_id, '--finding', 'f', '--auto'],
                                    store, input: no_input, output: StringIO.new)
      expect(store.find_discovery(auto_id)['origin']).to eq 'agent'

      human_id = mark('human-filed')
      Tyrion::Commands.cmd_discover([human_id, '--finding', 'f'],
                                    store, input: no_input, output: StringIO.new)
      expect(store.find_discovery(human_id)['origin']).to eq 'human'
    end

    it 'refuses a discovery that is not a mark, naming its current status' do
      id = mark
      Tyrion::Commands.cmd_discover([id, '--finding', 'first'], store, input: no_input, output: StringIO.new)

      expect { Tyrion::Commands.cmd_discover([id, '--finding', 'again'], store, input: no_input) }
        .to raise_error(SystemExit).and output(/findings_ready/).to_stderr
      expect(store.find_discovery(id)['finding']).to eq 'first'
    end

    it 'exits with not found for an unknown disc-id' do
      expect { Tyrion::Commands.cmd_discover(['disc-999', '--finding', 'f'], store, input: no_input) }
        .to raise_error(SystemExit).and output(/not found/).to_stderr
    end

    it 'exits with not found for a mark belonging to another project' do
      other  = store.create_project(slug: 'other-proj', name: 'Other')
      foreign = store.create_discovery(project_id: other['id'], status: 'mark', question: 'theirs')

      expect { Tyrion::Commands.cmd_discover([foreign['id'], '--finding', 'f'], store, input: no_input) }
        .to raise_error(SystemExit).and output(/not found/).to_stderr
      expect(store.find_discovery(foreign['id'])['status']).to eq 'mark'
    end

    it 'requires --finding' do
      id = mark
      expect { Tyrion::Commands.cmd_discover([id, '--question', 'q'], store, input: no_input) }
        .to raise_error(SystemExit).and output(/Usage: tyrion discover <disc-id> --finding/).to_stderr
      expect(store.find_discovery(id)['status']).to eq 'mark'
    end

    it 'still runs the interactive path for a bare --auto with no id' do
      input  = StringIO.new("q\nf\nlater\n")
      output = StringIO.new
      Tyrion::Commands.cmd_discover(['--auto'], store, input: input, output: output)

      disc_id = output.string[/\[findings_ready\] (disc-\d+)/, 1]
      expect(store.find_discovery(disc_id)['origin']).to eq 'agent'
      expect(store.find_discovery(disc_id)['question']).to eq 'q'
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
