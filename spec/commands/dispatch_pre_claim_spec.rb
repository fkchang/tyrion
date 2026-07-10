# frozen_string_literal: true

require 'spec_helper'

# Specs for `tyrion claim <slug> --as <label>` (dispatch-pre-claim story).
# A lead pre-claims a story for a lane that does not exist yet; the placeholder
# is claimed_by="assigned:<label>" and the story stays pending. When an agent
# starts with TYRION_LANE=<label>, rung 3 of resolve_my_story adopts it and
# re-stamps claimed_by to the real lane token (rung 3 itself is covered in
# story_resolver_spec; here we prove the pre-claim → adoption path end to end).

RSpec.describe 'tyrion claim <slug> --as <label> (dispatch-pre-claim)' do
  let(:ctx) do
    tyrion_worktree(
      project_slug: 'preclaimproj',
      epic_slug:    'preclaim-epic',
      git_branch:   'feature/dispatch-pre-claim'
    )
  end
  let(:store) { ctx.store }
  let(:epic)  { ctx.epic }

  def make_story(slug:, title: slug)
    store.create_story(epic_id: epic['id'], slug: slug, title: title)
    store.find_story(epic['id'], slug)
  end

  describe 'cmd_claim' do
    it 'writes claimed_by="assigned:<label>" without changing status' do
      make_story(slug: 'work-me')

      expect { Tyrion::Commands.cmd_claim(['work-me', '--as', 'lane1'], store) }
        .to output(/assigned:lane1/).to_stdout

      story = store.find_story(epic['id'], 'work-me')
      expect(story['claimed_by']).to eq 'assigned:lane1'
      expect(story['status']).to eq 'pending'
    end

    it 'dies with usage when no --as label is given' do
      make_story(slug: 'work-me')
      expect { Tyrion::Commands.cmd_claim(['work-me'], store) }
        .to raise_error(SystemExit).and output(/Usage: tyrion claim/).to_stderr
    end

    it 'dies with usage when no slug is given' do
      expect { Tyrion::Commands.cmd_claim(['--as', 'lane1'], store) }
        .to raise_error(SystemExit).and output(/Usage: tyrion claim/).to_stderr
    end

    it 'dies when the story is not found' do
      expect { Tyrion::Commands.cmd_claim(['nope', '--as', 'lane1'], store) }
        .to raise_error(SystemExit).and output(/not found/).to_stderr
    end

    it 'dies when the story is not pending' do
      s = make_story(slug: 'already-going')
      store.start_story(s['id'], claimed_by: 'claude:1:x')
      expect { Tyrion::Commands.cmd_claim(['already-going', '--as', 'lane1'], store) }
        .to raise_error(SystemExit).and output(/not pending/).to_stderr
    end
  end

  describe 'pre-claim → rung-3 adoption end to end' do
    around do |ex|
      saved = ENV.delete('TYRION_LANE')
      ENV['TYRION_LANE'] = 'lane1'
      ex.run
      saved.nil? ? ENV.delete('TYRION_LANE') : (ENV['TYRION_LANE'] = saved)
    end

    let(:real_token) { 'claude:222:realstamp' }

    before do
      allow(Tyrion::Commands).to receive(:current_lane_token).and_return(real_token)
      stub_repo(active_story: nil)
    end

    it 'adopts the pre-claimed story and re-stamps to the real token, still pending' do
      make_story(slug: 'work-me')
      Tyrion::Commands.cmd_claim(['work-me', '--as', 'lane1'], store)

      resolved = Tyrion::Commands.resolve_my_story(store, epic,
        explicit_slug: nil, claim_if_none: false)

      expect(resolved['slug']).to eq 'work-me'
      reloaded = store.find_story(epic['id'], 'work-me')
      expect(reloaded['claimed_by']).to eq real_token
      expect(reloaded['status']).to eq 'pending'
    end
  end

  describe 'cmd_dispatch (tyrion dispatch <slug> --to <label>)' do
    it 'starts the story immediately in_progress with dispatched: prefix' do
      make_story(slug: 'dispatch-me')

      expect { Tyrion::Commands.cmd_dispatch(['dispatch-me', '--to', 'lane2', 'begin impl'], store) }
        .to output(/Dispatched.*dispatch-me.*dispatched:lane2/m).to_stdout

      story = store.find_story(epic['id'], 'dispatch-me')
      expect(story['status']).to eq 'in_progress'
      expect(story['claimed_by']).to eq 'dispatched:lane2'
      expect(story['current_context']).to eq 'begin impl'
    end

    it 'records a progress note at dispatch time' do
      make_story(slug: 'dispatch-me')
      Tyrion::Commands.cmd_dispatch(['dispatch-me', '--to', 'lane2', 'start impl'], store)
      story = store.find_story(epic['id'], 'dispatch-me')
      notes = store.notes_for_story(story['id'], limit: 5)
      expect(notes.map { |n| n['body'] }).to include(match(/dispatched to lane2/))
    end

    it 'dies with usage when --to is missing' do
      make_story(slug: 'dispatch-me')
      expect { Tyrion::Commands.cmd_dispatch(['dispatch-me'], store) }
        .to raise_error(SystemExit).and output(/Usage: tyrion dispatch/).to_stderr
    end

    it 'dies when story not found' do
      expect { Tyrion::Commands.cmd_dispatch(['nope', '--to', 'lane2'], store) }
        .to raise_error(SystemExit).and output(/not found/).to_stderr
    end

    it 'dies when story is not pending' do
      s = make_story(slug: 'already-going')
      store.start_story(s['id'], claimed_by: 'claude:1:x')
      expect { Tyrion::Commands.cmd_dispatch(['already-going', '--to', 'lane2'], store) }
        .to raise_error(SystemExit).and output(/not pending/).to_stderr
    end
  end

  describe 'cmd_start adopts dispatched story' do
    let(:real_token) { 'claude:999:adoptstamp' }
    before { allow(Tyrion::Commands).to receive(:current_lane_token).and_return(real_token) }

    it 'adopts a dispatched story and re-stamps claimed_by to the real token' do
      make_story(slug: 'adopt-me')
      Tyrion::Commands.cmd_dispatch(['adopt-me', '--to', 'lane3', 'context'], store)

      expect { Tyrion::Commands.cmd_start(['adopt-me'], store) }
        .to output(/Adopted.*adopt-me/).to_stdout

      story = store.find_story(epic['id'], 'adopt-me')
      expect(story['status']).to eq 'in_progress'
      expect(story['claimed_by']).to eq real_token
    end
  end

  describe 'cmd_violations' do
    it 'reports unclaimed in_progress stories as violations' do
      s = make_story(slug: 'unclaimed-story')
      store.start_story(s['id'], claimed_by: nil)

      expect { Tyrion::Commands.cmd_violations([], store) }
        .to output(/unclaimed.*in_progress.*protocol violation/i).to_stdout
    end

    it 'reports clean when all in_progress stories are claimed' do
      s = make_story(slug: 'claimed-story')
      store.start_story(s['id'], claimed_by: 'claude:1:x')

      expect { Tyrion::Commands.cmd_violations([], store) }
        .to output(/No dispatch violations/).to_stdout
    end
  end
end
