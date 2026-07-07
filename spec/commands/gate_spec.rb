# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'tyrion gate' do
  let(:ctx)   { tyrion_worktree(epic_slug: 'my-epic') }
  let(:store) { ctx.store }
  let(:story) do
    store.create_story(epic_id: ctx.epic['id'], slug: 'test-story', title: 'Test Story')
    store.find_story(ctx.epic['id'], 'test-story')
  end

  before { story } # ensure the story row exists

  def gate_notes
    store.notes_for_story(story['id'], limit: 100).select { |n| n['kind'] == 'gate' }
  end

  describe 'cmd_gate' do
    it 'records a passing gate with a success line' do
      expect { Tyrion::Commands.cmd_gate(['test-story', 'pre-push', 'pass'], store) }
        .to output(/Gate recorded: pre-push PASS — test-story/).to_stdout
    end

    it 'records a failing gate with a success line' do
      expect { Tyrion::Commands.cmd_gate(['test-story', 'code-review', 'fail'], store) }
        .to output(/Gate recorded: code-review FAIL — test-story/).to_stdout
    end

    it 'writes a gate note whose body includes the detail suffix' do
      Tyrion::Commands.cmd_gate(['test-story', 'pre-push', 'pass', '--detail', 'all green'], store)
      expect(gate_notes.first['body']).to eq('pre-push: PASS — all green')
    end

    it 'omits the detail suffix when no --detail is given' do
      Tyrion::Commands.cmd_gate(['test-story', 'pre-push', 'pass'], store)
      expect(gate_notes.first['body']).to eq('pre-push: PASS')
    end

    it 'formats a failing body with FAIL' do
      Tyrion::Commands.cmd_gate(['test-story', 'uat', 'fail', '--detail', 'flow broke'], store)
      expect(gate_notes.first['body']).to eq('uat: FAIL — flow broke')
    end

    it 'stores metadata JSON with gate name, result, and detail' do
      Tyrion::Commands.cmd_gate(['test-story', 'uat', 'fail', '--detail', 'flow broke'], store)
      meta = JSON.parse(gate_notes.first['metadata'])
      expect(meta).to include('gate' => 'uat', 'result' => 'fail', 'detail' => 'flow broke')
    end

    it 'merges --meta JSON keys into the metadata' do
      Tyrion::Commands.cmd_gate(['test-story', 'codex-vet', 'pass', '--meta', '{"reviewer":"codex","score":9}'], store)
      meta = JSON.parse(gate_notes.first['metadata'])
      expect(meta).to include('gate' => 'codex-vet', 'result' => 'pass', 'reviewer' => 'codex', 'score' => 9)
    end

    it 'rejects a result other than pass or fail' do
      expect { Tyrion::Commands.cmd_gate(['test-story', 'pre-push', 'maybe'], store) }
        .to raise_error(SystemExit).and output(/pass\|fail/).to_stderr
    end

    it 'dies when the story is not found' do
      expect { Tyrion::Commands.cmd_gate(['no-such', 'pre-push', 'pass'], store) }
        .to raise_error(SystemExit).and output(/Story not found: no-such/).to_stderr
    end

    it 'shows a usage error when required args are missing' do
      expect { Tyrion::Commands.cmd_gate(['test-story'], store) }
        .to raise_error(SystemExit).and output(/Usage/).to_stderr
    end
  end

  describe 'GATES rendering in cmd_show' do
    it 'renders the latest result and run count per gate name' do
      Tyrion::Commands.cmd_gate(['test-story', 'pre-push', 'fail'], store)
      Tyrion::Commands.cmd_gate(['test-story', 'pre-push', 'pass'], store)
      Tyrion::Commands.cmd_gate(['test-story', 'code-review', 'fail'], store)

      out, = capture_io { Tyrion::Commands.cmd_show(['test-story'], store) }
      expect(out).to match(/Gates:/)
      expect(out).to match(/✓ pre-push \(2 runs\)/)
      expect(out).to match(/✗ code-review \(1 run\)/)
    end

    it 'renders a commit note body as-is in the gates section' do
      store.add_note(story['id'], 'commit', 'abc1234 feat: add thing')

      out, = capture_io { Tyrion::Commands.cmd_show(['test-story'], store) }
      expect(out).to match(/Gates:/)
      expect(out).to include('abc1234 feat: add thing')
    end

    it 'does not print a Gates section when there are no gate or commit notes' do
      out, = capture_io { Tyrion::Commands.cmd_show(['test-story'], store) }
      expect(out).not_to match(/Gates:/)
    end
  end

  describe 'GATES rendering in cmd_resume' do
    before { store.start_story(story['id']) }

    it 'renders the gates section for the resumed story' do
      Tyrion::Commands.cmd_gate(['test-story', 'pre-push', 'pass'], store)

      out, = capture_io { Tyrion::Commands.cmd_resume(['test-story'], store) }
      expect(out).to match(/Gates:/)
      expect(out).to match(/✓ pre-push \(1 run\)/)
    end

    it 'does not print a Gates section when there are no gate or commit notes' do
      out, = capture_io { Tyrion::Commands.cmd_resume(['test-story'], store) }
      expect(out).not_to match(/Gates:/)
    end
  end
end
