# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'tyrion reopen' do
  let(:ctx) do
    tyrion_worktree(
      project_slug: 'reopenproj',
      epic_slug:    'reopen-epic',
      git_branch:   'feature/reopen-status'
    )
  end
  let(:store)  { ctx.store }
  let(:epic)   { ctx.epic }

  before { allow(Tyrion::Commands).to receive(:current_lane_token).and_return('lane-A') }

  def make_story(slug: 'my-story', title: 'My Story', status: 'pending')
    story = store.create_story(epic_id: epic['id'], slug: slug, title: title)
    store.update_story(story['id'], 'status' => status) if status != 'pending'
    store.find_story(epic['id'], slug)
  end

  describe 'cmd_reopen' do
    context 'happy path — done story moves to in_progress' do
      before { make_story(status: 'done') }

      it 'prints Reopened: and the slug' do
        expect {
          Tyrion::Commands.cmd_reopen(['my-story', 'adversarial review found a real bug'], store)
        }.to output(/Reopened:.*my-story/).to_stdout
      end

      it 'sets status to in_progress' do
        capture_io { Tyrion::Commands.cmd_reopen(['my-story', 'found a bug'], store) }
        expect(store.find_story(epic['id'], 'my-story')['status']).to eq 'in_progress'
      end

      it 'records a lifecycle note with the reason and prior status' do
        capture_io { Tyrion::Commands.cmd_reopen(['my-story', 'found a bug'], store) }
        story = store.find_story(epic['id'], 'my-story')
        notes = store.notes_for_story(story['id']).select { |n| n['kind'] == 'recovery' }
        expect(notes.first['body']).to eq 'reopened: found a bug (was done)'
        meta = JSON.parse(notes.first['metadata'])
        expect(meta).to include('action' => 'reopen', 'reason' => 'found a bug', 'prior_status' => 'done')
      end

      it 'claims the story under the reopening lane, not left unclaimed' do
        capture_io { Tyrion::Commands.cmd_reopen(['my-story', 'found a bug'], store) }
        expect(store.find_story(epic['id'], 'my-story')['claimed_by']).to eq 'lane-A'
      end

      it 'clears completed_at/completed_by so the row does not claim to be both done and in_progress' do
        capture_io { Tyrion::Commands.cmd_reopen(['my-story', 'found a bug'], store) }
        story = store.find_story(epic['id'], 'my-story')
        expect(story['completed_at']).to be_nil
        expect(story['completed_by']).to be_nil
      end

      it 'does not show up as an unclaimed in_progress protocol violation' do
        capture_io { Tyrion::Commands.cmd_reopen(['my-story', 'found a bug'], store) }
        expect(store.violations_in_progress(epic['id'])).to be_empty
      end

      it 'leaves existing criterion evidence untouched' do
        story = store.find_story(epic['id'], 'my-story')
        store.add_criteria(story['id'], [{ keyword: 'Then', semantic_kind: 'then', text: 'it works' }])
        store.check_criterion(story['id'], 1, 'proof it worked')

        capture_io { Tyrion::Commands.cmd_reopen(['my-story', 'found a bug'], store) }

        criterion = store.criteria_for_story(story['id']).first
        expect(criterion['status']).to eq 'met'
        expect(criterion['evidence']).to eq 'proof it worked'
      end

      it 'reopens the epic if it had been sealed' do
        store.seal_epic(epic['id'])
        expect(store.find_epic_by_id(epic['id'])['status']).to eq 'done'

        capture_io { Tyrion::Commands.cmd_reopen(['my-story', 'found a bug'], store) }

        expect(store.find_epic_by_id(epic['id'])['status']).to eq 'active'
      end
    end

    context 'refuses a story that is not done' do
      before { make_story(status: 'pending') }

      it 'exits 1' do
        _out, err = capture_io do
          expect { Tyrion::Commands.cmd_reopen(['my-story', 'reason'], store) }.to raise_error(SystemExit)
        end
        expect(err).to match(/not done/i)
      end

      it 'leaves status as pending' do
        capture_io { expect { Tyrion::Commands.cmd_reopen(['my-story', 'reason'], store) }.to raise_error(SystemExit) }
        expect(store.find_story(epic['id'], 'my-story')['status']).to eq 'pending'
      end
    end

    context 'refuses an in_progress story' do
      before do
        story = make_story
        store.start_story(story['id'], claimed_by: 'lane-A')
      end

      it 'exits 1 with a clear message' do
        _out, err = capture_io do
          expect { Tyrion::Commands.cmd_reopen(['my-story', 'reason'], store) }.to raise_error(SystemExit)
        end
        expect(err).to match(/not done/i)
      end
    end

    context 'missing reason' do
      before { make_story(status: 'done') }

      it 'exits 1 with usage message' do
        _out, err = capture_io do
          expect { Tyrion::Commands.cmd_reopen(['my-story'], store) }.to raise_error(SystemExit)
        end
        expect(err).to match(/Usage:.*reopen/i)
      end
    end

    context '--help' do
      it 'prints usage instead of reopening on "--help" as the reason (disc-092 class)' do
        make_story(status: 'done')

        out, = capture_io { Tyrion::Commands.cmd_reopen(['my-story', '--help'], store) }

        expect(out).to eq("#{Tyrion::Commands::REOPEN_USAGE}\n")
        expect(store.find_story(epic['id'], 'my-story')['status']).to eq 'done'
      end
    end

    context 'story not found' do
      it 'exits 1' do
        _out, err = capture_io do
          expect { Tyrion::Commands.cmd_reopen(['nope', 'reason'], store) }.to raise_error(SystemExit)
        end
        expect(err).to match(/not found/i)
      end
    end

    context 'reopening collides with another story already in_progress under this lane' do
      before do
        done_story = make_story(slug: 'done-story', status: 'done')
        other = store.create_story(epic_id: epic['id'], slug: 'other-story', title: 'Other Story')
        store.start_story(other['id'], claimed_by: 'lane-A')
        done_story
      end

      it 'dies cleanly instead of raising a raw SQLite exception' do
        _out, err = capture_io do
          expect { Tyrion::Commands.cmd_reopen(['done-story', 'reason'], store) }.to raise_error(SystemExit)
        end
        expect(err).to match(/already in_progress/i)
      end

      it 'leaves done-story as done' do
        capture_io { expect { Tyrion::Commands.cmd_reopen(['done-story', 'reason'], store) }.to raise_error(SystemExit) }
        expect(store.find_story(epic['id'], 'done-story')['status']).to eq 'done'
      end
    end
  end

  describe 'full reopen -> fix -> re-verify -> seal cycle' do
    it 'closes cleanly a second time via the real CLI commands after reopen and re-check' do
      story = make_story(status: 'pending')
      store.add_criteria(story['id'], [{ keyword: 'Then', semantic_kind: 'then', text: 'it works' }])

      store.start_story(story['id'], claimed_by: 'lane-A')
      capture_io { Tyrion::Commands.cmd_check(['my-story', '1', 'first pass evidence'], store) }
      capture_io { Tyrion::Commands.cmd_done(['my-story', 'first close'], store) }
      first_close = store.find_story(epic['id'], 'my-story')
      expect(first_close['status']).to eq 'done'
      expect(first_close['completed_by']).to eq 'lane-A'

      capture_io { Tyrion::Commands.cmd_reopen(['my-story', 'adversarial pass found a gap'], store) }
      reopened = store.find_story(epic['id'], 'my-story')
      expect(reopened['status']).to eq 'in_progress'
      expect(reopened['claimed_by']).to eq 'lane-A'

      capture_io { Tyrion::Commands.cmd_uncheck(['my-story', '1'], store) }
      expect(store.criteria_for_story(story['id']).first['status']).to eq 'pending'

      capture_io { Tyrion::Commands.cmd_check(['my-story', '1', 'fixed and re-verified with real evidence'], store) }
      capture_io { Tyrion::Commands.cmd_done(['my-story', 'second close, rework verified'], store) }

      final = store.find_story(epic['id'], 'my-story')
      expect(final['status']).to eq 'done'
      # completed_by survives the reopen round-trip via the same lane that reopened it.
      expect(final['completed_by']).to eq 'lane-A'
    end
  end
end
